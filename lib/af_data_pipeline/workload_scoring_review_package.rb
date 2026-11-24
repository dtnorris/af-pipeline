# frozen_string_literal: true

module AfDataPipeline
  # Consumes one complete AFW workload-evidence manifest and prepares a single
  # review package without turning unresolved execution/evidence into invented
  # scoring candidates or source holds.
  class WorkloadScoringReviewPackage
    MANIFEST_CONTRACT = "afw-workload-evidence-manifest/v0.1"
    MANIFEST_STATUS = "authoritative_workload_evidence_snapshot"
    RECEIPT_CONTRACT = ScoringReviewPackage::RECEIPT_CONTRACT
    RECEIPT_STATUS = ScoringReviewPackage::RECEIPT_STATUS
    PACKAGE_CONTRACT = "af-workload-scoring-review-package/v0.1"
    INTEGRITY_CONTRACT = "af-workload-scoring-review-integrity-report/v0.1"
    UNRESOLVED_CONTRACT = "af-workload-scoring-review-unresolved-case/v0.1"
    WORKLOAD_CONTRACT = "afw-workload/v0.1"
    WLO_EXECUTION_CONTRACT = "wlo-execution-state/v0.1"
    PACKAGE_FILES = %w[
      candidates.jsonl
      holds.jsonl
      integrity_report.json
      review_package.json
      unresolved_cases.jsonl
    ].freeze
    INDEX_FIELDS = %w[
      case_id adventure_id dimension profile model_alias ollama_model qualified_model_digest
      qualification_sha256 runtime_sha256 preflight_sha256 case_path
    ].freeze
    OUTCOMES = %w[evidenced failed interrupted pending running unsafe].freeze
    EXECUTION_STATUSES = %w[complete failed interrupted pending running unresolved].freeze
    EVIDENCE_STATUSES = %w[ready unresolved].freeze
    HEX_SHA256 = /\A[0-9a-f]{64}\z/

    Result = Data.define(
      :package_id,
      :manifest_id,
      :review_dir,
      :audit_dir,
      :reused,
      :workload_complete,
      :intended_cases,
      :ready_cases,
      :unresolved_cases,
      :candidate_count,
      :ledger_state,
      :editorial_complete,
      :pending,
      :accepted,
      :held,
      :rejected,
      :next_human_decision
    )

    def self.prepare!(manifest_path:, afw_root:, review_dir:, audit_dir:)
      new(manifest_path:, afw_root:, review_dir:, audit_dir:).prepare!
    end

    def initialize(manifest_path:, afw_root:, review_dir:, audit_dir:)
      @manifest_path = File.expand_path(manifest_path)
      @afw_root = File.expand_path(afw_root)
      @review_dir = File.expand_path(PrivateDataRoot.destination!(review_dir))
      @audit_dir = File.expand_path(PrivateDataRoot.destination!(audit_dir))
    end

    def prepare!
      PrivateDataRoot.destination!(@review_dir)
      PrivateDataRoot.destination!(@audit_dir)
      manifest_bytes = read_file(@manifest_path, "AFW workload evidence manifest")
      validate_afw_path!(@manifest_path, "AFW workload evidence manifest")
      manifest = parse_json(manifest_bytes, "AFW workload evidence manifest")
      validate_manifest!(manifest)
      candidates = candidates_from(manifest)
      unresolved = unresolved_from(manifest)
      validate_candidate_accounting!(manifest, candidates, unresolved)
      package_id = package_id(manifest, candidates, unresolved)
      desired = package_files(manifest, manifest_bytes, candidates, unresolved, package_id)
      reused = write_or_verify_package!(desired)
      validation = prepare_or_validate_audit!
      summary = manifest.fetch("summary")
      ready_cases = summary.dig("evidence_counts", "ready").to_i

      Result.new(
        package_id:,
        manifest_id: manifest.fetch("manifest_id"),
        review_dir: @review_dir,
        audit_dir: @audit_dir,
        reused:,
        workload_complete: summary.fetch("evidence_complete"),
        intended_cases: summary.fetch("intended_cases"),
        ready_cases:,
        unresolved_cases: summary.fetch("intended_cases") - ready_cases,
        candidate_count: candidates.length,
        ledger_state: validation.pending.empty? ? "decided" : "pending",
        editorial_complete: validation.complete,
        pending: validation.pending.length,
        accepted: validation.accepted.length,
        held: validation.held.length,
        rejected: validation.rejected.length,
        next_human_decision: validation.pending.empty? ? nil : EditorialAudit::CANDIDATE_DECISIONS
      )
    rescue JSON::ParserError => e
      raise ValidationError, "malformed workload review input: #{e.message}"
    rescue CSV::MalformedCSVError => e
      raise ValidationError, "malformed AFW case index: #{e.message}"
    rescue Psych::Exception => e
      raise ValidationError, "malformed AFW workload YAML: #{e.message}"
    end

    private

    def validate_manifest!(document)
      unless document["contract_version"] == MANIFEST_CONTRACT
        raise ValidationError, "unsupported workload evidence manifest contract #{document['contract_version'].inspect}"
      end
      unless document["semantic_status"] == MANIFEST_STATUS
        raise ValidationError, "invalid workload evidence manifest semantic status"
      end
      supplied = document["manifest_id"].to_s
      body = document.reject { |key, _value| key == "manifest_id" }
      expected = sha256(canonical_json(body))
      unless supplied.match?(HEX_SHA256) && supplied == expected
        raise ValidationError, "workload evidence manifest identity mismatch"
      end

      workload = fetch_hash(document, "workload", "workload evidence manifest")
      summary = fetch_hash(document, "summary", "workload evidence manifest")
      cases = document["cases"]
      raise ValidationError, "workload evidence manifest cases must be an array" unless cases.is_a?(Array)

      plan_bytes = read_afw_reference(workload.dig("afw", "execution_plan"), "AFW execution plan")
      snapshot_bytes = read_afw_reference(workload.dig("afw", "snapshot"), "AFW snapshot")
      index_bytes = read_afw_reference(workload.dig("afw", "case_index"), "AFW case index")
      plan = parse_json(plan_bytes, "AFW execution plan")
      snapshot = parse_yaml(snapshot_bytes, "AFW snapshot")
      rows = parse_index(index_bytes)
      jobs = plan["jobs"]
      raise ValidationError, "AFW execution plan jobs must be an array" unless jobs.is_a?(Array)

      execution = validate_workload!(workload, plan, snapshot, rows, jobs, cases, plan_bytes)
      rows.zip(jobs, cases).each do |row, job, manifest_case|
        validate_case!(workload, snapshot, execution, row, job, manifest_case)
      end
      validate_summary!(summary, cases)
      document
    rescue KeyError, IndexError => e
      raise ValidationError, "incomplete workload evidence manifest: #{e.message}"
    end

    def validate_workload!(workload, plan, snapshot, rows, jobs, cases, plan_bytes)
      afw = fetch_hash(workload, "afw", "workload")
      wlo = fetch_hash(workload, "wlo", "workload")
      plan_id = required_string(workload["plan_id"], "workload plan_id")
      count = workload["intended_case_count"]
      valid = plan["plan_id"] == plan_id && snapshot["contract_version"] == WORKLOAD_CONTRACT &&
              snapshot["workload_id"] == plan_id &&
              snapshot["execution_plan_sha256"] == sha256(plan_bytes) &&
              count.is_a?(Integer) && count.positive? && !snapshot["scorer_commit"].to_s.empty?
      raise ValidationError, "workload evidence manifest has invalid frozen workload identity" unless valid
      unless rows.length == count && jobs.length == count && cases.length == count
        raise ValidationError, "workload evidence manifest denominator does not match frozen intent"
      end

      row_ids = rows.map { |row| row["case_id"] }
      job_ids = jobs.map { |job| job.is_a?(Hash) && job["job_id"] }
      case_ids = cases.map { |entry| entry.is_a?(Hash) && entry["case_id"] }
      exact = [row_ids, job_ids, case_ids].all? { |ids| ids.length == ids.uniq.length } &&
              row_ids == job_ids && row_ids == case_ids
      raise ValidationError, "workload evidence manifest case accounting is missing, duplicated or unexpected" unless exact

      wlo_plan = wlo["plan"]
      unless wlo_reference?(wlo_plan, expected_path: "plan.json") && wlo_plan["sha256"] == sha256(plan_bytes)
        raise ValidationError, "workload evidence manifest WLO plan identity mismatch"
      end
      execution_bytes = embedded_wlo_bytes(wlo["execution"], "WLO execution state", expected_path: "execution.json")
      execution = parse_json(execution_bytes, "WLO execution state")
      valid_execution = execution["contract_version"] == WLO_EXECUTION_CONTRACT &&
                        execution["contract_version"] == wlo["execution_contract"] &&
                        execution["plan_id"] == plan_id && execution["plan_sha256"] == sha256(plan_bytes) &&
                        execution["status"] == wlo["execution_status"]
      raise ValidationError, "workload evidence manifest WLO execution identity mismatch" unless valid_execution
      retry_pending = execution.fetch("retry_pending", {})
      retry_valid = retry_pending.is_a?(Hash) && (retry_pending.keys - job_ids).empty? &&
                    retry_pending.values.all? { |attempt| attempt.is_a?(Integer) && attempt.positive? }
      raise ValidationError, "workload evidence manifest WLO retry state is invalid" unless retry_valid
      raise ValidationError, "workload evidence manifest AFW references are incomplete" unless afw.keys.sort == %w[case_index execution_plan snapshot]

      execution
    end

    def validate_case!(workload, snapshot, execution, row, job, manifest_case)
      unless row.is_a?(Hash) && job.is_a?(Hash) && manifest_case.is_a?(Hash)
        raise ValidationError, "workload evidence manifest contains a malformed case"
      end
      unless manifest_case["adventure_id"] == row["adventure_id"] &&
             manifest_case["dimension"] == row["dimension"] &&
             manifest_case.dig("intent", "case_index_row") == row
        raise ValidationError, "workload evidence manifest frozen intent mismatch"
      end
      validate_job!(manifest_case["job"], job)
      validate_case_reference!(workload, snapshot, manifest_case, row)
      validate_classification!(manifest_case)
      validate_attempt!(manifest_case, job, execution)
      validate_receipt!(workload, snapshot, manifest_case, row)
    end

    def validate_job!(identity, job)
      unless identity.is_a?(Hash) && job["argv"].is_a?(Array)
        raise ValidationError, "workload evidence manifest job identity is malformed"
      end
      valid = identity["job_id"] == job["job_id"] && identity["pool_id"] == job["pool_id"] &&
              identity["group_id"] == job["group_id"] &&
              identity["argv_sha256"] == sha256(canonical_json(job.fetch("argv"))) &&
              identity["plan_job_sha256"] == sha256(canonical_json(job))
      raise ValidationError, "workload evidence manifest job identity mismatch" unless valid
    end

    def validate_case_reference!(workload, snapshot, manifest_case, row)
      reference = manifest_case.dig("intent", "case")
      unless reference.is_a?(Hash) && reference["path"] == row["case_path"]
        raise ValidationError, "workload evidence manifest case path mismatch"
      end
      data = parse_yaml(read_afw_reference(reference, "AFW scoring case"), "AFW scoring case")
      expected = {
        "contract_version" => WORKLOAD_CONTRACT,
        "workload_id" => workload.fetch("plan_id"),
        "case_id" => row.fetch("case_id"),
        "adventure_id" => row.fetch("adventure_id"),
        "dimension" => row.fetch("dimension"),
        "profile" => row.fetch("profile"),
        "model_alias" => row.fetch("model_alias"),
        "ollama_model" => row.fetch("ollama_model"),
        "qualified_model_digest" => row.fetch("qualified_model_digest"),
        "qualification_sha256" => row.fetch("qualification_sha256"),
        "runtime_sha256" => row.fetch("runtime_sha256"),
        "preflight_sha256" => row.fetch("preflight_sha256"),
        "scorer_commit" => snapshot.fetch("scorer_commit")
      }
      mismatch = expected.find { |key, value| data[key] != value }
      raise ValidationError, "workload evidence manifest case intent mismatch for #{mismatch.first}" if mismatch
    end

    def validate_classification!(manifest_case)
      classification = manifest_case["classification"]
      raise ValidationError, "workload evidence manifest case classification is malformed" unless classification.is_a?(Hash)
      outcome = classification["outcome"]
      execution = classification["execution_status"]
      evidence = classification["evidence_status"]
      valid_values = OUTCOMES.include?(outcome) && EXECUTION_STATUSES.include?(execution) &&
                     EVIDENCE_STATUSES.include?(evidence) && !classification["reason"].to_s.empty?
      ready = outcome == "evidenced" && execution == "complete" && evidence == "ready" &&
              classification["reason"] == "receipt_valid"
      unresolved = outcome != "evidenced" && evidence == "unresolved"
      unless valid_values && (ready || unresolved)
        raise ValidationError, "workload evidence manifest execution/evidence classification is inconsistent"
      end
    end

    def validate_attempt!(manifest_case, job, wlo_execution)
      execution = manifest_case["execution"]
      raise ValidationError, "workload evidence manifest case execution is malformed" unless execution.is_a?(Hash)
      snapshot = execution["current_attempt"]
      identity = execution["authoritative_attempt"]
      if snapshot.nil?
        valid = identity.nil? && manifest_case.dig("classification", "outcome") == "pending" &&
                manifest_case.dig("classification", "reason") == "wlo_attempt_unstarted"
        raise ValidationError, "workload evidence manifest is missing its attempt observation" unless valid
        return
      end

      expected_path = File.join("runs", job.fetch("job_id"), "metadata.json")
      bytes = embedded_wlo_bytes(snapshot, "WLO current attempt", expected_path:)
      if identity.nil?
        valid = manifest_case.dig("classification", "outcome") == "unsafe" &&
                manifest_case.dig("classification", "reason").to_s.include?("attempt")
        raise ValidationError, "workload evidence manifest has unaccounted attempt bytes" unless valid
        return
      end
      raise ValidationError, "workload evidence manifest authoritative attempt is malformed" unless identity.is_a?(Hash)

      metadata = parse_json(bytes, "WLO current attempt")
      source = snapshot.fetch("source")
      valid = source["path"] == identity["evidence_path"] && source["sha256"] == identity["evidence_sha256"] &&
              metadata["job_id"] == job["job_id"] && metadata["pool_id"] == job["pool_id"] &&
              metadata["argv"] == job["argv"] && metadata["attempt"] == identity["attempt"] &&
              metadata["status"] == identity["status"] && metadata["exit_status"] == identity["exit_status"]
      raise ValidationError, "workload evidence manifest attempt identity mismatch" unless valid
      validate_retained_attempts!(snapshot, identity, job)
      validate_attempt_classification!(manifest_case, metadata, wlo_execution)
    end

    def validate_retained_attempts!(snapshot, identity, job)
      expected = Array(identity["superseded_attempts"])
      retained = snapshot["retained_superseded_attempts"]
      unless retained.is_a?(Array) && retained.length == expected.length
        raise ValidationError, "workload evidence manifest superseded-attempt count mismatch"
      end
      numbers = []
      expected.zip(retained).each do |attempt, embedded|
        raise ValidationError, "workload evidence manifest superseded attempt is malformed" unless attempt.is_a?(Hash)
        bytes = embedded_wlo_bytes(embedded, "WLO superseded attempt")
        metadata = parse_json(bytes, "WLO superseded attempt")
        source = embedded.fetch("source")
        valid = source["path"] == attempt["evidence_path"] && source["sha256"] == attempt["evidence_sha256"] &&
                metadata["job_id"] == job["job_id"] && metadata["attempt"] == attempt["attempt"] &&
                metadata["status"] == attempt["status"] && attempt["attempt"].is_a?(Integer) &&
                attempt["attempt"] < identity.fetch("attempt")
        raise ValidationError, "workload evidence manifest superseded-attempt identity mismatch" unless valid
        numbers << attempt["attempt"]
      end
      unless numbers.uniq.length == numbers.length
        raise ValidationError, "workload evidence manifest superseded attempts are ambiguous"
      end
    end

    def validate_attempt_classification!(manifest_case, metadata, execution)
      classification = manifest_case.fetch("classification")
      job_id = manifest_case.fetch("case_id")
      retry_attempt = execution.fetch("retry_pending", {})[job_id]
      expected = if retry_attempt
                   if retry_attempt == metadata["attempt"] && %w[failed interrupted].include?(metadata["status"])
                     ["pending", "wlo_retry_authorized", "pending"]
                   end
                 else
                   case metadata["status"]
                   when "complete"
                     [classification["outcome"], classification["reason"], "complete"] if
                       %w[evidenced unsafe].include?(classification["outcome"])
                   when "failed" then ["failed", "wlo_attempt_failed", "failed"]
                   when "interrupted" then ["interrupted", "wlo_attempt_interrupted", "interrupted"]
                   when "running" then ["running", "wlo_attempt_running", "running"]
                   end
                 end
      actual = classification.values_at("outcome", "reason", "execution_status")
      raise ValidationError, "workload evidence manifest attempt classification mismatch" unless expected == actual
    end

    def validate_receipt!(workload, snapshot, manifest_case, row)
      classification = manifest_case.fetch("classification")
      receipt_ref = manifest_case["receipt"]
      if classification.fetch("evidence_status") == "unresolved"
        raise ValidationError, "unresolved workload case cannot carry a receipt" unless receipt_ref.nil?
        return
      end
      raise ValidationError, "evidenced workload case is missing a receipt" unless receipt_ref.is_a?(Hash)

      bytes = read_afw_reference(receipt_ref["reference"], "AFW scoring evidence receipt")
      receipt = parse_json(bytes, "AFW scoring evidence receipt")
      supplied = receipt["receipt_id"].to_s
      expected_id = sha256(canonical_json(receipt.reject { |key, _value| key == "receipt_id" }))
      attempt = manifest_case.dig("execution", "authoritative_attempt")
      receipt_attempt = receipt["attempt"]
      receipt_workload = receipt["workload"]
      receipt_intent = receipt["scoring_intent"]
      provenance = receipt["scorer_provenance"]
      unless [receipt_attempt, receipt_workload, receipt_intent, provenance].all? { |value| value.is_a?(Hash) }
        raise ValidationError, "workload evidence manifest receipt provenance is malformed"
      end
      valid = receipt_ref["contract_version"] == RECEIPT_CONTRACT &&
              receipt_ref["semantic_status"] == RECEIPT_STATUS && receipt_ref["receipt_id"] == supplied &&
              supplied.match?(HEX_SHA256) && supplied == expected_id && receipt["contract_version"] == RECEIPT_CONTRACT &&
              receipt["semantic_status"] == RECEIPT_STATUS &&
              valid_receipt_workload?(receipt_workload, workload, manifest_case) &&
              valid_receipt_intent?(receipt_intent, manifest_case, row) &&
              valid_receipt_attempt?(receipt_attempt, attempt, manifest_case) &&
              valid_receipt_provenance?(provenance, snapshot, row)
      raise ValidationError, "workload evidence manifest receipt identity mismatch" unless valid
      expected_candidates = manifest_case["dimension"] == "Levels" ? 2 : 1
      unless receipt_ref["review_candidate_count"] == expected_candidates
        raise ValidationError, "workload evidence manifest receipt candidate count mismatch"
      end
    end

    def valid_receipt_workload?(receipt, workload, manifest_case)
      receipt["plan_id"] == workload["plan_id"] && receipt["job_id"] == manifest_case["case_id"] &&
        receipt["pool_id"] == manifest_case.dig("job", "pool_id") &&
        receipt["plan_sha256"] == workload.dig("afw", "execution_plan", "sha256") &&
        receipt["snapshot_sha256"] == workload.dig("afw", "snapshot", "sha256") &&
        receipt["case_index_sha256"] == workload.dig("afw", "case_index", "sha256")
    end

    def valid_receipt_intent?(receipt, manifest_case, row)
      receipt["case_id"] == manifest_case["case_id"] && receipt["adventure_id"] == manifest_case["adventure_id"] &&
        receipt["dimension"] == manifest_case["dimension"] && receipt["profile"] == row["profile"] &&
        receipt["model_alias"] == row["model_alias"] && receipt["ollama_model"] == row["ollama_model"] &&
        receipt["case_sha256"] == manifest_case.dig("intent", "case", "sha256")
    end

    def valid_receipt_attempt?(receipt, attempt, manifest_case)
      attempt.is_a?(Hash) && receipt["job_id"] == manifest_case["case_id"] &&
        receipt["attempt"] == attempt["attempt"] && receipt["status"] == "complete" && receipt["exit_status"] == 0 &&
        receipt["evidence_path"] == attempt["evidence_path"] &&
        receipt["evidence_sha256"] == attempt["evidence_sha256"] &&
        Array(receipt["superseded_attempts"]) == Array(attempt["superseded_attempts"])
    end

    def valid_receipt_provenance?(receipt, snapshot, row)
      receipt["scorer_commit"] == snapshot["scorer_commit"] &&
        receipt["qualified_model_digest"] == row["qualified_model_digest"] &&
        receipt["qualification_sha256"] == row["qualification_sha256"] &&
        receipt["runtime_sha256"] == row["runtime_sha256"] &&
        receipt["preflight_sha256"] == row["preflight_sha256"]
    end

    def validate_summary!(summary, cases)
      intended = cases.length
      evidence_counts = tally(cases) { |row| row.dig("classification", "evidence_status") }
      execution_counts = tally(cases) { |row| row.dig("classification", "execution_status") }
      receipts = cases.filter_map { |row| row["receipt"] }
      expected = {
        "intended_cases" => intended,
        "classified_cases" => intended,
        "accounting_complete" => intended.positive?,
        "execution_counts" => execution_counts,
        "evidence_counts" => evidence_counts,
        "receipt_count" => receipts.length,
        "review_candidate_count" => receipts.sum { |receipt| receipt.fetch("review_candidate_count") },
        "evidence_complete" => intended.positive? && evidence_counts.fetch("ready", 0) == intended
      }
      raise ValidationError, "workload evidence manifest summary is internally inconsistent" unless summary == expected
    end

    def candidates_from(manifest)
      manifest.fetch("cases").filter_map do |manifest_case|
        next unless manifest_case.dig("classification", "evidence_status") == "ready"

        reference = manifest_case.dig("receipt", "reference")
        receipt_path = afw_reference_path(reference, "AFW scoring evidence receipt")
        material = ScoringReviewPackage.receipt_material!(receipt_path:, afw_root: @afw_root)
        unless material.receipt.fetch("receipt_id") == manifest_case.dig("receipt", "receipt_id")
          raise ValidationError, "workload receipt changed after manifest validation"
        end
        material.candidates.map do |candidate|
          candidate.merge(
            "afw_workload_manifest_id" => manifest.fetch("manifest_id"),
            "afw_workload_case_id" => manifest_case.fetch("case_id")
          )
        end
      end.flatten.sort_by { |candidate| candidate.fetch("candidate_key") }
    end

    def unresolved_from(manifest)
      manifest.fetch("cases").filter_map do |manifest_case|
        next unless manifest_case.dig("classification", "evidence_status") == "unresolved"

        current = manifest_case.dig("execution", "current_attempt")
        {
          "contract_version" => UNRESOLVED_CONTRACT,
          "manifest_id" => manifest.fetch("manifest_id"),
          "case_id" => manifest_case.fetch("case_id"),
          "adventure_id" => manifest_case.fetch("adventure_id"),
          "dimension" => manifest_case.fetch("dimension"),
          "classification" => manifest_case.fetch("classification"),
          "job" => manifest_case.fetch("job"),
          "case_reference" => manifest_case.dig("intent", "case"),
          "current_attempt_reference" => current && current["source"],
          "authoritative_attempt" => manifest_case.dig("execution", "authoritative_attempt")
        }
      end.sort_by { |entry| entry.fetch("case_id") }
    end

    def validate_candidate_accounting!(manifest, candidates, unresolved)
      keys = candidates.map { |candidate| candidate.fetch("candidate_key") }
      duplicates = keys.tally.select { |_key, count| count > 1 }.keys
      unless duplicates.empty?
        raise ValidationError, "workload review has conflicting candidate keys: #{duplicates.join(', ')}"
      end
      expected_candidates = manifest.dig("summary", "review_candidate_count")
      unless candidates.length == expected_candidates
        raise ValidationError, "workload review candidate count does not reconcile with the manifest"
      end
      expected_unresolved = manifest.dig("summary", "intended_cases") - manifest.dig("summary", "receipt_count")
      unless unresolved.length == expected_unresolved
        raise ValidationError, "workload review unresolved count does not reconcile with the manifest"
      end
      represented = candidates.map { |candidate| candidate.fetch("afw_workload_case_id") }.uniq +
                    unresolved.map { |entry| entry.fetch("case_id") }
      expected_cases = manifest.fetch("cases").map { |entry| entry.fetch("case_id") }
      unless represented.sort == expected_cases.sort
        raise ValidationError, "workload review does not represent every intended case"
      end
    end

    def package_id(manifest, candidates, unresolved)
      identity = {
        "contract_version" => PACKAGE_CONTRACT,
        "manifest_id" => manifest.fetch("manifest_id"),
        "candidates" => candidates,
        "unresolved_cases" => unresolved
      }
      sha256(canonical_json(identity))
    end

    def package_files(manifest, manifest_bytes, candidates, unresolved, package_id)
      candidate_keys = candidates.group_by { |candidate| candidate.fetch("afw_workload_case_id") }
                                 .transform_values { |rows| rows.map { |row| row.fetch("candidate_key") }.sort }
      accounting = manifest.fetch("cases").map do |manifest_case|
        case_id = manifest_case.fetch("case_id")
        {
          "case_id" => case_id,
          "adventure_id" => manifest_case.fetch("adventure_id"),
          "dimension" => manifest_case.fetch("dimension"),
          "execution_status" => manifest_case.dig("classification", "execution_status"),
          "evidence_status" => manifest_case.dig("classification", "evidence_status"),
          "candidate_keys" => candidate_keys.fetch(case_id, []),
          "unresolved_case_key" => unresolved.any? { |row| row.fetch("case_id") == case_id } ? case_id : nil
        }
      end
      summary = manifest.fetch("summary")
      report = {
        "schema_version" => INTEGRITY_CONTRACT,
        "package_id" => package_id,
        "manifest_id" => manifest.fetch("manifest_id"),
        "intended_cases" => summary.fetch("intended_cases"),
        "ready_cases" => summary.dig("evidence_counts", "ready").to_i,
        "unresolved_cases" => unresolved.length,
        "candidates" => candidates.length,
        "holds" => 0,
        "mechanically_invalid_runs" => 0,
        "expectation_match" => true,
        "workload_evidence_complete" => summary.fetch("evidence_complete"),
        "errors" => []
      }
      relative_manifest = Pathname.new(@manifest_path).relative_path_from(Pathname.new(@afw_root)).to_s
      package = {
        "contract_version" => PACKAGE_CONTRACT,
        "package_id" => package_id,
        "source" => {
          "contract_version" => MANIFEST_CONTRACT,
          "manifest_id" => manifest.fetch("manifest_id"),
          "path" => relative_manifest,
          "sha256" => sha256(manifest_bytes)
        },
        "workload" => manifest.fetch("workload"),
        "summary" => summary.merge(
          "candidate_rows" => candidates.length,
          "unresolved_case_rows" => unresolved.length,
          "editorial_completion_is_independent" => true
        ),
        "case_accounting" => accounting,
        "decision_ledger" => {
          "authority" => "editorial_decisions.csv",
          "candidate_decisions" => EditorialAudit::CANDIDATE_DECISIONS,
          "initial_state" => "pending",
          "unresolved_cases_are_not_decision_rows" => true
        },
        "mutation_boundary" => "review_only_no_retry_scoring_policy_acceptance_or_catalog_mutation"
      }
      {
        "candidates.jsonl" => jsonl(candidates),
        "holds.jsonl" => "",
        "integrity_report.json" => JSON.pretty_generate(report) + "\n",
        "review_package.json" => JSON.pretty_generate(package) + "\n",
        "unresolved_cases.jsonl" => jsonl(unresolved)
      }
    end

    def write_or_verify_package!(desired)
      if File.exist?(@review_dir)
        raise ValidationError, "review package path is not a directory: #{@review_dir}" unless File.directory?(@review_dir)
        actual_names = Dir.children(@review_dir).sort
        unless actual_names == PACKAGE_FILES.sort
          raise ValidationError, "existing workload review package file set conflicts with requested package"
        end
        mismatch = PACKAGE_FILES.find { |name| File.binread(File.join(@review_dir, name)) != desired.fetch(name) }
        raise ValidationError, "existing workload review package conflicts at #{mismatch}" if mismatch
        return true
      end

      parent = File.dirname(@review_dir)
      FileUtils.mkdir_p(parent)
      temporary = Dir.mktmpdir(".workload-scoring-review-", parent)
      desired.each { |name, bytes| File.binwrite(File.join(temporary, name), bytes) }
      File.rename(temporary, @review_dir)
      temporary = nil
      false
    rescue Errno::EEXIST, Errno::ENOTEMPTY
      raise ValidationError, "workload review package was created concurrently: #{@review_dir}"
    ensure
      FileUtils.remove_entry(temporary) if temporary && File.exist?(temporary)
    end

    def prepare_or_validate_audit!
      manifest_path = File.join(@audit_dir, "audit_manifest.json")
      ledger_path = File.join(@audit_dir, "editorial_decisions.csv")
      if File.exist?(manifest_path) || File.exist?(ledger_path)
        unless File.file?(manifest_path) && File.file?(ledger_path)
          raise ValidationError, "existing editorial audit is incomplete"
        end
        audit_manifest = parse_json(File.binread(manifest_path), "editorial audit manifest")
        bound_review = EditorialAudit.resolve_review_dir(@audit_dir, audit_manifest)
        unless File.expand_path(bound_review) == @review_dir
          raise ValidationError, "existing editorial audit is bound to a different review package"
        end
      else
        EditorialAudit.initialize!(review_dir: @review_dir, audit_dir: @audit_dir)
      end

      Dir.mktmpdir("workload-scoring-review-validation-", PrivateDataRoot.selected) do |output|
        validation = EditorialAudit.validate!(audit_dir: @audit_dir, output_dir: output)
        unless validation.errors.empty?
          raise ValidationError, "existing editorial audit is invalid: #{validation.errors.join('; ')}"
        end
        validation
      end
    end

    def read_afw_reference(reference, label)
      path = afw_reference_path(reference, label)
      bytes = read_file(path, label)
      raise ValidationError, "#{label} digest mismatch" unless sha256(bytes) == reference["sha256"]
      bytes
    end

    def afw_reference_path(reference, label)
      unless reference.is_a?(Hash) && reference["root"] == "afw" && reference["sha256"].to_s.match?(HEX_SHA256)
        raise ValidationError, "#{label} reference is invalid"
      end
      relative = clean_relative_path(reference["path"], label)
      path = File.expand_path(relative, @afw_root)
      validate_afw_path!(path, label)
      path
    end

    def validate_afw_path!(path, label)
      expanded_root = File.expand_path(@afw_root)
      expanded = File.expand_path(path)
      prefix = "#{expanded_root}#{File::SEPARATOR}"
      raise ValidationError, "#{label} escapes AFW root" unless expanded.start_with?(prefix)
      return unless File.exist?(expanded)

      real_root = File.realpath(expanded_root)
      real = File.realpath(expanded)
      raise ValidationError, "#{label} escapes AFW root" unless real.start_with?("#{real_root}#{File::SEPARATOR}")
    rescue Errno::ENOENT => e
      raise ValidationError, "missing AFW root or #{label}: #{e.message}"
    end

    def embedded_wlo_bytes(snapshot, label, expected_path: nil)
      unless snapshot.is_a?(Hash) && snapshot["encoding"] == "hex" &&
             wlo_reference?(snapshot["source"], expected_path:)
        raise ValidationError, "#{label} embedded snapshot is invalid"
      end
      content = snapshot["content"].to_s
      raise ValidationError, "#{label} embedded snapshot is malformed" unless content.match?(/\A(?:[0-9a-f]{2})*\z/)

      bytes = [content].pack("H*")
      unless sha256(bytes) == snapshot.dig("source", "sha256")
        raise ValidationError, "#{label} embedded digest mismatch"
      end
      bytes
    end

    def wlo_reference?(reference, expected_path: nil)
      return false unless reference.is_a?(Hash) && reference["root"] == "wlo"

      path = reference["path"].to_s
      clean = !path.empty? && !Pathname.new(path).absolute? && Pathname.new(path).cleanpath.to_s == path &&
              !path.split(File::SEPARATOR).include?("..")
      clean && reference["sha256"].to_s.match?(HEX_SHA256) && (!expected_path || path == expected_path)
    end

    def clean_relative_path(path, label)
      relative = path.to_s
      clean = !relative.empty? && !Pathname.new(relative).absolute? &&
              Pathname.new(relative).cleanpath.to_s == relative &&
              !relative.split(File::SEPARATOR).include?("..")
      raise ValidationError, "#{label} path is unsafe" unless clean

      relative
    end

    def parse_index(bytes)
      table = CSV.parse(bytes, headers: true)
      missing = INDEX_FIELDS - Array(table.headers)
      raise ValidationError, "AFW case index is missing #{missing.join(', ')}" unless missing.empty?
      rows = table.map(&:to_h)
      raise ValidationError, "AFW case index has no cases" if rows.empty?
      rows
    end

    def parse_json(bytes, label)
      value = JSON.parse(bytes)
      raise ValidationError, "#{label} must be a JSON object" unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => e
      raise ValidationError, "malformed #{label}: #{e.message}"
    end

    def parse_yaml(bytes, label)
      value = YAML.safe_load(bytes, aliases: true)
      raise ValidationError, "#{label} must be a mapping" unless value.is_a?(Hash)
      value
    end

    def fetch_hash(parent, key, label)
      value = parent[key]
      raise ValidationError, "#{label} #{key} must be an object" unless value.is_a?(Hash)
      value
    end

    def required_string(value, label)
      raise ValidationError, "#{label} is blank" if value.to_s.empty?
      value
    end

    def read_file(path, label)
      raise ValidationError, "missing #{label}: #{path}" unless File.file?(path)
      File.binread(path)
    end

    def jsonl(rows)
      return "" if rows.empty?
      rows.map { |row| JSON.generate(row) }.join("\n") + "\n"
    end

    def tally(rows, &)
      rows.map(&).tally.sort.to_h
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def sha256(bytes)
      Digest::SHA256.hexdigest(bytes)
    end
  end
end
