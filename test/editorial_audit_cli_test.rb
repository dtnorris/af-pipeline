# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/production_snapshot_fixture"
require "stringio"

class EditorialAuditCliTest < Minitest::Test
  include ProductionSnapshotFixture

  def build_review(root)
    source = File.join(root, "snapshot")
    review = File.join(root, "review")
    FileUtils.mkdir_p(source)
    write_production_run(
      source, experiment: "one", adventure_id: "ADV-0001", dimensions: ["Seriousness"], metadata_schema: :legacy
    )
    entries = AfDataPipeline::Scanner.new(root: source).scan
    extraction = AfDataPipeline::Adapters::ProductionSnapshotV1.new(root: source, entries:).extract(expected_candidates: 1)
    AfDataPipeline::ProductionReviewWriter.new(review).write!(entries:, extraction:, source:, source_type: "directory")
    review
  end

  def test_cli_initializes_then_validates_editorial_audit
    Dir.mktmpdir do |dir|
      review = build_review(dir)
      audit = File.join(dir, "audits", "batch")
      output = File.join(dir, "validation")
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::CLI.run(["editorial-audit-init", review, "--audit-dir", audit], out:, err:)
      assert_equal 0, status, err.string
      assert_match(/Production candidates: 1/, out.string)
      assert_match(/Editorial audit rows: 1/, out.string)
      assert_includes out.string, "HUMAN REVIEW REQUIRED"
      assert_includes out.string, "editorial-audit-validate"
      assert_includes out.string, audit

      out = StringIO.new
      status = AfDataPipeline::CLI.run(["editorial-audit-validate", audit, "--output", output], out:, err:)
      assert_equal 1, status
      assert_match(/Pending: 1/, out.string)
      assert_match(/Complete: false/, out.string)
      assert_includes out.string, "After resolving pending editorial decisions, rerun:"
      assert_includes out.string, "editorial-audit-validate"

      ledger_path = File.join(audit, "editorial_decisions.csv")
      table = CSV.read(ledger_path, headers: true)
      table.first["editorial_decision"] = "ACCEPT"
      CSV.open(ledger_path, "w") do |csv|
        csv << table.headers
        table.each { |row| csv << table.headers.map { |header| row[header] } }
      end

      out = StringIO.new
      status = AfDataPipeline::CLI.run(["editorial-audit-validate", audit, "--output", output], out:, err:)
      assert_equal 0, status, err.string
      assert_match(/Accepted: 1/, out.string)
      assert_match(/Pending: 0/, out.string)
      assert_match(/Complete: true/, out.string)
      assert_includes out.string, "Next command template:"
      assert_includes out.string, "amc-apply"
      assert_includes out.string, "--amc SOURCE.xlsx --output NEW.xlsx"
      assert File.file?(File.join(output, "accepted_candidates.jsonl"))
    end
  end
end
