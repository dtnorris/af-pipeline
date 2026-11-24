# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/production_snapshot_fixture"

class ProductionSnapshotV1Test < Minitest::Test
  include ProductionSnapshotFixture

  def extract(dir, expected_candidates: nil)
    entries = AfDataPipeline::Scanner.new(root: dir).scan
    AfDataPipeline::Adapters::ProductionSnapshotV1.new(root: dir, entries:).extract(expected_candidates:)
  end

  def test_supports_legacy_lme_metadata_and_openai_compatible_raw_response
    Dir.mktmpdir do |dir|
      experiment = "production-backlog-009-qwen-combat-adv0001-v1"
      lme_run_id = "historical-legacy-run-id"
      write_production_run(
        dir, experiment: experiment,
        adventure_id: "ADV-0001", dimensions: ["Combat Emphasis"], metadata_schema: :legacy,
        lme_run_id: lme_run_id
      )

      result = extract(dir, expected_candidates: 1)

      assert_empty result.errors
      assert_equal 1, result.runs.length
      run = result.runs.first
      run_path = "#{experiment}/runs/#{lme_run_id}"
      assert_equal "lme-legacy-v1", run["metadata_schema"]
      assert_equal lme_run_id, run["lme_run_id"]
      assert_equal run_path, run["run_path"]
      assert_nil run["repo_commit"]

      metadata = run.dig("provenance", "metadata")
      metadata_relative_path = "#{run_path}/metadata.json"
      metadata_path = File.join(dir, metadata_relative_path)
      assert_equal metadata_relative_path, metadata["source_path"]
      assert_equal Digest::SHA256.file(metadata_path).hexdigest, metadata["source_sha256"]
      assert_equal File.size(metadata_path), metadata["bytes"]

      assert_equal 1, result.candidates.length
      candidate = result.candidates.first
      assert_equal "ADV-0001::Combat Emphasis", candidate["candidate_key"]
      assert_equal lme_run_id, candidate["lme_run_id"]
      assert_equal 3, candidate["value"]
      assert_equal "Fixture model reasoning for Combat Emphasis.", candidate.dig("raw", "reasoning")

      assessment = candidate.dig("provenance", "assessment")
      assessment_relative_path = "#{run_path}/native/assessments/assessment.csv"
      assessment_path = File.join(dir, assessment_relative_path)
      assert_equal assessment_relative_path, assessment["source_path"]
      assert_equal Digest::SHA256.file(assessment_path).hexdigest, assessment["source_sha256"]
      assert_equal File.size(assessment_path), assessment["bytes"]
    end
  end

  def test_supports_post_rename_afio_runner_lme_compatibility_shape
    Dir.mktmpdir do |dir|
      experiment = "afio-post-rename-fixture"
      compatibility_run_id = "afio-compatible-job-id"
      run_root = write_production_run(
        dir, experiment: experiment,
        adventure_id: "ADV-0042", dimensions: ["Seriousness"], metadata_schema: :legacy,
        lme_run_id: compatibility_run_id
      )

      # AFIO intentionally retained LocalModelEvaluation::Runner's metadata wire
      # shape at the repository rename. Mirror the additional fields emitted by
      # that runner so this is a post-rename producer-compatibility regression,
      # not merely a second historical-LME test.
      metadata_path = File.join(run_root, "metadata.json")
      metadata = JSON.parse(File.read(metadata_path))
      metadata.merge!(
        "worker_base_url" => "http://127.0.0.1:11434",
        "worker_labels" => ["local"],
        "worker_hourly_rate_usd" => 0.0,
        "model_alias" => "fixture-alias",
        "elapsed_seconds" => 60.0,
        "command" => ["/fixture/af-score", "--model", "fixture-model"],
        "scorer_env_keys" => ["OLLAMA_HOST"],
        "estimated_cost_usd" => 0.0
      )
      File.write(metadata_path, JSON.pretty_generate(metadata))

      result = extract(dir, expected_candidates: 1)

      assert_empty result.errors
      assert_equal 1, result.runs.length
      run = result.runs.first
      assert_equal "lme-legacy-v1", run["metadata_schema"]
      assert_equal compatibility_run_id, run["lme_run_id"]
      assert_equal experiment, run["experiment_name"]
      assert_equal 1, result.candidates.length
      assert_equal compatibility_run_id, result.candidates.first["lme_run_id"]
      assert_equal 3, result.candidates.first["value"]
    end
  end

  def test_supports_current_lme_metadata_and_afcsu_raw_envelope
    Dir.mktmpdir do |dir|
      experiment = "discovery-horizontal-fixture"
      lme_run_id = "historical-current-run-id"
      write_production_run(
        dir, experiment: experiment, adventure_id: "ADV-0022",
        dimensions: ["Exploration Emphasis"], metadata_schema: :current, raw_format: :afcsu,
        lme_run_id: lme_run_id
      )

      result = extract(dir, expected_candidates: 1)

      assert_empty result.errors
      run = result.runs.first
      run_path = "#{experiment}/runs/#{lme_run_id}"
      assert_equal "lme-current-v1", run["metadata_schema"]
      assert_equal lme_run_id, run["lme_run_id"]
      assert_equal run_path, run["run_path"]
      assert_equal "repo-sha", run["repo_commit"]
      assert_equal "scorer-sha", run["scorer_commit"]
      candidate = result.candidates.first
      assert_equal lme_run_id, candidate["lme_run_id"]
      assert_equal 3, candidate["value"]
      assert_equal "ollama", candidate.dig("raw", "provider")
      assert_equal "fixture-model", candidate.dig("raw", "model")

      assessment = candidate.dig("provenance", "assessment")
      assessment_relative_path = "#{run_path}/native/assessments/assessment.csv"
      assessment_path = File.join(dir, assessment_relative_path)
      assert_equal assessment_relative_path, assessment["source_path"]
      assert_equal Digest::SHA256.file(assessment_path).hexdigest, assessment["source_sha256"]
      assert_equal File.size(assessment_path), assessment["bytes"]
    end
  end

  def test_levels_run_emits_two_amc_candidates
    Dir.mktmpdir do |dir|
      write_production_run(
        dir, experiment: "levels", adventure_id: "ADV-0001", dimensions: ["Levels"], metadata_schema: :legacy
      )

      result = extract(dir, expected_candidates: 2)

      assert_empty result.errors
      assert_equal 1, result.runs.length
      assert_equal 2, result.runs.first["candidate_count"]
      assert_equal ["Level End", "Level Start"], result.candidates.map { |candidate| candidate["dimension"] }.sort
      assert_equal [3, 5], result.candidates.sort_by { |candidate| candidate["dimension"] }.map { |candidate| candidate["value"] }.sort
    end
  end

  def test_unresolved_levels_emit_holds_without_mechanical_errors
    Dir.mktmpdir do |dir|
      run_root = write_production_run(
        dir, experiment: "unresolved-levels", adventure_id: "ADV-0122", dimensions: ["Levels"], metadata_schema: :legacy
      )
      mark_level_unresolved(run_root, metric: "Level Start", rationale: "Starting level requires source verification.")
      mark_level_unresolved(run_root, metric: "Level End", rationale: "Ending level requires source verification.")

      result = extract(dir)

      assert_empty result.errors
      assert_empty result.candidates
      assert_equal 2, result.holds.length
      assert_equal "valid", result.runs.first["mechanical_status"]
      assert_equal 0, result.runs.first["candidate_count"]
      assert_equal 2, result.runs.first["hold_count"]
      assert_equal ["Level End", "Level Start"], result.holds.map { |hold| hold["dimension"] }.sort
      result.holds.each do |hold|
        assert_equal "af-production-hold/v0.1", hold["schema_version"]
        assert_equal "Uncertain / Requires Source Verification", hold["assessment_state"]
        assert_nil hold["value"]
        assert_equal "REVIEW_REQUIRED", hold["review_disposition"]
        assert_equal "source_verification_required", hold["hold_reason"]
        assert_equal "hold", hold["production_disposition"]
        assert_equal "valid", hold["mechanical_status"]
      end
    end
  end

  def test_insufficient_evidence_emits_hold_without_mechanical_error
    Dir.mktmpdir do |dir|
      run_root = write_production_run(
        dir,
        experiment: "insufficient-evidence",
        adventure_id: "ADV-0498",
        dimensions: ["Structural Openness"],
        metadata_schema: :current,
        raw_format: :afcsu
      )
      mark_interpretive_insufficient_evidence(
        run_root,
        metric: "Structural Openness",
        rationale: "The supplied evidence is insufficient to score this dimension."
      )

      result = extract(dir)

      assert_empty result.errors
      assert_empty result.candidates
      assert_equal 1, result.holds.length
      assert_equal "valid", result.runs.first["mechanical_status"]
      assert_equal 0, result.runs.first["candidate_count"]
      assert_equal 1, result.runs.first["hold_count"]

      hold = result.holds.first
      assert_equal "Insufficient Evidence", hold["assessment_state"]
      assert_nil hold["value"]
      assert_equal "REVIEW_REQUIRED", hold["review_disposition"]
      assert_equal "insufficient_evidence", hold["hold_reason"]
      assert_equal "hold", hold["production_disposition"]
      assert_equal "valid", hold["mechanical_status"]
    end
  end

  def test_mixed_levels_run_preserves_scored_candidate_and_holds_unresolved_value
    Dir.mktmpdir do |dir|
      run_root = write_production_run(
        dir, experiment: "mixed-levels", adventure_id: "ADV-0031", dimensions: ["Levels"], metadata_schema: :current, raw_format: :afcsu,
        values: { "Levels" => { start: 8, end: 10 } }
      )
      mark_level_unresolved(run_root, metric: "Level End", rationale: "Completion level requires source verification.")

      result = extract(dir, expected_candidates: 1)

      assert_empty result.errors
      assert_equal 1, result.candidates.length
      assert_equal "Level Start", result.candidates.first["dimension"]
      assert_equal 8, result.candidates.first["value"]
      assert_equal 1, result.holds.length
      assert_equal "Level End", result.holds.first["dimension"]
      assert_equal 1, result.runs.first["candidate_count"]
      assert_equal 1, result.runs.first["hold_count"]
      assert_equal "valid", result.runs.first["mechanical_status"]
      assert result.expectation_match
    end
  end

  def test_recognized_incomplete_runs_are_reported_without_derivative_integrity_errors
    Dir.mktmpdir do |dir|
      legacy = write_production_run(
        dir, experiment: "incomplete-legacy", adventure_id: "ADV-0253",
        dimensions: ["GM Beginner Suitability"], metadata_schema: :legacy, success: false
      )
      current = write_production_run(
        dir, experiment: "incomplete-current", adventure_id: "ADV-0273",
        dimensions: ["Exploration Emphasis"], metadata_schema: :current, raw_format: :afcsu, success: false
      )
      [legacy, current].each do |run_root|
        FileUtils.rm_rf(File.join(run_root, "native", "assessments"))
        FileUtils.rm_rf(File.join(run_root, "native", "raw"))
      end

      result = extract(dir)

      assert_empty result.errors
      assert_empty result.candidates
      assert_empty result.holds
      assert_equal 2, result.runs.length
      result.runs.each do |run|
        assert_equal false, run["source_complete"]
        assert_equal "incomplete", run["mechanical_status"]
        assert_equal 0, run["candidate_count"]
        assert_equal 0, run["hold_count"]
        assert_empty run["issues"]
      end
    end
  end

  def test_sessions_candidate_preserves_and_cross_checks_practical_range
    Dir.mktmpdir do |dir|
      write_production_run(
        dir, experiment: "sessions", adventure_id: "ADV-0100", dimensions: ["# of Sessions"],
        metadata_schema: :current, raw_format: :afcsu
      )

      result = extract(dir, expected_candidates: 1)

      assert_empty result.errors
      candidate = result.candidates.first
      assert_equal 4, candidate["value"]
      assert_equal 3, candidate["range_low"]
      assert_equal 5, candidate["range_high"]
    end
  end

  def test_raw_value_mismatch_fails_closed_and_emits_no_candidate
    Dir.mktmpdir do |dir|
      run_root = write_production_run(
        dir, experiment: "mismatch", adventure_id: "ADV-0001", dimensions: ["Seriousness"], metadata_schema: :legacy
      )
      raw = Dir.glob(File.join(run_root, "native", "raw", "**", "dimension_seriousness.json")).first
      payload = JSON.parse(File.read(raw))
      structured = JSON.parse(payload.dig("choices", 0, "message", "content"))
      structured.fetch("dimensions").first["score"] = 4
      payload.fetch("choices").first.fetch("message")["content"] = JSON.generate(structured)
      File.write(raw, JSON.pretty_generate(payload))

      result = extract(dir, expected_candidates: 1)

      assert_equal 0, result.candidates.length
      assert_equal "error", result.runs.first["mechanical_status"]
      assert result.errors.any? { |message| message.include?("value mismatch") }
      refute result.expectation_match
    end
  end

  def test_unclaimed_assessment_csv_is_reported
    Dir.mktmpdir do |dir|
      stray = File.join(dir, "orphan", "native", "assessments")
      FileUtils.mkdir_p(stray)
      File.write(File.join(stray, "orphan.csv"), "adventure_id,metric,value\nADV-0001,Seriousness,3\n")

      result = extract(dir)

      assert_equal 1, result.unclaimed_assessments.length
      assert result.errors.any? { |message| message.include?("unclaimed assessment CSVs") }
    end
  end

  # Confirms that conflicting flat snapshot rows publish no candidates or holds.
  def test_flat_assessment_refuses_conflicting_identity_and_status
    Dir.mktmpdir do |dir|
      assessments = File.join(dir, "prod-batch", "assessments")
      FileUtils.mkdir_p(assessments)
      File.write(File.join(assessments, "levels.csv"), <<~CSV)
        adventure_id,run_id,status,metric,value
        ADV-0001,synthetic-start,PROPOSED,Level Start,3
        ADV-0002,synthetic-end,REJECTED,Level End,5
      CSV

      result = extract(dir)

      assert_empty result.candidates
      assert_empty result.holds
      assert_equal 1, result.runs.length
      run = result.runs.first
      assert_equal "afcsu-flat-v1", run.fetch("metadata_schema")
      assert_equal "error", run.fetch("mechanical_status")
      assert_match(/exactly one canonical adventure/, result.errors.join("\n"))
      assert_match(/exactly one scoring run_id/, result.errors.join("\n"))
      assert_match(/rows must all have status PROPOSED/, result.errors.join("\n"))
    end
  end

  def test_identical_duplicate_and_conflicting_candidate_keys_are_distinguished
    Dir.mktmpdir do |dir|
      write_production_run(
        dir, experiment: "same-a", adventure_id: "ADV-0001", dimensions: ["Seriousness"], metadata_schema: :legacy
      )
      write_production_run(
        dir, experiment: "same-b", adventure_id: "ADV-0001", dimensions: ["Seriousness"], metadata_schema: :current,
        raw_format: :afcsu
      )
      duplicate_result = extract(dir)
      assert_equal ["ADV-0001::Seriousness"], duplicate_result.duplicates.map { |item| item["candidate_key"] }
      assert_empty duplicate_result.conflicts

      write_production_run(
        dir, experiment: "different", adventure_id: "ADV-0002", dimensions: ["Seriousness"], metadata_schema: :legacy,
        values: { "Seriousness" => 2 }
      )
      write_production_run(
        dir, experiment: "different-2", adventure_id: "ADV-0002", dimensions: ["Seriousness"], metadata_schema: :current,
        raw_format: :afcsu, values: { "Seriousness" => 4 }
      )
      conflict_result = extract(dir)
      assert_equal ["ADV-0002::Seriousness"], conflict_result.conflicts.map { |item| item["candidate_key"] }
    end
  end

  def test_expect_candidates_420_is_an_assertion_not_discovery_logic
    Dir.mktmpdir do |dir|
      write_production_run(
        dir, experiment: "one", adventure_id: "ADV-0001", dimensions: ["Seriousness"], metadata_schema: :legacy
      )

      result = extract(dir, expected_candidates: 420)

      assert_equal 1, result.candidates.length
      assert_equal 420, result.expected_candidates
      refute result.expectation_match
      assert result.errors.any? { |message| message.include?("normalized 1 production candidates; expected 420") }
    end
  end
end
