# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/compatibility_amc_fixture"
require_relative "../lib/af_data_pipeline/amc_compatibility_cli"
require "stringio"

class AmcCompatibilityCliTest < Minitest::Test
  include CompatibilityAmcFixture

  def test_explicit_comparison_tolerates_missing_project_state_manifest
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      missing_manifest = File.join(dir, "missing-project-state.yml")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(candidate, rows: [compatible_row("ADV-0001", title: "Existing")])

      stdout, stderr, status = run_cli(
        candidate,
        "--against", base,
        "--manifest", missing_manifest
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "AMC cross-consumer compatibility: PASS"
      refute_includes stdout, "Next command:"
    end
  end

  def test_default_comparison_requires_valid_project_state_manifest
    Dir.mktmpdir do |dir|
      candidate = File.join(dir, "candidate.xlsx")
      missing_manifest = File.join(dir, "missing-project-state.yml")
      write_compatible_amc(candidate, rows: [compatible_row("ADV-0001", title: "Existing")])

      _stdout, stderr, status = run_cli(candidate, "--manifest", missing_manifest)

      assert_equal 2, status
      assert_includes stderr, "ERROR:"
    end
  end

  def test_catalog_head_itself_does_not_suggest_adoption
    Dir.mktmpdir do |dir|
      head = File.join(dir, "5e_Adventure_Master_Catalog_1.0.xlsx")
      write_compatible_amc(head, rows: [compatible_row("ADV-0001", title: "Existing")])
      manifest = write_manifest(dir, head, "1.0")

      stdout, stderr, status = run_cli(head, "--manifest", manifest)

      assert_equal 0, status, stderr
      assert_includes stdout, "AMC cross-consumer compatibility: PASS"
      refute_includes stdout, "Next command:"
    end
  end

  def test_noncanonical_candidate_filename_does_not_suggest_adoption
    Dir.mktmpdir do |dir|
      head = File.join(dir, "5e_Adventure_Master_Catalog_1.0.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(head, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(
        candidate,
        rows: [compatible_row("ADV-0001", title: "Existing"), compatible_row("ADV-0002", title: "New", levels: nil)]
      )
      manifest = write_manifest(dir, head, "1.0")

      stdout, stderr, status = run_cli(
        candidate,
        "--against", head,
        "--manifest", manifest
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "AMC cross-consumer compatibility: PASS"
      refute_includes stdout, "Next command:"
    end
  end

  def test_json_output_stays_machine_readable_without_adoption_continuation
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(candidate, rows: [compatible_row("ADV-0001", title: "Existing")])

      stdout, stderr, status = run_cli(candidate, "--against", base, "--json")
      report = JSON.parse(stdout)

      assert_equal 0, status, stderr
      assert_equal "PASS", report.fetch("status")
      refute_includes stdout, "Next command:"
    end
  end

  def test_cli_passes_with_explicit_comparison_workbook
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(
        candidate,
        rows: [compatible_row("ADV-0001", title: "Existing"), compatible_row("ADV-0002", title: "New", levels: nil)]
      )

      stdout, stderr, status = run_cli(candidate, "--against", base)

      assert_equal 0, status, stderr
      assert_includes stdout, "AMC cross-consumer compatibility: PASS"
      assert_includes stdout, "Added Adventure IDs: 1"
      assert_includes stdout, "Matcher baseline: not promoted or validated by this gate"
      refute_includes stdout, "Next command:"
    end
  end

  def test_pass_against_current_catalog_head_prints_exact_adoption_continuation
    Dir.mktmpdir do |dir|
      base = File.join(dir, "5e_Adventure_Master_Catalog_1.0.xlsx")
      candidate = File.join(dir, "5e_Adventure_Master_Catalog_1.1.xlsx")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(
        candidate,
        rows: [compatible_row("ADV-0001", title: "Existing"), compatible_row("ADV-0002", title: "New", levels: nil)]
      )
      manifest = write_manifest(dir, base, "1.0")

      stdout, stderr, status = run_cli(
        candidate,
        "--against", base,
        "--manifest", manifest
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "AMC cross-consumer compatibility: PASS"
      assert_includes stdout, "Next command:"
      assert_includes stdout, "bin/af-project-state"
      assert_includes stdout, "adopt"
      assert_includes stdout, Shellwords.escape(candidate)
      assert_includes stdout, "--manifest #{Shellwords.escape(manifest)}"
    end
  end

  def test_pass_against_historical_workbook_does_not_suggest_adoption
    Dir.mktmpdir do |dir|
      historical = File.join(dir, "5e_Adventure_Master_Catalog_1.0.xlsx")
      head = File.join(dir, "5e_Adventure_Master_Catalog_1.1.xlsx")
      candidate = File.join(dir, "5e_Adventure_Master_Catalog_1.2.xlsx")
      write_compatible_amc(historical, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(head, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(
        candidate,
        rows: [compatible_row("ADV-0001", title: "Existing"), compatible_row("ADV-0002", title: "New", levels: nil)]
      )
      manifest = write_manifest(dir, head, "1.1")

      stdout, stderr, status = run_cli(
        candidate,
        "--against", historical,
        "--manifest", manifest
      )

      assert_equal 0, status, stderr
      assert_includes stdout, "AMC cross-consumer compatibility: PASS"
      refute_includes stdout, "Next command:"
      refute_includes stdout, "af-project-state adopt"
    end
  end

  def test_cli_returns_nonzero_and_lists_defects
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base.xlsx")
      candidate = File.join(dir, "candidate.xlsx")
      write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing")])
      write_compatible_amc(candidate, rows: [compatible_row("ADV-0001", title: "Existing")])
      replace_zip_text(candidate, "xl/worksheets/sheet1.xml", "Exploration Emphasis", "Exploration Missing")

      stdout, _stderr, status = run_cli(candidate, "--against", base)

      assert_equal 2, status
      assert_includes stdout, "AMC cross-consumer compatibility: FAIL"
      assert_includes stdout, "Compatibility defects:"
      assert_includes stdout, "Exploration Emphasis"
      refute_includes stdout, "Next command:"
    end
  end

  private

  def write_manifest(dir, catalog_head, version)
    manifest = File.join(dir, "PROJECT_STATE.yml")
    File.write(
      manifest,
      {
        "schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
        "catalog_head" => role(catalog_head, version),
        "matcher_authorized_baseline" => role(catalog_head, version),
        "production_dependency_floor" => role(catalog_head, version)
      }.to_yaml
    )
    manifest
  end

  def role(path, version)
    {
      "version" => version,
      "filename" => File.basename(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::AmcCompatibilityCLI.run(argv, out: out, err: err)
    [out.string, err.string, status]
  end
end
