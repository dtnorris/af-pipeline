# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ScoringReviewPackageTest < Minitest::Test
  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end

  def digest(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def write_fixture(root, overrides = nil, **keyword_overrides)
    overrides = (overrides || {}).merge(keyword_overrides)
    dimension = overrides.fetch(:dimension, "Seriousness")
    afw = File.join(root, "afw")
    assessment_path = File.join(afw, "output", "scoring", "assessments", "ADV-0042_run-7.csv")
    request_path = File.join(afw, "output", "scoring", "raw", "ADV-0042", "run-7", "score_request.json")
    response_path = File.join(afw, "output", "scoring", "raw", "ADV-0042", "run-7", "score.json")
    receipt_path = File.join(afw, "output", "workloads", "plan-1", "evidence", "job-1.json")
    [assessment_path, request_path, response_path, receipt_path].each { |path| FileUtils.mkdir_p(File.dirname(path)) }

    headers = %w[
      run_id status adventure_id adventure_title source_book metric metric_kind value range_low range_high confidence
      path_sensitive path_variation_affects_anchor assessment_state rationale adjacent_lower_reason adjacent_higher_reason
      evidence review_disposition hold_reason metric_review_flags package_review_flags afao_version assessment_spec_version
      provider model
    ]
    row = {
      "run_id" => "run-7", "status" => "PROPOSED", "adventure_id" => "ADV-0042",
      "adventure_title" => "The Answer", "source_book" => "Fixture", "metric" => dimension,
      "metric_kind" => "ordinal", "value" => "3", "confidence" => "0.9", "path_sensitive" => "false",
      "path_variation_affects_anchor" => "false", "assessment_state" => "resolved",
      "rationale" => "The evidence supports anchor three.", "adjacent_lower_reason" => "Too mild.",
      "adjacent_higher_reason" => "Too severe.", "evidence" => JSON.generate(["fixture evidence"]),
      "review_disposition" => "REVIEW_REQUIRED", "metric_review_flags" => "",
      "package_review_flags" => "", "afao_version" => "1.0", "assessment_spec_version" => "1.0",
      "provider" => "ollama", "model" => "fixture-model"
    }.merge(overrides.fetch(:row, {}))
    rows = overrides.fetch(:metrics, [row.fetch("metric")]).map { |metric| row.merge("metric" => metric) }
    assessment_bytes = CSV.generate do |csv|
      csv << headers
      rows.each { |assessment_row| csv << headers.map { |header| assessment_row[header] } }
    end
    request_bytes = JSON.generate({ "request" => "fixture" }) + "\n"
    response_bytes = JSON.generate({ "response" => "fixture" }) + "\n"
    File.binwrite(assessment_path, assessment_bytes)
    File.binwrite(request_path, request_bytes)
    File.binwrite(response_path, response_bytes)

    relative = ->(path) { Pathname.new(path).relative_path_from(Pathname.new(afw)).to_s }
    body = {
      "contract_version" => "afw-scoring-evidence-receipt/v0.1",
      "semantic_status" => "provenance_validated_proposed_scoring_evidence",
      "workload" => {
        "plan_id" => "plan-1", "plan_sha256" => "a" * 64, "job_id" => "job-1", "pool_id" => "gpu"
      },
      "scoring_intent" => {
        "case_id" => "job-1", "adventure_id" => "ADV-0042", "dimension" => dimension,
        "profile" => "fixture", "model_alias" => "fixture", "ollama_model" => "fixture-model"
      },
      "attempt" => { "job_id" => "job-1", "attempt" => 2, "status" => "complete", "exit_status" => 0 },
      "scorer_provenance" => {
        "scorer_commit" => "b" * 40, "qualified_model_digest" => "sha256:fixture",
        "prompt_sha256" => "c" * 64, "schema_sha256" => "d" * 64
      },
      "artifacts" => {
        "run_id" => "run-7",
        "proposed_assessment" => { "path" => relative.call(assessment_path), "sha256" => digest(assessment_bytes) },
        "raw_request" => { "path" => relative.call(request_path), "sha256" => digest(request_bytes) },
        "raw_response" => { "path" => relative.call(response_path), "sha256" => digest(response_bytes) }
      }
    }
    body.merge!(overrides.fetch(:body, {}))
    receipt = body.merge("receipt_id" => digest(JSON.generate(canonical(body))))
    receipt.merge!(overrides.fetch(:receipt, {}))
    File.binwrite(receipt_path, JSON.pretty_generate(receipt) + "\n")
    { afw:, receipt_path:, assessment_path:, request_path:, raw_response_path: response_path }
  end

  def locations(root)
    { review_dir: File.join(root, "review"), audit_dir: File.join(root, "audit") }
  end

  def prepare(fixture, root)
    AfDataPipeline::ScoringReviewPackage.prepare!(
      receipt_path: fixture.fetch(:receipt_path),
      afw_root: fixture.fetch(:afw),
      **locations(root)
    )
  end

  def rewrite_receipt(path)
    receipt = JSON.parse(File.binread(path))
    yield receipt
    body = receipt.reject { |key, _value| key == "receipt_id" }
    receipt["receipt_id"] = digest(JSON.generate(canonical(body)))
    File.binwrite(path, JSON.pretty_generate(receipt) + "\n")
  end

  def set_decision(audit_dir, decision)
    path = File.join(audit_dir, "editorial_decisions.csv")
    table = CSV.read(path, headers: true)
    table.first["editorial_decision"] = decision
    table.first["editorial_note"] = "reviewed fixture" unless decision == "ACCEPT"
    CSV.open(path, "w") do |csv|
      csv << table.headers
      table.each { |row| csv << table.headers.map { |header| row[header] } }
    end
    path
  end

  def set_decisions(audit_dir, decisions)
    path = File.join(audit_dir, "editorial_decisions.csv")
    table = CSV.read(path, headers: true)
    table.each do |row|
      decision = decisions.fetch(row.fetch("record_key"))
      row["editorial_decision"] = decision
      row["editorial_note"] = "reviewed fixture" unless decision == "ACCEPT"
    end
    CSV.open(path, "w") do |csv|
      csv << table.headers
      table.each { |row| csv << table.headers.map { |header| row[header] } }
    end
    path
  end

  def test_valid_receipt_creates_deterministic_package_and_pending_existing_ledger
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      result = prepare(fixture, root)
      manifest = JSON.parse(File.binread(File.join(result.review_dir, "review_package.json")))
      candidate = JSON.parse(File.binread(File.join(result.review_dir, "candidates.jsonl")))

      assert_equal manifest.fetch("package_id"), result.package_id
      assert_equal "pending", result.ledger_state
      assert_equal 1, manifest.fetch("candidate_count")
      assert_equal "ADV-0042::Seriousness", candidate.fetch("candidate_key")
      assert_equal %w[ACCEPT HOLD REJECT], result.next_human_decision
      assert_equal fixture.fetch(:receipt_path).delete_prefix("#{fixture.fetch(:afw)}/"), candidate.dig("provenance", "metadata", "source_path")
      assert_equal "review_only_no_canonical_or_amc_mutation", manifest["mutation_boundary"]
    end
  end

  def test_valid_levels_receipt_creates_two_distinct_candidates_and_ledger_rows
    Dir.mktmpdir do |root|
      fixture = write_fixture(root, dimension: "Levels", metrics: ["Level End", "Level Start"])
      result = prepare(fixture, root)
      candidates = File.readlines(File.join(result.review_dir, "candidates.jsonl")).map { |line| JSON.parse(line) }
      ledger = CSV.read(File.join(result.audit_dir, "editorial_decisions.csv"), headers: true)

      expected_keys = ["ADV-0042::Level End", "ADV-0042::Level Start"]
      assert_equal expected_keys, candidates.map { |candidate| candidate.fetch("candidate_key") }
      assert_equal ["Level End", "Level Start"], candidates.map { |candidate| candidate.fetch("dimension") }
      assert_equal expected_keys, ledger.map { |row| row.fetch("record_key") }
      assert_equal ["Level End", "Level Start"], ledger.map { |row| row.fetch("dimension") }
      assert_equal 2, result.pending
    end
  end

  def test_identical_levels_rerun_preserves_package_and_both_human_decisions
    Dir.mktmpdir do |root|
      fixture = write_fixture(root, dimension: "Levels", metrics: ["Level Start", "Level End"])
      first = prepare(fixture, root)
      package_before = Dir.children(first.review_dir).to_h do |name|
        [name, File.binread(File.join(first.review_dir, name))]
      end
      ledger = set_decisions(
        first.audit_dir,
        "ADV-0042::Level Start" => "ACCEPT",
        "ADV-0042::Level End" => "HOLD"
      )
      ledger_before = File.binread(ledger)

      second = prepare(fixture, root)

      assert second.reused
      assert_equal package_before, Dir.children(second.review_dir).to_h { |name| [name, File.binread(File.join(second.review_dir, name))] }
      assert_equal ledger_before, File.binread(ledger)
      assert_equal 1, second.accepted
      assert_equal 1, second.held
      assert_equal 0, second.pending
    end
  end

  {
    "without_level_start" => ["Level End"],
    "without_level_end" => ["Level Start"],
    "with_duplicate_level_start" => ["Level Start", "Level Start", "Level End"],
    "with_duplicate_level_end" => ["Level Start", "Level End", "Level End"],
    "with_unexpected_third_metric" => ["Level Start", "Level End", "Seriousness"]
  }.each do |description, metrics|
    define_method("test_rejects_levels_#{description}") do
      Dir.mktmpdir do |root|
        fixture = write_fixture(root, dimension: "Levels", metrics:)
        error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
        assert_match(/does not match the AFW receipt/, error.message)
        refute File.exist?(locations(root).fetch(:review_dir))
      end
    end
  end

  def test_identical_rerun_reuses_byte_identical_package_and_ledger
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      first = prepare(fixture, root)
      package_before = Dir.children(first.review_dir).to_h { |name| [name, File.binread(File.join(first.review_dir, name))] }
      ledger_before = File.binread(File.join(first.audit_dir, "editorial_decisions.csv"))
      second = prepare(fixture, root)

      assert second.reused
      assert_equal first.package_id, second.package_id
      assert_equal package_before, Dir.children(second.review_dir).to_h { |name| [name, File.binread(File.join(second.review_dir, name))] }
      assert_equal ledger_before, File.binread(File.join(second.audit_dir, "editorial_decisions.csv"))
    end
  end

  %w[ACCEPT HOLD REJECT].each do |decision|
    define_method("test_repeat_preserves_#{decision.downcase}_decision") do
      Dir.mktmpdir do |root|
        fixture = write_fixture(root)
        first = prepare(fixture, root)
        ledger = set_decision(first.audit_dir, decision)
        before = File.binread(ledger)
        result = prepare(fixture, root)

        assert_equal before, File.binread(ledger)
        assert_equal 0, result.pending
        assert_nil result.next_human_decision
        count_method = { "ACCEPT" => :accepted, "HOLD" => :held, "REJECT" => :rejected }.fetch(decision)
        assert_equal 1, result.public_send(count_method)
      end
    end
  end

  def test_rejects_unsupported_contract
    assert_invalid_receipt(body: { "contract_version" => "afw-scoring-evidence-receipt/v9" }, message: /unsupported/)
  end

  def test_rejects_wrong_semantic_status
    assert_invalid_receipt(body: { "semantic_status" => "accepted" }, message: /not provenance-validated/)
  end

  def test_rejects_forged_receipt_identity
    assert_invalid_receipt(receipt: { "receipt_id" => "0" * 64 }, message: /identity mismatch/)
  end

  def test_rejects_malformed_receipt_json
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      File.binwrite(fixture.fetch(:receipt_path), "{not-json\n")
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/malformed AFW receipt/, error.message)
      refute File.exist?(locations(root).fetch(:review_dir))
    end
  end

  def test_rejects_missing_artifact
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      FileUtils.rm(fixture.fetch(:raw_response_path))
      assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
    end
  end

  def test_rejects_artifact_digest_mismatch
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      File.binwrite(fixture.fetch(:raw_response_path), "changed\n")
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/digest mismatch/, error.message)
    end
  end

  def test_rejects_artifact_path_escape_before_consumption
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      outside = File.join(root, "outside.json")
      File.binwrite(outside, "outside\n")
      rewrite_receipt(fixture.fetch(:receipt_path)) do |receipt|
        receipt.fetch("artifacts").fetch("raw_response")["path"] = "../outside.json"
        receipt.fetch("artifacts").fetch("raw_response")["sha256"] = digest("outside\n")
      end
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/escapes AFW root/, error.message)
    end
  end

  def test_rejects_assessment_identity_mismatch_even_with_updated_digest
    Dir.mktmpdir do |root|
      fixture = write_fixture(root, row: { "run_id" => "other-run" })
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/does not match/, error.message)
    end
  end

  def test_changed_upstream_provenance_conflicts_with_existing_package
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      prepare(fixture, root)
      changed = "changed response\n"
      File.binwrite(fixture.fetch(:raw_response_path), changed)
      rewrite_receipt(fixture.fetch(:receipt_path)) do |receipt|
        receipt.fetch("artifacts").fetch("raw_response")["sha256"] = digest(changed)
      end

      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/conflicts/, error.message)
    end
  end

  def test_conflicting_existing_package_bytes_fail_closed
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      result = prepare(fixture, root)
      File.binwrite(File.join(result.review_dir, "review_package.json"), "{}\n")
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/conflicts/, error.message)
    end
  end

  def test_tampered_ledger_fails_without_overwriting_human_state
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      result = prepare(fixture, root)
      ledger = File.join(result.audit_dir, "editorial_decisions.csv")
      table = CSV.read(ledger, headers: true)
      table.first["proposed_value"] = "999"
      CSV.open(ledger, "w") do |csv|
        csv << table.headers
        table.each { |row| csv << table.headers.map { |header| row[header] } }
      end
      tampered = File.binread(ledger)

      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/immutable ledger field proposed_value changed/, error.message)
      assert_equal tampered, File.binread(ledger)
    end
  end

  def test_incomplete_existing_audit_fails_closed
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      result = prepare(fixture, root)
      FileUtils.rm(File.join(result.audit_dir, "audit_manifest.json"))
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/incomplete/, error.message)
    end
  end

  def test_prepare_does_not_mutate_canonical_or_amc_files
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      canonical = File.join(root, "canonical.json")
      amc = File.join(root, "AMC.xlsx")
      File.binwrite(canonical, "canonical bytes\n")
      File.binwrite(amc, "amc bytes\n")
      before = [File.binread(canonical), File.binread(amc)]
      prepare(fixture, root)
      prepare(fixture, root)
      assert_equal before, [File.binread(canonical), File.binread(amc)]
    end
  end

  def test_cli_reports_package_ledger_and_exact_next_decision
    Dir.mktmpdir do |root|
      fixture = write_fixture(root)
      out = StringIO.new
      err = StringIO.new
      dirs = locations(root)
      status = AfDataPipeline::CLI.run(
        ["prepare-review", fixture.fetch(:receipt_path), "--afw-root", fixture.fetch(:afw),
         "--review-dir", dirs.fetch(:review_dir), "--audit-dir", dirs.fetch(:audit_dir)],
        out:, err:
      )

      assert_equal 0, status, err.string
      assert_match(/Review package ID: [0-9a-f]{64}/, out.string)
      assert_includes out.string, "Ledger state: pending"
      assert_includes out.string, "choose ACCEPT/HOLD/REJECT"
    end
  end

  def test_cli_fails_closed_for_invalid_receipt
    Dir.mktmpdir do |root|
      fixture = write_fixture(root, receipt: { "receipt_id" => "f" * 64 })
      out = StringIO.new
      err = StringIO.new
      dirs = locations(root)
      status = AfDataPipeline::CLI.run(
        ["prepare-review", fixture.fetch(:receipt_path), "--afw-root", fixture.fetch(:afw),
         "--review-dir", dirs.fetch(:review_dir), "--audit-dir", dirs.fetch(:audit_dir)],
        out:, err:
      )
      assert_equal 2, status
      assert_match(/identity mismatch/, err.string)
      refute File.exist?(dirs.fetch(:review_dir))
    end
  end

  private

  def assert_invalid_receipt(body: {}, receipt: {}, message:)
    Dir.mktmpdir do |root|
      fixture = write_fixture(root, body:, receipt:)
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match message, error.message
      refute File.exist?(locations(root).fetch(:review_dir))
    end
  end
end
