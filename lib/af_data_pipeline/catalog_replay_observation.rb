# frozen_string_literal: true

require_relative "error"
require_relative "project_state"
require_relative "standing_bulk_score_policy"

module AfDataPipeline
  # The pipeline's validation-only replay view. Exactly one manifest uses the
  # owner's verified historical observation; all other workflow inputs stay live.
  class CatalogReplayObservation
    prepend XlsxFilesErrors.wrap(:initialize, :file_binding, :project_state, :assert_current!)

    HistoricalErrors = XlsxFilesErrors.wrap(:validate!, :resolve, :promote!)
    private_constant :HistoricalErrors

    # Bind a reviewed snapshot and its historical manifest reference.
    # Inexact reviewed or live storage raises ValidationError.
    def initialize(snapshot:, historical_binding:)
      @storage = AfXlsxFiles::Internal::CatalogStorage::Replay.new(snapshot:, historical_binding:)
    end

    # Return hash and size from the historical manifest or the live input.
    # Inexact replay raises ValidationError; other read errors propagate.
    def file_binding(path)
      return StandingBulkScorePolicy.file_binding(path) unless @storage.observes?(path)
      @storage.binding
    end

    # Return a read-only historical manifest or normal project state for path.
    # A changed replay raises ValidationError.
    def project_state(path)
      return ProjectState.new(manifest_path: path) unless @storage.observes?(path)
      @storage.project_state.extend(HistoricalErrors)
    end

    # Recheck the exact promoted bytes and return true or raise ValidationError.
    def assert_current!
      @storage.assert_current!
    end
  end
end
