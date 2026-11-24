# frozen_string_literal: true

require_relative "evidence_compatibility"

module AfDataPipeline
  # Pipeline compatibility for the standalone EV owner; inputs and results retain
  # their existing shape, and EV validation is mapped to pipeline exceptions.
  class EvidenceIndexVerifier < AfEvidence::EvidenceIndexVerifier
    extend EvidenceCompatibility
    map_evidence_errors :initialize, :verify!
  end
end
