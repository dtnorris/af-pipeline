# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/production_snapshot_fixture"

class EditorialAuditTest < Minitest::Test
  include ProductionSnapshotFixture

  def build_review(root, candidates: ["ADV-0001", "ADV-0002"], with_source_hold: true)
    source = File.join(root, "snapshot")
    review = File.join(root, "review")
    FileUtils.mkdir_p(source)

    candidates.each_with_index do |adventure_id, index|
      write_production_run(
        source,
        experiment: "candidate-#{index}",
        adventure_id:,
        dimensions: ["Seriousness"],
        metadata_schema: index.even? ? :legacy : :current,
        raw_format: index.even? ? :openai : :afcsu,
        values: { "Seriousness" => index + 2 }
      )
    end

    if with_source_hold
      run_root = write_production_run(
        source,
        experiment: "levels-hold",
        adventure_id: "ADV-0031",
        dimensions: ["Levels"],
        metadata_schema: :current,
        raw_format: :afcsu,
        values: { "Levels" => { start: 8, end: 10 } }
      )
      mark_level_unresolved(run_root, metric: "Level End", rationale: "Completion level requires source verification.")
    end

    entries = AfDataPipeline::Scanner.new(root: source).scan
    extraction = AfDataPipeline::Adapters::ProductionSnapshotV1.new(root: source, entries:).extract
    raise extraction.errors.inspect unless extraction.errors.empty?

    AfDataPipeline::ProductionReviewWriter.new(review).write!(
      entries:,
      extraction:,
      source:,
      source_type: "directory"
    )
    review
  end

  def test_initializes_durable_ledger_with_pending_candidates_and_locked_source_hold
    Dir.mktmpdir do |dir|
      review = build_review(dir)
      audit = File.join(dir, "audits", "batch")

      manifest = AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)

      assert_equal 3, manifest["candidate_count"]
      assert_equal 1, manifest["source_hold_count"]
      assert_equal 4, manifest["audit_row_count"]
      assert File.file?(File.join(audit, "audit_manifest.json"))
      assert File.file?(File.join(audit, "README.md"))
      instructions = File.read(File.join(audit, "README.md"), encoding: "UTF-8")
      assert_includes instructions, "production sanity gate, not a second scoring pass"
      assert_includes instructions, "numeric value itself is unreliable"
      assert_includes instructions, "Do **not** HOLD merely because adjacent-anchor discussion is imperfect"

      rows = CSV.read(File.join(audit, "editorial_decisions.csv"), headers: true)
      assert_equal 4, rows.length
      candidate_rows = rows.select { |row| row["record_type"] == "candidate" }
      source_holds = rows.select { |row| row["record_type"] == "source_hold" }
      assert_equal 3, candidate_rows.length
      assert candidate_rows.all? { |row| row["editorial_decision"].to_s.empty? }
      assert_equal 1, source_holds.length
      assert_equal "HOLD", source_holds.first["editorial_decision"]
      assert_equal "ADV-0031::Level End", source_holds.first["record_key"]
    end
  end

  def test_refuses_to_overwrite_existing_human_ledger
    Dir.mktmpdir do |dir|
      review = build_review(dir, candidates: ["ADV-0001"], with_source_hold: false)
      audit = File.join(dir, "audits", "batch")
      AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)
      end
      assert_match(/refusing to overwrite/, error.message)
    end
  end

  def test_pending_ledger_is_valid_but_not_promotion_ready
    Dir.mktmpdir do |dir|
      review = build_review(dir, candidates: ["ADV-0001"], with_source_hold: false)
      audit = File.join(dir, "audits", "batch")
      output = File.join(dir, "validation")
      AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)

      result = AfDataPipeline::EditorialAudit.validate!(audit_dir: audit, output_dir: output)

      assert_empty result.errors
      refute result.complete
      assert_equal 1, result.pending.length
      assert File.file?(File.join(output, "editorial_audit_report.json"))
      refute File.exist?(File.join(output, "accepted_candidates.jsonl"))
      report = JSON.parse(File.read(File.join(output, "editorial_audit_report.json")))
      assert_equal false, report["complete"]
      assert_equal 1, report["pending"]
    end
  end

  def test_complete_ledger_emits_exact_candidates_by_editorial_disposition
    Dir.mktmpdir do |dir|
      review = build_review(dir, candidates: ["ADV-0001", "ADV-0002", "ADV-0003"], with_source_hold: true)
      audit = File.join(dir, "audits", "batch")
      output = File.join(dir, "validation")
      AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)

      ledger_path = File.join(audit, "editorial_decisions.csv")
      table = CSV.read(ledger_path, headers: true)
      candidate_rows = table.select { |row| row["record_type"] == "candidate" }
      candidate_rows[0]["editorial_decision"] = "ACCEPT"
      candidate_rows[1]["editorial_decision"] = "HOLD"
      candidate_rows[1]["editorial_note"] = "Rationale needs source re-check."
      candidate_rows[2]["editorial_decision"] = "REJECT"
      candidate_rows[2]["editorial_note"] = "Rationale does not support the proposed anchor."
      candidate_rows[3]["editorial_decision"] = "ACCEPT"
      CSV.open(ledger_path, "w") do |csv|
        csv << table.headers
        table.each { |row| csv << table.headers.map { |header| row[header] } }
      end

      result = AfDataPipeline::EditorialAudit.validate!(audit_dir: audit, output_dir: output)

      assert_empty result.errors
      assert result.complete
      assert_equal 2, result.accepted.length
      assert_equal 1, result.held.length
      assert_equal 1, result.rejected.length
      assert_equal 1, result.source_holds.length
      assert_equal 0, result.pending.length
      assert_equal 2, File.readlines(File.join(output, "accepted_candidates.jsonl")).length
      assert_equal 1, File.readlines(File.join(output, "held_candidates.jsonl")).length
      assert_equal 1, File.readlines(File.join(output, "rejected_candidates.jsonl")).length
      assert_equal 1, File.readlines(File.join(output, "source_holds.jsonl")).length

      accepted = File.readlines(File.join(output, "accepted_candidates.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      source_candidates = File.readlines(File.join(review, "candidates.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      accepted_keys = result.accepted.map { |decision| decision["record_key"] }
      assert_equal source_candidates.select { |item| accepted_keys.include?(item["candidate_key"]) }, accepted
    end
  end

  def test_hold_and_reject_require_notes
    Dir.mktmpdir do |dir|
      review = build_review(dir, candidates: ["ADV-0001"], with_source_hold: false)
      audit = File.join(dir, "audits", "batch")
      output = File.join(dir, "validation")
      AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)

      ledger_path = File.join(audit, "editorial_decisions.csv")
      table = CSV.read(ledger_path, headers: true)
      table.first["editorial_decision"] = "HOLD"
      CSV.open(ledger_path, "w") do |csv|
        csv << table.headers
        table.each { |row| csv << table.headers.map { |header| row[header] } }
      end

      result = AfDataPipeline::EditorialAudit.validate!(audit_dir: audit, output_dir: output)
      assert result.errors.any? { |message| message.include?("HOLD requires editorial_note") }
      refute result.complete
    end
  end

  def test_detects_edits_to_immutable_candidate_fields
    Dir.mktmpdir do |dir|
      review = build_review(dir, candidates: ["ADV-0001"], with_source_hold: false)
      audit = File.join(dir, "audits", "batch")
      output = File.join(dir, "validation")
      AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)

      ledger_path = File.join(audit, "editorial_decisions.csv")
      table = CSV.read(ledger_path, headers: true)
      table.first["proposed_value"] = "5"
      table.first["editorial_decision"] = "ACCEPT"
      CSV.open(ledger_path, "w") do |csv|
        csv << table.headers
        table.each { |row| csv << table.headers.map { |header| row[header] } }
      end

      result = AfDataPipeline::EditorialAudit.validate!(audit_dir: audit, output_dir: output)
      assert result.errors.any? { |message| message.include?("immutable ledger field proposed_value changed") }
      refute result.complete
      refute File.exist?(File.join(output, "accepted_candidates.jsonl"))
    end
  end

  def test_detects_source_review_drift_after_audit_initialization
    Dir.mktmpdir do |dir|
      review = build_review(dir, candidates: ["ADV-0001"], with_source_hold: false)
      audit = File.join(dir, "audits", "batch")
      output = File.join(dir, "validation")
      AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)
      File.open(File.join(review, "candidates.jsonl"), "a") { |file| file.puts(" ") }

      result = AfDataPipeline::EditorialAudit.validate!(audit_dir: audit, output_dir: output)
      assert result.errors.any? { |message| message.include?("source review file changed: candidates.jsonl") }
      refute result.complete
    end
  end

  def test_ledger_round_trips_utf8_rationale_text
    Dir.mktmpdir do |dir|
      review = build_review(dir, candidates: ["ADV-0001"], with_source_hold: false)
      candidate_path = File.join(review, "candidates.jsonl")
      candidate = JSON.parse(File.read(candidate_path, encoding: "UTF-8"))
      candidate["rationale"] = "Intrigue—rather than combat—drives the adventure’s progression."
      File.write(candidate_path, JSON.generate(candidate) + "\n", encoding: "UTF-8")
      report_path = File.join(review, "integrity_report.json")
      report = JSON.parse(File.read(report_path, encoding: "UTF-8"))
      File.write(report_path, JSON.pretty_generate(report) + "\n", encoding: "UTF-8")

      audit = File.join(dir, "audits", "batch")
      output = File.join(dir, "validation")
      AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)
      result = AfDataPipeline::EditorialAudit.validate!(audit_dir: audit, output_dir: output)

      assert_empty result.errors
      assert_equal 1, result.pending.length
      ledger = CSV.read(File.join(audit, "editorial_decisions.csv"), headers: true, encoding: "UTF-8")
      assert_equal "Intrigue—rather than combat—drives the adventure’s progression.", ledger.first["rationale"]
    end
  end

  def test_source_hold_decision_cannot_be_changed_in_ledger
    Dir.mktmpdir do |dir|
      review = build_review(dir, candidates: [], with_source_hold: true)
      audit = File.join(dir, "audits", "batch")
      output = File.join(dir, "validation")
      AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)

      ledger_path = File.join(audit, "editorial_decisions.csv")
      table = CSV.read(ledger_path, headers: true, encoding: "UTF-8")
      source_hold = table.find { |row| row["record_type"] == "source_hold" }
      source_hold["editorial_decision"] = "ACCEPT"
      CSV.open(ledger_path, "w", encoding: "UTF-8") do |csv|
        csv << table.headers
        table.each { |row| csv << table.headers.map { |header| row[header] } }
      end

      result = AfDataPipeline::EditorialAudit.validate!(audit_dir: audit, output_dir: output)
      assert result.errors.any? { |message| message.include?("source_hold decision is locked to HOLD") }
      refute result.complete
    end
  end
end
