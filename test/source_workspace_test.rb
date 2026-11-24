# frozen_string_literal: true
require_relative "test_helper"
require "zip"
class SourceWorkspaceTest < Minitest::Test
  def test_opens_directory_without_copying
    Dir.mktmpdir { |dir| w=AfDataPipeline::SourceWorkspace.new(dir); w.with_root { |r| assert_equal File.expand_path(dir),r; assert_equal "directory",w.source_type } }
  end
  def test_extracts_zip_to_temporary_workspace
    Dir.mktmpdir do |dir|
      zp=File.join(dir,"sample.zip"); Zip::File.open(zp,create:true){|z| z.get_output_stream("nested/result.json"){|io| io.write("{}")}}
      w=AfDataPipeline::SourceWorkspace.new(zp); extracted=nil; w.with_root{|r| extracted=r; assert File.file?(File.join(r,"nested","result.json")); assert_equal "zip",w.source_type}; refute File.exist?(extracted)
    end
  end
end
