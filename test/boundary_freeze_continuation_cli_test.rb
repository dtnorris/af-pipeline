# frozen_string_literal: true
require_relative "test_helper"
require "stringio"

class BoundaryFreezeContinuationCliTest < Minitest::Test
  def test_continuation_path_is_derived_from_freeze_draft_name
    Dir.mktmpdir("boundary-freeze-continuation") do |dir|
      editorial_dir = File.join(dir, "fixture-book-boundary-editorial")
      FileUtils.mkdir_p(editorial_dir)
      File.write(File.join(editorial_dir, "editorial_context.json"), "{}\n")
      File.write(File.join(editorial_dir, "editorial_decisions.yml"), "--- {}\n")

      freeze = File.join(dir, "fixture-book-boundary-freeze-draft.yml")
      cli = AfDataPipeline::CLI.new(out: StringIO.new, err: StringIO.new)
      continuation = cli.send(:boundary_freeze_editorial_continuation, freeze)

      assert_includes continuation, "Next command:"
      assert_includes continuation, "bin/af-ingest-next"
      assert_includes continuation, Shellwords.escape(editorial_dir)
    end
  end
end
