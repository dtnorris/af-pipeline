# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "cgi"

class BoundaryFreezeApplyTest < Minitest::Test
  def test_applies_campaign_adventure_embedded_chain_to_new_successor
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [
          frozen_record("campaign", "Campaign Parent", 1, 120),
          frozen_record("adventure", "Adventure", 10, 20, parent_key: "campaign", levels: [2, 4]),
          frozen_record("embedded", "Embedded Adventure", 15, 16, parent_key: "adventure")
        ]
      )
      output = File.join(dir, "successor.xlsx")
      source_sha = Digest::SHA256.file(base_amc).hexdigest

      result = AfDataPipeline::BoundaryFreezeApply.apply!(
        freeze_path: freeze,
        source_root:,
        amc_path: base_amc,
        publisher: "Fixture Publisher",
        output_path: output
      )

      assert_equal source_sha, Digest::SHA256.file(base_amc).hexdigest
      assert File.file?(output)
      assert File.file?(result.report_path)
      assert_equal 3, result.report.dig("counts", "adventure_ids_assigned")
      assert_equal "ADV-0010", result.report.dig("allocation", "first_adventure_id")
      assert_equal "ADV-0012", result.report.dig("allocation", "last_adventure_id")

      by_key = result.report.fetch("records").to_h { |record| [record.fetch("local_key"), record] }
      assert_equal "AMC >100pg", by_key.fetch("campaign").fetch("sheet")
      assert_equal "Adventure Catalog", by_key.fetch("adventure").fetch("sheet")
      assert_equal "Adventure Catalog", by_key.fetch("embedded").fetch("sheet")
      assert_equal "ADV-0010", by_key.fetch("adventure").fetch("resolved_parent_adventure_id")
      assert_equal "ADV-0011", by_key.fetch("embedded").fetch("resolved_parent_adventure_id")

      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(output)
      ordinary = workbook.sheet_by_name!("Adventure Catalog")
      large = workbook.sheet_by_name!("AMC >100pg")
      books = workbook.sheet_by_name!("Current Books")

      assert_equal "ADV-0010", large.cell_value("A4")
      assert_equal "Campaign Parent", large.cell_value("B4")
      assert_equal 120, large.cell_value("D4")
      assert_nil large.cell_value("I4")
      assert_nil large.cell_value("K4")

      assert_equal "ADV-0011", ordinary.cell_value("A3")
      assert_equal "Adventure", ordinary.cell_value("B3")
      assert_equal 11, ordinary.cell_value("D3")
      assert_equal 2, ordinary.cell_value("K3")
      assert_equal 4, ordinary.cell_value("L3")
      assert_nil ordinary.cell_value("I3")
      assert_nil ordinary.cell_value("J3")
      assert_nil ordinary.cell_value("M3")

      assert_equal "ADV-0012", ordinary.cell_value("A4")
      assert_equal "Embedded Adventure", ordinary.cell_value("B4")
      assert_equal "Fixture Book", ordinary.cell_value("E4")
      assert_equal "Fixture Publisher", ordinary.cell_value("F4")

      assert_equal "Fixture Book", books.cell_value("C6")
      assert_equal "Fixture Publisher", books.cell_value("D6")
      assert_equal 2, books.cell_value("B6")
      assert_equal "Fixture Publisher", books.cell_value("H6")
      assert_equal 2, books.cell_value("G6")
      assert_equal 5, books.cell_value("B2")
      assert_equal 5, books.cell_value("G2")
      assert_equal 2, large.cell_value("B2")
      assert result.report.dig("verification", "passed")
      assert_equal 0, result.report.dig("verification", "unauthorized_cell_changes")
    end
  end

  def test_applies_when_ordinary_catalog_omits_large_page_flag
    with_stage7_workspace(ordinary_large_flag: false) do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze,
        source_root,
        base_amc,
        records: [
          frozen_record("small", "Small Adventure", 40, 41, levels: [3, 4]),
          frozen_record("large", "Large Adventure", 1, 120)
        ]
      )
      output = File.join(dir, "successor.xlsx")

      result = AfDataPipeline::BoundaryFreezeApply.apply!(
        freeze_path: freeze,
        source_root:,
        amc_path: base_amc,
        publisher: "Fixture Publisher",
        output_path: output
      )

      assert_equal 2, result.report.dig("counts", "adventure_ids_assigned")

      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(output)
      ordinary = workbook.sheet_by_name!("Adventure Catalog")
      large = workbook.sheet_by_name!("AMC >100pg")

      assert_nil ordinary.column_for_header(">99 pgs")
      assert_equal "Small Adventure", ordinary.cell_value("B3")
      assert_equal 2, ordinary.cell_value("D3")

      large_flag_column = large.column_for_header(">99 pgs")
      refute_nil large_flag_column
      assert_equal "Large Adventure", large.cell_value("B4")
      assert_equal 1, large.cell_value("#{large_flag_column}4")
      assert result.report.dig("verification", "passed")
    end
  end

  def test_allows_matching_cross_sheet_mirror_ids
    with_stage7_workspace(mirror_large_in_ordinary: true) do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze,
        source_root,
        base_amc,
        records: [frozen_record("new", "New Adventure", 40, 41)]
      )
      output = File.join(dir, "successor.xlsx")

      result = AfDataPipeline::BoundaryFreezeApply.apply!(
        freeze_path: freeze,
        source_root:,
        amc_path: base_amc,
        publisher: "Fixture Publisher",
        output_path: output
      )

      assert_equal "ADV-0010", result.report.dig("allocation", "first_adventure_id")
      assert result.report.dig("verification", "passed")

      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(output)
      books = workbook.sheet_by_name!("Current Books")

      assert_equal 3, result.report.dig("current_books", "canonical_adventure_count")
      assert_equal 1, result.report.dig("current_books", "large_adventure_count")
      assert_equal 3, books.cell_value("B2")
      assert_equal 3, books.cell_value("G2")
      assert_equal 1.0, books.cell_value("A2")
      assert_equal 1.0, books.cell_value("F2")
    end
  end

  def test_adds_large_record_only_to_canonical_catalog_when_large_sheet_is_legacy_mirror
    with_stage7_workspace(mirror_large_in_ordinary: true) do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze,
        source_root,
        base_amc,
        records: [frozen_record("large-new", "New Large Adventure", 1, 120)]
      )
      output = File.join(dir, "successor.xlsx")
      source_workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(base_amc)
      source_large = source_workbook.sheet_by_name!("AMC >100pg")

      result = AfDataPipeline::BoundaryFreezeApply.apply!(
        freeze_path: freeze,
        source_root:,
        amc_path: base_amc,
        publisher: "Fixture Publisher",
        output_path: output
      )

      by_key = result.report.fetch("records").to_h { |record| [record.fetch("local_key"), record] }
      assert_equal "Adventure Catalog", by_key.fetch("large-new").fetch("sheet")
      assert_equal 1, result.report.dig("counts", "ordinary_rows_created")
      assert_equal 0, result.report.dig("counts", "large_rows_created")
      assert_equal 2, result.report.dig("current_books", "large_adventure_count")

      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(output)
      ordinary = workbook.sheet_by_name!("Adventure Catalog")
      large = workbook.sheet_by_name!("AMC >100pg")
      books = workbook.sheet_by_name!("Current Books")

      assert_equal "ADV-0010", ordinary.cell_value("A4")
      assert_equal "New Large Adventure", ordinary.cell_value("B4")
      assert_equal 120, ordinary.cell_value("D4")
      assert_nil large.cell_value("A4")
      assert_equal 1, large.cell_value("B2")
      assert_equal source_workbook.member_hashes.fetch(source_large.part),
                   workbook.member_hashes.fetch(large.part)

      assert_equal 3, books.cell_value("B2")
      assert_equal 2, books.cell_value("B4")
      assert_equal %(COUNTIF('Adventure Catalog'!D:D,">=100")), books.cell_formula(books.cell("B4"))
      assert_equal 3, books.cell_value("G2")
      assert_equal 2, books.cell_value("G5")
      assert_equal %(COUNTIF('Adventure Catalog'!D:D,">=100")), books.cell_formula(books.cell("G5"))
      assert result.report.dig("verification", "passed")
    end
  end

  def test_rejects_conflicting_cross_sheet_duplicate_ids
    with_stage7_workspace(
      mirror_large_in_ordinary: true,
      ordinary_mirror_title: "Conflicting Mirror"
    ) do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze,
        source_root,
        base_amc,
        records: [frozen_record("new", "New Adventure", 40, 41)]
      )
      output = File.join(dir, "successor.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreezeApply.apply!(
          freeze_path: freeze,
          source_root:,
          amc_path: base_amc,
          publisher: "Fixture Publisher",
          output_path: output
        )
      end

      assert_match(/conflicting duplicate Adventure IDs across AMC catalog sheets: ADV-0009/, error.message)
      refute File.exist?(output)
    end
  end

  def test_existing_parent_adventure_id_is_resolved_but_not_written_to_workbook
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [frozen_record("child", "New Child", 30, 31, parent_adventure_id: "ADV-0007")]
      )
      output = File.join(dir, "successor.xlsx")

      result = AfDataPipeline::BoundaryFreezeApply.apply!(
        freeze_path: freeze,
        source_root:,
        amc_path: base_amc,
        publisher: "Fixture Publisher",
        output_path: output
      )

      record = result.report.fetch("records").first
      assert_equal "ADV-0007", record.fetch("parent_adventure_id")
      assert_equal "ADV-0007", record.fetch("resolved_parent_adventure_id")
      assert_equal "ADV-0010", record.fetch("adventure_id")
    end
  end

  def test_missing_existing_parent_fails_closed_without_output
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [frozen_record("child", "New Child", 30, 31, parent_adventure_id: "ADV-9999")]
      )
      output = File.join(dir, "successor.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreezeApply.apply!(
          freeze_path: freeze,
          source_root:,
          amc_path: base_amc,
          publisher: "Fixture Publisher",
          output_path: output
        )
      end
      assert_match(/parent_adventure_id ADV-9999 does not exist/, error.message)
      refute File.exist?(output)
      refute File.exist?(AfDataPipeline::BoundaryFreezeApply.default_report_path(output))
    end
  end

  def test_duplicate_existing_source_title_fails_closed
    with_stage7_workspace(source_id: "Existing Book") do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        source_id: "Existing Book",
        records: [frozen_record("duplicate", "Existing Adventure", 40, 41)]
      )
      output = File.join(dir, "successor.xlsx")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreezeApply.apply!(
          freeze_path: freeze,
          source_root:,
          amc_path: base_amc,
          publisher: "Existing Publisher",
          output_path: output
        )
      end
      assert_match(/duplicate existing source\/title/, error.message)
      refute File.exist?(output)
    end
  end

  def test_cli_runs_boundary_freeze_apply
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(freeze, source_root, base_amc, records: [frozen_record("new", "New Adventure", 40, 41)])
      output = File.join(dir, "successor.xlsx")
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::CLI.run(
        [
          "boundary-freeze-apply", freeze,
          "--source-root", source_root,
          "--amc", base_amc,
          "--publisher", "Fixture Publisher",
          "--output", output,
          "--no-progress"
        ],
        out:,
        err:
      )

      assert_equal 0, status
      assert_empty err.string
      assert_match(/Frozen records applied: 1/, out.string)
      assert_match(/Adventure IDs assigned: 1/, out.string)
      assert File.file?(output)
    end
  end

  def test_cli_writes_boundary_freeze_apply_report_to_explicit_path
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "freeze.yml")
      write_frozen_boundary(
        freeze,
        source_root,
        base_amc,
        records: [frozen_record("new", "New Adventure", 40, 41)]
      )
      output = File.join(dir, "successor.xlsx")
      report_dir = File.join(dir, "audits", "pre-scoring")
      FileUtils.mkdir_p(report_dir)
      report = File.join(report_dir, "boundary-freeze-apply-report.json")
      default_report = AfDataPipeline::BoundaryFreezeApply.default_report_path(output)
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::CLI.run(
        [
          "boundary-freeze-apply", freeze,
          "--source-root", source_root,
          "--amc", base_amc,
          "--publisher", "Fixture Publisher",
          "--output", output,
          "--report", report,
          "--no-progress"
        ],
        out:,
        err:
      )

      assert_equal 0, status
      assert_empty err.string
      assert File.file?(output)
      assert File.file?(report)
      refute File.exist?(default_report)
      assert_match(/Wrote #{Regexp.escape(report)}/, out.string)
    end
  end

  def test_cli_derives_successor_workbook_and_standard_report_paths
    with_stage7_workspace do |dir, source_root, base_amc|
      audit_dir = File.join(dir, "audits", "pre-scoring")
      FileUtils.mkdir_p(audit_dir)
      freeze = File.join(audit_dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(freeze, source_root, base_amc, records: [frozen_record("new", "New Adventure", 40, 41)])
      output = File.join(dir, "5e_Adventure_Master_Catalog_0.2.xlsx")
      report = File.join(audit_dir, "fixture-book-boundary-freeze-apply-report-from-amc-0.1-to-0.2.json")
      source_sha = Digest::SHA256.file(base_amc).hexdigest

      status, out, err = run_apply_cli(
        freeze, source_root, base_amc,
        "--successor-version", "0.2", "--amc-dir", dir
      )

      assert_equal 0, status
      assert_empty err
      assert File.file?(output)
      assert File.file?(report)
      assert_match(/Wrote #{Regexp.escape(output)}/, out)
      assert_match(/Wrote #{Regexp.escape(report)}/, out)
      assert_match(/Next command:/, out)
      assert_includes out, "bin/af-ingest-next"
      assert_includes out, Shellwords.escape(report)
      assert_equal source_sha, Digest::SHA256.file(base_amc).hexdigest
    end
  end

  def test_cli_deterministic_mode_preserves_explicit_report_override
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze.yml")
      write_frozen_boundary(freeze, source_root, base_amc, records: [frozen_record("new", "New Adventure", 40, 41)])
      report = File.join(dir, "explicit-report.json")

      status, _out, err = run_apply_cli(
        freeze, source_root, base_amc,
        "--successor-version", "0.2", "--amc-dir", dir, "--report", report
      )

      assert_equal 0, status
      assert_empty err
      assert File.file?(report)
      refute File.exist?(File.join(dir, "fixture-book-boundary-freeze-apply-report-from-amc-0.1-to-0.2.json"))
    end
  end

  def test_deterministic_mode_rejects_equal_or_malformed_versions_and_unversioned_base
    Dir.mktmpdir("boundary-freeze-paths") do |dir|
      error = assert_raises(AfDataPipeline::ValidationError) do
        derive_paths(dir, successor_version: "4.25.1")
      end
      assert_match(/must differ from base AMC version/, error.message)

      ["../4.26", "4/26", "4.26-beta", "4"].each do |version|
        error = assert_raises(AfDataPipeline::ValidationError) do
          derive_paths(dir, successor_version: version)
        end
        assert_match(/dot-separated numeric components/, error.message)
      end

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryFreezeApply.derive_successor_paths(
          freeze_path: File.join(dir, "source-boundary-freeze.yml"),
          amc_path: File.join(dir, "AMC.xlsx"),
          successor_version: "4.26",
          amc_dir: dir
        )
      end
      assert_match(/must use the versioned filename/, error.message)
    end
  end

  def test_deterministic_mode_refuses_preexisting_derived_output
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze.yml")
      write_frozen_boundary(freeze, source_root, base_amc, records: [frozen_record("new", "New Adventure", 40, 41)])
      output = File.join(dir, "5e_Adventure_Master_Catalog_0.2.xlsx")
      File.write(output, "existing")

      status, _out, err = run_apply_cli(
        freeze, source_root, base_amc,
        "--successor-version", "0.2", "--amc-dir", dir
      )

      assert_equal 2, status
      assert_match(/refusing to overwrite existing output workbook/, err)
      assert_equal "existing", File.read(output)
    end
  end

  def test_deterministic_mode_refuses_preexisting_derived_report
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze.yml")
      write_frozen_boundary(freeze, source_root, base_amc, records: [frozen_record("new", "New Adventure", 40, 41)])
      report = File.join(dir, "fixture-book-boundary-freeze-apply-report-from-amc-0.1-to-0.2.json")
      File.write(report, "existing")

      status, _out, err = run_apply_cli(
        freeze, source_root, base_amc,
        "--successor-version", "0.2", "--amc-dir", dir
      )

      assert_equal 2, status
      assert_match(/refusing to overwrite existing integrity report/, err)
      refute File.exist?(File.join(dir, "5e_Adventure_Master_Catalog_0.2.xlsx"))
      assert_equal "existing", File.read(report)
    end
  end

  def test_operation_bound_stage_creates_verified_successor_without_promoting_shared_roles
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(
        freeze,
        source_root,
        base_amc,
        records: [
          frozen_record("parent", "Approved Parent", 10, 12, levels: [2, 4]),
          frozen_record("child", "Approved Child", 11, 12, parent_key: "parent")
        ]
      )
      bindings = write_stage_bindings(dir, source_root, base_amc, freeze)
      project_state_before = File.binread(bindings.fetch(:project_state))
      base_before = File.binread(base_amc)

      result = AfDataPipeline::BoundaryFreezeStage.stage!(
        freeze_path: freeze,
        operation_input_path: bindings.fetch(:operation_input),
        successor_authorization_path: bindings.fetch(:authorization),
        source_root:,
        catalog_root: dir
      )

      assert_equal "verified_staged_successor", result.status
      refute result.reused
      assert_equal 2, result.record_count
      assert File.file?(result.output_path)
      assert File.file?(result.report_path)
      assert File.file?(result.stage_path)
      assert_equal base_before, File.binread(base_amc)
      assert_equal project_state_before, File.binread(bindings.fetch(:project_state))
      assert_equal false, result.receipt.dig("continuation", "catalog_head_promoted")
      assert_equal false, result.receipt.dig("continuation", "scoring_authorized")
      assert_equal "VERIFIED_STAGED_SUCCESSOR", result.receipt.dig("continuation", "state")
      assert_equal %w[catalog_head matcher_authorized_baseline production_dependency_floor],
                   result.receipt.dig("project_state", "roles").keys
      assert_equal bindings.fetch(:authorization_id),
                   result.receipt.dig("successor_version_authorization", "authorization_id")
      assert_equal "David", result.receipt.dig("boundary_freeze", "approved_by")

      by_key = result.receipt.dig("successor", "records").to_h do |record|
        [record.fetch("local_key"), record]
      end
      assert_equal "ADV-0010", by_key.fetch("parent").fetch("adventure_id")
      assert_equal "ADV-0010", by_key.fetch("child").fetch("resolved_parent_adventure_id")

      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(result.output_path)
      ordinary = workbook.sheet_by_name!("Adventure Catalog")
      assert_equal "ADV-0007", ordinary.cell_value("A2")
      assert_equal "Approved Parent", ordinary.cell_value("B3")
      assert_equal "Fixture Book", ordinary.cell_value("E3")
      assert_equal "Fixture Publisher", ordinary.cell_value("F3")
      assert_equal 10, ordinary.cell_value("G3")
      assert_equal 12, ordinary.cell_value("H3")
      assert_equal 2, ordinary.cell_value("K3")
      assert_equal 4, ordinary.cell_value("L3")
      assert_nil ordinary.cell_value("I3")
      assert_nil ordinary.cell_value("J3")
      assert_nil ordinary.cell_value("M3")
    end
  end

  def test_operation_bound_stage_replay_preserves_exact_artifacts_and_ids
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [frozen_record("new", "Approved Adventure", 40, 41)]
      )
      bindings = write_stage_bindings(dir, source_root, base_amc, freeze)
      args = {
        freeze_path: freeze,
        operation_input_path: bindings.fetch(:operation_input),
        successor_authorization_path: bindings.fetch(:authorization),
        source_root:,
        catalog_root: dir
      }
      first = AfDataPipeline::BoundaryFreezeStage.stage!(**args)
      bytes = [first.output_path, first.report_path, first.stage_path].to_h do |path|
        [path, File.binread(path)]
      end

      replay = AfDataPipeline::BoundaryFreezeStage.stage!(**args)

      assert replay.reused
      assert_equal first.receipt, replay.receipt
      bytes.each { |path, content| assert_equal content, File.binread(path) }
      assert_equal 1, replay.receipt.dig("successor", "records").length
      assert_equal "ADV-0010", replay.receipt.dig("successor", "records", 0, "adventure_id")
    end
  end

  def test_operation_bound_stage_rejects_missing_or_conflicting_authoritative_metadata
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [frozen_record("new", "Approved Adventure", 40, 41)]
      )
      bindings = write_stage_bindings(dir, source_root, base_amc, freeze, publisher: nil)
      error = assert_raises(AfDataPipeline::ValidationError) do
        stage_fixture(dir, source_root, freeze, bindings)
      end
      assert_match(/no authoritative publisher/, error.message)

      bindings = write_stage_bindings(dir, source_root, base_amc, freeze, suffix: "missing-authority")
      File.unlink(bindings.fetch(:authorization))
      error = assert_raises(AfDataPipeline::ValidationError) do
        stage_fixture(dir, source_root, freeze, bindings)
      end
      assert_match(/missing successor-version authorization projection/, error.message)

      bindings = write_stage_bindings(dir, source_root, base_amc, freeze, suffix: "conflict")
      projection = JSON.parse(File.binread(bindings.fetch(:authorization)))
      projection.fetch("authorization")["authorization_id"] = "0" * 64
      File.write(bindings.fetch(:authorization), JSON.pretty_generate(projection) + "\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        stage_fixture(dir, source_root, freeze, bindings)
      end
      assert_match(/authorization digest/, error.message)
      refute File.exist?(File.join(dir, "5e_Adventure_Master_Catalog_0.2.xlsx"))
    end
  end

  def test_operation_bound_stage_rejects_operation_base_and_artifact_conflicts
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [frozen_record("new", "Approved Adventure", 40, 41)]
      )
      bindings = write_stage_bindings(dir, source_root, base_amc, freeze)
      projection = JSON.parse(File.binread(bindings.fetch(:authorization)))
      projection.fetch("authorization").fetch("operation")["operation_id"] =
        "22222222-2222-4222-8222-222222222222"
      authorization = projection.fetch("authorization")
      authorization["authorization_id"] = authorization_digest(authorization)
      File.write(bindings.fetch(:authorization), JSON.pretty_generate(projection) + "\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        stage_fixture(dir, source_root, freeze, bindings)
      end
      assert_match(/conflicts with operation input/, error.message)

      bindings = write_stage_bindings(dir, source_root, base_amc, freeze, suffix: "base-conflict")
      projection = JSON.parse(File.binread(bindings.fetch(:authorization)))
      authorization = projection.fetch("authorization")
      authorization.fetch("base_catalog")["sha256"] = "c" * 64
      authorization["authorization_id"] = authorization_digest(authorization)
      File.write(bindings.fetch(:authorization), JSON.pretty_generate(projection) + "\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        stage_fixture(dir, source_root, freeze, bindings)
      end
      assert_match(/conflicts with frozen base catalog/, error.message)

      bindings = write_stage_bindings(dir, source_root, base_amc, freeze, suffix: "stale")
      File.write(freeze, File.binread(freeze) + "# changed\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        stage_fixture(dir, source_root, freeze, bindings)
      end
      assert_match(/DIGEST_MISMATCH/, error.message)
    end
  end

  def test_operation_bound_stage_rejects_version_collisions_partial_publication_and_mutated_replay
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [frozen_record("new", "Approved Adventure", 40, 41)]
      )
      bindings = write_stage_bindings(dir, source_root, base_amc, freeze)
      output = File.join(dir, "5e_Adventure_Master_Catalog_0.2.xlsx")
      File.write(output, "collision")
      error = assert_raises(AfDataPipeline::ValidationError) do
        stage_fixture(dir, source_root, freeze, bindings)
      end
      assert_match(/partial staged-successor publication/, error.message)
      assert_equal "collision", File.binread(output)
    end

    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [frozen_record("new", "Approved Adventure", 40, 41)]
      )
      bindings = write_stage_bindings(dir, source_root, base_amc, freeze)
      result = stage_fixture(dir, source_root, freeze, bindings)
      File.binwrite(result.output_path, File.binread(result.output_path) + "changed")
      error = assert_raises(AfDataPipeline::ValidationError) do
        stage_fixture(dir, source_root, freeze, bindings)
      end
      assert_match(/parse failure|provenance|verification|XLSX/, error.message)
      assert File.file?(result.stage_path)
    end
  end

  def test_operation_bound_zero_record_stage_is_traceable_without_successor
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(freeze, source_root, base_amc, records: [])
      bindings = write_stage_bindings(dir, source_root, base_amc, freeze)

      first = stage_fixture(dir, source_root, freeze, bindings)
      replay = stage_fixture(dir, source_root, freeze, bindings)

      assert_equal "no_successor_needed", first.status
      assert_nil first.output_path
      assert_nil first.report_path
      assert File.file?(first.stage_path)
      assert replay.reused
      assert_equal "NO_SUCCESSOR_NEEDED", replay.receipt.dig("continuation", "state")
      refute File.exist?(File.join(dir, "5e_Adventure_Master_Catalog_0.2.xlsx"))
    end
  end

  def test_operation_bound_stage_cli_is_terminal_and_does_not_emit_adoption_or_scoring
    with_stage7_workspace do |dir, source_root, base_amc|
      freeze = File.join(dir, "fixture-book-boundary-freeze-from-amc-0.1.yml")
      write_frozen_boundary(
        freeze, source_root, base_amc,
        records: [frozen_record("new", "Approved Adventure", 40, 41)]
      )
      bindings = write_stage_bindings(dir, source_root, base_amc, freeze)
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::CLI.run(
        [
          "boundary-freeze-stage", freeze,
          "--operation-input", bindings.fetch(:operation_input),
          "--successor-authority", bindings.fetch(:authorization),
          "--source-root", source_root,
          "--catalog-root", dir,
          "--no-progress"
        ],
        out:,
        err:
      )

      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "VERIFIED STAGED SUCCESSOR"
      assert_includes out.string, "Shared catalog_head promoted: false"
      assert_includes out.string, "Scoring authorized: false"
      refute_match(/\badopt\b/i, out.string)
      refute_match(/workload|execute|promotion command/i, out.string)
    end
  end

  private

  def stage_fixture(dir, source_root, freeze, bindings)
    AfDataPipeline::BoundaryFreezeStage.stage!(
      freeze_path: freeze,
      operation_input_path: bindings.fetch(:operation_input),
      successor_authorization_path: bindings.fetch(:authorization),
      source_root:,
      catalog_root: dir
    )
  end

  def write_stage_bindings(dir, source_root, base_amc, freeze, publisher: "Fixture Publisher", suffix: nil)
    tag = suffix ? "-#{suffix}" : ""
    project_state = File.join(dir, "PROJECT_STATE.yml")
    base_binding = file_binding(base_amc)
    role = {
      "version" => "0.1",
      "filename" => File.basename(base_amc),
      "sha256" => base_binding.fetch("sha256"),
      "bytes" => base_binding.fetch("bytes")
    }
    File.write(
      project_state,
      YAML.dump(
        "schema_version" => "adventurefinder-project-state/v0.2",
        "catalog_head" => role.dup,
        "matcher_authorized_baseline" => role.dup,
        "production_dependency_floor" => role.dup
      )
    )
    operation_input = File.join(dir, "operation-input#{tag}.json")
    markdown = File.join(source_root, "fixture.md")
    operation = {
      "contract_version" => "adventurefinder-ingest-operation/v0.1",
      "operation_id" => "11111111-1111-4111-8111-111111111111",
      "revision" => 4,
      "document_sha256" => "a" * 64
    }
    write_json(
      operation_input,
      {
        "schema_version" => "af-ingest-routing-input/v0.1",
        "operation" => operation,
        "artifact" => {"kind" => "file", **file_binding(freeze)},
        "source" => {
          "source_id" => "Fixture Book",
          "canonical_markdown" => file_binding(markdown).merge("filename" => File.basename(markdown)),
          "edition" => "fixture edition",
          "pagination_authority" => "printed page labels",
          "publisher" => publisher
        },
        "base_catalog" => base_binding.merge(
          "filename" => File.basename(base_amc),
          "selection_method" => "explicit",
          "project_state_sha256" => nil
        ),
        "policy" => nil
      }
    )
    authority = {
      "contract_version" => "adventurefinder-successor-version-authorization/v0.1",
      "operation" => {
        "contract_version" => operation.fetch("contract_version"),
        "operation_id" => operation.fetch("operation_id"),
        "created_at" => "2026-10-07T20:00:00Z"
      },
      "base_catalog" => base_binding.slice("sha256", "bytes"),
      "successor_version" => "0.2",
      "selected_by" => "David",
      "selected_at" => "2026-10-07T20:01:00Z"
    }
    authority["authorization_id"] = authorization_digest(authority)
    authorization_path = File.join(dir, "successor-authorization#{tag}.json")
    write_json(
      authorization_path,
      {
        "contract_version" => "adventurefinder-successor-version-authorization-projection/v0.1",
        "authorization" => authority
      }
    )
    {
      operation_input:,
      authorization: authorization_path,
      authorization_id: authority.fetch("authorization_id"),
      project_state:
    }
  end

  def file_binding(path)
    {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
  end

  def authorization_digest(authorization)
    body = authorization.reject { |key, _value| key == "authorization_id" }
    Digest::SHA256.hexdigest(JSON.generate(canonical_json(body)))
  end

  def canonical_json(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical_json(value.fetch(key))] }
    when Array then value.map { |item| canonical_json(item) }
    else value
    end
  end

  def write_json(path, value)
    File.write(path, JSON.pretty_generate(value) + "\n")
  end

  def run_apply_cli(freeze, source_root, base_amc, *extra_args)
    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::CLI.run(
      [
        "boundary-freeze-apply", freeze,
        "--source-root", source_root,
        "--amc", base_amc,
        "--publisher", "Fixture Publisher",
        "--no-progress",
        *extra_args
      ],
      out:,
      err:
    )
    [status, out.string, err.string]
  end

  def derive_paths(dir, successor_version:)
    AfDataPipeline::BoundaryFreezeApply.derive_successor_paths(
      freeze_path: File.join(dir, "source-boundary-freeze-from-amc-4.25.1.yml"),
      amc_path: File.join(dir, "5e_Adventure_Master_Catalog_4.25.1.xlsx"),
      successor_version:,
      amc_dir: dir
    )
  end

  def frozen_record(key, title, start_page, end_page, parent_key: nil, parent_adventure_id: nil, levels: nil)
    record = {
      "local_key" => key,
      "canonical_title" => title,
      "printed_pages" => { "start" => start_page, "end" => end_page },
      "editorial_rationale" => "Synthetic frozen editorial decision.",
      "state" => "frozen"
    }
    record["parent_key"] = parent_key if parent_key
    record["parent_adventure_id"] = parent_adventure_id if parent_adventure_id
    record["levels"] = { "start" => levels[0], "end" => levels[1] } if levels
    record
  end

  def with_stage7_workspace(source_id: "Fixture Book", ordinary_large_flag: true,
                            mirror_large_in_ordinary: false,
                            ordinary_mirror_title: "Existing Large")
    Dir.mktmpdir("boundary-freeze-apply") do |dir|
      source_root = File.join(dir, "source")
      FileUtils.mkdir_p(source_root)
      File.write(File.join(source_root, "fixture.md"), "fixture source\n")
      File.write(
        File.join(source_root, "source_registry.yml"),
        YAML.dump(
          "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
          "sources" => { source_id => { "file" => "fixture.md" } }
        )
      )
      base_amc = write_stage7_amc(
        File.join(dir, "5e_Adventure_Master_Catalog_0.1.xlsx"),
        ordinary_large_flag:,
        mirror_large_in_ordinary:,
        ordinary_mirror_title:
      )
      yield dir, source_root, base_amc
    end
  end

  def write_frozen_boundary(path, source_root, base_amc, records:, source_id: "Fixture Book")
    AfDataPipeline::BoundaryFreeze.init!(
      source_root:,
      source_id:,
      amc_path: base_amc,
      output_path: path
    )
    artifact = YAML.safe_load_file(path)
    artifact["state"] = "frozen"
    artifact["approval"] = { "approved_by" => "David", "approved_at" => "2026-09-10" }
    artifact["records"] = records
    File.write(path, YAML.dump(artifact))
  end

  def write_stage7_amc(path, ordinary_large_flag: true, mirror_large_in_ordinary: false,
                       ordinary_mirror_title: "Existing Large")
    base_headers = [
      "ADV - ID", "Adventure Title", "Played", "Page Count", "Source Book", "Book Publisher",
      "Start Page", "End Page", "Number of Sessions", "Exploration Emphasis", "Level Start", "Level End",
      "Combat Emphasis", "Social Interaction Emphasis", "Investigation Emphasis", "Structural Openness",
      "Darkness / Horror Intensity", "Player Beginner Suitability", "GM Beginner Suitability",
      "GM Preparation Burden", "Seriousness", "Rules / System-Master Demand", "Tactical Complexity",
      "Lethality / Failure Severity", "Puzzle / Problem-Solving Emphasis", "Consequential Player Agency",
      "Fantastic Weirdness", "GM Improvisation Demand", "Scored", ">99 pgs", "AFAO Scored Count", "First 100"
    ]
    ordinary_headers = base_headers.dup
    ordinary_headers.delete(">99 pgs") unless ordinary_large_flag
    large_headers = base_headers.dup
    large_headers[2] = "Scored"
    large_headers.delete_at(28)
    large_headers.delete("First 100")

    ordinary_rows = [
      xml_row(1, ordinary_headers.each_with_index.map { |value, index| xml_text_cell(cell_ref(index + 1, 1), value) }),
      catalog_data_row(2, ordinary_headers, id: "ADV-0007", title: "Existing Adventure", source: "Existing Book", publisher: "Existing Publisher", start_page: 1, end_page: 5)
    ]
    if mirror_large_in_ordinary
      ordinary_rows << catalog_data_row(
        3,
        ordinary_headers,
        id: "ADV-0009",
        title: ordinary_mirror_title,
        source: "Existing Book",
        publisher: "Existing Publisher",
        start_page: 1,
        end_page: 105
      )
    end
    ordinary_blank_start = mirror_large_in_ordinary ? 4 : 3
    ordinary_rows += (ordinary_blank_start..12).map { |row| xml_row(row, []) }

    large_rows = [
      xml_row(1, large_headers.each_with_index.map { |value, index| xml_text_cell(cell_ref(index + 1, 1), value) }),
      xml_row(2, [xml_formula_cell("B2", "COUNTA(A3:A1000)", 1)]),
      catalog_data_row(3, large_headers, id: "ADV-0009", title: "Existing Large", source: "Existing Book", publisher: "Existing Publisher", start_page: 1, end_page: 105)
    ] + (4..12).map { |row| xml_row(row, []) }

    books_rows = [
      xml_row(1, []),
      xml_row(2, [
        xml_formula_cell("A2", "SUM(A3:A126)", 1.0),
        xml_formula_cell("B2", "SUM(B3:B5)", 2),
        xml_formula_cell("C2", "COUNTA(C5:C5)", 1),
        xml_formula_cell("F2", "SUM(F3:F1000)", 1.0),
        xml_formula_cell("G2", "SUM(G3:G1000)", 2),
        xml_formula_cell("H2", "COUNTA(H3:H4)", 1)
      ]),
      xml_row(3, []),
      xml_row(4, [
        xml_formula_cell("A4", "B4/$B$2", 0.5),
        xml_formula_cell("B4", "'AMC >100pg'!B2", 1),
        xml_text_cell("C4", ">100 page Adventures"),
        xml_text_cell("D4", "Various"),
        xml_formula_cell("E4", "$B$2", 2),
        xml_formula_cell("F4", "G4/$G$2", 0.5),
        xml_formula_cell("G4", "COUNTIF('Adventure Catalog'!F:F,H4)", 1),
        xml_text_cell("H4", "Existing Publisher"),
        xml_formula_cell("I4", "$G$2", 2)
      ]),
      xml_row(5, [
        xml_formula_cell("A5", "B5/$B$2", 0.5),
        xml_formula_cell("B5", "COUNTIF('Adventure Catalog'!E:E,C5)", 1),
        xml_text_cell("C5", "Existing Book"),
        xml_text_cell("D5", "Existing Publisher"),
        xml_formula_cell("E5", "$B$2", 2),
        xml_formula_cell("F5", "G5/$G$2", 0.5),
        xml_formula_cell("G5", "'AMC >100pg'!B2", 1),
        xml_text_cell("H5", ">100 page Adventures"),
        xml_formula_cell("I5", "$G$2", 2)
      ])
    ] + (6..20).map { |row| xml_row(row, []) }

    entries = {
      "[Content_Types].xml" => content_types_xml,
      "_rels/.rels" => package_rels_xml,
      "xl/workbook.xml" => workbook_xml,
      "xl/_rels/workbook.xml.rels" => workbook_rels_xml,
      "xl/worksheets/sheet1.xml" => worksheet_xml(ordinary_rows),
      "xl/worksheets/sheet2.xml" => worksheet_xml(large_rows),
      "xl/worksheets/sheet3.xml" => worksheet_xml(books_rows)
    }
    Zip::File.open(path, create: true) do |zip|
      entries.each { |name, content| zip.get_output_stream(name) { |stream| stream.write(content) } }
    end
    path
  end

  def catalog_data_row(row, headers, id:, title:, source:, publisher:, start_page:, end_page:)
    columns = headers.each_with_index.to_h { |header, index| [header, cell_ref(index + 1, row).sub(/\d+\z/, "")] }
    page_count = end_page - start_page + 1
    cells = [
      xml_text_cell("#{columns.fetch('ADV - ID')}#{row}", id),
      xml_text_cell("#{columns.fetch('Adventure Title')}#{row}", title),
      xml_formula_cell("#{columns.fetch('Page Count')}#{row}", "1+#{columns.fetch('End Page')}#{row}-#{columns.fetch('Start Page')}#{row}", page_count),
      xml_text_cell("#{columns.fetch('Source Book')}#{row}", source),
      xml_text_cell("#{columns.fetch('Book Publisher')}#{row}", publisher),
      xml_number_cell("#{columns.fetch('Start Page')}#{row}", start_page),
      xml_number_cell("#{columns.fetch('End Page')}#{row}", end_page),
      xml_formula_cell("#{columns.fetch('Scored')}#{row}", "COUNT(I#{row}:U#{row})", 0)
    ]
    if columns[">99 pgs"]
      cells << xml_formula_cell("#{columns.fetch('>99 pgs')}#{row}", "IF(D#{row}>99,1,0)", page_count >= 100 ? 1 : 0)
    end
    xml_row(row, cells)
  end

  def worksheet_xml(rows)
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}"><sheetData>#{rows.join}</sheetData></worksheet>
    XML
  end

  def xml_row(row, cells)
    %(<row r="#{row}" ht="15.75" customHeight="1">#{cells.join}</row>)
  end

  def xml_text_cell(reference, value)
    %(<c r="#{reference}" t="str"><v>#{escape_xml(value)}</v></c>)
  end

  def xml_number_cell(reference, value)
    %(<c r="#{reference}" t="n"><v>#{value}</v></c>)
  end

  def xml_formula_cell(reference, formula, value)
    %(<c r="#{reference}"><f>#{escape_xml(formula)}</f><v>#{value}</v></c>)
  end

  def cell_ref(column_number, row)
    number = column_number
    letters = +""
    while number.positive?
      number -= 1
      letters.prepend((65 + (number % 26)).chr)
      number /= 26
    end
    "#{letters}#{row}"
  end

  def escape_xml(value)
    CGI.escapeHTML(value.to_s)
  end

  def content_types_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      </Types>
    XML
  end

  def package_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="#{AfDataPipeline::AmcApply::PACKAGE_REL_NS}">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>
    XML
  end

  def workbook_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}" xmlns:r="#{AfDataPipeline::AmcApply::OFFICE_REL_NS}">
        <sheets>
          <sheet name="Adventure Catalog" sheetId="1" r:id="rId1"/>
          <sheet name="AMC &gt;100pg" sheetId="2" r:id="rId2"/>
          <sheet name="Current Books" sheetId="3" r:id="rId3"/>
        </sheets>
      </workbook>
    XML
  end

  def workbook_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="#{AfDataPipeline::AmcApply::PACKAGE_REL_NS}">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
      </Relationships>
    XML
  end
end
