# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/compatibility_amc_fixture"
require_relative "../lib/af_data_pipeline/ingest_next"

class IngestNextPublisherMetadataTest < Minitest::Test
  include CompatibilityAmcFixture

  def setup
    @tmpdir = Dir.mktmpdir("af-ingest-next-publisher")
    @source_root = File.join(@tmpdir, "source")
    @catalog_root = File.join(@tmpdir, "catalog")
    FileUtils.mkdir_p(@source_root)
    FileUtils.mkdir_p(@catalog_root)

    @markdown_name = "Fixture_LLM_Edition.md"
    @markdown = File.join(@source_root, @markdown_name)
    File.write(
      @markdown,
      "Printed in China. © 2025 Beadle &amp; Grimm's LLC, 2118 Wilshire Blvd, Santa Monica, CA.\n"
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

  def test_suggests_source_publisher_without_legal_suffix_when_amc_has_no_match
    amc = write_catalog(["Wizards of the Coast"])
    metadata = @router.send(:publisher_metadata, freeze_for(amc), amc)

    assert_equal ["Beadle & Grimm's LLC"], metadata.fetch(:source_claims).map { |claim| claim.fetch("value") }
    assert_empty metadata.fetch(:existing_matches)
    assert_equal "Beadle & Grimm's", metadata.fetch(:suggestion)
    assert_nil metadata.fetch(:warning)
  end

  def test_prefers_existing_amc_publisher_normalization
    amc = write_catalog(["Beadle & Grimm's"])
    metadata = @router.send(:publisher_metadata, freeze_for(amc), amc)

    assert_equal ["Beadle & Grimm's"], metadata.fetch(:existing_matches)
    assert_equal "Beadle & Grimm's", metadata.fetch(:suggestion)
  end

  def test_successor_metadata_state_surfaces_evidence_and_suggestion
    amc = write_catalog(["Wizards of the Coast"])
    freeze = freeze_for(amc)

    result = @router.send(
      :boundary_freeze_result,
      {
        data: freeze,
        path: File.join(@tmpdir, "fixture-boundary-freeze.yml")
      },
      publisher: nil,
      successor_version: nil
    )

    assert_equal "NEEDS_SUCCESSOR_METADATA", result.state
    assert result.evidence.any? { |line| line.include?("Beadle & Grimm's LLC") && line.include?(@markdown_name) }
    assert_includes result.evidence, "Existing AMC publisher match: none"
    assert_includes result.evidence, "Suggested Book Publisher: \"Beadle & Grimm's\""
    assert result.human_review.any? { |line| line.include?("Confirm Book Publisher \"Beadle & Grimm's\"") }
    assert result.human_review.any? { |line| line.include?("Resume command after human review:") }
    assert result.human_review.any? { |line| line.include?("bin/af-ingest-next") }
    assert result.human_review.any? { |line| line.include?("--publisher") && line.include?("--successor-version VERSION") }
    assert_empty result.commands
    assert_empty result.warnings
  end

  def test_rejects_placeholder_or_malformed_successor_version_before_ready_state
    amc = write_catalog(["Wizards of the Coast"])
    freeze = freeze_for(amc)
    artifact = {
      data: freeze,
      path: File.join(@tmpdir, "fixture-boundary-freeze.yml")
    }

    ["VERSION", "7", "7.1.beta", "../7.1.2"].each do |value|
      error = assert_raises(AfDataPipeline::IngestNext::Error) do
        @router.send(
          :boundary_freeze_result,
          artifact,
          publisher: "Beadle & Grimm's",
          successor_version: value
        )
      end
      assert_match(/dot-separated numeric components/, error.message)
    end
  end

  def test_accepts_numeric_dot_separated_successor_version
    amc = write_catalog(["Wizards of the Coast"])
    freeze = freeze_for(amc)

    result = @router.send(
      :boundary_freeze_result,
      {
        data: freeze,
        path: File.join(@tmpdir, "fixture-boundary-freeze.yml")
      },
      publisher: "Beadle & Grimm's",
      successor_version: "7.1.2"
    )

    assert_equal "READY_FOR_AMC_APPLICATION", result.state
    assert_includes result.evidence, "Successor version: 7.1.2"
  end

  private

  def write_catalog(publishers)
    path = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.1.1.xlsx")
    rows = publishers.each_with_index.map do |publisher, index|
      compatible_row(
        format("ADV-%04d", index + 1),
        title: "Existing #{index + 1}",
        source: "Existing Book #{index + 1}",
        publisher:
      )
    end
    write_compatible_amc(path, rows:)
  end

  def freeze_for(amc)
    {
      "state" => "frozen",
      "source" => {
        "canonical_source_id" => "Faster Purple Worm! Everybody Dies! Vol. 1",
        "markdown_files" => [
          {
            "filename" => @markdown_name,
            "sha256" => Digest::SHA256.file(@markdown).hexdigest
          }
        ]
      },
      "base_amc" => {
        "filename" => File.basename(amc),
        "sha256" => Digest::SHA256.file(amc).hexdigest
      }
    }
  end
end
