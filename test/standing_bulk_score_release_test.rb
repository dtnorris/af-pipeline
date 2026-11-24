# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/amc_fixture"
require_relative "support/standing_bulk_score_release_fixture"
require "stringio"

class StandingBulkScoreReleaseTest < Minitest::Test
  # Serialized PASS data cannot substitute for the exact live-promotion proof.
  def test_read_only_replay_rejects_a_serialized_historical_observation
    verifier = AfDataPipeline::StandingBulkScoreRelease.new(inputs_path: "unused", output_dir: "unused")
    error = assert_raises(AfDataPipeline::ValidationError) do
      verifier.validate_existing!(replay_observation: {"status" => "PASS"})
    end
    assert_includes error.message, "invalid historical catalog observation"
  end

  include AmcFixture

  def test_versioned_selection_input_rejects_legacy_downgrade_and_missing_authority
    with_fixture do |fixture|
      fixture.rewrite_inputs { |inputs| inputs.fetch("staged_scoring")["selection_path"] = "/tmp/forged-selection.json" }
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.release }
      assert_match(/staged scoring inputs has unexpected fields/, error.message)
      refute File.exist?(fixture.output_dir)
    end

    with_fixture do |fixture|
      fixture.rewrite_inputs { |inputs| inputs["schema_version"] = AfDataPipeline::StandingBulkScoreRelease::SELECTION_INPUT_SCHEMA }
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.release }
      assert_match(/staged scoring inputs has unexpected fields/, error.message)
      refute File.exist?(fixture.output_dir)
    end
  end

  def test_v02_rejects_wrong_or_escaped_frozen_selection_locators
    with_fixture do |fixture|
      fixture.rewrite_inputs do |inputs|
        inputs["schema_version"] = AfDataPipeline::StandingBulkScoreRelease::SELECTION_INPUT_SCHEMA
        staged = inputs.fetch("staged_scoring")
        staged["selection_path"] = File.join(fixture.root, "outside-selection.json")
        staged["selection_afw_root"] = fixture.root
        staged["selection_project_root"] = inputs.dig("workload_review", "afw_root")
        staged["selection_scorer_root"] = fixture.root
        staged.fetch("workload_paths")["generated"] = File.join(fixture.root, "outside-generated")
      end
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.release }
      assert_match(/v0\.2 release requires an exact AFW frozen workload/, error.message)
      refute File.exist?(fixture.output_dir)
    end
  end

  def test_generated_workload_snapshot_rejects_symlinks_and_tracks_each_file
    Dir.mktmpdir("standing-generated-") do |root|
      FileUtils.mkdir_p(File.join(root, "cases"))
      File.binwrite(File.join(root, "cases", "one.yml"), "synthetic\n")
      files = AfDataPipeline::StandingBulkScoreRelease.generated_files(root)
      assert_equal ["cases/one.yml"], files.keys
      File.symlink(File.join(root, "cases", "one.yml"), File.join(root, "cases", "alias.yml"))
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::StandingBulkScoreRelease.generated_files(root)
      end
      assert_match(/symlink/, error.message)
    end
  end

  def test_full_qualified_workload_uses_standing_directive_and_publishes_only_finalized_candidate
    with_fixture do |fixture|
      protected = protected_bytes(fixture)
      ledger_before = File.binread(File.join(fixture.audit_dir, "editorial_decisions.csv"))

      result = fixture.release
      manifest = result.manifest
      counts = manifest.fetch("counts")

      assert_equal "VERIFIED_RELEASE_CANDIDATE", manifest["status"]
      assert manifest["release_complete"]
      assert manifest["every_intended_score_present"]
      assert_equal false, manifest["shared_catalog_promotion"]
      assert_equal 3, counts["intended_cases"]
      assert_equal 4, counts["metric_candidates"]
      assert_equal 4, counts["standing_directive_accepted"]
      assert_equal 0, counts["individual_human_accepted"]
      assert_equal 0, counts["ig16b_machine_accepted"]
      assert_equal 0, counts["historical_mechanical_accepted"]
      assert_equal 2, counts["new_cells_written"]
      assert_equal 2, counts["already_present_exact"]
      assert_equal 2, counts["finalized_cells"]
      assert_equal 1, counts["boundary_created_ids"]
      assert_equal 0, manifest.dig("verification", "unauthorized_cell_changes")
      assert_equal 0, manifest.dig("verification", "shared_roles_mutated")
      assert_equal 0, manifest.dig("verification", "git_mutations")
      refute File.exist?(File.join(result.output_dir, AfDataPipeline::StandingBulkScoreRelease::PREVIEW_NAME))
      assert_equal ledger_before, File.binread(File.join(fixture.audit_dir, "editorial_decisions.csv"))
      assert_protected_bytes(protected)

      workbook = AfDataPipeline::AmcApply::Workbook.new(result.workbook_path)
      sheet = workbook.catalog_sheet!
      %w[L4 P4].each do |cell|
        assert_equal "#D0E0E3", workbook.styles.fill_rgb(sheet.cell(cell).attributes["s"])
      end
      assert_equal 3, sheet.cell_numeric_value(sheet.cell("L4"))
      assert_equal 4, sheet.cell_numeric_value(sheet.cell("P4"))
      assert_equal 1, sheet.cell_numeric_value(sheet.cell("J4"))
      assert_equal 5, sheet.cell_numeric_value(sheet.cell("K4"))
    end
  end

  def test_human_and_source_decisions_take_precedence_without_fabricated_accept_rows
    specs = [
      {case_id: "combat", dimension: "Combat Emphasis", metrics: {"Combat Emphasis" => 3}},
      {
        case_id: "openness", dimension: "Structural Openness", metrics: {"Structural Openness" => 4},
        review_disposition: "SOURCE_HOLD", hold_reason: "source pages require correction"
      },
      {case_id: "levels", dimension: "Levels", metrics: {"Level Start" => 1, "Level End" => 5}},
      {
        case_id: "social", dimension: "Social Interaction Emphasis", metrics: {"Social Interaction Emphasis" => 2},
        metric_review_flags: "LOW_CONFIDENCE"
      },
      {case_id: "investigation", dimension: "Investigation Emphasis", metrics: {"Investigation Emphasis" => 2}}
    ]
    with_fixture(specs:) do |fixture|
      fixture.mutate_policy { |policy| policy.dig("scope", "dimensions").delete("Investigation Emphasis") }
      fixture.set_decision("ADV-0003::Combat Emphasis", "ACCEPT")
      fixture.set_decision("ADV-0003::Structural Openness", "ACCEPT")
      fixture.set_decision("ADV-0003::Level Start", "HOLD")
      fixture.set_decision("ADV-0003::Level End", "REJECT")
      ledger_before = File.binread(File.join(fixture.audit_dir, "editorial_decisions.csv"))

      result = fixture.release
      counts = result.manifest.fetch("counts")
      assert_equal 1, counts["individual_human_accepted"]
      assert_equal 1, counts["standing_directive_accepted"]
      assert_equal 1, counts["human_hold"]
      assert_equal 1, counts["human_reject"]
      assert_equal 1, counts["source_holds"]
      assert_equal 1, counts["deferred_or_unsupported"]
      assert_equal 2, counts["authorized_candidates"]
      assert_equal 2, counts["new_cells_written"]
      refute result.manifest["every_intended_score_present"]
      categories = result.manifest.fetch("residuals").map { |row| row.fetch("category") }
      assert_equal %w[human_hold human_reject source_hold unsupported_scope], categories.sort
      authorization = JSON.parse(File.binread(File.join(result.output_dir, "release-authorization.json")))
      social = authorization.fetch("accepted_candidates").find do |row|
        row["candidate_key"] == "ADV-0003::Social Interaction Emphasis"
      end
      assert_equal ["LOW_CONFIDENCE"], social.fetch("advisory_flags")
      assert_equal ledger_before, File.binread(File.join(fixture.audit_dir, "editorial_decisions.csv"))
    end
  end

  def test_independently_authorized_machine_acceptance_remains_distinct
    with_fixture do |fixture|
      machine = fixture.add_machine_acceptance("ADV-0003::Combat Emphasis")
      result = fixture.release

      assert_equal 1, result.manifest.dig("counts", "ig16b_machine_accepted")
      assert_equal 3, result.manifest.dig("counts", "standing_directive_accepted")
      assert_equal 0, result.manifest.dig("counts", "individual_human_accepted")
      authorization = JSON.parse(File.binread(File.join(result.output_dir, "release-authorization.json")))
      record = authorization.fetch("accepted_candidates").find do |entry|
        entry["candidate_key"] == "ADV-0003::Combat Emphasis"
      end
      assert_equal "ig16b_machine", record["authority"]
      assert_equal machine.record.fetch("record_id"), record["authority_id"]
    end
  end

  def test_non_authoritative_machine_proposal_does_not_disable_standing_directive
    with_fixture do |fixture|
      fixture.add_machine_acceptance("ADV-0003::Combat Emphasis", state: "PROPOSED")
      result = fixture.release

      assert_equal 0, result.manifest.dig("counts", "ig16b_machine_accepted")
      assert_equal 4, result.manifest.dig("counts", "standing_directive_accepted")
    end
  end

  def test_scope_and_flag_classification_covers_every_policy_branch_without_rebuilding_a_workload
    policy = JSON.parse(File.binread(
      File.expand_path("fixtures/standing_bulk_score/synthetic-policy.json", __dir__)
    ))
    release = AfDataPipeline::StandingBulkScoreRelease.new(inputs_path: "unused", output_dir: "unused")
    candidate = {
      "candidate_key" => "ADV-0003::Combat Emphasis",
      "dimension" => "Combat Emphasis",
      "source_book" => "New Source",
      "metric_review_flags" => "LOW_CONFIDENCE"
    }
    assert_equal ["LOW_CONFIDENCE"], release.send(:standing_advisory_flags!, candidate, policy)

    {"UNRESOLVED" => /hard-refusal/, "UNCLASSIFIED_FLAG" => /ambiguous severity/}.each do |flag, message|
      error = assert_raises(AfDataPipeline::ValidationError) do
        release.send(:standing_advisory_flags!, candidate.merge("metric_review_flags" => flag), policy)
      end
      assert_match message, error.message
    end

    projection = {"authority" => {"intent" => {"source" => {"source_id" => "New Source"}}}}
    row = {"profile" => "production", "model_alias" => "qwen", "ollama_model" => "qwen3.6:35b-a3b"}
    assert_nil release.send(:unsupported_scope_reason, candidate, {"intent" => {"case_index_row" => row}}, projection, policy)
    {
      "profile" => row.merge("profile" => "unsupported-profile"),
      "model alias" => row.merge("model_alias" => "unsupported-alias"),
      "model" => row.merge("ollama_model" => "unsupported-model")
    }.each do |label, changed_row|
      reason = release.send(
        :unsupported_scope_reason,
        candidate,
        {"intent" => {"case_index_row" => changed_row}},
        projection,
        policy
      )
      assert_includes reason, label
    end
    reason = release.send(
      :unsupported_scope_reason,
      candidate.merge("dimension" => "Seriousness"),
      {"intent" => {"case_index_row" => row}},
      projection,
      policy
    )
    assert_includes reason, "dimension"
  end

  def test_failed_or_nonterminal_workload_evidence_blocks_before_workbook_mutation
    with_fixture(states: %i[ready failed ready]) do |fixture|
      staged_before = File.binread(fixture.staged_path)
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.release }

      assert_match(/nonterminal unresolved/, error.message)
      assert_match(/openness:wlo_attempt_failed/, error.message)
      assert_equal staged_before, File.binread(fixture.staged_path)
      refute File.exist?(fixture.output_dir)
    end
  end

  def test_zero_write_release_is_truthful_and_does_not_invent_a_version
    specs = [{case_id: "levels", dimension: "Levels", metrics: {"Level Start" => 1, "Level End" => 5}}]
    with_fixture(specs:) do |fixture|
      staged_sha = Digest::SHA256.file(fixture.staged_path).hexdigest
      result = fixture.release

      assert_equal 0, result.manifest.dig("counts", "new_cells_written")
      assert_equal 2, result.manifest.dig("counts", "already_present_exact")
      assert_equal 0, result.manifest.dig("counts", "finalized_cells")
      assert_equal staged_sha, Digest::SHA256.file(result.workbook_path).hexdigest
      assert_equal fixture.authority_projection.dig("authority", "staged_amc", "filename"),
                   result.manifest.dig("lineage", "staged_amc", "filename")
    end
  end

  def test_zero_authorized_write_release_preserves_terminal_gap_accounting
    specs = [{
      case_id: "combat",
      dimension: "Combat Emphasis",
      metrics: {"Combat Emphasis" => 3},
      review_disposition: "SOURCE_HOLD",
      hold_reason: "source evidence intentionally held"
    }]
    with_fixture(specs:) do |fixture|
      result = fixture.release

      assert_equal 0, result.manifest.dig("counts", "authorized_candidates")
      assert_equal 0, result.manifest.dig("counts", "new_cells_written")
      assert_equal 1, result.manifest.dig("counts", "source_holds")
      assert_equal "source_hold", result.manifest.dig("residuals", 0, "category")
      assert_equal Digest::SHA256.file(fixture.staged_path).hexdigest,
                   Digest::SHA256.file(result.workbook_path).hexdigest
      refute result.manifest["every_intended_score_present"]
    end
  end

  def test_explicit_preview_has_no_authority_effect_and_exact_replay_is_read_only
    with_fixture do |fixture|
      first = fixture.release(preview: true)
      hashes = Dir.children(first.output_dir).sort.to_h do |name|
        [name, Digest::SHA256.file(File.join(first.output_dir, name)).hexdigest]
      end
      second = fixture.release(preview: true)

      refute first.reused
      assert second.reused
      assert_equal first.manifest, second.manifest
      assert_equal "none", first.manifest.dig("artifacts", "explicit_red_cell_preview", "authority_effect")
      assert_equal(
        first.manifest.dig("artifacts", "apply_intermediate", "sha256"),
        first.manifest.dig("artifacts", "explicit_red_cell_preview", "sha256")
      )
      assert_equal hashes, Dir.children(second.output_dir).sort.to_h { |name|
        [name, Digest::SHA256.file(File.join(second.output_dir, name)).hexdigest]
      }
    end
  end

  def test_changed_output_collision_and_failures_between_phases_never_announce_completion
    with_fixture do |fixture|
      fixture.release
      File.open(File.join(fixture.output_dir, "amc-finalize-report.json"), "a") { |file| file.write("changed\n") }
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.release }
      assert_match(/artifact changed/, error.message)
    end

    %i[after_apply after_finalize].each do |phase|
      with_fixture do |fixture|
        error = assert_raises(RuntimeError) do
          fixture.release(fault_injector: ->(current) { raise "injected #{phase}" if current == phase })
        end
        assert_match(/injected/, error.message)
        refute File.exist?(fixture.output_dir)
      end
    end
  end

  def test_changed_policy_candidate_staged_bytes_and_revocation_fail_closed
    with_fixture do |fixture|
      fixture.mutate_policy { |policy| policy["status"] = "REVOKED" }
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.release }
      assert_match(/revoked/, error.message)
      refute File.exist?(fixture.output_dir)
    end

    with_fixture do |fixture|
      fixture.mutate_first_candidate { |candidate| candidate["value"] = 2 }
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.release }
      assert_match(/review package conflicts/, error.message)
      refute File.exist?(fixture.output_dir)
    end

    with_fixture do |fixture|
      File.open(fixture.staged_path, "a") { |file| file.write("changed") }
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.release }
      assert_match(/changed|conflict|evidence|provenance/i, error.message)
      refute File.exist?(fixture.output_dir)
    end
  end

  def test_standing_policy_rejects_unsupported_page_scope_and_changed_activation
    Dir.mktmpdir do |root|
      policy_path = File.join(root, "policy.json")
      selection_path = File.join(root, "selection.json")
      source_policy = File.expand_path("fixtures/standing_bulk_score/synthetic-policy.json", __dir__)
      source_selection = File.expand_path("fixtures/standing_bulk_score/synthetic-owner-selection.json", __dir__)
      FileUtils.cp(source_policy, policy_path)
      FileUtils.cp(source_selection, selection_path)

      policy = JSON.parse(File.binread(policy_path))
      policy.dig("scope")["page_eligibility"] = "unqualified-pages"
      policy["policy_digest"] = AfDataPipeline::StandingBulkScorePolicy.digest(policy.except("policy_digest"))
      File.write(policy_path, JSON.pretty_generate(policy) + "\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::StandingBulkScorePolicy.validate!(policy_path:, selection_path:)
      end
      assert_match(/page eligibility is unsupported/, error.message)

      FileUtils.cp(source_policy, policy_path)
      policy = JSON.parse(File.binread(policy_path))
      policy.dig("activation")["owner_selection_id"] = "changed-selection"
      policy["policy_digest"] = AfDataPipeline::StandingBulkScorePolicy.digest(policy.except("policy_digest"))
      File.write(policy_path, JSON.pretty_generate(policy) + "\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::StandingBulkScorePolicy.validate!(policy_path:, selection_path:)
      end
      assert_match(/does not bind the owner selection/, error.message)
    end
  end

  def test_public_cli_runs_in_a_fresh_process
    with_fixture do |fixture|
      command = [
        RbConfig.ruby,
        File.expand_path("../bin/af-standing-bulk-score-release", __dir__),
        "--inputs", fixture.inputs_path,
        "--output", fixture.output_dir
      ]
      stdout, stderr, status = Open3.capture3(*command)
      assert status.success?, stderr
      assert_match(/published new release/, stdout)
    end
  end

  def test_authorized_writer_preserves_conflict_and_already_present_behavior
    Dir.mktmpdir do |root|
      authorization = {"schema_version" => "fixture/v0.1", "authorization_id" => "a" * 64}
      accounting = {
        "source_holds" => 0,
        "held_candidates" => 0,
        "rejected_candidates" => 0,
        "pending_candidates" => 0
      }
      source = write_amc_workbook(
        File.join(root, "source.xlsx"),
        rows: [{adventure_id: "ADV-0001", values: {"Seriousness" => 4}}]
      )
      candidate = [{
        "candidate_key" => "ADV-0001::Seriousness",
        "adventure_id" => "ADV-0001",
        "dimension" => "Seriousness",
        "proposed_value" => 4
      }]
      output = File.join(root, "output.xlsx")
      result = AfDataPipeline::AmcApply.apply_authorized!(
        authorized_candidates: candidate,
        authorization:,
        accounting:,
        amc_path: source,
        output_path: output
      )
      assert_equal 0, result.report.dig("counts", "new_cells_written")
      assert_equal 1, result.report.dig("counts", "already_present_exact_matches")
      assert_nil result.report["editorial_audit"]
      assert_equal "validated_authorized_candidate_set", result.report.dig("candidate_authorization", "kind")

      conflicting = candidate.map { |row| row.merge("proposed_value" => 2) }
      conflict_output = File.join(root, "conflict.xlsx")
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcApply.apply_authorized!(
          authorized_candidates: conflicting,
          authorization:,
          accounting:,
          amc_path: source,
          output_path: conflict_output
        )
      end
      assert_match(/existing=4/, error.message)
      refute File.exist?(conflict_output)
    end
  end

  private

  def with_fixture(**options)
    Dir.mktmpdir("standing-bulk-release-") do |root|
      yield StandingBulkScoreReleaseFixture.new(root:, **options)
    end
  end

  def protected_bytes(fixture)
    inputs = JSON.parse(File.binread(fixture.inputs_path))
    state = inputs.dig("staged_scoring", "current_project_state_path")
    document = YAML.safe_load_file(state, aliases: false)
    paths = {"staged" => fixture.staged_path, "state" => state}
    AfDataPipeline::ProjectState::ROLES.each do |role|
      paths[role] = File.join(File.dirname(state), document.fetch(role).fetch("filename"))
    end
    paths.to_h { |name, path| [name, [path, File.binread(path)]] }
  end

  def assert_protected_bytes(snapshot)
    snapshot.each do |name, (path, bytes)|
      assert_equal bytes, File.binread(path), "#{name} changed"
    end
  end
end
