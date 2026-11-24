# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/compatibility_amc_fixture"

class AmcCompatibilityCheckTest < Minitest::Test
  include CompatibilityAmcFixture

  # Structural helper rescues must still collect owner errors into the report.
  def test_missing_sheet_returns_failed_report
    Dir.mktmpdir do |dir|
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(candidate, rows: [])
      replace_zip_text(candidate, "xl/workbook.xml", "Adventure Catalog", "Missing Catalog")
      report = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: candidate)
      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("Adventure Catalog") }
    end
  end

  def test_compatible_successor_passes_and_reports_added_ids
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(
        candidate,
        rows: [
          compatible_row("ADV-0001", title: "Existing"),
          compatible_row("ADV-0002", title: "New", levels: nil)
        ]
      )

      report = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: candidate, base_path: base)

      assert_equal "PASS", report.fetch("status"), report.fetch("errors").join("\n")
      assert_equal ["ADV-0002"], report.fetch("added_adventure_ids")
      assert_equal 2, report.fetch("canonical_adventure_count")
      assert_equal "mirrored", report.fetch("mirror_mode")
    end
  end

  def test_missing_afio_header_fails_in_one_preflight
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(candidate, rows: [compatible_row("ADV-0001", title: "Existing")])
      replace_zip_text(candidate, "xl/worksheets/sheet1.xml", "Exploration Emphasis", "Exploration Missing")

      report = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: candidate, base_path: base)

      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("missing required header \"Exploration Emphasis\"") }
    end
  end

  def test_new_scoring_value_fails_blank_field_contract
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(
        candidate,
        rows: [
          compatible_row("ADV-0001", title: "Existing"),
          compatible_row("ADV-0002", title: "New", scores: {"Seriousness" => 4})
        ]
      )

      report = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: candidate, base_path: base)

      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("ADV-0002") && error.include?("Seriousness") && error.include?("must be blank") }
    end
  end

  def test_new_page_count_formula_is_required
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(
        candidate,
        rows: [compatible_row("ADV-0001", title: "Existing"), compatible_row("ADV-0002", title: "New")]
      )
      replace_zip_text(candidate, "xl/worksheets/sheet1.xml", "<f>1+H3-G3</f>", "<f>H3-G3</f>")

      report = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: candidate, base_path: base)

      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("ADV-0002") && error.include?("Page Count must use formula") }
    end
  end

  def test_legacy_large_mirror_allows_new_large_only_in_canonical_catalog
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      existing = compatible_row("ADV-0001", title: "Existing Large", start_page: 1, end_page: 120)
      added = compatible_row("ADV-0002", title: "New Large", start_page: 1, end_page: 130)

      write_compatible_amc(base, rows: [existing])
      write_compatible_amc(
        candidate,
        rows: [existing, added],
        large_snapshot_ids: ["ADV-0001"]
      )

      report = AfDataPipeline::AmcCompatibilityCheck.check(
        candidate_path: candidate,
        base_path: base
      )

      assert_equal "PASS", report.fetch("status"), report.fetch("errors").join("\n")
      assert_equal "mirrored", report.fetch("mirror_mode")
      assert_equal ["ADV-0002"], report.fetch("added_adventure_ids")
      assert_equal 2, report.fetch("canonical_adventure_count")

      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(candidate)
      ordinary = workbook.sheet_by_name!("Adventure Catalog")
      large = workbook.sheet_by_name!("AMC >100pg")
      books = workbook.sheet_by_name!("Current Books")

      assert_equal "ADV-0002", ordinary.cell_value("A3")
      assert_nil large.cell_value("A4")
      assert_equal 1, large.cell_value("B2")
      assert_equal 2, books.cell_value("B4")
      assert_equal %(COUNTIF('Adventure Catalog'!D:D,">=100")), books.cell_formula(books.cell("B4"))
      assert_equal 2, books.cell_value("G4")
      assert_equal %(COUNTIF('Adventure Catalog'!D:D,">=100")), books.cell_formula(books.cell("G4"))
    end
  end

  def test_mixed_large_sheet_mirroring_fails
    Dir.mktmpdir do |dir|
      candidate = File.join(dir, "candidate.xlsx")
      rows = [
        compatible_row("ADV-0001", title: "Large One", start_page: 1, end_page: 120),
        compatible_row("ADV-0002", title: "Large Two", start_page: 1, end_page: 130)
      ]
      write_compatible_amc(candidate, rows: rows, mirror_large: true)
      replace_zip_text(candidate, "xl/worksheets/sheet2.xml", "ADV-0002", "ADV-0999")

      report = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: candidate)

      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("mixed mirrored and non-mirrored") }
    end
  end

  def test_current_books_double_count_is_caught
    Dir.mktmpdir do |dir|
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(candidate, rows: [compatible_row("ADV-0001", title: "Large", start_page: 1, end_page: 120)])
      replace_zip_text(candidate, "xl/worksheets/sheet3.xml", "<v>1</v>", "<v>2</v>")

      report = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: candidate)

      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("Current Books") }
    end
  end
end
