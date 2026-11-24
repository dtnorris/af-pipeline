# frozen_string_literal: true

module AfDataPipeline
  # Turns one AFW provenance-validated scoring receipt into the existing
  # production-review/editorial-audit boundary. It deliberately stops before
  # any AMC or other canonical data mutation.
  class ScoringReviewPackage
    RECEIPT_CONTRACT = "afw-scoring-evidence-receipt/v0.1"
    RECEIPT_STATUS = "provenance_validated_proposed_scoring_evidence"
    PACKAGE_CONTRACT = "af-scoring-review-package/v0.1"
    INTEGRITY_CONTRACT = "af-scoring-review-integrity-report/v0.1"
    CANDIDATE_CONTRACT = Adapters::ProductionSnapshotV1::CANDIDATE_SCHEMA
    PACKAGE_FILES = %w[candidates.jsonl holds.jsonl integrity_report.json review_package.json].freeze
    ARTIFACT_NAMES = %w[proposed_assessment raw_request raw_response].freeze
    HEX_SHA256 = /\A[0-9a-f]{64}\z/
    LEVELS_METRICS = ["Level Start", "Level End"].freeze

    Result = Data.define(
      :package_id,
      :review_dir,
      :audit_dir,
      :reused,
      :ledger_state,
      :pending,
      :accepted,
      :held,
      :rejected,
      :next_human_decision
    )

    ReceiptMaterial = Data.define(:receipt, :receipt_bytes, :candidates)

    def self.prepare!(receipt_path:, afw_root:, review_dir:, audit_dir:)
      new(receipt_path:, afw_root:, review_dir:, audit_dir:).prepare!
    end

    # Public consumer seam for composing already-validated receipt evidence
    # without creating a per-receipt review package or editorial ledger.
    def self.receipt_material!(receipt_path:, afw_root:)
      new(receipt_path:, afw_root:, review_dir: nil, audit_dir: nil).receipt_material!
    end

    def initialize(receipt_path:, afw_root:, review_dir:, audit_dir:)
      @receipt_path = File.expand_path(receipt_path)
      @afw_root = File.expand_path(afw_root)
      @review_dir = File.expand_path(PrivateDataRoot.destination!(review_dir)) if review_dir
      @audit_dir = File.expand_path(PrivateDataRoot.destination!(audit_dir)) if audit_dir
    end

    def prepare!
      PrivateDataRoot.destination!(@review_dir)
      PrivateDataRoot.destination!(@audit_dir)
      material = receipt_material!
      receipt = material.receipt
      candidates = material.candidates
      package_id = package_id(receipt, candidates)
      desired = package_files(receipt, candidates, package_id)
      reused = write_or_verify_package!(desired)
      validation = prepare_or_validate_audit!

      Result.new(
        package_id:,
        review_dir: @review_dir,
        audit_dir: @audit_dir,
        reused:,
        ledger_state: validation.pending.empty? ? "decided" : "pending",
        pending: validation.pending.length,
        accepted: validation.accepted.length,
        held: validation.held.length,
        rejected: validation.rejected.length,
        next_human_decision: validation.pending.empty? ? nil : EditorialAudit::CANDIDATE_DECISIONS
      )
    rescue JSON::ParserError => e
      raise ValidationError, "malformed AFW receipt: #{e.message}"
    rescue CSV::MalformedCSVError => e
      raise ValidationError, "malformed proposed assessment: #{e.message}"
    end

    def receipt_material!
      receipt_bytes = read_file(@receipt_path, "AFW receipt")
      validate_within_afw_root!(@receipt_path, "AFW receipt")
      receipt = parse_object(receipt_bytes, "AFW receipt")
      validate_receipt!(receipt)
      artifacts = validate_artifacts!(receipt)
      candidates = candidates_from(receipt, artifacts, receipt_bytes)
      ReceiptMaterial.new(receipt:, receipt_bytes:, candidates:)
    rescue JSON::ParserError => e
      raise ValidationError, "malformed AFW receipt: #{e.message}"
    rescue CSV::MalformedCSVError => e
      raise ValidationError, "malformed proposed assessment: #{e.message}"
    end

    private

    def validate_receipt!(receipt)
      unless receipt["contract_version"] == RECEIPT_CONTRACT
        raise ValidationError, "unsupported AFW receipt contract #{receipt['contract_version'].inspect}"
      end
      unless receipt["semantic_status"] == RECEIPT_STATUS
        raise ValidationError, "AFW receipt is not provenance-validated proposed scoring evidence"
      end

      supplied = receipt["receipt_id"].to_s
      body = receipt.reject { |key, _value| key == "receipt_id" }
      expected = sha256(canonical_json(body))
      raise ValidationError, "AFW receipt identity mismatch" unless supplied.match?(HEX_SHA256) && supplied == expected

      workload = receipt["workload"]
      intent = receipt["scoring_intent"]
      attempt = receipt["attempt"]
      scorer = receipt["scorer_provenance"]
      artifacts = receipt["artifacts"]
      unless [workload, intent, attempt, scorer, artifacts].all? { |value| value.is_a?(Hash) }
        raise ValidationError, "AFW receipt provenance sections must be objects"
      end
      unless attempt["job_id"] == workload["job_id"] && attempt["status"] == "complete" && attempt["exit_status"] == 0
        raise ValidationError, "AFW receipt attempt is not an authoritative terminal success"
      end
      raise ValidationError, "AFW receipt job identity is incomplete" if blank?(workload["job_id"])
      raise ValidationError, "AFW receipt adventure identity is incomplete" if blank?(intent["adventure_id"])
      raise ValidationError, "AFW receipt scoring dimension is incomplete" if blank?(intent["dimension"])
      raise ValidationError, "AFW receipt artifact run identity is incomplete" if blank?(artifacts["run_id"])
    end

    def validate_artifacts!(receipt)
      root = File.realpath(@afw_root)
      ARTIFACT_NAMES.to_h do |name|
        reference = receipt.fetch("artifacts")[name]
        raise ValidationError, "AFW receipt artifact #{name} must be an object" unless reference.is_a?(Hash)

        relative = reference["path"].to_s
        expected = reference["sha256"].to_s
        if relative.empty? || Pathname.new(relative).absolute?
          raise ValidationError, "AFW receipt artifact #{name} path must be AFW-root-relative"
        end
        raise ValidationError, "AFW receipt artifact #{name} has invalid SHA-256" unless expected.match?(HEX_SHA256)

        candidate = File.expand_path(relative, @afw_root)
        root_prefix = "#{File.expand_path(@afw_root)}#{File::SEPARATOR}"
        unless candidate.start_with?(root_prefix)
          raise ValidationError, "AFW receipt artifact #{name} escapes AFW root"
        end
        bytes = read_file(candidate, "AFW receipt artifact #{name}")
        real = File.realpath(candidate)
        unless real.start_with?("#{root}#{File::SEPARATOR}")
          raise ValidationError, "AFW receipt artifact #{name} escapes AFW root"
        end
        actual = sha256(bytes)
        raise ValidationError, "AFW receipt artifact #{name} digest mismatch" unless actual == expected

        [name, { "path" => relative, "sha256" => actual, "bytes" => bytes }]
      end
    rescue Errno::ENOENT => e
      raise ValidationError, "missing AFW root or artifact: #{e.message}"
    end

    def candidates_from(receipt, artifacts, receipt_bytes)
      table = CSV.parse(artifacts.fetch("proposed_assessment").fetch("bytes"), headers: true)
      required = %w[run_id status adventure_id metric value assessment_state rationale provider model]
      missing = required - Array(table.headers)
      raise ValidationError, "proposed assessment missing columns: #{missing.join(', ')}" unless missing.empty?
      raise ValidationError, "proposed assessment contains no candidates" if table.empty?

      intent = receipt.fetch("scoring_intent")
      artifact_run_id = receipt.fetch("artifacts").fetch("run_id").to_s
      rows = table.map(&:to_h)
      metrics = rows.map { |row| row["metric"] }
      expected_metrics = intent["dimension"] == "Levels" ? LEVELS_METRICS : [intent["dimension"]]
      valid = metrics.sort == expected_metrics.sort && rows.all? do |row|
        row["run_id"] == artifact_run_id && row["status"] == "PROPOSED" &&
          row["adventure_id"] == intent["adventure_id"] && row["model"] == intent["ollama_model"]
      end
      raise ValidationError, "proposed assessment does not match the AFW receipt" unless valid

      rows.map do |row|
        candidate_from(receipt, artifacts, receipt_bytes, row)
      end.sort_by { |candidate| candidate.fetch("candidate_key") }.tap do |candidates|
        keys = candidates.map { |candidate| candidate.fetch("candidate_key") }
        duplicates = keys.tally.select { |_key, count| count > 1 }.keys
        unless duplicates.empty?
          raise ValidationError, "proposed assessment has duplicate candidate keys: #{duplicates.join(', ')}"
        end
      end
    end

    def candidate_from(receipt, artifacts, receipt_bytes, row)
      workload = receipt.fetch("workload")
      intent = receipt.fetch("scoring_intent")
      attempt = receipt.fetch("attempt")
      scorer = receipt.fetch("scorer_provenance")
      metric = row.fetch("metric")
      assessment = artifacts.fetch("proposed_assessment")
      raw_response = artifacts.fetch("raw_response")
      receipt_relative = begin
        Pathname.new(@receipt_path).relative_path_from(Pathname.new(@afw_root)).to_s
      rescue ArgumentError
        @receipt_path
      end

      {
        "schema_version" => CANDIDATE_CONTRACT,
        "adapter" => "AfwScoringEvidenceReceiptV01",
        "candidate_key" => "#{intent.fetch('adventure_id')}::#{metric}",
        "adventure_id" => intent.fetch("adventure_id"),
        "adventure_title" => row["adventure_title"],
        "source_book" => row["source_book"],
        "dimension" => metric,
        "metric_kind" => row["metric_kind"],
        "assessment_state" => row.fetch("assessment_state"),
        "value" => coerce_value(row.fetch("value")),
        "range_low" => coerce_value(row["range_low"]),
        "range_high" => coerce_value(row["range_high"]),
        "confidence" => coerce_value(row["confidence"]),
        "path_sensitive" => coerce_bool(row["path_sensitive"]),
        "path_variation_affects_anchor" => coerce_bool(row["path_variation_affects_anchor"]),
        "rationale" => row.fetch("rationale"),
        "adjacent_lower_reason" => row["adjacent_lower_reason"],
        "adjacent_higher_reason" => row["adjacent_higher_reason"],
        "evidence" => parse_evidence(row["evidence"]),
        "review_disposition" => row["review_disposition"],
        "hold_reason" => row["hold_reason"],
        "metric_review_flags" => row["metric_review_flags"],
        "package_review_flags" => row["package_review_flags"],
        "afao_version" => row["afao_version"],
        "assessment_spec_version" => row["assessment_spec_version"],
        "provider" => row.fetch("provider"),
        "model" => row.fetch("model"),
        "scoring_run_id" => row.fetch("run_id"),
        "lme_run_id" => row.fetch("run_id"),
        "experiment_name" => workload["plan_id"],
        "scorer_commit" => scorer["scorer_commit"],
        "afw_receipt_id" => receipt.fetch("receipt_id"),
        "afw_plan_sha256" => workload["plan_sha256"],
        "afw_job_id" => workload["job_id"],
        "wlo_attempt" => attempt["attempt"],
        "scorer_provenance" => scorer,
        "provenance" => {
          "metadata" => { "source_path" => receipt_relative, "source_sha256" => sha256(receipt_bytes) },
          "assessment" => { "source_path" => assessment.fetch("path"), "source_sha256" => assessment.fetch("sha256") },
          "raw_response" => { "source_path" => raw_response.fetch("path"), "source_sha256" => raw_response.fetch("sha256") }
        },
        "mechanical_status" => "valid"
      }
    end

    def package_id(receipt, candidates)
      identity = {
        "contract_version" => PACKAGE_CONTRACT,
        "afw_receipt_id" => receipt.fetch("receipt_id"),
        "candidates" => candidates
      }
      sha256(canonical_json(identity))
    end

    def package_files(receipt, candidates, package_id)
      candidates_bytes = candidates.map { |candidate| JSON.generate(candidate) }.join("\n") + "\n"
      holds_bytes = ""
      report = {
        "schema_version" => INTEGRITY_CONTRACT,
        "package_id" => package_id,
        "afw_receipt_id" => receipt.fetch("receipt_id"),
        "candidates" => candidates.length,
        "holds" => 0,
        "mechanically_invalid_runs" => 0,
        "expectation_match" => true,
        "errors" => []
      }
      manifest = {
        "contract_version" => PACKAGE_CONTRACT,
        "package_id" => package_id,
        "source" => {
          "contract_version" => RECEIPT_CONTRACT,
          "receipt_id" => receipt.fetch("receipt_id"),
          "semantic_status" => RECEIPT_STATUS,
          "workload" => receipt.fetch("workload"),
          "scoring_intent" => receipt.fetch("scoring_intent"),
          "attempt" => receipt.fetch("attempt"),
          "artifacts" => receipt.fetch("artifacts")
        },
        "candidate_count" => candidates.length,
        "decision_ledger" => {
          "authority" => "editorial_decisions.csv",
          "candidate_decisions" => EditorialAudit::CANDIDATE_DECISIONS,
          "initial_state" => "pending"
        },
        "mutation_boundary" => "review_only_no_canonical_or_amc_mutation"
      }
      {
        "candidates.jsonl" => candidates_bytes,
        "holds.jsonl" => holds_bytes,
        "integrity_report.json" => JSON.pretty_generate(report) + "\n",
        "review_package.json" => JSON.pretty_generate(manifest) + "\n"
      }
    end

    def write_or_verify_package!(desired)
      if File.exist?(@review_dir)
        raise ValidationError, "review package path is not a directory: #{@review_dir}" unless File.directory?(@review_dir)
        actual_names = Dir.children(@review_dir).sort
        unless actual_names == PACKAGE_FILES.sort
          raise ValidationError, "existing review package file set conflicts with requested package"
        end
        mismatch = PACKAGE_FILES.find { |name| File.binread(File.join(@review_dir, name)) != desired.fetch(name) }
        raise ValidationError, "existing review package conflicts at #{mismatch}" if mismatch

        return true
      end

      parent = File.dirname(@review_dir)
      FileUtils.mkdir_p(parent)
      temporary = Dir.mktmpdir(".scoring-review-", parent)
      desired.each { |name, bytes| File.binwrite(File.join(temporary, name), bytes) }
      File.rename(temporary, @review_dir)
      temporary = nil
      false
    rescue Errno::EEXIST, Errno::ENOTEMPTY
      raise ValidationError, "review package was created concurrently: #{@review_dir}"
    ensure
      FileUtils.remove_entry(temporary) if temporary && File.exist?(temporary)
    end

    def prepare_or_validate_audit!
      manifest = File.join(@audit_dir, "audit_manifest.json")
      ledger = File.join(@audit_dir, "editorial_decisions.csv")
      if File.exist?(manifest) || File.exist?(ledger)
        unless File.file?(manifest) && File.file?(ledger)
          raise ValidationError, "existing editorial audit is incomplete"
        end
        audit_manifest = parse_object(File.binread(manifest), "editorial audit manifest")
        bound_review = EditorialAudit.resolve_review_dir(@audit_dir, audit_manifest)
        unless File.expand_path(bound_review) == @review_dir
          raise ValidationError, "existing editorial audit is bound to a different review package"
        end
      else
        EditorialAudit.initialize!(review_dir: @review_dir, audit_dir: @audit_dir)
      end

      Dir.mktmpdir("scoring-review-validation-", PrivateDataRoot.selected) do |output|
        validation = EditorialAudit.validate!(audit_dir: @audit_dir, output_dir: output)
        unless validation.errors.empty?
          raise ValidationError, "existing editorial audit is invalid: #{validation.errors.join('; ')}"
        end
        validation
      end
    end

    def parse_object(bytes, label)
      value = JSON.parse(bytes)
      raise ValidationError, "#{label} must be a JSON object" unless value.is_a?(Hash)

      value
    end

    def parse_evidence(value)
      return [] if blank?(value)

      parsed = JSON.parse(value)
      raise ValidationError, "proposed assessment evidence must be a JSON array" unless parsed.is_a?(Array)

      parsed
    rescue JSON::ParserError => e
      raise ValidationError, "proposed assessment evidence is malformed JSON: #{e.message}"
    end

    def coerce_value(value)
      return nil if blank?(value)
      return Integer(value, 10) if value.to_s.match?(/\A-?\d+\z/)
      return Float(value) if value.to_s.match?(/\A-?\d+(?:\.\d+)?\z/)

      value
    rescue ArgumentError
      value
    end

    def coerce_bool(value)
      return true if value.to_s.casecmp?("true")
      return false if value.to_s.casecmp?("false")

      nil
    end

    def read_file(path, label)
      raise ValidationError, "missing #{label}: #{path}" unless File.file?(path)

      File.binread(path)
    end

    def validate_within_afw_root!(path, label)
      root = File.realpath(@afw_root)
      real = File.realpath(path)
      return if real.start_with?("#{root}#{File::SEPARATOR}")

      raise ValidationError, "#{label} escapes AFW root"
    rescue Errno::ENOENT => e
      raise ValidationError, "missing AFW root or #{label}: #{e.message}"
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array
        value.map { |entry| canonical(entry) }
      else
        value
      end
    end

    def sha256(bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
