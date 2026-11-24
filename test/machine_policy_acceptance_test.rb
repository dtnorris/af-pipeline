# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/machine_policy_acceptance_fixture"

class MachinePolicyAcceptanceTest < Minitest::Test
  CONTRACT = AfDataPipeline::MachinePolicyAcceptance

  def test_valid_scalar_proposal_binds_and_revalidates_every_artifact
    with_fixture do |fixture|
      validation = CONTRACT.validate_file!(
        path: fixture.path,
        roots: fixture.roots,
        current: fixture.current_bindings
      )

      assert_equal "PROPOSED", validation.state
      refute validation.authoritative
      assert_equal fixture.record.fetch("record_id"), validation.record_id
      assert_equal fixture.record.fetch("binding_sha256"), validation.binding_sha256
      assert_equal "MACHINE_POLICY_PROPOSAL", fixture.record.dig("authority", "kind")
      assert_equal "WOULD_MACHINE_ACCEPT", fixture.record.dig("decision", "result")
    end
  end

  def test_levels_candidates_share_receipt_without_sharing_candidate_acceptance
    Dir.mktmpdir do |root|
      start = MachinePolicyAcceptanceFixture.new(root:, dimension: "Levels", metric: "Level Start")
      finish = MachinePolicyAcceptanceFixture.new(root:, dimension: "Levels", metric: "Level End")

      [start, finish].each do |fixture|
        CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots, current: fixture.current_bindings)
      end
      assert_equal start.record.dig("evidence", "receipt", "receipt_id"),
                   finish.record.dig("evidence", "receipt", "receipt_id")
      refute_equal start.record.dig("candidate", "key"), finish.record.dig("candidate", "key")
      refute_equal start.record.dig("candidate", "content_sha256"),
                   finish.record.dig("candidate", "content_sha256")
      refute_equal start.record.fetch("record_id"), finish.record.fetch("record_id")
    end
  end

  def test_identical_replay_is_byte_identical_and_reusable_without_timestamp_churn
    Dir.mktmpdir do |root|
      first = MachinePolicyAcceptanceFixture.new(root:)
      replay = MachinePolicyAcceptanceFixture.new(root:)

      assert_equal first.bytes, replay.bytes
      validation = CONTRACT.validate_file!(
        path: replay.path,
        roots: replay.roots,
        current: replay.current_bindings,
        existing_path: first.path
      )
      assert_equal first.record.fetch("record_id"), validation.record_id
    end
  end

  def test_authoritative_shape_requires_and_revalidates_later_authorities
    with_fixture(state: "ACCEPTED") do |fixture|
      validation = CONTRACT.validate_file!(
        path: fixture.path,
        roots: fixture.roots,
        current: fixture.current_bindings
      )

      assert validation.authoritative
      assert_equal "MACHINE_POLICY_ACCEPTANCE", fixture.record.dig("authority", "kind")
      assert_equal "MACHINE_ACCEPTED", fixture.record.dig("decision", "result")
      assert_equal "PASSED", fixture.record.dig("prerequisites", "ig12b_evaluation", "status")
      assert_equal "GRANTED", fixture.record.dig("prerequisites", "application_authorization", "status")
    end
  end

  def test_authoritative_shape_refuses_missing_revalidation_roots
    with_fixture(state: "ACCEPTED") do |fixture|
      error = assert_raises(AfDataPipeline::ValidationError) do
        CONTRACT.validate_file!(path: fixture.path, roots: {})
      end
      assert_match(/requires artifact revalidation roots/, error.message)
    end
  end

  def test_human_hold_remains_distinct_and_forces_human_review
    conditions = {
      "assessment_state" => "resolved", "review_flags" => [], "source_hold" => false,
      "existing_human_decision" => "HOLD"
    }
    with_fixture(result: "HUMAN_REVIEW_REQUIRED", conditions:) do |fixture|
      validation = CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots)

      refute validation.authoritative
      assert_equal false, fixture.record.dig("authority", "human_reviewed")
      assert_nil fixture.record.dig("authority", "human_decision")
      assert_equal "HOLD", fixture.record.dig("evidence", "review_conditions", "existing_human_decision")
    end
  end

  def test_machine_acceptance_cannot_overwrite_human_decision_source_hold_or_flags
    variants = {
      "assessment" => { "assessment_state" => "unresolved" },
      "human" => { "existing_human_decision" => "REJECT" },
      "source" => { "source_hold" => true },
      "flags" => { "review_flags" => ["UNRESOLVED"] }
    }
    variants.each do |label, change|
      conditions = {
        "assessment_state" => "resolved", "review_flags" => [], "source_hold" => false,
        "existing_human_decision" => nil
      }.merge(change)
      with_fixture(conditions:) do |fixture|
        error = assert_raises(AfDataPipeline::ValidationError, label) do
          CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots)
        end
        assert_match(/cannot accept/, error.message, label)
      end
    end
  end

  def test_wrong_missing_and_extra_schema_identity_are_rejected
    mutations = {
      "wrong schema" => ->(record) { record["schema_version"] = "v99" },
      "missing field" => ->(record) { record.delete("producer") },
      "extra field" => ->(record) { record["editorial_decision"] = "ACCEPT" },
      "candidate identity" => ->(record) { record.dig("candidate")["proposed_value"] = 99 },
      "binding identity" => ->(record) { record["binding_sha256"] = "0" * 64 },
      "record identity" => ->(record) { record["record_id"] = "0" * 64 }
    }
    mutations.each do |label, mutation|
      with_fixture do |fixture|
        mutation.call(fixture.record)
        File.binwrite(fixture.path, JSON.pretty_generate(fixture.record) + "\n")
        assert_raises(AfDataPipeline::ValidationError, label) do
          CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots)
        end
      end
    end
  end

  def test_each_changed_current_binding_refuses_stale_reuse
    changes = {
      "candidate" => ->(value) { value["proposed_value"] = 2 },
      "evidence" => ->(value) { value.dig("receipt")["content_sha256"] = "a" * 64 },
      "workload" => ->(value) { value["plan_sha256"] = "b" * 64 },
      "attempt" => ->(value) { value["number"] = 2 },
      "qualification" => ->(value) { value["profile_id"] = "changed-profile" },
      "policy" => ->(value) { value["version"] = "0.2" },
      "decision" => ->(value) { value.dig("evaluation_output")["sha256"] = "c" * 64 }
    }
    changes.each do |section, change|
      with_fixture do |fixture|
        current = fixture.current_bindings
        change.call(current.fetch(section))
        error = assert_raises(AfDataPipeline::ValidationError, section) do
          CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots, current:)
        end
        assert_match(/#{section} changed/, error.message, section)
      end
    end
  end

  def test_changed_receipt_attempt_qualification_policy_and_review_artifacts_fail_revalidation
    reference_paths = [
      %w[evidence receipt reference],
      %w[attempt metadata],
      %w[qualification artifact],
      %w[policy artifact],
      %w[evidence review_package]
    ]
    reference_paths.each do |keys|
      with_fixture do |fixture|
        reference = keys.reduce(fixture.record) { |value, key| value.fetch(key) }
        File.open(File.join(fixture.roots.fetch(reference.fetch("root")), reference.fetch("path")), "a") do |file|
          file.write("changed\n")
        end
        assert_raises(AfDataPipeline::ValidationError, keys.join(".")) do
          CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots)
        end
      end
    end
  end

  def test_workload_attempt_and_levels_identity_mismatches_are_rejected
    mutations = {
      "job" => ->(record) { record.dig("attempt")["job_id"] = "other-job" },
      "case" => ->(record) { record.dig("workload")["case_id"] = "other-case" },
      "metric" => ->(record) { record.dig("candidate")["metric"] = "Level Middle" }
    }
    mutations.each do |label, mutation|
      with_fixture(dimension: "Levels") do |fixture|
        mutation.call(fixture.record)
        fixture.rewrite!
        assert_raises(AfDataPipeline::ValidationError, label) do
          CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots)
        end
      end
    end
  end

  def test_retry_supersession_interruption_failure_rerun_and_unqualified_state_cannot_be_accepted
    mutations = {
      "retry" => ->(record) { record.dig("attempt")["retry"] = true },
      "superseded" => ->(record) { record.dig("attempt")["superseded"] = true },
      "interrupted" => ->(record) { record.dig("attempt")["status"] = "interrupted" },
      "failed" => lambda do |record|
        record.dig("attempt")["status"] = "failed"
        record.dig("attempt")["exit_status"] = 1
      end,
      "favorable rerun" => ->(record) { record.dig("attempt")["favorable_rerun"] = true },
      "qualification" => ->(record) { record.dig("qualification")["state"] = "QUALIFICATION_NUMERIC_PASS_ALL" }
    }
    mutations.each do |label, mutation|
      with_fixture do |fixture|
        mutation.call(fixture.record)
        fixture.rewrite!
        assert_raises(AfDataPipeline::ValidationError, label) do
          CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots)
        end
      end
    end
  end

  def test_authoritative_record_refuses_failed_or_missing_later_authority
    %w[ig12b_evaluation application_authorization].each do |name|
      with_fixture(state: "ACCEPTED") do |fixture|
        prerequisite = fixture.record.dig("prerequisites", name)
        prerequisite["status"] = name == "ig12b_evaluation" ? "FAILED" : "NOT_GRANTED"
        prerequisite["artifact"] = nil if prerequisite["status"] == "NOT_GRANTED"
        fixture.rewrite!
        error = assert_raises(AfDataPipeline::ValidationError) do
          CONTRACT.validate_file!(path: fixture.path, roots: fixture.roots)
        end
        assert_match(/requires successful IG-12B/, error.message)
      end
    end
  end

  def test_timestamp_refresh_cannot_replace_existing_authority
    Dir.mktmpdir do |root|
      original = MachinePolicyAcceptanceFixture.new(root:)
      original_path = File.join(root, "original.json")
      File.binwrite(original_path, original.bytes)
      changed = MachinePolicyAcceptanceFixture.new(root:, recorded_at: "2026-10-07T02:00:00Z")

      assert_equal original.record.fetch("record_id"), changed.record.fetch("record_id")
      error = assert_raises(AfDataPipeline::ValidationError) do
        CONTRACT.validate_file!(
          path: changed.path, roots: changed.roots, current: changed.current_bindings, existing_path: original_path
        )
      end
      assert_match(/identity collision/, error.message)
    end
  end

  def test_different_identity_cannot_overwrite_existing_record
    Dir.mktmpdir do |root|
      scalar = MachinePolicyAcceptanceFixture.new(root:)
      scalar_path = File.join(root, "scalar.json")
      File.binwrite(scalar_path, scalar.bytes)
      level = MachinePolicyAcceptanceFixture.new(root:, dimension: "Levels", metric: "Level Start")

      error = assert_raises(AfDataPipeline::ValidationError) do
        CONTRACT.validate_file!(path: level.path, roots: level.roots, existing_path: scalar_path)
      end
      assert_match(/different immutable identity/, error.message)
    end
  end

  def test_malformed_json_path_traversal_and_incomplete_reference_fail_closed
    with_fixture do |fixture|
      File.binwrite(fixture.path, "{not-json\n")
      assert_raises(AfDataPipeline::ValidationError) { CONTRACT.validate_file!(path: fixture.path) }
    end
    with_fixture do |fixture|
      fixture.record.dig("evidence", "receipt", "reference")["path"] = "../receipt.json"
      fixture.rewrite!
      assert_raises(AfDataPipeline::ValidationError) { CONTRACT.validate_file!(path: fixture.path) }
    end
    with_fixture do |fixture|
      fixture.record.dig("policy", "artifact").delete("sha256")
      fixture.rewrite!
      assert_raises(AfDataPipeline::ValidationError) { CONTRACT.validate_file!(path: fixture.path) }
    end
    with_fixture do |fixture|
      fixture.record.dig("attempt")["exit_status"] = "zero"
      fixture.rewrite!
      assert_raises(AfDataPipeline::ValidationError) { CONTRACT.validate_file!(path: fixture.path) }
    end
  end

  private

  def with_fixture(**options)
    Dir.mktmpdir do |root|
      yield MachinePolicyAcceptanceFixture.new(root:, **options)
    end
  end
end
