# frozen_string_literal: true

require_relative "evidence_compatibility"
require_relative "private_data_root"

module AfDataPipeline
  # Pipeline compatibility for the standalone EV owner; inputs and results retain
  # their existing shape, and EV validation is mapped to pipeline exceptions.
  class EvidenceRetriever < AfEvidence::EvidenceRetriever
    extend EvidenceCompatibility
    map_evidence_errors :initialize, :extract_member!, :extract_run!

    private

    # Applies selected-root/opt-in PL authorization before EV independently checks
    # local safety. Returns EV's absolute destination or raises ValidationError.
    def safe_file_output(path)
      PrivateDataRoot.destination!(path)
      super
    end
  end
end
