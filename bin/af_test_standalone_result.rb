# frozen_string_literal: true

require "minitest"
require_relative "af_test_suite_handoff"

# Captures an ordinary, single-process Minitest execution without changing its
# autorunner, options or presentation. Only this child owns the consumed request.
module AfTestStandaloneResult
  REQUEST = [AfTestSuiteHandoff::PATH_KEY, AfTestSuiteHandoff::ID_KEY].to_h { |key| [key, ENV.delete(key)] }
  SUITE = ENV.delete("AFDP_STANDALONE_SUITE")

  # Adds an accounting reporter using Minitest's actual parsed options. Plugin
  # auto-loading may be disabled; explicit registration still runs this hook.
  def self.minitest_plugin_init(options)
    Minitest.reporter << Reporter.new(options)
  end

  # Counts actual results and refuses publication unless the complete selected
  # inventory ran exactly once. Process status remains an independent veto.
  class Reporter < Minitest::StatisticsReporter
    # Retains options for selection validation after execution, avoiding extra
    # pre-run discovery/shuffling that could change seeded test order.
    def initialize(options)
      super()
      @options = options
      @methods = []
    end

    # Records one actual Minitest result and its fully qualified method name.
    def record(result)
      super
      @methods << "#{result.class_name}##{result.name}"
    end

    # Validates all selected names after execution and exclusively publishes
    # complete counters. Interruptions, duplicate runs and I/O errors fail closed.
    def report
      super
      matcher = lambda do |value|
        value.is_a?(String) && value =~ %r%/(.*)/% ? Regexp.new(Regexp.last_match(1)) : value
      end
      filter = matcher.call(@options[:filter]) || /./
      reject = matcher.call(@options[:exclude])
      selected = Minitest::Runnable.runnables.flat_map do |suite|
        suite.runnable_methods.filter_map do |method|
          name = "#{suite}##{method}"
          next unless filter === method || filter === name
          next if reject && (reject === method || reject === name)
          name
        end
      end
      unless selected.sort == @methods.sort && selected.uniq.length == selected.length
        raise AfTestSuiteHandoff::InvalidResult, "standalone Minitest execution is incomplete or duplicated"
      end

      AfTestSuiteHandoff.publish(REQUEST, suite: SUITE,
        totals: [count, assertions, failures, errors, skips],
        success: failures.zero? && errors.zero?)
    end

    # Existing Minitest reporters and the observed OS exit retain exit authority.
    def passed?
      true
    end
  end
end

Minitest.extensions << AfTestStandaloneResult
