# frozen_string_literal: true
require_relative "test_helper"
class CanonicalJsonV01Test < Minitest::Test
  def test_recognizes_and_extracts_canonical_json
    Dir.mktmpdir do |dir|
      p=File.join(dir,"result.json"); File.write(p,JSON.generate("schema_version"=>"af-result-record/v0.1","adventure_id"=>"ADV-0251","dimension"=>"Seriousness","score"=>3,"reason"=>"Reason"))
      e=AfDataPipeline::Scanner.new(root:dir).scan.first; a=AfDataPipeline::Adapters::CanonicalJsonV01.new; assert a.recognize?(e); r=a.extract(e).first.to_h; assert_equal "result.json",r["source_path"]; assert_equal a.name,r["adapter"]; assert_equal 64,r["source_sha256"].length
    end
  end
end
