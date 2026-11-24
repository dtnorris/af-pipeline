# frozen_string_literal: true
require_relative "test_helper"
require "stringio"
class CliTest < Minitest::Test
  def test_version; o=StringIO.new; e=StringIO.new; s=AfDataPipeline::CLI.run(["version"],out:o,err:e); assert_equal 0,s; assert_equal "#{AfDataPipeline::VERSION}\n",o.string; assert_empty e.string; end
  def test_unknown_command_fails; o=StringIO.new; e=StringIO.new; s=AfDataPipeline::CLI.run(["nope"],out:o,err:e); assert_equal 2,s; assert_match(/unknown command/,e.string); end
end
