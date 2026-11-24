# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/compatibility_amc_fixture"
require_relative "../lib/af_data_pipeline/ingest_next"

class IngestNextReadyForAmcApplicationTest < Minitest::Test
  include CompatibilityAmcFixture

  def setup
    @tmpdir = Dir.mktmpdir("af-ingest-next-ready-apply")
    @source_root = File.join(@tmpdir, "source")
    @catalog_root = File.join(@tmpdir, "catalog")
    FileUtils.mkdir_p(@source_root)
    FileUtils.mkdir_p(@catalog_root)

    @base_amc = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.1.1.xlsx")
    write_compatible_amc(
      @base_amc,
      rows: [
        compatible_row(
          "ADV-0001",
          title: "Existing Adventure",
          source: "Existing Book",
          publisher: "Existing Publisher"
        )
      ]
    )

    @router = AfDataPipeline::IngestNext.new(
      source_root: @source_root,
      catalog_root: @catalog_root,
      afio_root: File.join(@tmpdir, "afio"),
      pdf_converter_root: File.join(@tmpdir, "converter")
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_ready_for_amc_application_emits_only_apply_command
    freeze_path = File.join(@tmpdir, "fixture-boundary-freeze.yml")
    freeze = {
      "state" => "frozen",
      "source" => {
        "canonical_source_id" => "Fixture Book"
      },
      "base_amc" => {
        "filename" => File.basename(@base_amc),
        "sha256" => Digest::SHA256.file(@base_amc).hexdigest
      }
    }

    result = @router.send(
      :boundary_freeze_result,
      {data: freeze, path: freeze_path},
      publisher: "Fixture Publisher",
      successor_version: "7.2"
    )

    assert_equal "READY_FOR_AMC_APPLICATION", result.state
    assert_equal 1, result.commands.length

    next_command = result.commands.first.fetch("command")
    assert_includes next_command, "boundary-freeze-apply"
    refute_includes next_command, "boundary-freeze-validate"
    assert_includes next_command, "--successor-version 7.2"
  end
end
