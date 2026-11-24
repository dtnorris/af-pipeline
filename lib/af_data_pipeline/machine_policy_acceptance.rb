# frozen_string_literal: true

module AfDataPipeline
  # Validates the durable provenance record for a policy decision about one
  # exact scoring candidate. It does not evaluate policy, create records, edit
  # human ledgers, or apply accepted values.
  class MachinePolicyAcceptance
    SCHEMA_VERSION = "adventurefinder-machine-policy-acceptance/v0.1"
    RECORD_TYPE = "machine_policy_acceptance"
    POLICY_SCHEMA = "adventurefinder-scoring-acceptance-policy/v0.1"
    RECEIPT_CONTRACT = "afw-scoring-evidence-receipt/v0.1"
    RECEIPT_STATUS = "provenance_validated_proposed_scoring_evidence"
    STATES = %w[PROPOSED ACCEPTED].freeze
    ATTEMPT_STATUSES = %w[complete failed interrupted running].freeze
    HUMAN_DECISIONS = %w[ACCEPT HOLD REJECT].freeze
    BINDING_SECTIONS = %w[candidate evidence workload attempt qualification policy decision].freeze
    HEX_SHA256 = /\A[0-9a-f]{64}\z/
    GIT_SHA = /\A[0-9a-f]{40}\z/
    ROOT_NAME = /\A[a-z][a-z0-9_-]*\z/

    Validation = Data.define(:record_id, :binding_sha256, :state, :authoritative)

    def self.validate_file!(path:, roots: {}, current: nil, existing_path: nil)
      bytes = File.binread(path)
      document = JSON.parse(bytes)
      existing_bytes = File.binread(existing_path) if existing_path
      validate!(document, roots:, current:, bytes:, existing_bytes:)
    rescue Errno::ENOENT, JSON::ParserError => e
      raise ValidationError, "invalid machine policy acceptance record: #{e.message}"
    end

    def self.validate!(document, roots: {}, current: nil, bytes: nil, existing_bytes: nil)
      new(document, roots:, current:, bytes:, existing_bytes:).validate!
    end

    def initialize(document, roots:, current:, bytes:, existing_bytes:)
      @document = document
      @roots = roots.transform_keys(&:to_s)
      @current = current
      @bytes = bytes
      @existing_bytes = existing_bytes
    end

    def validate!
      require_hash!(@document, "record")
      require_exact_keys!(@document, %w[
        schema_version record_type record_state authority candidate evidence workload attempt qualification policy
        decision prerequisites evaluator producer recorded_at binding_sha256 record_id
      ], "record")
      require_value!(@document, "schema_version", SCHEMA_VERSION)
      require_value!(@document, "record_type", RECORD_TYPE)
      state = require_enum!(@document, "record_state", STATES)

      validate_authority!(state)
      validate_candidate!
      validate_evidence!
      validate_workload!
      validate_attempt!
      validate_qualification!
      validate_policy!(state)
      validate_decision!(state)
      validate_prerequisites!(state)
      validate_software_identity!(@document.fetch("evaluator"), "evaluator")
      validate_software_identity!(@document.fetch("producer"), "producer")
      validate_timestamp!
      validate_binding_identity!
      validate_record_identity!
      validate_current!
      validate_collision!

      Validation.new(
        record_id: @document.fetch("record_id"),
        binding_sha256: @document.fetch("binding_sha256"),
        state:,
        authoritative: @document.dig("authority", "authoritative")
      )
    end

    private

    def validate_authority!(state)
      authority = @document.fetch("authority")
      require_hash!(authority, "authority")
      require_exact_keys!(authority, %w[kind authoritative human_reviewed human_decision], "authority")
      expected_kind = state == "ACCEPTED" ? "MACHINE_POLICY_ACCEPTANCE" : "MACHINE_POLICY_PROPOSAL"
      require_value!(authority, "kind", expected_kind)
      require_value!(authority, "authoritative", state == "ACCEPTED")
      require_value!(authority, "human_reviewed", false)
      require_value!(authority, "human_decision", nil)
    end

    def validate_candidate!
      candidate = @document.fetch("candidate")
      require_hash!(candidate, "candidate")
      require_exact_keys!(candidate, %w[
        key content_sha256 adventure_id dimension metric proposed_value
      ], "candidate")
      %w[key adventure_id dimension metric].each { |key| require_string!(candidate, key) }
      require_sha!(candidate.fetch("content_sha256"), "candidate.content_sha256")
      unless candidate.fetch("key") == "#{candidate.fetch('adventure_id')}::#{candidate.fetch('metric')}"
        raise ValidationError, "candidate key does not bind adventure and metric"
      end
      if candidate.fetch("dimension") == "Levels"
        unless ["Level Start", "Level End"].include?(candidate.fetch("metric"))
          raise ValidationError, "Levels candidate metric must be Level Start or Level End"
        end
      elsif candidate.fetch("dimension") != candidate.fetch("metric")
        raise ValidationError, "scalar candidate metric must equal dimension"
      end

      content = candidate.reject { |key, _value| key == "content_sha256" }
      unless candidate.fetch("content_sha256") == sha256(canonical_json(content))
        raise ValidationError, "candidate content identity mismatch"
      end
    end

    def validate_evidence!
      evidence = @document.fetch("evidence")
      require_hash!(evidence, "evidence")
      require_exact_keys!(evidence, %w[
        receipt review_package scoring_artifacts review_conditions review_conditions_sha256
      ], "evidence")
      receipt = evidence.fetch("receipt")
      require_hash!(receipt, "evidence.receipt")
      require_exact_keys!(receipt, %w[contract_version semantic_status receipt_id content_sha256 reference], "evidence.receipt")
      require_value!(receipt, "contract_version", RECEIPT_CONTRACT)
      require_value!(receipt, "semantic_status", RECEIPT_STATUS)
      require_sha!(receipt.fetch("receipt_id"), "evidence.receipt.receipt_id")
      require_sha!(receipt.fetch("content_sha256"), "evidence.receipt.content_sha256")
      validate_reference!(receipt.fetch("reference"), "evidence.receipt.reference")
      validate_reference!(evidence.fetch("review_package"), "evidence.review_package")

      artifacts = evidence.fetch("scoring_artifacts")
      unless artifacts.is_a?(Array) && !artifacts.empty?
        raise ValidationError, "evidence.scoring_artifacts must be a non-empty array"
      end
      artifacts.each_with_index do |artifact, index|
        require_hash!(artifact, "evidence.scoring_artifacts[#{index}]")
        require_exact_keys!(artifact, %w[kind reference], "evidence.scoring_artifacts[#{index}]")
        require_string!(artifact, "kind")
        validate_reference!(artifact.fetch("reference"), "evidence.scoring_artifacts[#{index}].reference")
      end
      kinds = artifacts.map { |artifact| artifact.fetch("kind") }
      raise ValidationError, "scoring artifact kinds must be unique" unless kinds.uniq.length == kinds.length

      conditions = evidence.fetch("review_conditions")
      require_hash!(conditions, "evidence.review_conditions")
      require_exact_keys!(conditions, %w[
        assessment_state review_flags source_hold existing_human_decision
      ], "evidence.review_conditions")
      require_string!(conditions, "assessment_state")
      unless conditions.fetch("review_flags").is_a?(Array) &&
             conditions.fetch("review_flags").all? { |flag| flag.is_a?(String) && !flag.empty? }
        raise ValidationError, "review_flags must be an array of non-empty strings"
      end
      require_boolean!(conditions.fetch("source_hold"), "source_hold")
      human = conditions.fetch("existing_human_decision")
      unless human.nil? || HUMAN_DECISIONS.include?(human)
        raise ValidationError, "existing_human_decision is invalid"
      end
      require_sha!(evidence.fetch("review_conditions_sha256"), "evidence.review_conditions_sha256")
      unless evidence.fetch("review_conditions_sha256") == sha256(canonical_json(conditions))
        raise ValidationError, "review conditions identity mismatch"
      end
    end

    def validate_workload!
      workload = @document.fetch("workload")
      require_hash!(workload, "workload")
      require_exact_keys!(workload, %w[
        manifest_id manifest_sha256 plan_id plan_sha256 case_id case job_id plan_job_sha256
      ], "workload")
      %w[manifest_id plan_id case_id job_id].each { |key| require_string!(workload, key) }
      %w[manifest_id manifest_sha256 plan_sha256 plan_job_sha256].each do |key|
        require_sha!(workload.fetch(key), "workload.#{key}")
      end
      validate_reference!(workload.fetch("case"), "workload.case")
      unless workload.fetch("case_id") == workload.fetch("job_id")
        raise ValidationError, "workload case and job identity mismatch"
      end
    end

    def validate_attempt!
      attempt = @document.fetch("attempt")
      require_hash!(attempt, "attempt")
      require_exact_keys!(attempt, %w[
        job_id number status exit_status authoritative retry superseded favorable_rerun metadata
      ], "attempt")
      require_string!(attempt, "job_id")
      unless attempt.fetch("number").is_a?(Integer) && attempt.fetch("number").positive?
        raise ValidationError, "attempt.number must be a positive integer"
      end
      require_enum!(attempt, "status", ATTEMPT_STATUSES)
      unless attempt.fetch("exit_status").nil? || attempt.fetch("exit_status").is_a?(Integer)
        raise ValidationError, "attempt.exit_status must be an integer or null"
      end
      require_boolean!(attempt.fetch("authoritative"), "attempt.authoritative")
      %w[retry superseded favorable_rerun].each do |key|
        require_boolean!(attempt.fetch(key), "attempt.#{key}")
      end
      validate_reference!(attempt.fetch("metadata"), "attempt.metadata")
      unless attempt.fetch("job_id") == @document.dig("workload", "job_id")
        raise ValidationError, "attempt does not match workload job"
      end
    end

    def validate_qualification!
      qualification = @document.fetch("qualification")
      require_hash!(qualification, "qualification")
      require_exact_keys!(qualification, %w[
        state profile_id artifact profile afw_contract_sha256 model runtime
      ], "qualification")
      %w[state profile_id].each { |key| require_string!(qualification, key) }
      validate_reference!(qualification.fetch("artifact"), "qualification.artifact")
      validate_reference!(qualification.fetch("profile"), "qualification.profile")
      require_sha!(qualification.fetch("afw_contract_sha256"), "qualification.afw_contract_sha256")

      model = qualification.fetch("model")
      require_hash!(model, "qualification.model")
      require_exact_keys!(model, %w[alias manifest_digest], "qualification.model")
      require_string!(model, "alias")
      require_sha!(model.fetch("manifest_digest"), "qualification.model.manifest_digest")

      runtime = qualification.fetch("runtime")
      require_hash!(runtime, "qualification.runtime")
      require_exact_keys!(runtime, %w[identity sha256], "qualification.runtime")
      require_string!(runtime, "identity")
      require_sha!(runtime.fetch("sha256"), "qualification.runtime.sha256")
    end

    def validate_policy!(state)
      policy = @document.fetch("policy")
      require_hash!(policy, "policy")
      require_exact_keys!(policy, %w[schema_version id version status artifact], "policy")
      require_value!(policy, "schema_version", POLICY_SCHEMA)
      %w[id version].each { |key| require_string!(policy, key) }
      expected_status = state == "ACCEPTED" ? "ENABLED" : "CANDIDATE_NOT_ENABLED"
      require_value!(policy, "status", expected_status)
      validate_reference!(policy.fetch("artifact"), "policy.artifact")
    end

    def validate_decision!(state)
      decision = @document.fetch("decision")
      require_hash!(decision, "decision")
      require_exact_keys!(decision, %w[result reasons evaluation_input evaluation_output], "decision")
      allowed = state == "ACCEPTED" ? ["MACHINE_ACCEPTED"] : %w[WOULD_MACHINE_ACCEPT HUMAN_REVIEW_REQUIRED]
      result = require_enum!(decision, "result", allowed)
      reasons = decision.fetch("reasons")
      unless reasons.is_a?(Array) && reasons.all? { |reason| reason.is_a?(String) && !reason.empty? }
        raise ValidationError, "decision.reasons must be an array of non-empty strings"
      end
      validate_reference!(decision.fetch("evaluation_input"), "decision.evaluation_input")
      validate_reference!(decision.fetch("evaluation_output"), "decision.evaluation_output")

      conditions = @document.dig("evidence", "review_conditions")
      accepting = %w[WOULD_MACHINE_ACCEPT MACHINE_ACCEPTED].include?(result)
      if accepting
        raise ValidationError, "accepting decision cannot contain reasons" unless reasons.empty?
        unless conditions.fetch("assessment_state") == "resolved" && conditions.fetch("review_flags").empty? &&
               conditions.fetch("source_hold") == false &&
               conditions.fetch("existing_human_decision").nil?
          raise ValidationError,
                "machine policy cannot accept unresolved assessments, review flags, source holds, or human decisions"
        end
        unless @document.dig("attempt", "status") == "complete" && @document.dig("attempt", "exit_status") == 0 &&
               @document.dig("attempt", "authoritative") == true && @document.dig("attempt", "retry") == false &&
               @document.dig("attempt", "superseded") == false &&
               @document.dig("attempt", "favorable_rerun") == false
          raise ValidationError, "accepting decision requires one authoritative successful unsuperseded attempt"
        end
        unless @document.dig("qualification", "state") == "LOCAL_QUALIFIED"
          raise ValidationError, "accepting decision requires final qualification"
        end
      elsif reasons.empty?
        raise ValidationError, "HUMAN_REVIEW_REQUIRED must contain reasons"
      end
    end

    def validate_prerequisites!(state)
      prerequisites = @document.fetch("prerequisites")
      require_hash!(prerequisites, "prerequisites")
      require_exact_keys!(prerequisites, %w[ig12b_evaluation application_authorization], "prerequisites")
      ig12b = validate_prerequisite!(
        prerequisites.fetch("ig12b_evaluation"), "ig12b_evaluation", %w[NOT_EVALUATED PASSED FAILED]
      )
      authorization = validate_prerequisite!(
        prerequisites.fetch("application_authorization"), "application_authorization", %w[NOT_GRANTED GRANTED]
      )
      return unless state == "ACCEPTED"

      unless ig12b == "PASSED" && authorization == "GRANTED"
        raise ValidationError, "authoritative acceptance requires successful IG-12B and explicit application authorization"
      end
      required_roots = referenced_roots
      missing_roots = required_roots - @roots.keys
      unless missing_roots.empty?
        raise ValidationError, "authoritative acceptance requires artifact revalidation roots: #{missing_roots.join(', ')}"
      end
    end

    def validate_prerequisite!(value, label, statuses)
      require_hash!(value, label)
      require_exact_keys!(value, %w[status artifact], label)
      status = require_enum!(value, "status", statuses)
      artifact = value.fetch("artifact")
      if %w[NOT_EVALUATED NOT_GRANTED].include?(status)
        raise ValidationError, "#{label}.artifact must be null for #{status}" unless artifact.nil?
      else
        validate_reference!(artifact, "#{label}.artifact")
      end
      status
    end

    def validate_software_identity!(value, label)
      require_hash!(value, label)
      require_exact_keys!(value, %w[id version git_commit code_sha256], label)
      %w[id version].each { |key| require_string!(value, key) }
      require_git_sha!(value.fetch("git_commit"), "#{label}.git_commit")
      require_sha!(value.fetch("code_sha256"), "#{label}.code_sha256")
    end

    def validate_timestamp!
      value = @document.fetch("recorded_at")
      time = Time.iso8601(value)
      raise ValidationError, "recorded_at must be UTC" unless value.end_with?("Z") && time.utc?
    rescue ArgumentError, TypeError
      raise ValidationError, "recorded_at must be an ISO-8601 UTC timestamp"
    end

    def validate_binding_identity!
      supplied = @document.fetch("binding_sha256")
      require_sha!(supplied, "binding_sha256")
      expected = sha256(canonical_json(binding_document(@document)))
      raise ValidationError, "binding identity mismatch" unless supplied == expected
    end

    def validate_record_identity!
      supplied = @document.fetch("record_id")
      require_sha!(supplied, "record_id")
      identity = @document.reject { |key, _value| %w[record_id recorded_at].include?(key) }
      expected = sha256(canonical_json(identity))
      raise ValidationError, "record identity mismatch" unless supplied == expected
    end

    def validate_current!
      return unless @current

      require_hash!(@current, "current bindings")
      BINDING_SECTIONS.each do |section|
        unless canonical_json(@current[section]) == canonical_json(@document.fetch(section))
          raise ValidationError, "stale machine policy acceptance: #{section} changed"
        end
      end
    end

    def validate_collision!
      return unless @existing_bytes

      existing = JSON.parse(@existing_bytes)
      existing_id = existing["record_id"]
      if existing_id == @document.fetch("record_id") && @bytes && @existing_bytes != @bytes
        raise ValidationError, "machine policy acceptance identity collision; refusing byte replacement"
      end
      unless existing_id == @document.fetch("record_id")
        raise ValidationError, "existing machine policy acceptance has a different immutable identity"
      end
    rescue JSON::ParserError => e
      raise ValidationError, "invalid existing machine policy acceptance record: #{e.message}"
    end

    def validate_reference!(reference, label)
      require_hash!(reference, label)
      require_exact_keys!(reference, %w[root path sha256], label)
      root_name = reference.fetch("root")
      path = reference.fetch("path")
      require_sha!(reference.fetch("sha256"), "#{label}.sha256")
      unless root_name.is_a?(String) && ROOT_NAME.match?(root_name)
        raise ValidationError, "#{label}.root is invalid"
      end
      unless path.is_a?(String) && !path.empty? && !Pathname.new(path).absolute? &&
             !Pathname.new(path).each_filename.include?("..")
        raise ValidationError, "#{label}.path must be root-relative without traversal"
      end
      return unless @roots.key?(root_name)

      root = File.realpath(@roots.fetch(root_name))
      candidate = File.expand_path(path, root)
      unless candidate.start_with?("#{root}#{File::SEPARATOR}") && File.file?(candidate)
        raise ValidationError, "#{label} is missing or escapes its root"
      end
      real = File.realpath(candidate)
      unless real.start_with?("#{root}#{File::SEPARATOR}")
        raise ValidationError, "#{label} escapes its root"
      end
      unless Digest::SHA256.file(real).hexdigest == reference.fetch("sha256")
        raise ValidationError, "#{label} digest mismatch"
      end
    rescue Errno::ENOENT => e
      raise ValidationError, "#{label} cannot be revalidated: #{e.message}"
    end

    def referenced_roots
      references = []
      walk = lambda do |value|
        case value
        when Hash
          if value.keys.sort == %w[path root sha256]
            references << value.fetch("root")
          else
            value.each_value { |child| walk.call(child) }
          end
        when Array then value.each { |child| walk.call(child) }
        end
      end
      walk.call(@document)
      references.uniq.sort
    end

    def binding_document(document)
      BINDING_SECTIONS.to_h { |section| [section, document.fetch(section)] }
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

    def require_hash!(value, label)
      raise ValidationError, "#{label} must be an object" unless value.is_a?(Hash)
    end

    def require_exact_keys!(value, keys, label)
      missing = keys - value.keys
      extra = value.keys - keys
      return if missing.empty? && extra.empty?

      raise ValidationError, "#{label} keys are incompatible (missing: #{missing.join(', ')}; extra: #{extra.join(', ')})"
    end

    def require_string!(hash, key)
      value = hash[key]
      raise ValidationError, "#{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?

      value
    end

    def require_value!(hash, key, expected)
      raise ValidationError, "#{key} must equal #{expected.inspect}" unless hash[key] == expected
    end

    def require_enum!(hash, key, allowed)
      value = hash[key]
      raise ValidationError, "#{key} must be one of #{allowed.join(', ')}" unless allowed.include?(value)

      value
    end

    def require_boolean!(value, label)
      raise ValidationError, "#{label} must be boolean" unless value == true || value == false
    end

    def require_sha!(value, label)
      raise ValidationError, "#{label} must be a lowercase SHA-256" unless HEX_SHA256.match?(value.to_s)
    end

    def require_git_sha!(value, label)
      raise ValidationError, "#{label} must be a lowercase 40-character Git SHA" unless GIT_SHA.match?(value.to_s)
    end
  end
end
