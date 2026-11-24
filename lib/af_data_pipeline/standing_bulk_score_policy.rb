# frozen_string_literal: true

module AfDataPipeline
  # Validates the durable project-owner directive used by bulk score release.
  # The policy grants application authority only; it is not a semantic review.
  class StandingBulkScorePolicy
    POLICY_SCHEMA = "adventurefinder-standing-bulk-score-ingestion-policy/v0.1"
    SELECTION_SCHEMA = "adventurefinder-project-owner-standing-policy-selection/v0.1"
    POLICY_ID = "adventurefinder-standing-bulk-score-ingestion"
    STATUS = %w[ACTIVE REVOKED].freeze
    HEX_SHA256 = /\A[0-9a-f]{64}\z/
    DIMENSIONS = AmcApply::DIMENSION_HEADERS.keys.uniq.freeze

    Result = Data.define(:policy, :selection, :policy_binding, :selection_binding)

    def self.validate!(policy_path:, selection_path:)
      new(policy_path:, selection_path:).validate!
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def self.file_binding(path)
      {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
    end

    def initialize(policy_path:, selection_path:)
      @policy_path = File.expand_path(policy_path)
      @selection_path = File.expand_path(selection_path)
    end

    def validate!
      policy = read_json(@policy_path, "standing policy")
      selection = read_json(@selection_path, "owner selection")
      exact_keys!(selection, %w[
        schema_version project policy_id policy_version decision selected_by selection_evidence selection_id
      ], "owner selection")
      require_value!(selection, "schema_version", SELECTION_SCHEMA, "owner selection")
      require_value!(selection, "project", "AdventureFinder", "owner selection")
      require_value!(selection, "policy_id", POLICY_ID, "owner selection")
      require_value!(selection, "decision", "ACTIVATE", "owner selection")
      text!(selection["policy_version"], "owner selection policy_version")
      text!(selection["selected_by"], "owner selection selected_by")
      evidence = selection["selection_evidence"]
      unless evidence.is_a?(Hash) && evidence.keys.sort == %w[kind reference] &&
             evidence["kind"] == "project_owner_directive"
        raise ValidationError, "owner selection evidence is malformed"
      end
      text!(evidence["reference"], "owner selection evidence reference")
      unless selection["selection_id"] == self.class.digest(selection.except("selection_id"))
        raise ValidationError, "owner selection identity mismatch"
      end

      exact_keys!(policy, %w[
        schema_version policy_id policy_version status scope flag_rules activation revision_id policy_digest
      ], "standing policy")
      require_value!(policy, "schema_version", POLICY_SCHEMA, "standing policy")
      require_value!(policy, "policy_id", POLICY_ID, "standing policy")
      text!(policy["policy_version"], "standing policy version")
      unless STATUS.include?(policy["status"])
        raise ValidationError, "standing policy status is invalid"
      end
      raise ValidationError, "standing bulk score policy is revoked" unless policy["status"] == "ACTIVE"
      validate_scope!(policy["scope"])
      validate_flags!(policy["flag_rules"])
      activation = policy["activation"]
      unless activation.is_a?(Hash) && activation.keys.sort == %w[activation_id owner_selection_id]
        raise ValidationError, "standing policy activation is malformed"
      end
      text!(activation["activation_id"], "standing policy activation_id")
      unless activation["owner_selection_id"] == selection["selection_id"] &&
             policy["policy_version"] == selection["policy_version"]
        raise ValidationError, "standing policy does not bind the owner selection"
      end
      text!(policy["revision_id"], "standing policy revision_id")
      unless policy["policy_digest"].match?(HEX_SHA256) &&
             policy["policy_digest"] == self.class.digest(policy.except("policy_digest"))
        raise ValidationError, "standing policy digest mismatch"
      end

      Result.new(
        policy:,
        selection:,
        policy_binding: self.class.file_binding(@policy_path),
        selection_binding: self.class.file_binding(@selection_path)
      )
    end

    private

    def validate_scope!(scope)
      unless scope.is_a?(Hash) && scope.keys.sort == %w[
        dimensions model_aliases models page_eligibility profiles source_scope
      ]
        raise ValidationError, "standing policy scope is malformed"
      end
      %w[profiles model_aliases models dimensions].each do |key|
        values = scope[key]
        unless values.is_a?(Array) && !values.empty? &&
               values.all? { |value| value.is_a?(String) && !value.empty? } && values.uniq == values
          raise ValidationError, "standing policy scope #{key} must be a unique non-empty string array"
        end
      end
      unknown = scope["dimensions"] - DIMENSIONS
      raise ValidationError, "standing policy has unsupported dimensions: #{unknown.join(', ')}" unless unknown.empty?
      unless scope["source_scope"] == "operation-bound-exact-source"
        raise ValidationError, "standing policy source scope is unsupported"
      end
      unless scope["page_eligibility"] == "frozen-qualified-workload"
        raise ValidationError, "standing policy page eligibility is unsupported"
      end
    end

    def validate_flags!(rules)
      unless rules.is_a?(Hash) && rules.keys.sort == %w[advisory hard_refusal]
        raise ValidationError, "standing policy flag rules are malformed"
      end
      %w[advisory hard_refusal].each do |key|
        values = rules[key]
        unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) && !value.empty? } &&
               values.uniq == values
          raise ValidationError, "standing policy #{key} flags are malformed"
        end
      end
      overlap = rules["advisory"] & rules["hard_refusal"]
      raise ValidationError, "standing policy flags have ambiguous severity: #{overlap.join(', ')}" unless overlap.empty?
    end

    def read_json(path, label)
      raise ValidationError, "missing #{label}: #{path}" unless File.file?(path)
      value = JSON.parse(File.binread(path))
      raise ValidationError, "#{label} must be an object" unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => e
      raise ValidationError, "malformed #{label}: #{e.message}"
    end

    def exact_keys!(value, keys, label)
      unless value.is_a?(Hash) && value.keys.sort == keys.sort
        raise ValidationError, "#{label} has unexpected fields"
      end
    end

    def require_value!(value, key, expected, label)
      raise ValidationError, "#{label} #{key} is invalid" unless value[key] == expected
    end

    def text!(value, label)
      raise ValidationError, "#{label} is blank" unless value.is_a?(String) && !value.strip.empty?
    end
  end
end
