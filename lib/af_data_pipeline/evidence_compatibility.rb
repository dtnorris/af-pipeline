# frozen_string_literal: true

# Load the selected public evidence owner. Missing or conflicting code raises LoadError.
evidence_root = ENV["AF_EVIDENCE_ROOT"]
unless evidence_root && File.absolute_path(evidence_root) == evidence_root && File.directory?(evidence_root)
  raise LoadError, "set AF_EVIDENCE_ROOT to the pinned public evidence owner"
end
evidence_entry = File.realpath(File.join(evidence_root, "lib", "af_evidence.rb"))
loaded_evidence = $LOADED_FEATURES.find { |feature| feature.end_with?("/af_evidence.rb") }
if loaded_evidence && File.realpath(loaded_evidence) != evidence_entry
  raise LoadError, "another af-evidence owner is already loaded: #{loaded_evidence}"
end
require evidence_entry
require_relative "error"

module AfDataPipeline
  # Keeps pipeline exception identities while mechanics live exclusively in EV.
  # Only public owner calls cross this boundary; validators are never replaced.
  module EvidenceCompatibility
    # Wraps the named inherited instance methods, forwarding inputs/results and
    # blocks unchanged. EV validation failures become PL ValidationError; other
    # exceptions propagate. This includes explicit compressor/decompressor calls.
    def map_evidence_errors(*method_names)
      method_names.each do |method_name|
        define_method(method_name) do |*arguments, **keywords, &block|
          super(*arguments, **keywords, &block)
        rescue AfEvidence::ValidationError => error
          raise ValidationError, error.message
        end
      end
    end
  end
end
