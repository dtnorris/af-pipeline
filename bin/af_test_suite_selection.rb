# frozen_string_literal: true

require "json"

module AfTestSuiteSelection
  MODES = %w[fast integration all].freeze

  def self.files(root, mode)
    raise ArgumentError, "unknown test suite: #{mode}" unless MODES.include?(mode)

    entries = JSON.parse(File.binread(File.join(root, "test/integration.json")))
    unless entries.is_a?(Array) && entries.uniq == entries && entries.all? { |path|
      path.is_a?(String) && path.match?(%r{\Atest/integration/[a-z_]+_test\.rb\z})
    }
      raise ArgumentError, "invalid integration test inventory"
    end
    integration = entries.map { |path| File.join(root, path) }.sort
    discovered = Dir[File.join(root, "test/integration/**/*_test.rb")].sort
    unless discovered == integration && integration.all? { |path| File.file?(path) }
      raise ArgumentError, "integration test inventory differs from files on disk"
    end
    all = Dir[File.join(root, "test/**/*_test.rb")].sort
    case mode
    when "fast" then all - integration
    when "integration" then integration
    when "all" then all
    end
  end
end
