# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class BoundaryDossierTest < Minitest::Test
  class FakeSheet
    attr_reader :name

    COLUMNS = {
      "Page Count" => "D",
      "Start Page" => "G",
      "End Page" => "H",
      "Level Start" => "K",
      "Level End" => "L"
    }.freeze

    def initialize(name, records)
      @name = name
      @records = records
    end

    def validate_catalog_schema!
      true
    end

    def catalog_records
      @records.map do |record|
        record.slice("adventure_id", "title", "source_book", "publisher", "row")
      end
    end

    def column_for_header(header)
      COLUMNS.fetch(header)
    end

    def cell_value(reference)
      match = /\A([A-Z]+)(\d+)\z/.match(reference)
      record = @records.find { |item| item.fetch("row") == Integer(match[2], 10) }
      return nil unless record

      {
        "D" => record["page_count"],
        "G" => record["start_page"],
        "H" => record["end_page"],
        "K" => record["level_start"],
        "L" => record["level_end"]
      }.fetch(match[1])
    end
  end

  class FakeWorkbook
    def initialize(_path)
      @ordinary = FakeSheet.new(
        AfDataPipeline::BoundaryFreezeApply::ORDINARY_SHEET,
        [
          self.class.record("ADV-0001", "One Page", "Existing Book", 1, 1, 1, 1),
          self.class.record("ADV-0002", "The Glass Vault", "Another Book", 5, 6, 3, 4)
        ]
      )
      @large = FakeSheet.new(
        AfDataPipeline::BoundaryFreezeApply::LARGE_SHEET,
        [self.class.record("ADV-0009", "Existing Large", "Existing Book", 1, 105, 1, 10)]
      )
    end

    def sheet_by_name!(name)
      return @ordinary if name == AfDataPipeline::BoundaryFreezeApply::ORDINARY_SHEET
      return @large if name == AfDataPipeline::BoundaryFreezeApply::LARGE_SHEET

      raise "unexpected sheet #{name}"
    end

    def self.record(id, title, source, start_page, end_page, level_start, level_end)
      {
        "adventure_id" => id,
        "title" => title,
        "source_book" => source,
        "publisher" => "Fixture Publisher",
        "row" => Integer(id.delete_prefix("ADV-"), 10) + 1,
        "start_page" => start_page,
        "end_page" => end_page,
        "page_count" => end_page - start_page + 1,
        "level_start" => level_start,
        "level_end" => level_end
      }
    end
  end

  def test_generates_deterministic_evidence_without_boundary_decisions
    with_workspace do |root, amc, output_one, output_two|
      before = input_hashes(root, amc)

      first = AfDataPipeline::BoundaryDossier.generate!(
        source_root: root,
        source_id: "Fixture Book",
        amc_path: amc,
        output_dir: output_one,
        workbook_class: FakeWorkbook
      )
      second = AfDataPipeline::BoundaryDossier.generate!(
        source_root: root,
        source_id: "Fixture Book",
        amc_path: amc,
        output_dir: output_two,
        workbook_class: FakeWorkbook
      )

      assert_equal File.read(first.json_path), File.read(second.json_path)
      assert_equal File.read(first.markdown_path), File.read(second.markdown_path)
      assert_equal before, input_hashes(root, amc)

      report = first.report
      assert_equal AfDataPipeline::BoundaryDossier::SCHEMA_VERSION, report.fetch("schema_version")
      assert report.dig("review_contract", "no_decisions_made")
      assert report.dig("review_contract", "no_adventure_ids_assigned")
      assert_equal 3, report.dig("amc_evidence", "catalog_record_count")
      assert_equal 1, report.dig("amc_evidence", "short_record_counts", "lte_1_pages")

      source = report.fetch("source_files").first
      titles = source.fetch("headings").map { |heading| heading.fetch("title") }
      assert_includes titles, "The Glass Vault"
      refute_includes titles, "Chapter Three: Lost Vault"

      navigation = source.fetch("navigation_evidence")
      assert_equal "literal_markdown_only", navigation.dig("contract", "headings")
      assert_equal "explicit_same_pdf_page_marker_only", navigation.dig("contract", "printed_page_mappings")
      assert_equal "none", navigation.dig("contract", "adventure_classification")

      page_three = navigation.fetch("page_mappings").find { |mapping| mapping.fetch("pdf_page") == 3 }
      refute_nil page_three
      assert_equal "unknown", page_three.fetch("mapping_status")
      refute page_three.key?("printed_page")

      contents_anchor = navigation.fetch("anchors").find do |anchor|
        anchor.fetch("kind") == "contents_entry" && anchor.fetch("text") == "The Glass Vault"
      end
      refute_nil contents_anchor
      assert_equal 10, contents_anchor.fetch("source_target_page_start")
      assert_equal 10, contents_anchor.fetch("source_target_page_end")

      structural_anchor = navigation.fetch("anchors").find do |anchor|
        anchor.fetch("kind") == "structural_label_signal" &&
          anchor.fetch("text") == "Chapter Three: Lost Vault"
      end
      refute_nil structural_anchor
      assert_equal 3, structural_anchor.fetch("pdf_page")
      refute structural_anchor.key?("printed_page")
      assert(
        source.fetch("signal_tables").any? do |table|
          table.fetch("signal_categories").include?("toc_or_overview_table")
        end
      )
      assert(
        source.fetch("level_mentions").any? do |mention|
          mention.fetch("start") == 3 && mention.fetch("end") == 3
        end
      )
      assert_equal 1, source.fetch("quality_flags").length

      mission_hit = source.fetch("signal_hits").find do |hit|
        hit.fetch("text") == "Mission: Recover the Lens"
      end
      refute_nil mission_hit
      assert_equal 3, mission_hit.fetch("pdf_page")
      refute mission_hit.key?("printed_page")

      match = report.dig("amc_evidence", "heading_title_matches").find do |item|
        item.fetch("heading_title") == "The Glass Vault"
      end
      refute_nil match
      assert_equal ["ADV-0002"], match.fetch("exact_title_matches").map { |item| item.fetch("adventure_id") }

      markdown = File.read(first.markdown_path)
      assert_includes markdown, "Evidence only."
      assert_includes markdown, "No boundary decisions made"
      assert_includes markdown, "Deterministic navigation evidence"
      assert_includes markdown, "otherwise it remains unknown"
    end
  end

  def test_refuses_to_overwrite_existing_dossier
    with_workspace do |root, amc, output_one, _output_two|
      FileUtils.mkdir_p(output_one)
      existing = File.join(output_one, AfDataPipeline::BoundaryDossier::JSON_FILENAME)
      File.write(existing, "keep me")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryDossier.generate!(
          source_root: root,
          source_id: "Fixture Book",
          amc_path: amc,
          output_dir: output_one,
          workbook_class: FakeWorkbook
        )
      end
      assert_match(/refusing to overwrite/, error.message)
      assert_equal "keep me", File.read(existing)
    end
  end

  def test_cli_requires_explicit_source_amc_and_output
    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::BoundaryDossier::CLI.run([], out:, err:)

    assert_equal 2, status
    assert_empty out.string
    assert_match(/--source-root DIR/, err.string)
  end

  private

  def with_workspace
    Dir.mktmpdir("boundary-dossier") do |dir|
      root = File.join(dir, "source")
      FileUtils.mkdir_p(root)
      File.write(
        File.join(root, "Fixture_Book.md"),
        <<~MD
          <!-- PDF Page 1 -->
          <!-- Printed Page 10 -->
          # Contents
          | Section | Page |
          | --- | --- |
          | The Glass Vault | 10 |
          # Chapter One
          ## The Glass Vault
          Adventure for Level 3 Characters
          | Name | Level | Page |
          | --- | --- | --- |
          | The Glass Vault | 3 | 10 |
          ### Adventure Hook
          Retrieve the key from the vault.
          ### Encounters
          The adventurers face two encounters.
          ### Conclusion
          Success returns the key to the patron.
          <!-- PDF Page 2 -->
          <!-- Printed Page 11 -->
          ## Appendix
          ERROR conversion sentinel for test coverage
          <!-- PDF Page 3 -->
          Chapter Three: Lost Vault
          Mission: Recover the Lens
        MD
      )
      File.write(
        File.join(root, "source_registry.yml"),
        YAML.dump(
          "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
          "sources" => { "Fixture Book" => { "file" => "Fixture_Book.md" } }
        )
      )
      amc = File.join(dir, "5e_Adventure_Master_Catalog_9.9.xlsx")
      File.write(amc, "fixture AMC bytes")
      yield root, amc, File.join(dir, "dossier-one"), File.join(dir, "dossier-two")
    end
  end

  def input_hashes(root, amc)
    [
      File.join(root, "Fixture_Book.md"),
      File.join(root, "source_registry.yml"),
      amc
    ].to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  end
end
