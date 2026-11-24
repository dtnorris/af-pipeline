# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class WorkloadScoringReviewPackageTest < Minitest::Test
  HEAD = "b" * 40
  MODEL = "fixture-model"
  INDEX_HEADERS = %w[
    case_id adventure_id dimension profile model_alias ollama_model qualified_model_digest
    qualification_sha256 runtime_sha256 preflight_sha256 case_path
  ].freeze
  ASSESSMENT_HEADERS = %w[
    run_id status adventure_id adventure_title source_book metric metric_kind value range_low range_high confidence
    path_sensitive path_variation_affects_anchor assessment_state rationale adjacent_lower_reason adjacent_higher_reason
    evidence review_disposition hold_reason metric_review_flags package_review_flags afao_version assessment_spec_version
    provider model
  ].freeze

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

  def json_bytes(value)
    JSON.pretty_generate(value) + "\n"
  end

  def reference(root, path)
    bytes = File.binread(path)
    {
      "root" => root,
      "path" => Pathname.new(path).relative_path_from(Pathname.new(root == "afw" ? @afw : @wlo)).to_s,
      "sha256" => digest(bytes)
    }
  end

  def embedded(path)
    bytes = File.binread(path)
    {
      "source" => reference("wlo", path),
      "encoding" => "hex",
      "content" => bytes.unpack1("H*")
    }
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(File.dirname(path))
    CSV.open(path, "w") do |csv|
      csv << headers
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def write_workload_fixture(root, states: %i[ready ready], identities: nil)
    @afw = File.join(root, "afw")
    @wlo = File.join(root, "wlo")
    FileUtils.mkdir_p(@afw)
    FileUtils.mkdir_p(@wlo)
    identities ||= [
      { case_id: "job-scalar", adventure_id: "ADV-0001", dimension: "Seriousness", metrics: ["Seriousness"] },
      { case_id: "job-levels", adventure_id: "ADV-0002", dimension: "Levels", metrics: ["Level Start", "Level End"] }
    ]
    bindings = {
      "profile" => "production", "model_alias" => "fixture", "ollama_model" => MODEL,
      "qualified_model_digest" => "a" * 64, "qualification_sha256" => "1" * 64,
      "runtime_sha256" => "2" * 64, "preflight_sha256" => "3" * 64
    }
    rows = []
    jobs = []
    case_paths = {}
    identities.each do |spec|
      case_path = File.join(@afw, "build", "cases", "#{spec.fetch(:case_id)}.yml")
      FileUtils.mkdir_p(File.dirname(case_path))
      case_data = bindings.merge(
        "contract_version" => "afw-workload/v0.1", "workload_id" => "batch",
        "case_id" => spec.fetch(:case_id), "adventure_id" => spec.fetch(:adventure_id),
        "dimension" => spec.fetch(:dimension), "scorer_commit" => HEAD
      )
      File.write(case_path, YAML.dump(case_data))
      relative_case = Pathname.new(case_path).relative_path_from(Pathname.new(@afw)).to_s
      row = {
        "case_id" => spec.fetch(:case_id), "adventure_id" => spec.fetch(:adventure_id),
        "dimension" => spec.fetch(:dimension), "case_path" => relative_case
      }.merge(bindings)
      rows << row
      jobs << {
        "job_id" => spec.fetch(:case_id), "pool_id" => "fixture", "group_id" => spec.fetch(:adventure_id),
        "argv" => ["bin/afw-score-job", relative_case], "env" => {}, "depends_on_job_ids" => []
      }
      case_paths[spec.fetch(:case_id)] = case_path
    end

    workload_dir = File.join(@afw, "workloads", "batch")
    FileUtils.mkdir_p(workload_dir)
    plan = {
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => "batch",
      "failure_policy" => {}, "pools" => [], "jobs" => jobs
    }
    plan_path = File.join(workload_dir, "execution-plan.json")
    File.binwrite(plan_path, json_bytes(plan))
    snapshot = {
      "contract_version" => "afw-workload/v0.1", "workload_id" => "batch", "scorer_commit" => HEAD,
      "execution_plan_sha256" => digest(File.binread(plan_path))
    }
    snapshot_path = File.join(workload_dir, "snapshot.yml")
    File.write(snapshot_path, YAML.dump(snapshot))
    index_path = File.join(workload_dir, "case_index.csv")
    write_csv(index_path, INDEX_HEADERS, rows)
    wlo_plan_path = File.join(@wlo, "plan.json")
    File.binwrite(wlo_plan_path, File.binread(plan_path))
    wlo_execution_path = File.join(@wlo, "execution.json")
    retry_pending = states.each_with_index.each_with_object({}) do |(state, index), pending|
      pending[identities.fetch(index).fetch(:case_id)] = 1 if state == :retry_pending
    end
    File.binwrite(wlo_execution_path, json_bytes(
      "contract_version" => "wlo-execution-state/v0.1", "plan_id" => "batch",
      "plan_sha256" => digest(File.binread(plan_path)), "status" => "completed",
      "retry_pending" => retry_pending
    ))

    manifest_cases = identities.each_with_index.map do |spec, index|
      state = states.fetch(index)
      job = jobs.fetch(index)
      metadata_path = File.join(@wlo, "runs", spec.fetch(:case_id), "metadata.json")
      attempt_number = state == :superseded_ready ? 2 : 1
      metadata_status, exit_status = attempt_status(state)
      metadata = if state == :pending
                   nil
                 else
                   FileUtils.mkdir_p(File.dirname(metadata_path))
                   value = {
                     "job_id" => spec.fetch(:case_id), "pool_id" => "fixture", "argv" => job.fetch("argv"),
                     "attempt" => attempt_number, "status" => metadata_status, "exit_status" => exit_status
                   }
                   File.binwrite(metadata_path, json_bytes(value))
                   value
                 end
      superseded = superseded_attempt(spec, job, state)
      attempt = metadata && {
        "job_id" => spec.fetch(:case_id), "attempt" => attempt_number, "status" => metadata.fetch("status"),
        "exit_status" => metadata.fetch("exit_status"),
        "evidence_path" => reference("wlo", metadata_path).fetch("path"),
        "evidence_sha256" => reference("wlo", metadata_path).fetch("sha256"),
        "superseded_attempts" => superseded.fetch(:identities)
      }
      receipt = if %i[ready superseded_ready].include?(state)
                  write_receipt(
                    spec:, bindings:, attempt:, plan_path:, snapshot_path:, index_path:,
                    case_path: case_paths.fetch(spec.fetch(:case_id))
                  )
                end
      {
        "case_id" => spec.fetch(:case_id), "adventure_id" => spec.fetch(:adventure_id),
        "dimension" => spec.fetch(:dimension),
        "intent" => { "case_index_row" => rows.fetch(index), "case" => reference("afw", case_paths.fetch(spec.fetch(:case_id))) },
        "job" => {
          "job_id" => job.fetch("job_id"), "pool_id" => job.fetch("pool_id"), "group_id" => job.fetch("group_id"),
          "argv_sha256" => digest(JSON.generate(canonical(job.fetch("argv")))),
          "plan_job_sha256" => digest(JSON.generate(canonical(job)))
        },
        "classification" => classification(state),
        "execution" => {
          "current_attempt" => metadata && embedded(metadata_path).merge(
            "retained_superseded_attempts" => superseded.fetch(:snapshots)
          ),
          "authoritative_attempt" => attempt
        },
        "receipt" => receipt && {
          "reference" => reference("afw", receipt.fetch(:path)), "receipt_id" => receipt.fetch(:document).fetch("receipt_id"),
          "contract_version" => "afw-scoring-evidence-receipt/v0.1",
          "semantic_status" => "provenance_validated_proposed_scoring_evidence",
          "review_candidate_count" => spec.fetch(:metrics).length
        }
      }
    end

    evidence_counts = manifest_cases.map { |row| row.dig("classification", "evidence_status") }.tally.sort.to_h
    execution_counts = manifest_cases.map { |row| row.dig("classification", "execution_status") }.tally.sort.to_h
    receipts = manifest_cases.filter_map { |row| row["receipt"] }
    summary = {
      "intended_cases" => identities.length, "classified_cases" => identities.length, "accounting_complete" => true,
      "execution_counts" => execution_counts, "evidence_counts" => evidence_counts,
      "receipt_count" => receipts.length,
      "review_candidate_count" => receipts.sum { |receipt| receipt.fetch("review_candidate_count") },
      "evidence_complete" => evidence_counts.fetch("ready", 0) == identities.length
    }
    body = {
      "contract_version" => "afw-workload-evidence-manifest/v0.1",
      "semantic_status" => "authoritative_workload_evidence_snapshot",
      "workload" => {
        "plan_id" => "batch", "intended_case_count" => identities.length,
        "afw" => {
          "execution_plan" => reference("afw", plan_path), "snapshot" => reference("afw", snapshot_path),
          "case_index" => reference("afw", index_path)
        },
        "wlo" => {
          "plan" => reference("wlo", wlo_plan_path), "execution" => embedded(wlo_execution_path),
          "execution_contract" => "wlo-execution-state/v0.1", "execution_status" => "completed"
        }
      },
      "summary" => summary,
      "cases" => manifest_cases
    }
    document = body.merge("manifest_id" => digest(JSON.generate(canonical(body))))
    manifest_path = File.join(@afw, "output", "workloads", "batch", "evidence", "manifests", "fixture.json")
    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.binwrite(manifest_path, json_bytes(document))
    { afw: @afw, manifest_path:, document: }
  end

  def attempt_status(state)
    case state
    when :ready, :superseded_ready, :missing_evidence, :ambiguous_evidence then ["complete", 0]
    when :failed, :retry_pending then ["failed", 7]
    when :interrupted then ["interrupted", 130]
    when :running then ["running", nil]
    when :pending then [nil, nil]
    else raise "unknown fixture state #{state.inspect}"
    end
  end

  def superseded_attempt(spec, job, state)
    return { identities: [], snapshots: [] } unless state == :superseded_ready

    path = File.join(@wlo, "runs", spec.fetch(:case_id), "attempts", "1", "metadata.json")
    FileUtils.mkdir_p(File.dirname(path))
    metadata = {
      "job_id" => spec.fetch(:case_id), "pool_id" => "fixture", "argv" => job.fetch("argv"),
      "attempt" => 1, "status" => "failed", "exit_status" => 7
    }
    File.binwrite(path, json_bytes(metadata))
    identity = {
      "job_id" => spec.fetch(:case_id), "attempt" => 1, "status" => "failed", "exit_status" => 7,
      "evidence_path" => reference("wlo", path).fetch("path"),
      "evidence_sha256" => reference("wlo", path).fetch("sha256")
    }
    { identities: [identity], snapshots: [embedded(path)] }
  end

  def classification(state)
    values = case state
             when :ready, :superseded_ready then ["evidenced", "receipt_valid", "complete", "ready"]
             when :failed then ["failed", "wlo_attempt_failed", "failed", "unresolved"]
             when :interrupted then ["interrupted", "wlo_attempt_interrupted", "interrupted", "unresolved"]
             when :running then ["running", "wlo_attempt_running", "running", "unresolved"]
             when :pending then ["pending", "wlo_attempt_unstarted", "pending", "unresolved"]
             when :retry_pending then ["pending", "wlo_retry_authorized", "pending", "unresolved"]
             when :missing_evidence then ["unsafe", "missing_scoring_evidence", "complete", "unresolved"]
             when :ambiguous_evidence then ["unsafe", "ambiguous_scoring_evidence", "complete", "unresolved"]
             else raise "unknown fixture state #{state.inspect}"
             end
    %w[outcome reason execution_status evidence_status].zip(values).to_h
  end

  def write_receipt(spec:, bindings:, attempt:, plan_path:, snapshot_path:, index_path:, case_path:)
    run_id = "run-#{spec.fetch(:case_id)}"
    result_dir = File.join(@afw, "output", "results", spec.fetch(:case_id))
    assessment_path = File.join(result_dir, "assessment.csv")
    request_path = File.join(result_dir, "request.json")
    response_path = File.join(result_dir, "response.json")
    row = {
      "run_id" => run_id, "status" => "PROPOSED", "adventure_id" => spec.fetch(:adventure_id),
      "adventure_title" => "Fixture", "source_book" => "Fixture", "metric_kind" => "ordinal",
      "value" => "3", "confidence" => "0.9", "path_sensitive" => "false",
      "path_variation_affects_anchor" => "false", "assessment_state" => "resolved",
      "rationale" => "Synthetic evidence supports the proposed value.", "evidence" => "[]",
      "review_disposition" => "REVIEW_REQUIRED", "afao_version" => "1.6.1",
      "assessment_spec_version" => "0.1", "provider" => "ollama", "model" => MODEL
    }
    write_csv(assessment_path, ASSESSMENT_HEADERS, spec.fetch(:metrics).map { |metric| row.merge("metric" => metric) })
    File.binwrite(request_path, "{}\n")
    File.binwrite(response_path, "{}\n")
    relative = ->(path) { Pathname.new(path).relative_path_from(Pathname.new(@afw)).to_s }
    body = {
      "contract_version" => "afw-scoring-evidence-receipt/v0.1",
      "semantic_status" => "provenance_validated_proposed_scoring_evidence",
      "workload" => {
        "plan_id" => "batch", "plan_sha256" => digest(File.binread(plan_path)),
        "snapshot_sha256" => digest(File.binread(snapshot_path)), "case_index_sha256" => digest(File.binread(index_path)),
        "job_id" => spec.fetch(:case_id), "pool_id" => "fixture"
      },
      "scoring_intent" => {
        "case_id" => spec.fetch(:case_id), "adventure_id" => spec.fetch(:adventure_id),
        "dimension" => spec.fetch(:dimension), "profile" => bindings.fetch("profile"),
        "model_alias" => bindings.fetch("model_alias"), "ollama_model" => bindings.fetch("ollama_model"),
        "case_sha256" => digest(File.binread(case_path))
      },
      "attempt" => attempt,
      "scorer_provenance" => {
        "scorer_commit" => HEAD, "qualified_model_digest" => bindings.fetch("qualified_model_digest"),
        "qualification_sha256" => bindings.fetch("qualification_sha256"),
        "runtime_sha256" => bindings.fetch("runtime_sha256"), "preflight_sha256" => bindings.fetch("preflight_sha256"),
        "prompt_sha256" => "4" * 64, "schema_sha256" => "5" * 64
      },
      "artifacts" => {
        "run_id" => run_id,
        "proposed_assessment" => { "path" => relative.call(assessment_path), "sha256" => digest(File.binread(assessment_path)) },
        "raw_request" => { "path" => relative.call(request_path), "sha256" => digest(File.binread(request_path)) },
        "raw_response" => { "path" => relative.call(response_path), "sha256" => digest(File.binread(response_path)) }
      }
    }
    document = body.merge("receipt_id" => digest(JSON.generate(canonical(body))))
    path = File.join(@afw, "output", "receipts", "#{spec.fetch(:case_id)}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, json_bytes(document))
    { path:, document: }
  end

  def locations(root)
    { review_dir: File.join(root, "review"), audit_dir: File.join(root, "audit") }
  end

  def prepare(fixture, root, **overrides)
    AfDataPipeline::WorkloadScoringReviewPackage.prepare!(
      manifest_path: fixture.fetch(:manifest_path), afw_root: fixture.fetch(:afw),
      **locations(root).merge(overrides)
    )
  end

  def rewrite_manifest(path)
    document = JSON.parse(File.binread(path))
    yield document
    body = document.reject { |key, _value| key == "manifest_id" }
    document["manifest_id"] = digest(JSON.generate(canonical(body)))
    File.binwrite(path, json_bytes(document))
  end

  def set_all_decisions(audit_dir, decision)
    path = File.join(audit_dir, "editorial_decisions.csv")
    table = CSV.read(path, headers: true)
    table.each do |row|
      row["editorial_decision"] = decision
      row["editorial_note"] = "reviewed fixture" unless decision == "ACCEPT"
    end
    CSV.open(path, "w") do |csv|
      csv << table.headers
      table.each { |row| csv << table.headers.map { |header| row[header] } }
    end
    path
  end

  def revise_first_candidate_value(fixture, value)
    manifest = JSON.parse(File.binread(fixture.fetch(:manifest_path)))
    manifest_case = manifest.fetch("cases").find { |entry| entry.dig("receipt", "reference") }
    receipt_ref = manifest_case.dig("receipt", "reference")
    receipt_path = File.join(fixture.fetch(:afw), receipt_ref.fetch("path"))
    receipt = JSON.parse(File.binread(receipt_path))
    assessment_path = File.join(fixture.fetch(:afw), receipt.dig("artifacts", "proposed_assessment", "path"))
    assessment = CSV.read(assessment_path, headers: true)
    assessment.first["value"] = value.to_s
    CSV.open(assessment_path, "w") do |csv|
      csv << assessment.headers
      assessment.each { |row| csv << assessment.headers.map { |header| row[header] } }
    end
    receipt.dig("artifacts", "proposed_assessment")["sha256"] = digest(File.binread(assessment_path))
    receipt_body = receipt.reject { |key, _entry| key == "receipt_id" }
    receipt["receipt_id"] = digest(JSON.generate(canonical(receipt_body)))
    File.binwrite(receipt_path, json_bytes(receipt))
    manifest_case.fetch("receipt")["receipt_id"] = receipt.fetch("receipt_id")
    receipt_ref["sha256"] = digest(File.binread(receipt_path))
    manifest_body = manifest.reject { |key, _entry| key == "manifest_id" }
    manifest["manifest_id"] = digest(JSON.generate(canonical(manifest_body)))
    File.binwrite(fixture.fetch(:manifest_path), json_bytes(manifest))
  end

  def test_all_success_composes_scalar_and_levels_into_one_complete_review
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      result = prepare(fixture, root)
      package = JSON.parse(File.binread(File.join(result.review_dir, "review_package.json")))
      candidates = File.readlines(File.join(result.review_dir, "candidates.jsonl")).map { |line| JSON.parse(line) }
      ledger = CSV.read(File.join(result.audit_dir, "editorial_decisions.csv"), headers: true)

      assert result.workload_complete
      assert_equal 2, result.intended_cases
      assert_equal 3, result.candidate_count
      assert_equal 3, result.pending
      assert_empty File.binread(File.join(result.review_dir, "unresolved_cases.jsonl"))
      assert_empty File.binread(File.join(result.review_dir, "holds.jsonl"))
      assert_equal [1, 2], package.fetch("case_accounting").map { |row| row.fetch("candidate_keys").length }
      assert_equal 3, candidates.map { |row| row.fetch("candidate_key") }.uniq.length
      assert_equal 3, ledger.length
      assert_equal "review_only_no_retry_scoring_policy_acceptance_or_catalog_mutation", package.fetch("mutation_boundary")
    end
  end

  def test_identical_recreation_preserves_accept_hold_reject_notes_and_hashes
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      first = prepare(fixture, root)
      ledger = File.join(first.audit_dir, "editorial_decisions.csv")
      table = CSV.read(ledger, headers: true)
      %w[ACCEPT HOLD REJECT].zip(table).each do |decision, row|
        row["editorial_decision"] = decision
        row["editorial_note"] = "preserved #{decision.downcase} note" unless decision == "ACCEPT"
      end
      CSV.open(ledger, "w") do |csv|
        csv << table.headers
        table.each { |row| csv << table.headers.map { |header| row[header] } }
      end
      ledger_before = File.binread(ledger)
      hashes_before = table.map { |row| row.fetch("record_sha256") }
      FileUtils.rm_r(first.review_dir)

      second = prepare(fixture, root)
      replayed = CSV.read(ledger, headers: true)
      assert_equal ledger_before, File.binread(ledger)
      assert_equal hashes_before, replayed.map { |row| row.fetch("record_sha256") }
      assert_equal [1, 1, 1], [second.accepted, second.held, second.rejected]
      assert second.editorial_complete
    end
  end

  def test_partial_success_keeps_decided_subset_visibly_workload_incomplete
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root, states: %i[ready failed])
      first = prepare(fixture, root)
      ledger = set_all_decisions(first.audit_dir, "ACCEPT")
      ledger_before = File.binread(ledger)
      FileUtils.rm_r(first.review_dir)

      second = prepare(fixture, root)
      unresolved = File.readlines(File.join(second.review_dir, "unresolved_cases.jsonl")).map { |line| JSON.parse(line) }

      refute second.workload_complete
      assert second.editorial_complete
      assert_equal 1, second.accepted
      assert_equal 1, second.unresolved_cases
      assert_equal "job-levels", unresolved.first.fetch("case_id")
      assert_equal ledger_before, File.binread(ledger)
      assert_nil second.next_human_decision
      report = JSON.parse(File.binread(File.join(second.review_dir, "integrity_report.json")))
      assert_equal 2, report.fetch("intended_cases")
      assert_equal 1, report.fetch("ready_cases")
      assert_equal 1, report.fetch("unresolved_cases")
      refute report.fetch("workload_evidence_complete")
    end
  end

  def test_every_execution_and_evidence_state_is_explicit_without_fabricated_rows
    Dir.mktmpdir do |root|
      states = %i[ready failed interrupted running pending missing_evidence ambiguous_evidence]
      identities = states.each_with_index.map do |_state, index|
        number = index + 1
        {
          case_id: "job-#{number}", adventure_id: format("ADV-%04d", number),
          dimension: "Seriousness", metrics: ["Seriousness"]
        }
      end
      fixture = write_workload_fixture(root, states:, identities:)
      result = prepare(fixture, root)
      unresolved = File.readlines(File.join(result.review_dir, "unresolved_cases.jsonl")).map { |line| JSON.parse(line) }

      refute result.workload_complete
      assert_equal 7, result.intended_cases
      assert_equal 1, result.ready_cases
      assert_equal 6, result.unresolved_cases
      assert_equal 1, result.candidate_count
      assert_empty File.binread(File.join(result.review_dir, "holds.jsonl"))
      assert_equal(
        %w[ambiguous_scoring_evidence missing_scoring_evidence wlo_attempt_failed wlo_attempt_interrupted
           wlo_attempt_running wlo_attempt_unstarted].sort,
        unresolved.map { |entry| entry.dig("classification", "reason") }.sort
      )
    end
  end

  def test_authorized_retry_and_superseded_attempts_remain_visible
    Dir.mktmpdir do |root|
      identities = [
        { case_id: "job-retry", adventure_id: "ADV-0001", dimension: "Seriousness", metrics: ["Seriousness"] },
        { case_id: "job-complete", adventure_id: "ADV-0002", dimension: "Seriousness", metrics: ["Seriousness"] }
      ]
      fixture = write_workload_fixture(root, states: %i[retry_pending superseded_ready], identities:)
      result = prepare(fixture, root)
      unresolved = JSON.parse(File.binread(File.join(result.review_dir, "unresolved_cases.jsonl")))
      candidate = JSON.parse(File.binread(File.join(result.review_dir, "candidates.jsonl")))

      refute result.workload_complete
      assert_equal "wlo_retry_authorized", unresolved.dig("classification", "reason")
      assert_equal 1, unresolved.dig("authoritative_attempt", "attempt")
      assert_equal 2, candidate.fetch("wlo_attempt")
      assert_equal HEAD, candidate.dig("scorer_provenance", "scorer_commit")
      manifest = JSON.parse(File.binread(fixture.fetch(:manifest_path)))
      assert_equal 1, manifest.dig("cases", 1, "execution", "authoritative_attempt", "superseded_attempts").length
    end
  end

  def test_rejects_denominator_mutation_even_with_recomputed_manifest_identity
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      rewrite_manifest(fixture.fetch(:manifest_path)) { |document| document.fetch("cases").pop }
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/denominator|case accounting/, error.message)
      refute File.exist?(locations(root).fetch(:review_dir))
    end
  end

  def test_rejects_duplicate_and_extra_denominator_members
    {
      "duplicate" => lambda do |document|
        document.fetch("cases") << Marshal.load(Marshal.dump(document.fetch("cases").first))
      end,
      "extra" => lambda do |document|
        extra = Marshal.load(Marshal.dump(document.fetch("cases").first))
        extra["case_id"] = "unexpected-case"
        document.fetch("cases") << extra
      end
    }.each do |label, mutation|
      Dir.mktmpdir do |root|
        fixture = write_workload_fixture(root)
        rewrite_manifest(fixture.fetch(:manifest_path), &mutation)
        error = assert_raises(AfDataPipeline::ValidationError, label) { prepare(fixture, root) }
        assert_match(/denominator|case accounting/, error.message, label)
      end
    end
  end

  def test_rejects_unknown_manifest_contract
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      rewrite_manifest(fixture.fetch(:manifest_path)) do |document|
        document["contract_version"] = "afw-workload-evidence-manifest/v99"
      end
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/unsupported workload evidence manifest contract/, error.message)
    end
  end

  def test_rejects_malformed_manifest_and_inconsistent_receipt_counts
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root, states: %i[ready failed])
      rewrite_manifest(fixture.fetch(:manifest_path)) do |document|
        document.fetch("summary")["receipt_count"] = 2
      end
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/summary is internally inconsistent/, error.message)
    end

    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      rewrite_manifest(fixture.fetch(:manifest_path)) { |document| document["cases"] = {} }
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/cases must be an array/, error.message)
    end
  end

  def test_rejects_mutated_receipt_artifact
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      manifest = JSON.parse(File.binread(fixture.fetch(:manifest_path)))
      receipt_path = File.join(fixture.fetch(:afw), manifest.dig("cases", 0, "receipt", "reference", "path"))
      receipt = JSON.parse(File.binread(receipt_path))
      response_path = File.join(fixture.fetch(:afw), receipt.dig("artifacts", "raw_response", "path"))
      File.binwrite(response_path, "changed artifact\n")

      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/artifact raw_response digest mismatch/, error.message)
    end
  end

  def test_rejects_unsafe_manifest_reference_independently_of_producer
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      rewrite_manifest(fixture.fetch(:manifest_path)) do |document|
        document.dig("workload", "afw", "case_index")["path"] = "../case_index.csv"
      end
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/unsafe|escapes/, error.message)
    end
  end

  def test_rejects_conflicting_candidate_keys_across_distinct_cases
    Dir.mktmpdir do |root|
      identities = [
        { case_id: "job-a", adventure_id: "ADV-0001", dimension: "Seriousness", metrics: ["Seriousness"] },
        { case_id: "job-b", adventure_id: "ADV-0001", dimension: "Seriousness", metrics: ["Seriousness"] }
      ]
      fixture = write_workload_fixture(root, identities:)
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/conflicting candidate keys/, error.message)
    end
  end

  def test_changed_receipt_cannot_inherit_prior_approval
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root, states: %i[ready failed])
      first = prepare(fixture, root)
      ledger = set_all_decisions(first.audit_dir, "ACCEPT")
      ledger_before = File.binread(ledger)
      rewrite_manifest(fixture.fetch(:manifest_path)) do |document|
        document.dig("cases", 0, "receipt")["receipt_id"] = "f" * 64
      end

      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/receipt identity mismatch/, error.message)
      assert_equal ledger_before, File.binread(ledger)
    end
  end

  def test_valid_new_evidence_revision_cannot_reuse_old_package_or_decisions
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root, states: %i[ready failed])
      first = prepare(fixture, root)
      ledger = set_all_decisions(first.audit_dir, "ACCEPT")
      ledger_before = File.binread(ledger)
      candidates_before = File.binread(File.join(first.review_dir, "candidates.jsonl"))
      revise_first_candidate_value(fixture, 4)

      error = assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }
      assert_match(/existing workload review package conflicts/, error.message)
      assert_equal ledger_before, File.binread(ledger)
      assert_equal candidates_before, File.binread(File.join(first.review_dir, "candidates.jsonl"))
    end
  end

  def test_incomplete_audit_and_partial_generated_output_are_refused
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      result = prepare(fixture, root)
      ledger = File.join(result.audit_dir, "editorial_decisions.csv")
      ledger_before = File.binread(ledger)
      FileUtils.rm(File.join(result.audit_dir, "audit_manifest.json"))
      assert_match(/incomplete/, assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }.message)
      assert_equal ledger_before, File.binread(ledger)

      FileUtils.rm_r(result.audit_dir)
      FileUtils.rm(File.join(result.review_dir, "unresolved_cases.jsonl"))
      assert_match(/file set conflicts/, assert_raises(AfDataPipeline::ValidationError) { prepare(fixture, root) }.message)
    end
  end

  def test_cli_reports_workload_and_editorial_completeness_separately
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root, states: %i[ready failed])
      out = StringIO.new
      err = StringIO.new
      dirs = locations(root)
      status = AfDataPipeline::CLI.run(
        ["prepare-workload-review", fixture.fetch(:manifest_path), "--afw-root", fixture.fetch(:afw),
         "--review-dir", dirs.fetch(:review_dir), "--audit-dir", dirs.fetch(:audit_dir)],
        out:, err:
      )

      assert_equal 0, status, err.string
      assert_includes out.string, "Intended cases: 2"
      assert_includes out.string, "Unresolved cases: 1"
      assert_includes out.string, "Workload evidence complete: false"
      assert_includes out.string, "Editorial complete: false"

      set_all_decisions(dirs.fetch(:audit_dir), "ACCEPT")
      out = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["prepare-workload-review", fixture.fetch(:manifest_path), "--afw-root", fixture.fetch(:afw),
         "--review-dir", dirs.fetch(:review_dir), "--audit-dir", dirs.fetch(:audit_dir)],
        out:, err:
      )
      assert_equal 0, status, err.string
      assert_includes out.string, "Editorial complete: true"
      assert_includes out.string, "unresolved workload cases remain explicit"
    end
  end

  def test_cli_reports_no_remaining_decision_for_complete_decided_workload
    Dir.mktmpdir do |root|
      fixture = write_workload_fixture(root)
      result = prepare(fixture, root)
      set_all_decisions(result.audit_dir, "ACCEPT")
      out = StringIO.new
      err = StringIO.new
      dirs = locations(root)

      status = AfDataPipeline::CLI.run(
        ["prepare-workload-review", fixture.fetch(:manifest_path), "--afw-root", fixture.fetch(:afw),
         "--review-dir", dirs.fetch(:review_dir), "--audit-dir", dirs.fetch(:audit_dir)],
        out:, err:
      )

      assert_equal 0, status, err.string
      assert_includes out.string, "Workload evidence complete: true"
      assert_includes out.string, "every candidate already has a preserved editorial decision"
    end
  end

  def test_cli_rejects_missing_and_unexpected_arguments
    argument_sets = [
      [],
      ["manifest.json"],
      ["manifest.json", "--afw-root", "afw"],
      ["manifest.json", "--afw-root", "afw", "--review-dir", "review"],
      ["manifest.json", "--afw-root", "afw", "--review-dir", "review", "--audit-dir", "audit", "extra"]
    ]

    argument_sets.each do |arguments|
      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(["prepare-workload-review", *arguments], out:, err:)
      assert_equal 2, status
      assert_match(/ERROR:/, err.string)
    end
  end
end
