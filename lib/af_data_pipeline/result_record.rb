# frozen_string_literal: true
module AfDataPipeline
  class ResultRecord
    SCHEMA_VERSION="af-result-record/v0.1"
    ADV_ID=/\AADV-\d{4}\z/
    attr_reader :data
    def initialize(data); @data=stringify_keys(data); validate!; end
    def to_h; data.dup; end
    private
    def validate!
      errors=[]
      errors << "schema_version must be #{SCHEMA_VERSION.inspect}" unless data["schema_version"]==SCHEMA_VERSION
      errors << "adventure_id must match ADV-####" unless data["adventure_id"].to_s.match?(ADV_ID)
      errors << "dimension must be non-empty" if data["dimension"].to_s.strip.empty?
      errors << "score must be an integer in 1..5" unless data["score"].is_a?(Integer) && (1..5).cover?(data["score"])
      errors << "reason must be non-empty" if data["reason"].to_s.strip.empty?
      raise ValidationError, errors.join("; ") unless errors.empty?
    end
    def stringify_keys(hash); hash.to_h.each_with_object({}) { |(k,v),o| o[k.to_s]=v }; end
  end
end
