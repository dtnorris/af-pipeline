# frozen_string_literal: true

require "json"
require "digest"
require "minitest"

# Authoritative worker accounting, independent of presentation and telemetry.
# Process exits and coverage checks retain their independent vetoes.
module AfTestSuiteResult
  SCHEMA = "afdp-worker-result/v1"
  BINDING_KEYS = %w[run_id suite worker population_sha256 selection_sha256].freeze
  COUNTERS = %w[tests assertions failures errors skips].freeze
  KEYS = (BINDING_KEYS + COUNTERS + %w[schema status]).sort.freeze

  # Raised when an expected worker's evidence is absent, ambiguous or incomplete.
  class InvalidResult < StandardError; end

  # Reject ambiguous JSON keys instead of silently keeping the last value.
  class Document < Hash
    # Stores a parsed JSON field; duplicate keys raise InvalidResult.
    def []=(key, value)
      raise InvalidResult, "duplicate terminal result field: #{key}" if key?(key)

      super
    end
  end

  # Returns the SHA-256 of a sorted JSON array of fully qualified test names.
  # Duplicate names remain significant; selection and execution use this format.
  def self.fingerprint(methods)
    Digest::SHA256.hexdigest(JSON.generate(methods.sort))
  end

  # Registers one private worker reporter using its path, binding and selection.
  # The explicitly registered plugin also runs with plugin auto-loading disabled.
  def self.install(path:, identity:, selection:)
    @worker_reporter = Reporter.new(path: path, identity: identity, selection: selection)
    Minitest.extensions << self
  end

  # Adds the prepared reporter at Minitest's plugin setup hook; returns no result.
  # Called only in workers, before execution, with Minitest's options hash.
  def self.minitest_plugin_init(_options)
    Minitest.reporter << @worker_reporter
  end

  # Validates a complete worker inventory against independently supplied bindings
  # and observed Process::Status objects. Returns parsed records in worker order;
  # raises InvalidResult for missing/duplicate, corrupt, stale or incomplete data.
  # Normal Minitest failure exits remain valid evidence, never proof of a pass.
  def self.verify!(paths, expected:, statuses:)
    unless !paths.empty? && paths.uniq == paths && paths.length == expected.length &&
        statuses.length == paths.length && expected.map { |entry| entry["worker"] } == (1..paths.length).to_a &&
        %w[run_id suite population_sha256].all? { |key| expected.map { |entry| entry[key] }.uniq.length == 1 }
      raise InvalidResult, "terminal worker inventory is incomplete or duplicated"
    end

    paths.each_with_index.map do |path, index|
      verify_worker!(path, expected: expected.fetch(index), status: statuses.fetch(index))
    end
  end

  # Validates one exited worker against its independently assigned identity and
  # selection. Returns counters or raises InvalidResult; stdout is never read.
  def self.verify_worker!(path, expected:, status:)
    record = JSON.parse(File.binread(path), object_class: Document, allow_duplicate_key: false)
    binding = expected
    unless status && status.exited? && [0, 1].include?(status.exitstatus)
      raise InvalidResult, "worker #{expected.fetch('worker')} did not exit normally through Minitest"
    end
    unless record.is_a?(Hash) && record.keys.sort == KEYS && record["schema"] == SCHEMA &&
        record["status"] == "complete" && record["run_id"].is_a?(String) &&
        record["run_id"].match?(/\A[0-9a-f]{32}\z/) && %w[fast integration all].include?(record["suite"]) &&
        record["worker"].is_a?(Integer) && record["worker"].positive? &&
        %w[population_sha256 selection_sha256].all? { |key|
          record[key].is_a?(String) && record[key].match?(/\A[0-9a-f]{64}\z/)
        } && BINDING_KEYS.all? { |key| record[key] == binding[key] } &&
        COUNTERS.all? { |key| record[key].is_a?(Integer) && record[key] >= 0 } &&
        record["tests"] == binding["tests"] &&
        record.values_at("failures", "errors", "skips").sum <= record["tests"]
      raise InvalidResult, "worker #{expected.fetch('worker')} terminal result is malformed, mismatched or incomplete"
    end
    record
  rescue SystemCallError, JSON::ParserError => error
    raise InvalidResult, "worker #{expected.fetch('worker')} terminal result is missing or corrupt: #{error.message}"
  end

  # Observes Minitest results directly, including failures/errors/skips. It emits
  # one terminal document after reporting, without parsing stdout.
  class Reporter < Minitest::StatisticsReporter
    # Accepts the private result path, run binding and assigned test-name array.
    # Initializes counters without changing Minitest's summary reporter.
    def initialize(path:, identity:, selection:)
      super()
      @path, @identity, @selection = path, identity, selection.sort
      @methods = []
    end

    # Records one Minitest::Result and its fully qualified name; returns no count.
    def record(result)
      super
      @methods << "#{result.class_name}##{result.name}"
    end

    # Emits counters and the observed selection fingerprint. Partial execution
    # is explicitly incomplete. Duplicate emissions append a second JSON document
    # so validation rejects them. I/O/reporting errors leave missing evidence, which the parent rejects.
    def report
      super
      record = @identity.merge("schema" => SCHEMA,
        "selection_sha256" => AfTestSuiteResult.fingerprint(@methods),
        "status" => @methods.sort == @selection ? "complete" : "incomplete",
        "tests" => count, "assertions" => assertions, "failures" => failures,
        "errors" => errors, "skips" => skips)
      File.open(@path, "ab") { |file| file.write(JSON.generate(record) + "\n") }
    rescue StandardError => error
      warn "Worker terminal result unavailable: #{error.class}: #{error.message}"
    end

    # Always returns true: existing reporters retain independent exit authority,
    # including Minitest options such as warning-as-error handling.
    def passed?
      true
    end
  end
end
