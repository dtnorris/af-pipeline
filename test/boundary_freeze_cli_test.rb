# frozen_string_literal: true
require_relative "test_helper"
require "stringio"

class BoundaryFreezeCliTest < Minitest::Test
  def test_init_and_validate_commands_round_trip_without_workbook_mutation
    Dir.mktmpdir("boundary-freeze-cli") do |dir|
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
      before_amc = Digest::SHA256.file(amc).hexdigest
      output = File.join(dir, "freeze.yml")

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        [
          "boundary-freeze-init",
          "--source-root", source_root,
          "--source-id", "Fixture Book",
          "--amc", amc,
          "--output", output
        ],
        out: out,
        err: err
      )

      assert_equal 0, status
      assert_empty err.string
      assert_match(/Boundary freeze initialized: draft/, out.string)
      assert_match(/No Adventure IDs assigned/, out.string)
      assert File.file?(output)

      artifact = YAML.safe_load_file(output)
      artifact["state"] = "frozen"
      artifact["approval"] = { "approved_by" => "David", "approved_at" => "2026-09-10" }
      artifact["records"] = [
        {
          "local_key" => "fixture",
          "canonical_title" => "Fixture Adventure",
          "printed_pages" => { "start" => 1, "end" => 2 },
          "editorial_rationale" => "Reviewed against source.",
          "state" => "frozen"
        }
      ]
      File.write(output, YAML.dump(artifact))

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        [
          "boundary-freeze-validate", output,
          "--source-root", source_root,
          "--amc", amc
        ],
        out: out,
        err: err
      )

      assert_equal 0, status
      assert_empty err.string
      assert_match(/Boundary freeze validation: PASS/, out.string)
      assert_match(/Frozen records: 1/, out.string)
      assert_equal before_amc, Digest::SHA256.file(amc).hexdigest
    end
  end

  def test_validate_returns_nonzero_for_draft
    Dir.mktmpdir("boundary-freeze-cli") do |dir|
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
      output = File.join(dir, "freeze.yml")
      AfDataPipeline::BoundaryFreeze.init!(
        source_root: source_root,
        source_id: "Fixture Book",
        amc_path: amc,
        output_path: output
      )

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["boundary-freeze-validate", output, "--source-root", source_root, "--amc", amc],
        out: out,
        err: err
      )

      assert_equal 2, status
      assert_match(/state must be "frozen"/, err.string)
    end
  end

  def test_apply_requires_one_complete_output_mode
    common = [
      "boundary-freeze-apply", "freeze.yml",
      "--source-root", "source",
      "--amc", "5e_Adventure_Master_Catalog_4.25.1.xlsx",
      "--publisher", "Fixture Publisher"
    ]

    status, error = run_cli(*common)
    assert_equal 2, status
    assert_match(/missing argument: --successor-version VERSION/, error)

    status, error = run_cli(*common, "--successor-version", "4.26")
    assert_equal 2, status
    assert_match(/missing argument: --amc-dir DIR/, error)

    status, error = run_cli(
      *common,
      "--output", "successor.xlsx",
      "--successor-version", "4.26"
    )
    assert_equal 2, status
    assert_match(/--output and --successor-version cannot be used together/, error)
  end

  private

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::CLI.run(argv, out:, err:)
    [status, err.string]
  end
end
