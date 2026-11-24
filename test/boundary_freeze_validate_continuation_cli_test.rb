# frozen_string_literal: true
require_relative "test_helper"
require "stringio"

class BoundaryFreezeValidateContinuationCliTest < Minitest::Test
  def test_validate_prints_router_continuation
    Dir.mktmpdir("boundary-freeze-validate-continuation") do |dir|
      source_root = File.join(dir, "source")
      FileUtils.mkdir_p(source_root)
      File.write(File.join(source_root, "Fixture_Book.md"), "fixture source\n")
      File.write(
        File.join(source_root, "source_registry.yml"),
        YAML.dump(
          "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
          "sources" => { "Fixture Book" => { "file" => "Fixture_Book.md" } }
        )
      )

      amc = File.join(dir, "AMC.xlsx")
      File.write(amc, "AMC bytes")
      freeze = File.join(dir, "fixture-book-boundary-freeze.yml")

      AfDataPipeline::BoundaryFreeze.init!(
        source_root: source_root,
        source_id: "Fixture Book",
        amc_path: amc,
        output_path: freeze
      )

      artifact = YAML.safe_load_file(freeze)
      artifact["state"] = "frozen"
      artifact["approval"] = {
        "approved_by" => "David",
        "approved_at" => "2026-09-25"
      }
      artifact["records"] = [
        {
          "local_key" => "fixture",
          "canonical_title" => "Fixture Adventure",
          "printed_pages" => { "start" => 1, "end" => 2 },
          "editorial_rationale" => "Reviewed against source.",
          "state" => "frozen"
        }
      ]
      File.write(freeze, YAML.dump(artifact))

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        [
          "boundary-freeze-validate", freeze,
          "--source-root", source_root,
          "--amc", amc
        ],
        out: out,
        err: err
      )

      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "Boundary freeze validation: PASS"
      assert_includes out.string, "Next command:"
      assert_includes out.string, "bin/af-ingest-next"
      assert_includes out.string, Shellwords.escape(File.expand_path(freeze))
    end
  end
end
