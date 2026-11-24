# frozen_string_literal: true

require_relative "evidence_compatibility"

module AfDataPipeline
  # Pipeline compatibility for the standalone EV owner; inputs and results retain
  # their existing shape, and EV validation is mapped to pipeline exceptions.
  class EvidenceBundleVerifier < AfEvidence::EvidenceBundleVerifier
    extend EvidenceCompatibility
    map_evidence_errors :initialize, :verify!

    # Preserves direct pipeline compression calls and their exception contract.
    class ZstdDecompressor < AfEvidence::EvidenceBundleVerifier::ZstdDecompressor
      extend EvidenceCompatibility
      map_evidence_errors :initialize, :decompress!
    end
  end
end
