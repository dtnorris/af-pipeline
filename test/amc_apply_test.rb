# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/amc_fixture"
require "stringio"

class AmcApplyTest < Minitest::Test
  include AmcFixture

  # Returned worksheet/style failures reach existing pipeline rescues while
  # standalone owner instances retain their own exception classes.
  def test_helper_failures_translate_without_changing_standalone_owner
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(File.join(dir, "source.xlsx"), rows: [])
      pipeline = AfDataPipeline::AmcApply::Workbook.new(source)
      assert_raises(AfDataPipeline::ValidationError) { pipeline.catalog_sheet!.resolve_headers!(["Combat Emphasis"]) }
      assert_raises(AfDataPipeline::ValidationError) { pipeline.styles.base_signature(9999) }
      owner = AfXlsxFiles::AmcApply::Workbook.new(source)
      assert_raises(AfXlsxFiles::ValidationError) { owner.catalog_sheet!.resolve_headers!(["Combat Emphasis"]) }
      assert_raises(AfXlsxFiles::ValidationError) { owner.styles.base_signature(9999) }
    end
  end

  def test_blank_target_writes_value_and_red_fill_while_preserving_formula_and_unrelated_cells
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", title: "Unrelated Title", values: { "Seriousness" => nil } }]
      )
      audit_data = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      )
      audit = audit_data.fetch(:audit)
      output = File.join(dir, "output.xlsx")
      source_sha = Digest::SHA256.file(source).hexdigest
      source_workbook = AfDataPipeline::AmcApply::Workbook.new(source)
      source_sheet = source_workbook.sheet("xl/worksheets/sheet1.xml")
      source_title = source_sheet.snapshot(source_sheet.cell("B2"))
      source_formula = source_sheet.snapshot(source_sheet.cell("D2"))

      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)

      assert_equal source_sha, Digest::SHA256.file(source).hexdigest
      assert File.file?(output)
      assert File.file?(result.report_path)
      assert_equal source_sha, result.report.dig("source_amc", "sha256")
      assert_equal Digest::SHA256.file(output).hexdigest, result.report.dig("output_amc", "sha256")
      assert_equal Digest::SHA256.file(File.join(audit, "audit_manifest.json")).hexdigest,
        result.report.dig("editorial_audit", "audit_manifest_sha256")
      assert_equal Digest::SHA256.file(audit_data.fetch(:ledger)).hexdigest,
        result.report.dig("editorial_audit", "editorial_decisions_sha256")
      assert_equal 1, result.report.dig("counts", "new_cells_written")
      assert_equal 0, result.report.dig("counts", "already_present_exact_matches")
      record = result.report.fetch("records").first
      assert_equal "ADV-0001::Seriousness", record["candidate_key"]
      assert_nil record["previous_value"]
      assert_equal "written", record["action"]
      assert_equal "C2", record["cell"]
      assert_equal "#F4CCCC", record["expected_fill"]

      output_workbook = AfDataPipeline::AmcApply::Workbook.new(output)
      output_sheet = output_workbook.sheet("xl/worksheets/sheet1.xml")
      written_cell = output_sheet.cell("C2")
      assert_equal 4, output_sheet.cell_numeric_value(written_cell)
      assert_equal "#F4CCCC", output_workbook.styles.fill_rgb(written_cell.attributes["s"])
      assert_equal source_title, output_sheet.snapshot(output_sheet.cell("B2"))
      assert_equal source_formula, output_sheet.snapshot(output_sheet.cell("D2"))
      assert_equal 1, result.report.dig("verification", "formula_cells_checked")
      assert_equal 0, result.report.dig("verification", "unauthorized_cell_changes")
      assert_equal ["xl/worksheets/sheet1.xml"], result.report.dig("verification", "package_members_changed")
    end
  end

  def test_progress_callback_reports_major_apply_phases
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")
      messages = []

      AfDataPipeline::AmcApply.apply!(
        audit_dir: audit,
        amc_path: source,
        output_path: output,
        progress: ->(message) { messages << message }
      )

      assert_equal(
        %w[audit audit preflight preflight write write verify verify publish publish],
        messages.map { |message| message[/\A\[(\w+)\]/, 1] }
      )
      assert_includes messages, "[preflight] 1 write(s), 0 already present"
      assert_includes messages, "[verify] passed"
      assert_includes messages, "[publish] complete"
    end
  end

  def test_cli_progress_flag_writes_incremental_feedback_to_stderr
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::CLI.run(
        ["amc-apply", audit, "--amc", source, "--output", output, "--progress"],
        out:,
        err:
      )

      assert_equal 0, status
      assert_match(/\[audit\] validating editorial audit/, err.string)
      assert_match(/\[preflight\] 1 write\(s\), 0 already present/, err.string)
      assert_match(/\[verify\] passed/, err.string)
      assert_match(/\[publish\] complete/, err.string)
      assert_match(/New cells written: 1/, out.string)
      assert_includes out.string, "Next command template:"
      assert_includes out.string, "amc-finalize"
      assert_includes out.string, "--amc #{output}"
      assert_includes out.string, "--apply-report #{AfDataPipeline::AmcApply.default_report_path(output)}"
      assert_includes out.string, "--output FINAL.xlsx"
      assert_includes out.string, "--expect-cells 1"
    end
  end

  def test_exact_existing_value_is_idempotent_no_op_without_recoloring
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => 4 } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)

      assert_equal 0, result.report.dig("counts", "new_cells_written")
      assert_equal 1, result.report.dig("counts", "already_present_exact_matches")
      assert_equal "already_present", result.report.fetch("records").first["action"]
      assert_equal Digest::SHA256.file(source).hexdigest, Digest::SHA256.file(output).hexdigest
    end
  end

  def test_hash_of_sessions_resolves_to_number_of_sessions_header
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        dimensions: ["Number of Sessions"],
        rows: [{
          adventure_id: "ADV-0001",
          values: { "Number of Sessions" => nil }
        }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "# of Sessions", value: 2 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      result = AfDataPipeline::AmcApply.apply!(
        audit_dir: audit,
        amc_path: source,
        output_path: output
      )

      assert_equal 1, result.report.dig("counts", "new_cells_written")
      assert_equal "C2", result.report.fetch("records").first.fetch("cell")

      workbook = AfDataPipeline::AmcApply::Workbook.new(output)
      sheet = workbook.sheet("xl/worksheets/sheet1.xml")
      assert_equal 2, sheet.cell_numeric_value(sheet.cell("C2"))
    end
  end

  def test_write_preserves_prefixed_spreadsheetml_namespace_for_existing_cell
    xml = <<~XML
      <x:worksheet xmlns:x="#{AfDataPipeline::AmcApply::MAIN_NS}">
        <x:sheetData>
          <x:row r="2">
            <x:c r="I2" s="1"/>
          </x:row>
        </x:sheetData>
      </x:worksheet>
    XML

    sheet = AfDataPipeline::AmcApply::Worksheet.new(
      name: "Adventure Catalog",
      part: "xl/worksheets/sheet1.xml",
      xml: xml,
      shared_strings: []
    )

    sheet.write!(
      "cell" => "I2",
      "expected_style_index" => 1,
      "proposed_value" => 2
    )

    reloaded = AfDataPipeline::AmcApply::Worksheet.new(
      name: "Adventure Catalog",
      part: "xl/worksheets/sheet1.xml",
      xml: sheet.to_xml,
      shared_strings: []
    )

    assert_equal 2, reloaded.cell_numeric_value(reloaded.cell("I2"))
    assert_match(/<x:v>2<\/x:v>/, sheet.to_xml)
  end

  def test_write_preserves_prefixed_spreadsheetml_namespace_for_absent_cell
    xml = <<~XML
      <x:worksheet xmlns:x="#{AfDataPipeline::AmcApply::MAIN_NS}">
        <x:sheetData>
          <x:row r="2">
            <x:c r="H2" s="1"/>
            <x:c r="J2" s="1"/>
          </x:row>
        </x:sheetData>
      </x:worksheet>
    XML

    sheet = AfDataPipeline::AmcApply::Worksheet.new(
      name: "Adventure Catalog",
      part: "xl/worksheets/sheet1.xml",
      xml: xml,
      shared_strings: []
    )

    sheet.write!(
      "cell" => "I2",
      "expected_style_index" => 1,
      "proposed_value" => 3
    )

    reloaded = AfDataPipeline::AmcApply::Worksheet.new(
      name: "Adventure Catalog",
      part: "xl/worksheets/sheet1.xml",
      xml: sheet.to_xml,
      shared_strings: []
    )

    assert_equal 3, reloaded.cell_numeric_value(reloaded.cell("I2"))
    assert_match(/<x:c[^>]*r=['"]I2['"][^>]*>.*<x:v>3<\/x:v>.*<\/x:c>/m, sheet.to_xml)
  end

  def test_level_start_and_level_end_resolve_as_independent_targets
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        dimensions: ["Level Start", "Level End"],
        rows: [{
          adventure_id: "ADV-0001",
          values: { "Level Start" => 1, "Level End" => nil }
        }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [
          { adventure_id: "ADV-0001", dimension: "Level Start", value: 1 },
          { adventure_id: "ADV-0001", dimension: "Level End", value: 5 }
        ]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)

      assert_equal 1, result.report.dig("counts", "new_cells_written")
      assert_equal 1, result.report.dig("counts", "already_present_exact_matches")
      records = result.report.fetch("records").to_h { |record| [record.fetch("dimension"), record] }
      assert_equal ["C2", "already_present"], records.fetch("Level Start").values_at("cell", "action")
      assert_equal ["D2", "written"], records.fetch("Level End").values_at("cell", "action")
    end
  end

  def test_conflicting_existing_value_is_fatal_and_produces_no_output
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => 2 } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)
      end

      assert_match(/ADV-0001::Seriousness/, error.message)
      assert_match(/existing=2/, error.message)
      assert_match(/proposed=4/, error.message)
      refute File.exist?(output)
      refute File.exist?(AfDataPipeline::AmcApply.default_report_path(output))
    end
  end

  def test_editorial_hold_produces_no_write
    assert_nonaccepted_no_write("HOLD", count_key: "held_candidates")
  end

  def test_editorial_reject_produces_no_write
    assert_nonaccepted_no_write("REJECT", count_key: "rejected_candidates")
  end

  def test_source_hold_produces_no_write
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [],
        source_holds: [{ adventure_id: "ADV-0001", dimension: "Seriousness" }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)

      assert_equal 1, result.report.dig("counts", "source_holds")
      assert_equal 0, result.report.dig("counts", "new_cells_written")
      assert_equal Digest::SHA256.file(source).hexdigest, Digest::SHA256.file(output).hexdigest
    end
  end

  def test_incomplete_audit_fails_closed
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      key = "ADV-0001::Seriousness"
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }],
        decisions: { key => nil }
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)
      end
      assert_match(/remain pending/, error.message)
      refute File.exist?(output)
    end
  end

  def test_tampered_or_stale_audit_fails_closed
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit_data = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      )
      File.open(File.join(audit_data.fetch(:review), "candidates.jsonl"), "a") { |file| file.puts }
      output = File.join(dir, "output.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.apply!(audit_dir: audit_data.fetch(:audit), amc_path: source, output_path: output)
      end
      assert_match(/source review file changed/, error.message)
      refute File.exist?(output)
    end
  end

  def test_unknown_adventure_id_fails_closed
    assert_preflight_failure(
      rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }],
      candidate: { adventure_id: "ADV-9999", dimension: "Seriousness", value: 4 },
      expected: /unknown Adventure ID ADV-9999/
    )
  end

  def test_unsupported_candidate_dimension_fails_closed
    assert_preflight_failure(
      rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }],
      candidate: { adventure_id: "ADV-0001", dimension: "Unsupported Metric", value: 4 },
      expected: /unsupported candidate dimension/
    )
  end

  def test_missing_target_header_fails_closed
    assert_preflight_failure(
      rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }],
      candidate: { adventure_id: "ADV-0001", dimension: "Level End", value: 4 },
      expected: /missing target dimension\/header "Level End"/
    )
  end

  def test_ambiguous_target_header_fails_closed
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }],
        duplicate_header: "Seriousness"
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)
      end
      assert_match(/ambiguous target dimension\/header/, error.message)
      refute File.exist?(output)
    end
  end

  def test_duplicate_adventure_ids_fail_closed
    assert_preflight_failure(
      rows: [
        { adventure_id: "ADV-0001", values: { "Seriousness" => nil } },
        { adventure_id: "ADV-0001", values: { "Seriousness" => nil } }
      ],
      candidate: { adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 },
      expected: /duplicate Adventure IDs/
    )
  end

  def test_source_and_output_paths_must_differ
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(dir, candidates: []).fetch(:audit)

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: source)
      end
      assert_match(/different file/, error.message)
    end
  end

  def test_existing_output_is_not_overwritten
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(dir, candidates: []).fetch(:audit)
      output = File.join(dir, "output.xlsx")
      File.write(output, "keep me")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)
      end
      assert_match(/refusing to overwrite/, error.message)
      assert_equal "keep me", File.read(output)
    end
  end

  def test_style_resolution_does_not_depend_on_numeric_style_id
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)

      assert_equal 5, result.report.fetch("records").first["expected_style_index"]
      workbook = AfDataPipeline::AmcApply::Workbook.new(output)
      cell = workbook.sheet("xl/worksheets/sheet1.xml").cell("C2")
      assert_equal "#F4CCCC", workbook.styles.fill_rgb(cell.attributes["s"])
    end
  end

  def test_safely_appends_red_variant_when_no_matching_cell_xf_exists
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }],
        red_style_match: false
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)

      assert_equal 1, result.report.dig("style_mutation", "cell_xfs_appended")
      assert_equal 6, result.report.fetch("records").first["expected_style_index"]
      assert result.report.dig("verification", "passed")
    end
  end

  def test_second_application_is_fully_idempotent
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      first = File.join(dir, "first.xlsx")
      second = File.join(dir, "second.xlsx")
      AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: first)

      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: first, output_path: second)

      assert_equal 0, result.report.dig("counts", "new_cells_written")
      assert_equal 1, result.report.dig("counts", "already_present_exact_matches")
      assert_equal Digest::SHA256.file(first).hexdigest, Digest::SHA256.file(second).hexdigest
    end
  end

  def test_post_write_verifier_detects_intentional_corruption
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", title: "Fixture Adventure", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")
      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)
      corrupt_inline_cell(output, before: "Fixture Adventure", after: "Corrupted Adventure")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.verify!(
          source_amc: source,
          output_amc: output,
          records: result.report.fetch("records"),
          styles_appended: result.report.dig("style_mutation", "cell_xfs_appended")
        )
      end
      assert_match(/unauthorized worksheet cell change/, error.message)
    end
  end

  def test_nonnumeric_accepted_value_fails_closed
    assert_preflight_failure(
      rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }],
      candidate: { adventure_id: "ADV-0001", dimension: "Seriousness", value: "high" },
      expected: /accepted value must be numeric/
    )
  end

  def test_cli_and_help_expose_amc_apply
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }]
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::CLI.run(["amc-apply", audit, "--amc", source, "--output", output], out:, err:)

      assert_equal 0, status, err.string
      assert_match(/New cells written: 1/, out.string)
      assert_match(/amc-apply/, capture_help)
    end
  end

  private

  def assert_nonaccepted_no_write(decision, count_key:)
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(
        File.join(dir, "source.xlsx"),
        rows: [{ adventure_id: "ADV-0001", values: { "Seriousness" => nil } }]
      )
      key = "ADV-0001::Seriousness"
      audit = build_editorial_audit(
        dir,
        candidates: [{ adventure_id: "ADV-0001", dimension: "Seriousness", value: 4 }],
        decisions: { key => decision }
      ).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      result = AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)

      assert_equal 1, result.report.dig("counts", count_key)
      assert_equal 0, result.report.dig("counts", "new_cells_written")
      assert_equal Digest::SHA256.file(source).hexdigest, Digest::SHA256.file(output).hexdigest
    end
  end

  def assert_preflight_failure(rows:, candidate:, expected:)
    Dir.mktmpdir do |dir|
      source = write_amc_workbook(File.join(dir, "source.xlsx"), rows:)
      audit = build_editorial_audit(dir, candidates: [candidate]).fetch(:audit)
      output = File.join(dir, "output.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.apply!(audit_dir: audit, amc_path: source, output_path: output)
      end
      assert_match expected, error.message
      refute File.exist?(output)
    end
  end

  def capture_help
    out = StringIO.new
    AfDataPipeline::CLI.run(["help"], out:, err: StringIO.new)
    out.string
  end
end
