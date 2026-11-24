# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/amc_fixture"
require "stringio"

class AmcFinalizeTest < Minitest::Test
  include AmcFixture

  def test_finalizes_only_apply_written_cells_to_existing_blue_style
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [
          { adventure_id: "ADV-0001", values: { "Seriousness" => nil } },
          { adventure_id: "ADV-0002", values: { "Seriousness" => 3 } }
        ]
      )
      add_existing_blue_style!(source)
      set_cell_style!(source, "C3", 5) # Historical red cell; not part of this apply.

      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      applied = File.join(dir, "applied.xlsx")
      apply_result = AfDataPipeline::AmcApply.apply!(
        audit_dir: audit,
        amc_path: source,
        output_path: applied
      )
      final = File.join(dir, "final.xlsx")

      applied_workbook = AfDataPipeline::AmcApply::Workbook.new(applied)
      applied_sheet = applied_workbook.sheet("xl/worksheets/sheet1.xml")
      assert_equal "#F4CCCC", applied_workbook.styles.fill_rgb(applied_sheet.cell("C2").attributes["s"])
      assert_equal "#F4CCCC", applied_workbook.styles.fill_rgb(applied_sheet.cell("C3").attributes["s"])

      result = AfDataPipeline::AmcFinalize.finalize!(
        amc_path: applied,
        apply_report_path: apply_result.report_path,
        output_path: final
      )

      final_workbook = AfDataPipeline::AmcApply::Workbook.new(final)
      final_sheet = final_workbook.sheet("xl/worksheets/sheet1.xml")
      assert_equal 4, final_sheet.cell_numeric_value(final_sheet.cell("C2"))
      assert_equal "#D0E0E3", final_workbook.styles.fill_rgb(final_sheet.cell("C2").attributes["s"])
      assert_equal "#F4CCCC", final_workbook.styles.fill_rgb(final_sheet.cell("C3").attributes["s"])
      assert_equal applied_workbook.formula_count, final_workbook.formula_count
      assert_equal applied_sheet.snapshot(applied_sheet.cell("D2")), final_sheet.snapshot(final_sheet.cell("D2"))
      assert_equal applied_sheet.snapshot(applied_sheet.cell("D3")), final_sheet.snapshot(final_sheet.cell("D3"))
      assert_equal 1, result.report.dig("counts", "finalized_cells")
      assert_equal 0, result.report.dig("verification", "unauthorized_cell_changes")
      assert_equal ["xl/worksheets/sheet1.xml"], result.report.dig("verification", "package_members_changed")
      assert_equal Digest::SHA256.file(final).hexdigest, result.report.dig("output_amc", "sha256")
    end
  end

  def test_finalizes_prefixed_spreadsheetml_cells
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      add_existing_blue_style!(source)
      prefix_spreadsheetml_worksheet!(source)

      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)

      applied = File.join(dir, "applied.xlsx")
      apply_result = AfDataPipeline::AmcApply.apply!(
        audit_dir: audit,
        amc_path: source,
        output_path: applied
      )

      final = File.join(dir, "final.xlsx")
      result = AfDataPipeline::AmcFinalize.finalize!(
        amc_path: applied,
        apply_report_path: apply_result.report_path,
        output_path: final
      )

      workbook = AfDataPipeline::AmcApply::Workbook.new(final)
      sheet = workbook.sheet("xl/worksheets/sheet1.xml")

      assert_equal 4, sheet.cell_numeric_value(sheet.cell("C2"))
      assert_equal "#D0E0E3", workbook.styles.fill_rgb(sheet.cell("C2").attributes["s"])
      assert_equal 1, result.report.dig("counts", "finalized_cells")
    end
  end

  def test_appends_equivalent_blue_style_when_fill_exists_but_style_is_missing
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      add_existing_blue_fill!(source)

      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      applied = File.join(dir, "applied.xlsx")
      apply_result = AfDataPipeline::AmcApply.apply!(
        audit_dir: audit,
        amc_path: source,
        output_path: applied
      )

      applied_workbook = AfDataPipeline::AmcApply::Workbook.new(applied)
      applied_sheet = applied_workbook.sheet("xl/worksheets/sheet1.xml")
      red_style = Integer(applied_sheet.cell("C2").attributes["s"], 10)

      final = File.join(dir, "final.xlsx")
      result = AfDataPipeline::AmcFinalize.finalize!(
        amc_path: applied,
        apply_report_path: apply_result.report_path,
        output_path: final
      )

      final_workbook = AfDataPipeline::AmcApply::Workbook.new(final)
      final_sheet = final_workbook.sheet("xl/worksheets/sheet1.xml")
      blue_style = Integer(final_sheet.cell("C2").attributes["s"], 10)

      assert_equal 4, final_sheet.cell_numeric_value(final_sheet.cell("C2"))
      assert_equal "#D0E0E3", final_workbook.styles.fill_rgb(blue_style.to_s)
      assert_equal applied_workbook.styles.base_signature(red_style), final_workbook.styles.base_signature(blue_style)
      assert_equal 1, result.report.dig("style_transition", "cell_xfs_appended")
      assert_equal(
        ["xl/styles.xml", "xl/worksheets/sheet1.xml"],
        result.report.dig("verification", "package_members_changed")
      )
    end
  end

  def test_cli_progress_reports_major_finalize_phases
    Dir.mktmpdir do |dir|
      applied, report = build_applied_fixture(dir)
      final = File.join(dir, "final.xlsx")
      final_report = File.join(dir, "final-report.json")
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::CLI.run(
        [
          "amc-finalize",
          "--amc", applied,
          "--apply-report", report,
          "--output", final,
          "--report", final_report,
          "--expect-cells", "1",
          "--progress"
        ],
        out:,
        err:
      )

      assert_equal 0, status
      assert_equal(
        %w[report report preflight preflight write write verify verify publish publish],
        err.string.lines.filter_map { |line| line[/\A\[(\w+)\]/, 1] }
      )
      assert_includes err.string, "[report] 1 written cell(s) authorized for finalization"
      assert_includes err.string, "[write] recolored 1 cell(s)"
      assert_includes err.string, "[verify] passed"
      assert_includes err.string, "[publish] complete"
      assert_includes out.string, "Finalized cells: 1"
      assert_includes out.string, "Next compatibility/adoption command:"
      assert_includes out.string, "bin/af-project-state"
      assert_includes out.string, "adopt #{final}"
    end
  end

  def test_rejects_applied_workbook_that_does_not_match_apply_report_hash
    Dir.mktmpdir do |dir|
      applied, report = build_applied_fixture(dir)
      corrupt_inline_cell(applied, before: "Adventure 2", after: "Changed Title")
      final = File.join(dir, "final.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcFinalize.finalize!(
          amc_path: applied,
          apply_report_path: report,
          output_path: final
        )
      end

      assert_match(/SHA-256 does not match/, error.message)
      refute File.exist?(final)
    end
  end

  def test_fails_closed_when_no_equivalent_existing_blue_style_exists
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      applied = File.join(dir, "applied.xlsx")
      apply_result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: applied)
      final = File.join(dir, "final.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcFinalize.finalize!(
          amc_path: applied,
          apply_report_path: apply_result.report_path,
          output_path: final
        )
      end

      assert_match(/exactly one #D0E0E3 style equivalent/, error.message)
      refute File.exist?(final)
    end
  end

  def test_refuses_to_overwrite_existing_output
    Dir.mktmpdir do |dir|
      applied, report = build_applied_fixture(dir)
      final = File.join(dir, "final.xlsx")
      File.write(final, "existing")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcFinalize.finalize!(
          amc_path: applied,
          apply_report_path: report,
          output_path: final
        )
      end

      assert_match(/refusing to overwrite existing output workbook/, error.message)
      assert_equal "existing", File.read(final)
    end
  end

  def test_verify_existing_rejects_a_valid_but_changed_report
    Dir.mktmpdir do |dir|
      applied, apply_report = build_applied_fixture(dir)
      final = File.join(dir, "final.xlsx")
      final_report = File.join(dir, "final-report.json")
      AfDataPipeline::AmcFinalize.finalize!(
        amc_path: applied,
        apply_report_path: apply_report,
        output_path: final,
        report_path: final_report
      )
      report = JSON.parse(File.binread(final_report))
      report["status"] = "changed"
      File.write(final_report, JSON.pretty_generate(report) + "\n")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcFinalize.verify_existing!(
          amc_path: applied,
          apply_report_path: apply_report,
          output_path: final,
          report_path: final_report
        )
      end

      assert_match(/report conflicts/, error.message)
    end
  end

  private

  def build_applied_fixture(dir)
    source = write_amc_workbook(
      File.join(dir, "source.xlsx"),
      rows: [
        { adventure_id: "ADV-0001", values: { "Seriousness" => nil } },
        { adventure_id: "ADV-0002", values: { "Seriousness" => 3 } }
      ]
    )
    add_existing_blue_style!(source)
    audit = build_editorial_audit(
      dir,
      candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
    ).fetch(:audit)
    applied = File.join(dir, "applied.xlsx")
    result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: applied)
    [applied, result.report_path]
  end

  def add_existing_blue_fill!(path)
    Zip::File.open(path) do |zip|
      entry = zip.find_entry("xl/styles.xml")
      xml = entry.get_input_stream.read
      xml = xml.sub('<fills count="4">', '<fills count="5">')
      xml = xml.sub(
        "</fills>",
        '<fill><patternFill patternType="solid"><fgColor rgb="FFD0E0E3"/><bgColor indexed="64"/></patternFill></fill></fills>'
      )
      zip.get_output_stream(entry) { |stream| stream.write(xml) }
    end
  end

  def prefix_spreadsheetml_worksheet!(path)
    tags = %w[
      worksheet dimension sheetViews sheetView pane cols col
      sheetData row c is t f v mergeCells mergeCell
    ]
    pattern = /<(\/?)(#{tags.join("|")})(?=[\s>\/])/

    Zip::File.open(path) do |zip|
      entry = zip.find_entry("xl/worksheets/sheet1.xml")
      xml = entry.get_input_stream.read
      xml = xml.gsub(pattern) do
        "<#{Regexp.last_match(1)}x:#{Regexp.last_match(2)}"
      end
      xml = xml.sub(
        %(xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}"),
        %(xmlns:x="#{AfDataPipeline::AmcApply::MAIN_NS}")
      )
      zip.get_output_stream(entry) { |stream| stream.write(xml) }
    end
  end

  def add_existing_blue_style!(path)
    Zip::File.open(path) do |zip|
      entry = zip.find_entry("xl/styles.xml")
      xml = entry.get_input_stream.read
      xml = xml.sub('<fills count="4">', '<fills count="5">')
      xml = xml.sub(
        "</fills>",
        '<fill><patternFill patternType="solid"><fgColor rgb="FFD0E0E3"/><bgColor indexed="64"/></patternFill></fill></fills>'
      )
      xml = xml.sub('<cellXfs count="6">', '<cellXfs count="7">')
      xml = xml.sub(
        "</cellXfs>",
        '<xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="left" vertical="bottom"/></xf></cellXfs>'
      )
      zip.get_output_stream(entry) { |stream| stream.write(xml) }
    end
  end

  def set_cell_style!(path, reference, style)
    Zip::File.open(path) do |zip|
      entry = zip.find_entry("xl/worksheets/sheet1.xml")
      xml = entry.get_input_stream.read
      pattern = /(<c\s+r="#{Regexp.escape(reference)}"\s+)s="\d+"/
      raise "fixture cell not found: #{reference}" unless xml.match?(pattern)
      xml = xml.sub(pattern, "\\1s=\"#{style}\"")
      zip.get_output_stream(entry) { |stream| stream.write(xml) }
    end
  end
end
