# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/amc_fixture"

class FrontierResidualScoringSafetyTest < Minitest::Test
  include AmcFixture
  SERVICE = AfDataPipeline::FrontierResidualScoring
  ERROR = AfDataPipeline::ValidationError

  def test_exact_population_schema_and_source_reasoning_are_required
    handoff, returned = return_fixture
    mutations = [
      ->(doc) { doc["schema_version"] = "unsupported" },
      ->(doc) { doc["handoff_id"] = "0" * 64 },
      ->(doc) { doc["records"].clear },
      ->(doc) { doc["records"] << doc["records"].first.dup },
      ->(doc) { doc["records"][0]["candidate_key"] = "ADV-0001::Seriousness" },
      ->(doc) { doc["records"][0]["extra"] = true },
      ->(doc) { doc["records"][0]["reason"] = " " },
      ->(doc) { doc["records"][0]["source_references"] = ["rubric"] },
      ->(doc) { doc["records"][0]["source_references"] = ["authority:source:missing"] }
    ]
    mutations.each do |mutation|
      variant = Marshal.load(Marshal.dump(returned))
      mutation.call(variant)
      seal_return(variant)
      assert_raises(ERROR) { SERVICE.validate_return!(handoff:, returned: variant, original: "unused") }
    end
    returned["return_id"] = "0" * 64
    assert_raises(ERROR) { SERVICE.validate_return!(handoff:, returned:, original: "unused") }
  end

  def test_ordinal_session_and_level_bounds_and_uncertainty
    {"Seriousness" => [0, 6, 2.5, "4"], "# of Sessions" => [0, -1, 1.5],
     "Level Start" => [0, 21], "Level End" => [0, 21]}.each do |dimension, invalid|
      invalid.each do |value|
        handoff, returned = return_fixture(dimension:, value:)
        assert_raises(ERROR) { SERVICE.validate_return!(handoff:, returned:, original: "unused") }
      end
    end
    [1, 5, nil].each do |value|
      handoff, returned = return_fixture(value:)
      accepted = SERVICE.validate_return!(handoff:, returned:, original: "unused")
      assert_equal value.nil? ? [] : [value], accepted.map { |row| row.fetch("proposed_value") }
    end
    handoff, returned = return_fixture(dimension: "# of Sessions", value: 100)
    assert_equal 100, SERVICE.validate_return!(handoff:, returned:, original: "unused").first.fetch("proposed_value")
  end

  def test_effective_levels_sibling_is_read_from_a_real_workbook
    Dir.mktmpdir("frontier-safety-") do |root|
      path = write_amc_workbook(File.join(root, "catalog.xlsx"), dimensions: ["Level Start", "Level End"],
        rows: [{adventure_id: "ADV-0003", values: {"Level Start" => 1, "Level End" => 5}}])
      handoff, returned = return_fixture(dimension: "Level Start", value: 6)
      assert_raises(ERROR) { SERVICE.validate_return!(handoff:, returned:, original: path) }
      returned["records"][0]["proposed_value"] = 5
      seal_return(returned)
      assert_equal 5, SERVICE.validate_return!(handoff:, returned:, original: path).first.fetch("proposed_value")
      assert_raises(Zip::Error) { SERVICE.validate_return!(handoff:, returned:, original: path + ".missing") }
    end
  end

  private

  def return_fixture(dimension: "Seriousness", value: 4)
    key = "ADV-0003::#{dimension}"
    handoff = {"handoff_id" => "a" * 64, "targets" => [
      {"candidate_key" => key, "adventure_id" => "ADV-0003", "dimension" => dimension}
    ], "references" => {"authority:source:fixture.md" => {}, "rubric" => {}}}
    returned = {"schema_version" => AfDataPipeline::FrontierReleaseEvidence::RETURN_SCHEMA,
      "handoff_id" => handoff.fetch("handoff_id"), "records" => [
        {"candidate_key" => key, "proposed_value" => value, "reason" => "Structural test evidence",
         "source_references" => ["authority:source:fixture.md"]}
      ]}
    seal_return(returned)
    [handoff, returned]
  end

  def seal_return(document)
    document["return_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(document.except("return_id"))
  end
end
