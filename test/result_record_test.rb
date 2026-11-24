# frozen_string_literal: true
require_relative "test_helper"
class ResultRecordTest < Minitest::Test
  def valid_data; {"schema_version"=>"af-result-record/v0.1","adventure_id"=>"ADV-0251","dimension"=>"Seriousness","score"=>3,"reason"=>"The adventure maintains a mostly serious tone."}; end
  def test_accepts_valid_record; assert_equal 3, AfDataPipeline::ResultRecord.new(valid_data).to_h["score"]; end
  def test_rejects_score_outside_range; e=assert_raises(AfDataPipeline::ValidationError){AfDataPipeline::ResultRecord.new(valid_data.merge("score"=>6))}; assert_match(/1\.\.5/,e.message); end
  def test_rejects_blank_reason; assert_raises(AfDataPipeline::ValidationError){AfDataPipeline::ResultRecord.new(valid_data.merge("reason"=>" "))}; end
end
