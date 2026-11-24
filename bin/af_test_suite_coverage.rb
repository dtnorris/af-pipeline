# frozen_string_literal: true

require "json"

module AfTestSuiteCoverage
  # The test runner accepts only one complete, attributable SimpleCov slice
  # from each selected worker before asking SimpleCov to collate them.
  class InvalidResult < StandardError; end

  def self.verify!(paths, names: nil, started_at: nil)
    if paths.empty? || paths.uniq != paths || names && names.length != paths.length
      raise InvalidResult, "coverage worker inventory is incomplete"
    end
    paths.each_with_index do |path, index|
      name = names ? names.fetch(index) : "af-test-suite-worker-#{index}"
      resultset = JSON.parse(File.binread(path))
      raise InvalidResult, "worker #{index + 1} has an unexpected resultset" unless resultset.is_a?(Hash) && resultset.keys == [name]

      entry = resultset.fetch(name)
      coverage = entry.is_a?(Hash) && entry["coverage"]
      unless entry.is_a?(Hash) && entry["timestamp"].is_a?(Numeric) && coverage.is_a?(Hash) && !coverage.empty?
        raise InvalidResult, "worker #{index + 1} has incomplete coverage"
      end

      if started_at && !entry["timestamp"].between?(started_at, Time.now.to_i + 1)
        raise InvalidResult, "worker #{index + 1} has stale coverage"
      end
      valid = coverage.all? do |file, data|
        file.is_a?(String) && data.is_a?(Hash) &&
          data["lines"].is_a?(Array) && data["lines"].all? { |hit| hit.nil? || hit.is_a?(Integer) && hit >= 0 } &&
          data["branches"].is_a?(Hash) && data["branches"].values.all? { |arms|
            arms.is_a?(Hash) && arms.values.all? { |hit| hit.is_a?(Integer) && hit >= 0 }
          }
      end
      raise InvalidResult, "worker #{index + 1} has malformed line or branch coverage" unless valid
    rescue Errno::ENOENT, JSON::ParserError => e
      raise InvalidResult, "worker #{index + 1} coverage result is missing or corrupt: #{e.message}"
    end
    true
  end
end
