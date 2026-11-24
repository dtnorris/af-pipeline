# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/horizontal_package_fixture"

class HorizontalDiscoveryV1Test < Minitest::Test
  include HorizontalPackageFixture

  def test_reconstructs_exact_prod_ingest6_boundary_as_117_logical_results
    Dir.mktmpdir do |dir|
      specs = (1..116).map do |index|
        interpretive_spec(adventure_id: format("ADV-%04d", 1000 + index), dimension: "Seriousness")
      end
      specs << interpretive_spec(
        adventure_id: "ADV-0251",
        dimension: "Seriousness",
        experiment: "production-backlog-012-qwen-seriousness-adv0251-v1",
        manifest: PROD_INGEST6_CUTOFF
      )
      write_horizontal_package(
        dir,
        specs:,
        cutoff_manifest: PROD_INGEST6_CUTOFF,
        first_excluded: PROD_INGEST6_FIRST_EXCLUDED
      )

      entries = AfDataPipeline::Scanner.new(root: dir).scan
      extraction = AfDataPipeline::Adapters::HorizontalDiscoveryV1.new(root: dir, entries:).extract(
        through: "ADV-0251",
        dimension: "Seriousness",
        expected_count: 117
      )

      assert_empty extraction.errors
      assert_equal 117, extraction.records.length
      assert_equal 117, extraction.all_records.length
      assert_empty extraction.excluded_records
      assert_equal PROD_INGEST6_CUTOFF, extraction.scope.inclusive_cutoff
      assert_equal PROD_INGEST6_FIRST_EXCLUDED, extraction.scope.first_excluded
      assert_equal "ADV-0251", extraction.records.last["adventure_id"]
      assert_equal "Seriousness", extraction.records.last["dimension"]
      assert_equal 3, extraction.records.last["score"]
      assert_equal "Fixture raw reasoning 117.", extraction.records.last.dig("raw", "reasoning")
      assert_equal ["Seriousness"], extraction.records.last.dig("raw_assessment_consistency", "matches")
    end
  end

  def test_levels_rows_remain_one_logical_result
    Dir.mktmpdir do |dir|
      write_horizontal_package(dir, specs: [levels_spec(adventure_id: "ADV-0251")])
      entries = AfDataPipeline::Scanner.new(root: dir).scan
      extraction = AfDataPipeline::Adapters::HorizontalDiscoveryV1.new(root: dir, entries:).extract(
        through: "ADV-0251",
        dimension: "Levels",
        expected_count: 1
      )

      assert_empty extraction.errors
      assert_equal 1, extraction.records.length
      record = extraction.records.first
      assert_equal "Levels", record["dimension"]
      assert_nil record["score"]
      assert_equal [
        { "metric" => "Level Start", "value" => 1 },
        { "metric" => "Level End", "value" => 4 }
      ], record["values"]
      assert_equal ["Level Start", "Level End"], record.dig("raw_assessment_consistency", "matches")
    end
  end

  def test_raw_and_assessment_value_mismatch_fails_closed
    Dir.mktmpdir do |dir|
      write_horizontal_package(
        dir,
        specs: [interpretive_spec(adventure_id: "ADV-0251", dimension: "Seriousness", value: 3, raw_value: 4)]
      )
      entries = AfDataPipeline::Scanner.new(root: dir).scan
      extraction = AfDataPipeline::Adapters::HorizontalDiscoveryV1.new(root: dir, entries:).extract(
        through: "ADV-0251",
        dimension: "Seriousness",
        expected_count: 1
      )

      assert_equal "error", extraction.records.first["mechanical_status"]
      assert extraction.errors.any? { |message| message.include?("raw/assessment value mismatch") }
    end
  end

  def test_raw_and_assessment_rationale_mismatch_fails_closed
    Dir.mktmpdir do |dir|
      spec = interpretive_spec(adventure_id: "ADV-0251", dimension: "Seriousness", value: 3)
      spec[:structured_content] = {
        "group" => "fixture",
        "dimensions" => [
          { "dimension" => "Seriousness", "score" => 3, "rationale" => "Different raw rationale." }
        ]
      }
      write_horizontal_package(dir, specs: [spec])
      entries = AfDataPipeline::Scanner.new(root: dir).scan
      extraction = AfDataPipeline::Adapters::HorizontalDiscoveryV1.new(root: dir, entries:).extract(
        through: "ADV-0251",
        dimension: "Seriousness",
        expected_count: 1
      )

      assert_equal "error", extraction.records.first["mechanical_status"]
      assert extraction.errors.any? { |message| message.include?("raw/assessment rationale mismatch") }
    end
  end

  def test_missing_assessment_is_reported_not_silently_dropped
    Dir.mktmpdir do |dir|
      write_horizontal_package(
        dir,
        specs: [interpretive_spec(adventure_id: "ADV-0251", dimension: "Seriousness")]
      )
      FileUtils.rm(Dir.glob(File.join(dir, "output", "**", "assessments", "*.csv")).first)
      entries = AfDataPipeline::Scanner.new(root: dir).scan
      extraction = AfDataPipeline::Adapters::HorizontalDiscoveryV1.new(root: dir, entries:).extract(
        through: "ADV-0251",
        dimension: "Seriousness",
        expected_count: 1
      )

      assert_equal 1, extraction.records.length
      assert extraction.errors.any? { |message| message.include?("declared cutoff record resolves") }
      assert_equal 1, extraction.all_records.length
      assert_equal "error", extraction.records.first["mechanical_status"]
      assert extraction.errors.any? { |message| message.include?("expected exactly 1 assessment CSV") }
    end
  end
end
