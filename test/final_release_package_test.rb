# frozen_string_literal: true

require_relative "test_helper"

class FinalReleasePackageSafetyTest < Minitest::Test
  def test_complete_metric_identity_requires_levels_siblings_and_unique_members
    validator = AfDataPipeline::FinalReleasePackage.new(inputs_path: "unused")
    workload = {"cases" => [{"adventure_id" => "ADV-0003", "dimension" => "Levels"}]}
    [[], [{"candidate_key" => "ADV-0003::Level Start"}],
     [{"candidate_key" => "ADV-0003::Level Start"}, {"candidate_key" => "ADV-0003::Level Start"}]].each do |candidates|
      error = assert_raises(AfDataPipeline::ValidationError) { validator.send(:reconcile_population!, workload, candidates, {}, "unused") }
      assert_includes error.message, "Levels siblings"
    end
  end

  def test_catalog_delta_reports_lost_additions_removals_and_conflicting_ids
    validator = AfDataPipeline::FinalReleasePackage.new(inputs_path: "unused")
    current = {"ADV-0001" => {"sheet:L" => 9}, "ADV-0003" => {"sheet:L" => 8}, "ADV-0999" => {"sheet:L" => nil}}
    proposed = {"ADV-0001" => {"sheet:L" => 3}, "ADV-0003" => {"sheet:L" => 4}, "ADV-0004" => {"sheet:L" => 2}}
    base = {"ADV-0001" => {"sheet:L" => 3}}
    views = {"current" => current, "proposed" => proposed, "base" => base}
    delta = validator.stub(:catalog_view, ->(path) { views.fetch(path) }) { validator.send(:catalog_transition, "current", "proposed", "base") }
    assert_equal ["ADV-0004"], delta["added_ids"]
    assert_equal ["ADV-0999"], delta["removed_ids"]
    assert_equal 2, delta["changed_cells"].length
    assert_equal %w[CONCURRENT_ID_CONFLICT CONCURRENT_UPDATE_LOST CURRENT_ID_REMOVED], delta["unpreserved"].map { |row| row["reason"] }.sort
  end
end
