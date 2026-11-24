# frozen_string_literal: true
require_relative "test_helper"
class NormalizerTest < Minitest::Test
  def test_reports_unrecognized_files_instead_of_guessing
    Dir.mktmpdir do |dir|
      File.write(File.join(dir,"notes.txt"),"score=4 maybe"); r=AfDataPipeline::Normalizer.new.normalize(AfDataPipeline::Scanner.new(root:dir).scan); assert_empty r.records; assert_equal ["notes.txt"],r.unrecognized_files; assert_empty r.errors
    end
  end
end
