# frozen_string_literal: true

require_relative "../test/test_helper"
require "minitest/benchmark"
require_relative "../test/support/horizontal_package_fixture"

class HorizontalDiscoveryV1Benchmark < Minitest::Benchmark
  include HorizontalPackageFixture

  RANGE = [25, 50, 100, 200].freeze
  REPETITIONS = 2
  MIN_POWER_FIT = 0.90
  MAX_GROWTH_EXPONENT = 1.50

  def self.bench_range
    RANGE
  end

  def setup
    @roots = []
    @cases = self.class.bench_range.to_h do |count|
      root = Dir.mktmpdir("horizontal-discovery-benchmark-")
      @roots << root
      specs = (1..count).map do |index|
        interpretive_spec(
          adventure_id: format("ADV-%04d", 1000 + index),
          dimension: "Seriousness"
        )
      end
      write_horizontal_package(root, specs:)
      entries = AfDataPipeline::Scanner.new(root:).scan

      [
        count,
        {
          root:,
          entries:,
          through: format("ADV-%04d", 1000 + count)
        }
      ]
    end
  end

  def teardown
    @roots.each { |root| FileUtils.remove_entry(root) if File.exist?(root) }
  end

  def bench_package_extraction_growth
    validation = proc do |range, times|
      _coefficient, exponent, fit = fit_power(range, times)
      assert_operator fit, :>=, MIN_POWER_FIT,
                      "Horizontal Discovery benchmark power fit is too noisy"
      assert_operator exponent, :<=, MAX_GROWTH_EXPONENT,
                      "Horizontal Discovery extraction grew with exponent #{exponent.round(3)}"
    end

    assert_performance(validation) do |count|
      data = @cases.fetch(count)
      REPETITIONS.times do
        extraction = AfDataPipeline::Adapters::HorizontalDiscoveryV1.new(
          root: data.fetch(:root),
          entries: data.fetch(:entries)
        ).extract(
          through: data.fetch(:through),
          dimension: "Seriousness",
          expected_count: count
        )
        raise "benchmark fixture extraction failed" unless extraction.errors.empty?
      end
    end
  end
end
