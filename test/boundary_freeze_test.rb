# frozen_string_literal: true
require_relative "test_helper"

class BoundaryFreezeTest < Minitest::Test
  def test_init_binds_registry_source_files_and_base_amc_without_assigning_ids
    with_workspace do |root, amc, output|
      result = AfDataPipeline::BoundaryFreeze.init!(
        source_root: root,
        source_id: "Fixture Book",
        amc_path: amc,
        output_path: output
      )

      artifact = result.artifact
      assert_equal AfDataPipeline::BoundaryFreeze::SCHEMA_VERSION, artifact["schema_version"]
      assert_equal "draft", artifact["state"]
      assert_equal "Fixture Book", artifact.dig("source", "canonical_source_id")
      assert_equal "source_registry.yml", artifact.dig("source", "registry_filename")
      assert_equal Digest::SHA256.file(File.join(root, "source_registry.yml")).hexdigest,
                   artifact.dig("source", "registry_sha256")
      assert_equal ["Fixture_Book.md"], artifact.dig("source", "markdown_files").map { |item| item["filename"] }
      assert_equal Digest::SHA256.file(File.join(root, "Fixture_Book.md")).hexdigest,
                   artifact.dig("source", "markdown_files", 0, "sha256")
      assert_equal File.basename(amc), artifact.dig("base_amc", "filename")
      assert_nil artifact.dig("approval", "approved_by")
      assert_empty artifact["records"]
      refute_includes File.read(output), "adventure_id"
    end
  end

  def test_init_refuses_to_overwrite_existing_handoff
    with_workspace do |root, amc, output|
      File.write(output, "keep me")
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.init!(
          source_root: root,
          source_id: "Fixture Book",
          amc_path: amc,
          output_path: output
        )
      end
      assert_match(/already exists/, error.message)
      assert_equal "keep me", File.read(output)
    end
  end

  def test_init_binds_all_files_for_segmented_registry_source
    with_workspace(segmented: true) do |root, amc, output|
      result = AfDataPipeline::BoundaryFreeze.init!(
        source_root: root,
        source_id: "Fixture Book",
        amc_path: amc,
        output_path: output
      )

      assert_equal %w[Fixture_Part_One.md Fixture_Part_Two.md],
                   result.artifact.dig("source", "markdown_files").map { |item| item["filename"] }
    end
  end

  def test_validate_accepts_campaign_adventure_embedded_adventure_chain_and_optional_levels
    with_workspace do |root, amc, output|
      initialize_and_freeze!(
        root,
        amc,
        output,
        records: [
          frozen_record(
            local_key: "campaign",
            title: "Campaign",
            pages: [10, 20]
          ),
          frozen_record(
            local_key: "adventure",
            title: "Adventure",
            pages: [11, 18],
            parent_key: "campaign"
          ),
          frozen_record(
            local_key: "embedded-adventure",
            title: "Embedded Adventure",
            pages: [12, 14],
            parent_key: "adventure",
            levels: { "start" => 3, "end" => 5 }
          )
        ]
      )

      result = AfDataPipeline::BoundaryFreeze.validate!(
        freeze_path: output,
        source_root: root,
        amc_path: amc
      )

      assert_equal 3, result.record_count
      assert_match(/\A[0-9a-f]{64}\z/, result.sha256)
    end
  end

  def test_validate_rejects_new_adventure_id_field
    with_workspace do |root, amc, output|
      initialize_and_freeze!(root, amc, output, records: [frozen_record])
      artifact = YAML.safe_load_file(output)
      artifact.fetch("records").first["adventure_id"] = "ADV-9999"
      File.write(output, YAML.dump(artifact))

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
      assert_match(/unknown fields: adventure_id/, error.message)
    end
  end

  def test_validate_fails_when_markdown_bytes_drift
    with_workspace do |root, amc, output|
      initialize_and_freeze!(root, amc, output, records: [frozen_record])
      File.write(File.join(root, "Fixture_Book.md"), "changed after review\n")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
      assert_match(/sha256 mismatch/, error.message)
    end
  end

  def test_validate_fails_when_registry_or_base_amc_drift
    with_workspace do |root, amc, output|
      initialize_and_freeze!(root, amc, output, records: [frozen_record])
      File.open(File.join(root, "source_registry.yml"), "a") { |file| file.puts("# changed") }

      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
    end

    with_workspace do |root, amc, output|
      initialize_and_freeze!(root, amc, output, records: [frozen_record])
      File.write(amc, "changed AMC")

      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
    end
  end

  def test_validate_rejects_segment_gap_and_cross_segment_range
    with_workspace(segmented: true) do |root, amc, output|
      initialize_and_freeze!(
        root,
        amc,
        output,
        records: [frozen_record(pages: [21, 21])]
      )

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
      assert_match(/not fully contained/, error.message)
    end

    with_workspace(segmented: true) do |root, amc, output|
      initialize_and_freeze!(
        root,
        amc,
        output,
        records: [frozen_record(pages: [18, 32])]
      )

      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
    end
  end

  def test_validate_rejects_bad_parent_reference_and_bad_levels
    with_workspace do |root, amc, output|
      child = frozen_record(parent_key: "missing")
      initialize_and_freeze!(root, amc, output, records: [child])

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
      assert_match(/unknown local record/, error.message)
    end

    with_workspace do |root, amc, output|
      records = [
        frozen_record(local_key: "one", parent_key: "two"),
        frozen_record(local_key: "two", parent_key: "one")
      ]
      initialize_and_freeze!(root, amc, output, records: records)

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
      assert_match(/parent_key cycle detected/, error.message)
    end

    with_workspace do |root, amc, output|
      record = frozen_record(levels: { "start" => 5, "end" => 3 })
      initialize_and_freeze!(root, amc, output, records: [record])

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreeze.validate!(freeze_path: output, source_root: root, amc_path: amc)
      end
      assert_match(/levels.start exceeds end/, error.message)
    end
  end

  private

  def with_workspace(segmented: false)
    Dir.mktmpdir("boundary-freeze") do |dir|
      root = File.join(dir, "source")
      FileUtils.mkdir_p(root)
      mapping = if segmented
                  File.write(File.join(root, "Fixture_Part_One.md"), "part one\n")
                  File.write(File.join(root, "Fixture_Part_Two.md"), "part two\n")
                  {
                    "segments" => [
                      { "start_page" => 10, "end_page" => 20, "file" => "Fixture_Part_One.md" },
                      { "start_page" => 30, "end_page" => 40, "file" => "Fixture_Part_Two.md" }
                    ]
                  }
                else
                  File.write(File.join(root, "Fixture_Book.md"), "fixture source\n")
                  { "file" => "Fixture_Book.md" }
                end
      File.write(
        File.join(root, "source_registry.yml"),
        YAML.dump(
          "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
          "sources" => { "Fixture Book" => mapping }
        )
      )
      amc = File.join(dir, "5e_Adventure_Master_Catalog_4.18.xlsx")
      File.write(amc, "fixture AMC bytes")
      yield root, amc, File.join(dir, "fixture-boundary-freeze.yml")
    end
  end

  def initialize_and_freeze!(root, amc, output, records:)
    AfDataPipeline::BoundaryFreeze.init!(
      source_root: root,
      source_id: "Fixture Book",
      amc_path: amc,
      output_path: output
    )
    artifact = YAML.safe_load_file(output)
    artifact["state"] = "frozen"
    artifact["approval"] = {
      "approved_by" => "David",
      "approved_at" => "2026-09-10T12:00:00-04:00"
    }
    artifact["records"] = records
    File.write(output, YAML.dump(artifact))
  end

  def frozen_record(
    local_key: "fixture-adventure",
    title: "Fixture Adventure",
    pages: [10, 12],
    parent_key: nil,
    levels: nil
  )
    record = {
      "local_key" => local_key,
      "canonical_title" => title,
      "printed_pages" => { "start" => pages[0], "end" => pages[1] },
      "editorial_rationale" => "Reviewed against the canonical source.",
      "state" => "frozen"
    }
    record["parent_key"] = parent_key if parent_key
    record["levels"] = levels if levels
    record
  end
end
