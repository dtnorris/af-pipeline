# frozen_string_literal: true
require_relative "test_helper"
class ReviewPacketWriterTest < Minitest::Test
  def test_writes_review_packet
    Dir.mktmpdir do |dir|
      source=File.join(dir,"source"); output=File.join(dir,"out"); FileUtils.mkdir_p(source); File.write(File.join(source,"result.json"),JSON.generate("schema_version"=>"af-result-record/v0.1","adventure_id"=>"ADV-0251","dimension"=>"Seriousness","score"=>3,"reason"=>"Complete reasoning."))
      e=AfDataPipeline::Scanner.new(root:source).scan; n=AfDataPipeline::Normalizer.new.normalize(e); AfDataPipeline::ReviewPacketWriter.new(output).write!(entries:e,normalization:n,source:source,source_type:"directory")
      assert File.file?(File.join(output,"results.jsonl")); review=File.read(File.join(output,"audit_review.md")); assert_includes review,"ADV-0251"; assert_includes review,"Complete reasoning."
    end
  end
end
