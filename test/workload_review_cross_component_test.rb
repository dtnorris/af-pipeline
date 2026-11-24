# frozen_string_literal: true

require_relative "test_helper"
require "csv"
require "digest"
require "open3"
require "rbconfig"

class WorkloadReviewCrossComponentTest < Minitest::Test
  AFW_ROOT = File.expand_path(ENV.fetch("AF_AFW_ROOT"))
  AFW_EXECUTABLE = File.join(AFW_ROOT, "bin", "afw-workload-evidence")
  PIPELINE_EXECUTABLE = File.expand_path("../bin/af-data", __dir__)
  FIXTURE_PATH = File.join(AFW_ROOT, "test", "support", "workload_scoring_evidence_fixture.rb")

  unless File.file?(FIXTURE_PATH) && File.executable?(AFW_EXECUTABLE)
    raise "AFW_ROOT must identify an af-workloads checkout with the public workload-evidence CLI and fixture builder"
  end

  require FIXTURE_PATH

  def setup
    @workspace = Dir.mktmpdir("workload-review-cross-component-test")
    @synthetic_afw_root = File.join(@workspace, "afw")
  end

  def teardown
    FileUtils.rm_rf(@workspace)
  end

  def test_real_producer_complete_scalar_and_levels_workload_has_no_false_unresolved_cases
    fixture = WorkloadScoringEvidenceFixture.new(
      root: @synthetic_afw_root,
      cases: [
        case_spec("ready-scalar", "ADV-0001", "Seriousness"),
        case_spec("ready-levels", "ADV-0002", "Levels", metrics: ["Level Start", "Level End"])
      ]
    )

    publication = publish(fixture)
    assert publication.fetch("evidence_complete")
    assert_equal 2, publication.fetch("intended_cases")
    assert_equal 2, publication.fetch("receipt_count")
    assert_equal 3, publication.fetch("review_candidate_count")
    manifest_path = File.join(@synthetic_afw_root, publication.fetch("manifest_path"))
    producer_snapshot = file_snapshot(@synthetic_afw_root)

    stdout = prepare_review(manifest_path)
    assert_includes stdout, "Workload evidence complete: true"
    assert_includes stdout, "Unresolved cases: 0"
    assert_empty File.binread(File.join(review_dir, "unresolved_cases.jsonl"))
    candidates = read_jsonl(File.join(review_dir, "candidates.jsonl"))
    assert_equal 3, candidates.length
    assert_equal 3, candidates.map { |row| row.fetch("candidate_key") }.uniq.length
    assert_equal producer_snapshot, file_snapshot(@synthetic_afw_root)
  end

  def test_real_producer_partial_manifest_replays_without_claiming_complete_scoring
    fixture = WorkloadScoringEvidenceFixture.new(
      root: @synthetic_afw_root,
      cases: [
        case_spec("ready-scalar", "ADV-0001", "Seriousness"),
        case_spec("ready-levels", "ADV-0002", "Levels", metrics: ["Level Start", "Level End"]),
        case_spec("failed", "ADV-0003", "Seriousness"),
        case_spec("interrupted", "ADV-0004", "Seriousness"),
        case_spec("pending", "ADV-0005", "Seriousness"),
        case_spec("running", "ADV-0006", "Seriousness"),
        case_spec("missing-evidence", "ADV-0007", "Seriousness"),
        case_spec("ambiguous-evidence", "ADV-0008", "Seriousness")
      ]
    )
    fixture.write_metadata("failed", "status" => "failed", "exit_status" => 7)
    fixture.write_metadata("interrupted", "status" => "interrupted", "exit_status" => 130)
    fixture.remove_metadata("pending")
    rewrite_metadata(fixture.metadata_path("running")) do |metadata|
      metadata.delete("exit_status")
      metadata.delete("completed_at")
      metadata["status"] = "running"
    end
    FileUtils.rm_f(fixture.assessment_path("missing-evidence"))
    fixture.add_evidence_set("ambiguous-evidence", "20261011T120130Z_duplicate")

    publication = publish(fixture)
    refute publication.fetch("evidence_complete")
    assert_equal 8, publication.fetch("intended_cases")
    assert_equal 2, publication.fetch("receipt_count")
    assert_equal 3, publication.fetch("review_candidate_count")
    manifest_path = File.join(@synthetic_afw_root, publication.fetch("manifest_path"))
    producer_snapshot = file_snapshot(@synthetic_afw_root)

    first_stdout = prepare_review(manifest_path)
    assert_includes first_stdout, "Intended cases: 8"
    assert_includes first_stdout, "Evidence-ready cases: 2"
    assert_includes first_stdout, "Unresolved cases: 6"
    assert_includes first_stdout, "Candidate rows: 3"
    assert_includes first_stdout, "Workload evidence complete: false"

    package = read_json(File.join(review_dir, "review_package.json"))
    report = read_json(File.join(review_dir, "integrity_report.json"))
    candidates = read_jsonl(File.join(review_dir, "candidates.jsonl"))
    unresolved = read_jsonl(File.join(review_dir, "unresolved_cases.jsonl"))
    candidate_counts = package.fetch("case_accounting").filter_map do |row|
      row.fetch("candidate_keys").length if row.fetch("candidate_keys").any?
    end
    assert_equal [1, 2], candidate_counts
    assert_equal 3, candidates.map { |row| row.fetch("candidate_key") }.uniq.length
    assert_equal 8, report.fetch("intended_cases")
    assert_equal 2, report.fetch("ready_cases")
    assert_equal 6, report.fetch("unresolved_cases")
    refute report.fetch("workload_evidence_complete")
    assert_equal(
      %w[ambiguous_scoring_evidence missing_scoring_evidence wlo_attempt_failed
         wlo_attempt_interrupted wlo_attempt_running wlo_attempt_unstarted].sort,
      unresolved.map { |row| row.dig("classification", "reason") }.sort
    )
    assert_equal "review_only_no_retry_scoring_policy_acceptance_or_catalog_mutation",
                 package.fetch("mutation_boundary")

    ledger = File.join(audit_dir, "editorial_decisions.csv")
    decide_all_candidates(ledger)
    ledger_bytes = File.binread(ledger)
    generated_bytes = generated_review_bytes
    FileUtils.rm_r(review_dir)

    replay_stdout = prepare_review(manifest_path)
    assert_includes replay_stdout, "Workload evidence complete: false"
    assert_includes replay_stdout, "Editorial complete: true"
    assert_includes replay_stdout, "unresolved workload cases remain explicit"
    assert_equal generated_bytes, generated_review_bytes
    assert_equal ledger_bytes, File.binread(ledger)
    assert_equal producer_snapshot, file_snapshot(@synthetic_afw_root)
    refute File.exist?(File.join(@workspace, "catalog"))
  end

  def test_real_producer_preserves_authorized_retry_and_newer_authoritative_attempt
    fixture = WorkloadScoringEvidenceFixture.new(
      root: @synthetic_afw_root,
      cases: [
        case_spec("retry-pending", "ADV-0001", "Seriousness"),
        case_spec("completed-retry", "ADV-0002", "Seriousness")
      ]
    )
    fixture.write_archived_attempt("retry-pending", 1)
    fixture.write_metadata("retry-pending", "status" => "failed", "attempt" => 1, "exit_status" => 1)
    fixture.write_archived_attempt("completed-retry", 1)
    fixture.write_metadata("completed-retry", "attempt" => 2)
    fixture.write_execution("status" => "pending", "retry_pending" => { "retry-pending" => 1 })

    publication = publish(fixture)
    manifest_path = File.join(@synthetic_afw_root, publication.fetch("manifest_path"))
    manifest = read_json(manifest_path)
    producer_snapshot = file_snapshot(@synthetic_afw_root)
    prepare_review(manifest_path)

    unresolved = read_jsonl(File.join(review_dir, "unresolved_cases.jsonl")).fetch(0)
    candidate = read_jsonl(File.join(review_dir, "candidates.jsonl")).fetch(0)
    completed = manifest.fetch("cases").find { |row| row.fetch("case_id") == "completed-retry" }
    assert_equal "wlo_retry_authorized", unresolved.dig("classification", "reason")
    assert_equal 1, unresolved.dig("authoritative_attempt", "attempt")
    assert_equal 2, candidate.fetch("wlo_attempt")
    superseded_attempts = completed.dig("execution", "authoritative_attempt", "superseded_attempts").map do |attempt|
      attempt.fetch("attempt")
    end
    assert_equal [1], superseded_attempts
    assert_equal producer_snapshot, file_snapshot(@synthetic_afw_root)
  end

  def test_real_producer_emits_immutable_revision_for_conflicting_existing_receipt
    fixture = WorkloadScoringEvidenceFixture.new(
      root: @synthetic_afw_root,
      cases: [case_spec("receipt-conflict", "ADV-0001", "Seriousness")]
    )
    first = publish(fixture)
    first_path = File.join(@synthetic_afw_root, first.fetch("manifest_path"))
    first_bytes = File.binread(first_path)
    fixture.write_archived_attempt("receipt-conflict", 1)
    fixture.write_metadata("receipt-conflict", "attempt" => 2)

    second = publish(fixture)
    second_path = File.join(@synthetic_afw_root, second.fetch("manifest_path"))
    refute_equal first.fetch("manifest_id"), second.fetch("manifest_id")
    refute second.fetch("evidence_complete")
    assert_equal first_bytes, File.binread(first_path)
    assert_equal first.fetch("manifest_id"), validate_manifest(first.fetch("manifest_path")).fetch("manifest_id")

    prepare_review(second_path)
    assert_empty File.binread(File.join(review_dir, "candidates.jsonl"))
    unresolved = read_jsonl(File.join(review_dir, "unresolved_cases.jsonl")).fetch(0)
    assert_equal "receipt_conflict", unresolved.dig("classification", "reason")
  end

  private

  def case_spec(job_id, adventure_id, dimension, metrics: nil)
    { job_id:, adventure_id:, dimension:, metrics: metrics || [dimension] }
  end

  def rewrite_metadata(path)
    metadata = read_json(path)
    yield metadata
    File.binwrite(path, JSON.pretty_generate(metadata) + "\n")
  end

  def publish(fixture)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, AFW_EXECUTABLE, "--data-root", @synthetic_afw_root, "publish", fixture.workload_id, fixture.wlo
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def validate_manifest(relative_path)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, AFW_EXECUTABLE, "--data-root", @synthetic_afw_root, "validate", relative_path
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def prepare_review(manifest_path)
    stdout, stderr, status = Open3.capture3(
      {"AF_DATA_PIPELINE_DATA_ROOT" => File.realpath(@workspace)},
      RbConfig.ruby, PIPELINE_EXECUTABLE, "prepare-workload-review", manifest_path,
      "--afw-root", @synthetic_afw_root, "--review-dir", review_dir, "--audit-dir", audit_dir
    )
    assert status.success?, stderr
    stdout
  end

  def review_dir
    File.join(@workspace, "review")
  end

  def audit_dir
    File.join(@workspace, "audit")
  end

  def read_json(path)
    JSON.parse(File.binread(path))
  end

  def read_jsonl(path)
    File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
  end

  def decide_all_candidates(path)
    table = CSV.read(path, headers: true)
    %w[ACCEPT HOLD REJECT].zip(table).each do |decision, row|
      row["editorial_decision"] = decision
      row["editorial_note"] = "preserved #{decision.downcase} note" unless decision == "ACCEPT"
    end
    CSV.open(path, "w") do |csv|
      csv << table.headers
      table.each { |row| csv << table.headers.map { |header| row[header] } }
    end
  end

  def generated_review_bytes
    Dir.children(review_dir).sort.to_h do |name|
      [name, File.binread(File.join(review_dir, name))]
    end
  end

  def file_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.to_h do |path|
      [Pathname.new(path).relative_path_from(Pathname.new(root)).to_s, Digest::SHA256.file(path).hexdigest]
    end
  end
end
