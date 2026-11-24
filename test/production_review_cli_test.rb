# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/production_snapshot_fixture"
require "stringio"

class ProductionReviewCliTest < Minitest::Test
  include ProductionSnapshotFixture

  def test_production_review_from_zip_writes_runs_candidates_and_integrity_packet
    Dir.mktmpdir do |dir|
      source = File.join(dir, "snapshot")
      output = File.join(dir, "review")
      zip_path = File.join(dir, "snapshot.zip")
      FileUtils.mkdir_p(source)
      write_production_run(
        source, experiment: "legacy", adventure_id: "ADV-0001", dimensions: ["Combat Emphasis"], metadata_schema: :legacy
      )
      write_production_run(
        source, experiment: "levels", adventure_id: "ADV-0002", dimensions: ["Levels"], metadata_schema: :current,
        raw_format: :afcsu
      )
      FileUtils.mkdir_p(File.join(source, "production-backlog-control"))
      File.write(File.join(source, "production-backlog-control", "failures.log"), "control state\n")
      zip_directory(source, zip_path)

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["production-review", zip_path, "--expect-candidates", "3", "--output", output],
        out:, err:
      )

      assert_equal 0, status, err.string
      %w[inventory.jsonl runs.jsonl candidates.jsonl holds.jsonl audit_review.md integrity_report.json].each do |name|
        assert File.file?(File.join(output, name)), "missing #{name}"
      end
      assert_equal 2, File.readlines(File.join(output, "runs.jsonl")).length
      assert_equal 3, File.readlines(File.join(output, "candidates.jsonl")).length
      report = JSON.parse(File.read(File.join(output, "integrity_report.json")))
      assert_equal 3, report["top_level_snapshot_folders"]
      assert_equal 2, report["top_level_folders_with_run_packages"]
      assert_equal 1, report["top_level_folders_without_run_packages"]
      assert_equal ["production-backlog-control"], report["top_level_non_run_folders"]
      assert_equal 2, report["run_packages_discovered"]
      assert_equal 3, report["candidates"]
      assert_equal 0, report["holds"]
      assert_equal 3, report["assessment_outcomes"]
      assert_equal 3, report["unique_candidate_keys"]
      assert_equal 3, report["expected_candidates"]
      assert_equal true, report["expectation_match"]
      assert_empty report["errors"]
      assert_match(/Complete production candidates: 3/, File.read(File.join(output, "audit_review.md"), encoding: "UTF-8"))
      assert_match(/Production candidates: 3/, out.string)
      assert_includes out.string, "Next command template:"
      assert_includes out.string, "editorial-audit-init"
      assert_includes out.string, "--audit-dir AUDIT_DIR"
      assert_empty err.string
    end
  end

  def test_production_review_writes_valid_unresolved_assessments_to_holds_packet
    Dir.mktmpdir do |dir|
      source = File.join(dir, "snapshot")
      output = File.join(dir, "review")
      FileUtils.mkdir_p(source)
      run_root = write_production_run(
        source, experiment: "mixed-levels", adventure_id: "ADV-0031", dimensions: ["Levels"], metadata_schema: :current,
        raw_format: :afcsu, values: { "Levels" => { start: 8, end: 10 } }
      )
      mark_level_unresolved(run_root, metric: "Level End", rationale: "Completion level requires source verification.")

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["production-review", source, "--expect-candidates", "1", "--output", output],
        out:, err:
      )

      assert_equal 0, status, err.string
      assert_equal 1, File.readlines(File.join(output, "candidates.jsonl")).length
      assert_equal 1, File.readlines(File.join(output, "holds.jsonl")).length
      hold = JSON.parse(File.read(File.join(output, "holds.jsonl")))
      assert_equal "ADV-0031::Level End", hold["hold_key"]
      assert_equal "Uncertain / Requires Source Verification", hold["assessment_state"]
      report = JSON.parse(File.read(File.join(output, "integrity_report.json")))
      assert_equal 1, report["candidates"]
      assert_equal 1, report["holds"]
      assert_equal 2, report["assessment_outcomes"]
      assert_empty report["errors"]
      review = File.read(File.join(output, "audit_review.md"), encoding: "UTF-8")
      assert_match(/Holds requiring review: 1/, review)
      assert_match(/ADV-0031 — Level End/, review)
      assert_match(/Review holds: 1/, out.string)
    end
  end

  def test_production_review_reports_incomplete_runs_without_failing_integrity
    Dir.mktmpdir do |dir|
      source = File.join(dir, "snapshot")
      output = File.join(dir, "review")
      FileUtils.mkdir_p(source)
      write_production_run(
        source, experiment: "complete", adventure_id: "ADV-0001",
        dimensions: ["Seriousness"], metadata_schema: :legacy
      )
      incomplete = write_production_run(
        source, experiment: "incomplete", adventure_id: "ADV-0253",
        dimensions: ["GM Beginner Suitability"], metadata_schema: :legacy, success: false
      )
      FileUtils.rm_rf(File.join(incomplete, "native", "assessments"))
      FileUtils.rm_rf(File.join(incomplete, "native", "raw"))

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["production-review", source, "--expect-candidates", "1", "--output", output],
        out:, err:
      )

      assert_equal 0, status, err.string
      report = JSON.parse(File.read(File.join(output, "integrity_report.json")))
      assert_equal 2, report["run_packages_discovered"]
      assert_equal 1, report["mechanically_valid_runs"]
      assert_equal 1, report["incomplete_runs"]
      assert_equal 0, report["mechanically_invalid_runs"]
      assert_equal 1, report["candidates"]
      assert_empty report["errors"]
      assert_equal "ADV-0253", report.fetch("incomplete_run_details").first["adventure_id"]
      assert_equal ["GM Beginner Suitability"], report.fetch("incomplete_run_details").first["dimensions"]
      assert_match(/Incomplete runs: 1/, out.string)
      assert_match(/Incomplete executions/, File.read(File.join(output, "audit_review.md"), encoding: "UTF-8"))
      assert_empty err.string
    end
  end

  def test_production_review_exits_nonzero_when_420_expectation_does_not_match
    Dir.mktmpdir do |dir|
      source = File.join(dir, "snapshot")
      output = File.join(dir, "review")
      FileUtils.mkdir_p(source)
      write_production_run(
        source, experiment: "one", adventure_id: "ADV-0001", dimensions: ["Seriousness"], metadata_schema: :legacy
      )

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["production-review", source, "--expect-candidates", "420", "--output", output],
        out:, err:
      )

      assert_equal 1, status
      report = JSON.parse(File.read(File.join(output, "integrity_report.json")))
      assert_equal 420, report["expected_candidates"]
      assert_equal false, report["expectation_match"]
      assert report["errors"].any? { |message| message.include?("expected 420") }
      assert_empty err.string
    end
  end
  def test_production_review_progress_can_be_forced_for_redirected_output
    Dir.mktmpdir do |dir|
      source = File.join(dir, "snapshot")
      output = File.join(dir, "review")
      FileUtils.mkdir_p(source)
      write_production_run(
        source, experiment: "one", adventure_id: "ADV-0001", dimensions: ["Seriousness"], metadata_schema: :legacy
      )

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["production-review", source, "--expect-candidates", "1", "--progress", "--output", output],
        out:, err:
      )

      assert_equal 0, status, err.string
      assert_match(/\[open\]/, err.string)
      assert_match(/\[scan\] 0\//, err.string)
      assert_match(/\[scan\] \d+\/\d+ files \(100\.0%\)/, err.string)
      assert_match(/\[discover\] 1 run packages/, err.string)
      assert_match(/\[extract\] 1\/1 run packages/, err.string)
      assert_match(/\[write\]/, err.string)
    end
  end

  def test_production_review_no_progress_suppresses_forced_progress
    Dir.mktmpdir do |dir|
      source = File.join(dir, "snapshot")
      output = File.join(dir, "review")
      FileUtils.mkdir_p(source)
      write_production_run(
        source, experiment: "one", adventure_id: "ADV-0001", dimensions: ["Seriousness"], metadata_schema: :legacy
      )

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["production-review", source, "--expect-candidates", "1", "--no-progress", "--output", output],
        out:, err:
      )

      assert_equal 0, status, err.string
      assert_empty err.string
    end
  end

  def test_production_review_accepts_flat_afcsu_batch_without_lme_metadata
    Dir.mktmpdir do |dir|
      packaged = File.join(dir, "packaged")
      snapshot = File.join(dir, "snapshot")
      flat = File.join(snapshot, "prod-batch")
      output = File.join(dir, "review")
      zip_path = File.join(dir, "flat-batch.zip")
      FileUtils.mkdir_p(packaged)
      FileUtils.mkdir_p(File.join(flat, "assessments"))

      run_root = write_production_run(
        packaged,
        experiment: "levels",
        adventure_id: "ADV-0031",
        dimensions: ["Levels"],
        metadata_schema: :current,
        raw_format: :afcsu,
        values: { "Levels" => { start: 8, end: 10 } }
      )
      mark_level_unresolved(
        run_root,
        metric: "Level End",
        rationale: "Completion level requires source verification."
      )

      native = File.join(run_root, "native")
      Dir.glob(File.join(native, "assessments", "*.csv")).each do |path|
        FileUtils.cp(path, File.join(flat, "assessments", File.basename(path)))
      end
      FileUtils.cp_r(File.join(native, "raw"), File.join(flat, "raw"))
      zip_directory(snapshot, zip_path)

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        ["production-review", zip_path, "--expect-candidates", "1", "--output", output],
        out:, err:
      )

      assert_equal 0, status, err.string
      runs = File.readlines(File.join(output, "runs.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal 1, runs.length
      assert_equal "afcsu-flat-v1", runs.first["metadata_schema"]
      assert_nil runs.first["lme_run_id"]
      assert_equal ["Levels"], runs.first["dimensions"]

      candidate = JSON.parse(File.read(File.join(output, "candidates.jsonl")))
      hold = JSON.parse(File.read(File.join(output, "holds.jsonl")))
      assert_equal "ADV-0031::Level Start", candidate["candidate_key"]
      assert_equal 8, candidate["value"]
      assert_nil candidate["lme_run_id"]
      assert_equal "ADV-0031::Level End", hold["hold_key"]
      assert_equal "Uncertain / Requires Source Verification", hold["assessment_state"]

      report = JSON.parse(File.read(File.join(output, "integrity_report.json")))
      assert_equal 1, report["candidates"]
      assert_equal 1, report["holds"]
      assert_empty report["unclaimed_assessment_files"]
      assert_empty report["errors"]
    end
  end

end
