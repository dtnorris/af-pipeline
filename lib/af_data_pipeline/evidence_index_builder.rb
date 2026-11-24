# frozen_string_literal: true

require_relative "evidence_compatibility"

module AfDataPipeline
  # Pipeline compatibility for the standalone EV owner; inputs and results retain
  # their existing shape, and EV validation is mapped to pipeline exceptions.
  class EvidenceIndexBuilder < AfEvidence::EvidenceIndexBuilder
    extend EvidenceCompatibility
    map_evidence_errors :initialize, :build!
  end
end
