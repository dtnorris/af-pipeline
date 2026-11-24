# frozen_string_literal: true

require_relative "evidence_compatibility"

module AfDataPipeline
  # Pipeline compatibility for the standalone EV owner; inputs and results retain
  # their existing shape, and EV validation is mapped to pipeline exceptions.
  class EvidenceBundleBuilder < AfEvidence::EvidenceBundleBuilder
    extend EvidenceCompatibility
    map_evidence_errors :initialize, :build!

    # Preserves direct pipeline compression calls and their exception contract.
    class ZstdCompressor < AfEvidence::EvidenceBundleBuilder::ZstdCompressor
      extend EvidenceCompatibility
      map_evidence_errors :initialize, :compress!
    end
  end
end
