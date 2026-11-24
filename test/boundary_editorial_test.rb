# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/af_data_pipeline/boundary_editorial"

class BoundaryEditorialTest < Minitest::Test
  def test_init_creates_separate_provenance_and_editable_decision_files
    with_source do |workspace|
      result = AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )

      assert_equal "Fixture Book", result.context.dig("source", "canonical_source_id")
      assert_equal "5e_Adventure_Master_Catalog_9.9.xlsx", result.context.dig("base_amc", "filename")
      assert_equal [], result.decisions.fetch("candidates")
      assert File.file?(result.context_path)
      assert File.file?(result.decisions_path)
      assert File.file?(result.review_path)

      review = File.read(result.review_path)
      assert_includes review, "`candidate_key` is stable once introduced"
      assert_includes review, "No Adventure IDs are assigned here"
    end
  end

  def test_complete_validation_requires_explicit_dispositions_and_stable_references
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(
        workspace.fetch(:bundle),
        [
          accepted_candidate("FX-PARENT", "Parent Adventure", 10, 20),
          accepted_candidate(
            "FX-CHILD",
            "Child Adventure",
            12,
            15,
            parent_candidate_key: "FX-PARENT"
          ),
          rejected_candidate("FX-REJECT", "Location Hook"),
          merged_candidate("FX-MERGE", "Alternate Label", "FX-CHILD")
        ]
      )

      result = AfDataPipeline::BoundaryEditorial.validate!(
        bundle_dir: workspace.fetch(:bundle),
        complete: true
      )

      assert result.complete
      assert_equal 2, result.counts.fetch("accept")
      assert_equal 1, result.counts.fetch("reject")
      assert_equal 1, result.counts.fetch("merge")
      assert_equal 0, result.counts.fetch("pending")
    end
  end

  def test_import_writes_only_accepted_records_and_preserves_human_approval
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(
        workspace.fetch(:bundle),
        [
          accepted_candidate("FX-PARENT", "Parent Adventure", 10, 20),
          accepted_candidate(
            "FX-CHILD",
            "Child Adventure",
            12,
            15,
            parent_candidate_key: "FX-PARENT"
          ),
          rejected_candidate("FX-REJECT", "Location Hook"),
          merged_candidate("FX-MERGE", "Alternate Label", "FX-CHILD")
        ]
      )

      draft = File.join(workspace.fetch(:dir), "draft-freeze.yml")
      AfDataPipeline::BoundaryFreeze.init!(
        source_root: workspace.fetch(:source_root),
        source_id: "Fixture Book",
        amc_path: workspace.fetch(:amc),
        output_path: draft
      )
      output = File.join(workspace.fetch(:dir), "frozen-freeze.yml")
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      AfDataPipeline::BoundaryEditorial.approve!(
        bundle_dir: workspace.fetch(:bundle),
        dossier_path: workspace.fetch(:dossier_dir),
        source_root: workspace.fetch(:source_root),
        amc_path: workspace.fetch(:amc),
        approved_by: "David",
        output_path: approval_path,
        clock: -> { Time.iso8601("2026-09-24T14:00:00Z") }
      )

      result = AfDataPipeline::BoundaryEditorial.import!(
        bundle_dir: workspace.fetch(:bundle),
        dossier_path: workspace.fetch(:dossier_dir),
        freeze_path: draft,
        source_root: workspace.fetch(:source_root),
        amc_path: workspace.fetch(:amc),
        approval_path:,
        output_path: output
      )

      assert_equal 2, result.record_count
      frozen = YAML.safe_load_file(output, permitted_classes: [Date, Time], aliases: false)
      assert_equal "frozen", frozen.fetch("state")
      assert_equal "David", frozen.dig("approval", "approved_by")
      assert_equal "2026-09-24T14:00:00.000000Z", frozen.dig("approval", "approved_at")
      assert_equal %w[FX-PARENT FX-CHILD], frozen.fetch("records").map { |record| record.fetch("local_key") }
      child = frozen.fetch("records").find { |record| record.fetch("local_key") == "FX-CHILD" }
      assert_equal "FX-PARENT", child.fetch("parent_key")
      refute frozen.fetch("records").any? { |record| record.key?("adventure_id") }

      AfDataPipeline::BoundaryFreeze.validate!(
        freeze_path: output,
        source_root: workspace.fetch(:source_root),
        amc_path: workspace.fetch(:amc)
      )
    end
  end

  def test_import_refuses_pending_or_held_candidates
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      pending = base_candidate("FX-PENDING", "Needs Review")
      pending["disposition"] = "pending"
      write_decisions(workspace.fetch(:bundle), [pending])

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.validate!(
          bundle_dir: workspace.fetch(:bundle),
          complete: true
        )
      end
      assert_match(/incomplete/, error.message)
    end
  end

  def test_rebind_preserves_decisions_and_records_history
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(
        workspace.fetch(:bundle),
        [accepted_candidate("FX-ONE", "Fixture Adventure", 10, 12)]
      )
      decisions_before = File.binread(
        File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
      )

      new_amc = File.join(workspace.fetch(:dir), "5e_Adventure_Master_Catalog_10.0.xlsx")
      File.write(new_amc, "new fixture AMC bytes")
      rebound_dossier = write_dossier(
        dir: File.join(workspace.fetch(:dir), "rebound-dossier"),
        source_root: workspace.fetch(:source_root),
        amc: new_amc,
        source_id: "Fixture Book"
      )
      rebound_bundle = File.join(workspace.fetch(:dir), "rebound-bundle")

      result = AfDataPipeline::BoundaryEditorial.rebind!(
        bundle_dir: workspace.fetch(:bundle),
        dossier_path: rebound_dossier,
        output_dir: rebound_bundle,
        reason: "Move editorial work to the newly adopted catalog head"
      )

      decisions_after = File.binread(
        File.join(rebound_bundle, AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
      )
      assert_equal decisions_before, decisions_after
      assert_equal 1, result.context.fetch("rebind_history").length
      history = result.context.fetch("rebind_history").first
      assert_equal "5e_Adventure_Master_Catalog_9.9.xlsx", history.dig("from", "base_amc", "filename")
      assert_equal "5e_Adventure_Master_Catalog_10.0.xlsx", history.dig("to", "base_amc", "filename")
    end
  end

  def test_rebind_requires_explicit_source_identity_change_and_same_source_bytes
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(
        workspace.fetch(:bundle),
        [accepted_candidate("FX-ONE", "Fixture Adventure", 10, 12)]
      )

      corrected_dossier = write_dossier(
        dir: File.join(workspace.fetch(:dir), "corrected-dossier"),
        source_root: workspace.fetch(:source_root),
        amc: workspace.fetch(:amc),
        source_id: "Fixture Book: Corrected Identity"
      )

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.rebind!(
          bundle_dir: workspace.fetch(:bundle),
          dossier_path: corrected_dossier,
          output_dir: File.join(workspace.fetch(:dir), "rebound-blocked"),
          reason: "Correct source identity"
        )
      end
      assert_match(/--allow-source-id-change/, error.message)

      result = AfDataPipeline::BoundaryEditorial.rebind!(
        bundle_dir: workspace.fetch(:bundle),
        dossier_path: corrected_dossier,
        output_dir: File.join(workspace.fetch(:dir), "rebound-allowed"),
        reason: "Correct source identity",
        allow_source_id_change: true
      )
      assert_equal "Fixture Book: Corrected Identity", result.context.dig("source", "canonical_source_id")

      changed_source_root = File.join(workspace.fetch(:dir), "changed-source")
      FileUtils.cp_r(workspace.fetch(:source_root), changed_source_root)
      File.write(File.join(changed_source_root, "Fixture_Book.md"), "changed source bytes\n")
      changed_dossier = write_dossier(
        dir: File.join(workspace.fetch(:dir), "changed-dossier"),
        source_root: changed_source_root,
        amc: workspace.fetch(:amc),
        source_id: "Fixture Book"
      )

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.rebind!(
          bundle_dir: workspace.fetch(:bundle),
          dossier_path: changed_dossier,
          output_dir: File.join(workspace.fetch(:dir), "changed-rebind"),
          reason: "Attempt changed-source rebind"
        )
      end
      assert_match(/source content\/ranges changed/, error.message)
    end
  end

  def test_workspace_foregrounds_explicit_ambiguity_and_retains_complete_inventory
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      parent = accepted_candidate("FX-PARENT", "Parent Unit", 10, 20)
      child = accepted_candidate("FX-CHILD", "Nested Unit", 12, 15, parent_candidate_key: "FX-PARENT")
      child["provisional_pdf_pages"] = {"start" => 14, "end" => 17}
      child["open_questions"] = ["Does the nested unit remain independently runnable?"]
      child["editorial_review"] = complete_editorial_review
      rejected = rejected_candidate("FX-REJECT", "Borderline Location")
      merged = merged_candidate("FX-MERGE", "Alternate Nested Label", "FX-CHILD")
      split = base_candidate("FX-SPLIT", "Collected Episodes")
      split["disposition"] = "split"
      split["split_into_candidate_keys"] = %w[FX-PARENT FX-CHILD]
      split["decision_rationale"] = "The reviewed source presents two separately runnable units."
      held = base_candidate("FX-HOLD", "Unresolved Appendix")
      held["disposition"] = "hold"
      held["decision_rationale"] = "Printed-page boundary evidence remains unresolved."
      pending = base_candidate("FX-PENDING", "Unreviewed Sidebar")
      write_decisions(workspace.fetch(:bundle), [parent, child, rejected, merged, split, held, pending])

      decisions_path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
      context_path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::CONTEXT_FILENAME)
      decisions_before = File.binread(decisions_path)
      context_before = File.binread(context_path)
      first = AfDataPipeline::BoundaryEditorial.render_workspace(bundle_dir: workspace.fetch(:bundle))
      second = AfDataPipeline::BoundaryEditorial.render_workspace(bundle_dir: workspace.fetch(:bundle))

      assert_equal first, second
      assert_equal decisions_before, File.binread(decisions_path)
      assert_equal context_before, File.binread(context_path)
      ambiguity = first.split("## Complete proposed canonical set").first
      assert_operator ambiguity.index("### `FX-HOLD`"), :<, ambiguity.index("### `FX-PENDING`")
      assert_operator ambiguity.index("### `FX-PENDING`"), :<, ambiguity.index("### `FX-SPLIT`")
      assert_operator ambiguity.index("### `FX-SPLIT`"), :<, ambiguity.index("### `FX-MERGE`")
      assert_operator ambiguity.index("### `FX-MERGE`"), :<, ambiguity.index("### `FX-REJECT`")
      assert_operator ambiguity.index("### `FX-REJECT`"), :<, ambiguity.index("### `FX-CHILD`")
      refute_includes ambiguity, "### `FX-PARENT`"
      %w[FX-PARENT FX-CHILD FX-REJECT FX-MERGE FX-SPLIT FX-HOLD FX-PENDING].each do |key|
        assert_includes first.split("## Full Phase 1 candidate inventory").last, "`#{key}`"
      end
      assert_includes first, "Survivor Play-Spine Proof"
      assert_includes first, "Homogeneous sibling-set calibration"
      assert_includes first, "Incremental Playable Identity"
      assert_includes first, "Precedent `ABDS-example`"
      assert_includes first, "Competing interpretation"
      assert_includes first, "Boundary disagreements"
    end
  end

  def test_split_is_traceable_and_references_existing_candidates
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(dossier_path: workspace.fetch(:dossier_dir), output_dir: workspace.fetch(:bundle))
      first = accepted_candidate("FX-A", "First Unit", 10, 11)
      second = accepted_candidate("FX-B", "Second Unit", 12, 13)
      original = base_candidate("FX-ORIGINAL", "Collected Unit")
      original.merge!(
        "disposition" => "split",
        "split_into_candidate_keys" => %w[FX-A FX-B],
        "decision_rationale" => "Phase 2 retained two separately runnable units."
      )
      original["review_history"] << {
        "phase" => "phase2",
        "status" => "split",
        "rationale" => "Original high-recall candidate retained as split provenance."
      }
      write_decisions(workspace.fetch(:bundle), [original, first, second])

      result = AfDataPipeline::BoundaryEditorial.validate!(bundle_dir: workspace.fetch(:bundle), complete: true)

      assert result.complete
      assert_equal 1, result.counts.fetch("split")
      assert_equal 2, result.counts.fetch("accept")

      original["split_into_candidate_keys"] = %w[FX-A FX-MISSING]
      write_decisions(workspace.fetch(:bundle), [original, first, second])
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.validate!(bundle_dir: workspace.fetch(:bundle))
      end
      assert_match(/unknown candidate/, error.message)
    end
  end

  def test_complete_validation_allows_a_traceable_zero_accepted_result
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(dossier_path: workspace.fetch(:dossier_dir), output_dir: workspace.fetch(:bundle))
      write_decisions(workspace.fetch(:bundle), [rejected_candidate("FX-NONE", "Considered Unit")])

      result = AfDataPipeline::BoundaryEditorial.validate!(bundle_dir: workspace.fetch(:bundle), complete: true)
      workspace_markdown = AfDataPipeline::BoundaryEditorial.render_workspace(bundle_dir: workspace.fetch(:bundle))

      assert result.complete
      assert_equal 0, result.counts.fetch("accept")
      assert_includes workspace_markdown, "A zero-adventure result is valid"
      assert_includes workspace_markdown, "`FX-NONE`"
    end
  end

  def test_render_cli_prints_workspace_without_writing_an_output_artifact
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(dossier_path: workspace.fetch(:dossier_dir), output_dir: workspace.fetch(:bundle))
      write_decisions(workspace.fetch(:bundle), [accepted_candidate("FX-ONE", "Fixture Unit", 10, 12)])
      before = Dir.children(workspace.fetch(:bundle)).sort
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::BoundaryEditorial::CLI.run(
        ["render", workspace.fetch(:bundle)],
        out:,
        err:
      )

      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "# AdventureFinder boundary review workspace"
      assert_includes out.string, "## Full Phase 1 candidate inventory"
      assert_equal before, Dir.children(workspace.fetch(:bundle)).sort
    end
  end

  def test_workspace_schema_fails_closed_on_unsupported_fields_and_references
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(dossier_path: workspace.fetch(:dossier_dir), output_dir: workspace.fetch(:bundle))
      candidate = accepted_candidate("FX-ONE", "Fixture Unit", 10, 12)
      candidate["editorial_review"] = {"automated_adventure_confidence" => 0.9}
      write_decisions(workspace.fetch(:bundle), [candidate])

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.render_workspace(bundle_dir: workspace.fetch(:bundle))
      end
      assert_match(/unknown fields.*automated_adventure_confidence/, error.message)

      candidate["editorial_review"] = complete_editorial_review
      candidate["editorial_review"]["pairwise_identity"].first["candidate_key"] = "FX-MISSING"
      write_decisions(workspace.fetch(:bundle), [candidate])
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.render_workspace(bundle_dir: workspace.fetch(:bundle))
      end
      assert_match(/unknown candidate/, error.message)
    end
  end

  def test_legacy_v01_ledgers_remain_readable_but_cannot_use_v02_extensions
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(dossier_path: workspace.fetch(:dossier_dir), output_dir: workspace.fetch(:bundle))
      candidate = accepted_candidate("FX-ONE", "Fixture Unit", 10, 12)
      path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
      File.write(
        path,
        YAML.dump(
          "schema_version" => AfDataPipeline::BoundaryEditorial::LEGACY_DECISIONS_SCHEMA_VERSION,
          "candidates" => [candidate]
        )
      )

      assert AfDataPipeline::BoundaryEditorial.validate!(bundle_dir: workspace.fetch(:bundle), complete: true).complete

      candidate["editorial_review"] = complete_editorial_review
      File.write(
        path,
        YAML.dump(
          "schema_version" => AfDataPipeline::BoundaryEditorial::LEGACY_DECISIONS_SCHEMA_VERSION,
          "candidates" => [candidate]
        )
      )
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.validate!(bundle_dir: workspace.fetch(:bundle))
      end
      assert_match(/unknown fields.*editorial_review/, error.message)
    end
  end

  def test_explicit_approval_binds_complete_review_and_identical_replay_reuses_exact_bytes
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(
        workspace.fetch(:bundle),
        [
          accepted_candidate("FX-ONE", "Fixture Adventure", 10, 12),
          rejected_candidate("FX-REJECT", "Reviewed Rejection"),
          merged_candidate("FX-MERGE", "Reviewed Alias", "FX-ONE")
        ]
      )
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      before = input_hashes(workspace)
      clock_calls = 0
      clock = lambda do
        clock_calls += 1
        Time.iso8601("2026-10-07T01:02:03Z")
      end

      first = AfDataPipeline::BoundaryEditorial.approve!(
        bundle_dir: workspace.fetch(:bundle),
        dossier_path: workspace.fetch(:dossier_dir),
        source_root: workspace.fetch(:source_root),
        amc_path: workspace.fetch(:amc),
        approved_by: "David",
        output_path: approval_path,
        clock:
      )
      first_bytes = File.binread(approval_path)
      second = AfDataPipeline::BoundaryEditorial.approve!(
        bundle_dir: workspace.fetch(:bundle),
        dossier_path: workspace.fetch(:dossier_dir),
        source_root: workspace.fetch(:source_root),
        amc_path: workspace.fetch(:amc),
        approved_by: "David",
        output_path: approval_path,
        clock:
      )

      assert_equal AfDataPipeline::BoundaryEditorial::APPROVAL_SCHEMA_VERSION,
                   first.approval.fetch("schema_version")
      assert_equal "approved", first.approval.fetch("status")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, first.approval.fetch("approval_id"))
      assert_equal "David", first.approval.dig("approval", "approved_by")
      assert_equal "2026-10-07T01:02:03.000000Z", first.approval.dig("approval", "approved_at")
      assert_equal 3, first.approval.dig("binding", "review_summary", "candidate_count")
      assert_equal 1, first.approval.dig("binding", "review_summary", "dispositions", "reject")
      assert_equal 1, first.approval.dig("binding", "review_summary", "dispositions", "merge")
      assert_equal AfDataPipeline::BoundaryEditorial::RENDER_DERIVATION,
                   first.approval.dig("binding", "rendered_review", "derivation")
      assert second.reused
      refute first.reused
      assert_equal first.sha256, second.sha256
      assert_equal first_bytes, File.binread(approval_path)
      assert_equal 1, clock_calls
      assert_equal before, input_hashes(workspace)
    end
  end

  def test_approval_invalidates_for_each_changed_review_or_provenance_input
    mutations = {
      "rejected ledger row" => lambda do |workspace|
        path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
        decisions = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false)
        decisions.fetch("candidates").find { |candidate| candidate["candidate_key"] == "FX-REJECT" }[
          "decision_rationale"
        ] = "Changed rejected-candidate rationale."
        File.write(path, YAML.dump(decisions))
      end,
      "merged ledger row" => lambda do |workspace|
        path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
        decisions = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false)
        decisions.fetch("candidates").find { |candidate| candidate["candidate_key"] == "FX-MERGE" }[
          "decision_rationale"
        ] = "Changed merged-candidate rationale."
        File.write(path, YAML.dump(decisions))
      end,
      "dossier" => ->(workspace) { File.open(File.join(workspace.fetch(:dossier_dir), "boundary_dossier.json"), "a") { |file| file.write(" ") } },
      "editorial context" => lambda do |workspace|
        path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::CONTEXT_FILENAME)
        File.open(path, "a") { |file| file.write(" ") }
      end,
      "editorial instructions" => lambda do |workspace|
        path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::REVIEW_FILENAME)
        File.open(path, "a") { |file| file.write("\nChanged independent review instruction.\n") }
      end,
      "source bytes" => ->(workspace) { File.open(File.join(workspace.fetch(:source_root), "Fixture_Book.md"), "a") { |file| file.write("changed") } },
      "registry bytes" => ->(workspace) { File.open(File.join(workspace.fetch(:source_root), "source_registry.yml"), "a") { |file| file.write("# changed\n") } },
      "base AMC bytes" => ->(workspace) { File.open(workspace.fetch(:amc), "a") { |file| file.write("changed") } }
    }

    mutations.each do |label, mutate|
      with_approved_workspace do |workspace, approval_path|
        mutate.call(workspace)
        error = assert_raises(AfDataPipeline::ValidationError, label) do
          validate_approval(workspace, approval_path)
        end
        assert_match(/changed|stale|mismatch/, error.message, label)
      end
    end
  end

  def test_approval_refuses_incomplete_or_unreviewed_empty_ledgers_but_allows_reviewed_zero_accept
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      error = assert_raises(AfDataPipeline::ValidationError) do
        issue_approval(workspace, approval_path)
      end
      assert_match(/unreviewed empty/, error.message)
      refute File.exist?(approval_path)

      pending = base_candidate("FX-PENDING", "Pending Candidate")
      write_decisions(workspace.fetch(:bundle), [pending])
      error = assert_raises(AfDataPipeline::ValidationError) do
        issue_approval(workspace, approval_path)
      end
      assert_match(/incomplete/, error.message)
      refute File.exist?(approval_path)

      unresolved = accepted_candidate("FX-OPEN", "Unresolved Candidate", 10, 12)
      unresolved["open_questions"] = ["Does the source support this exact ending?"]
      unresolved["editorial_review"] = {
        "evidence" => {"unresolved_ambiguities" => ["The exact ending remains disputed."]}
      }
      write_decisions(workspace.fetch(:bundle), [unresolved])
      error = assert_raises(AfDataPipeline::ValidationError) do
        issue_approval(workspace, approval_path)
      end
      assert_match(/materially unresolved/, error.message)
      refute File.exist?(approval_path)

      write_decisions(workspace.fetch(:bundle), [rejected_candidate("FX-NONE", "Reviewed Non-Adventure")])
      result = issue_approval(workspace, approval_path)
      assert_equal 0, result.approval.dig("binding", "review_summary", "dispositions", "accept")
      assert_equal 1, result.approval.dig("binding", "review_summary", "candidate_count")
    end
  end

  def test_approval_rejects_malformed_schema_identity_and_changed_registered_segments
    with_approved_workspace do |workspace, approval_path|
      approval = JSON.parse(File.read(approval_path))
      approval["schema_version"] = "af-boundary-editorial-approval/v9.9"
      File.write(approval_path, JSON.pretty_generate(approval) + "\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        validate_approval(workspace, approval_path)
      end
      assert_match(/Unsupported boundary editorial approval schema/, error.message)
    end

    with_approved_workspace do |workspace, approval_path|
      approval = JSON.parse(File.read(approval_path))
      approval["approval_id"] = "sha256:#{'0' * 64}"
      File.write(approval_path, JSON.pretty_generate(approval) + "\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        validate_approval(workspace, approval_path)
      end
      assert_match(/identity does not match/, error.message)
    end

    with_approved_workspace do |workspace, approval_path|
      approval = JSON.parse(File.read(approval_path))
      approval.fetch("approval").delete("approved_at")
      File.write(approval_path, JSON.pretty_generate(approval) + "\n")
      error = assert_raises(AfDataPipeline::ValidationError) do
        validate_approval(workspace, approval_path)
      end
      assert_match(/missing required fields: approved_at/, error.message)
    end

    with_segmented_source do |workspace|
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      issue_approval(workspace, approval_path)
      registry_path = File.join(workspace.fetch(:source_root), "source_registry.yml")
      registry = YAML.safe_load_file(registry_path, permitted_classes: [Date, Time], aliases: false)
      registry.dig("sources", "Fixture Book", "segments", 0)["end_page"] = 11
      File.write(registry_path, YAML.dump(registry))
      error = assert_raises(AfDataPipeline::ValidationError) do
        validate_approval(workspace, approval_path)
      end
      assert_match(/mismatch|segment provenance/, error.message)
    end
  end

  def test_approval_fails_closed_when_inputs_change_during_construction
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(workspace.fetch(:bundle), [accepted_candidate("FX-ONE", "Fixture Adventure", 10, 12)])
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      decisions_path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
      clock = lambda do
        File.open(decisions_path, "a") { |file| file.write("\n") }
        Time.iso8601("2026-10-07T01:02:03Z")
      end

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.approve!(
          bundle_dir: workspace.fetch(:bundle),
          dossier_path: workspace.fetch(:dossier_dir),
          source_root: workspace.fetch(:source_root),
          amc_path: workspace.fetch(:amc),
          approved_by: "David",
          output_path: approval_path,
          clock:
        )
      end
      assert_match(/changed while approval was being issued/, error.message)
      refute File.exist?(approval_path)
    end
  end

  def test_import_refuses_missing_stale_or_legacy_loose_approval_without_publishing
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(workspace.fetch(:bundle), [accepted_candidate("FX-ONE", "Fixture Adventure", 10, 12)])
      draft = File.join(workspace.fetch(:dir), "draft-freeze.yml")
      AfDataPipeline::BoundaryFreeze.init!(
        source_root: workspace.fetch(:source_root),
        source_id: "Fixture Book",
        amc_path: workspace.fetch(:amc),
        output_path: draft
      )
      output = File.join(workspace.fetch(:dir), "frozen-freeze.yml")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.import!(
          bundle_dir: workspace.fetch(:bundle),
          dossier_path: workspace.fetch(:dossier_dir),
          freeze_path: draft,
          source_root: workspace.fetch(:source_root),
          amc_path: workspace.fetch(:amc),
          approval_path: File.join(workspace.fetch(:dir), "missing.json"),
          output_path: output
        )
      end
      assert_match(/Missing boundary editorial approval/, error.message)
      refute File.exist?(output)

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.import!(
          bundle_dir: workspace.fetch(:bundle),
          dossier_path: workspace.fetch(:dossier_dir),
          freeze_path: draft,
          source_root: workspace.fetch(:source_root),
          amc_path: workspace.fetch(:amc),
          approved_by: "David",
          approved_at: "2026-10-07",
          output_path: output
        )
      end
      assert_match(/legacy loose/, error.message)
      refute File.exist?(output)

      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      issue_approval(workspace, approval_path)
      decisions_path = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
      File.open(decisions_path, "a") { |file| file.write("\n") }
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.import!(
          bundle_dir: workspace.fetch(:bundle),
          dossier_path: workspace.fetch(:dossier_dir),
          freeze_path: draft,
          source_root: workspace.fetch(:source_root),
          amc_path: workspace.fetch(:amc),
          approval_path:,
          output_path: output
        )
      end
      assert_match(/stale/, error.message)
      refute File.exist?(output)
    end
  end

  def test_approval_cli_issues_and_validates_the_public_record
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(workspace.fetch(:bundle), [accepted_candidate("FX-ONE", "Fixture Adventure", 10, 12)])
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      common = [
        workspace.fetch(:bundle),
        "--dossier", workspace.fetch(:dossier_dir),
        "--source-root", workspace.fetch(:source_root),
        "--amc", workspace.fetch(:amc)
      ]
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::BoundaryEditorial::CLI.run(
        ["approve", *common, "--approved-by", "David", "--output", approval_path],
        out:,
        err:
      )
      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "Boundary editorial approval: PASS"
      assert_includes out.string, "issued new approval"
      assert File.file?(approval_path)

      out = StringIO.new
      status = AfDataPipeline::BoundaryEditorial::CLI.run(
        ["validate-approval", *common, "--approval", approval_path],
        out:,
        err: StringIO.new
      )
      assert_equal 0, status
      assert_includes out.string, "Boundary editorial approval validation: PASS"
    end
  end

  def test_freeze_approved_composes_clean_draft_import_and_exact_final_validation
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      parent = accepted_candidate("FX-PARENT", "Parent Adventure", 10, 12)
      parent.fetch("decision")["pdf_pages"] = {"start" => 1, "end" => 3}
      parent.fetch("decision")["levels"] = {"start" => 3, "end" => 5}
      child = accepted_candidate(
        "FX-CHILD", "Child Adventure", 11, 12, parent_candidate_key: "FX-PARENT"
      )
      write_decisions(
        workspace.fetch(:bundle),
        [parent, child, rejected_candidate("FX-REJECT", "Reviewed Rejection")]
      )
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      approval = issue_approval(workspace, approval_path)
      draft = File.join(workspace.fetch(:dir), "draft.yml")
      output = File.join(workspace.fetch(:dir), "frozen.yml")
      before = input_hashes(workspace)

      result = compose_approved(workspace, approval_path, draft, output)

      assert result.draft_initialized
      refute result.reused
      assert_equal 2, result.record_count
      assert_equal approval.approval.fetch("approval_id"), result.approval_id
      assert_equal approval.sha256, result.approval_sha256
      assert File.file?(draft)
      assert File.file?(output)
      frozen = YAML.safe_load_file(output, permitted_classes: [Date, Time], aliases: false)
      assert_equal %w[FX-PARENT FX-CHILD], frozen.fetch("records").map { |record| record.fetch("local_key") }
      assert_equal({"start" => 1, "end" => 3}, frozen.dig("records", 0, "pdf_pages"))
      assert_equal({"start" => 3, "end" => 5}, frozen.dig("records", 0, "levels"))
      assert_equal "FX-PARENT", frozen.dig("records", 1, "parent_key")
      refute frozen.fetch("records").any? { |record| record.key?("adventure_id") }
      assert_equal before, input_hashes(workspace)

      validated = AfDataPipeline::BoundaryEditorial.validate_approved_freeze!(
        freeze_path: output,
        approval_path:,
        bundle_dir: workspace.fetch(:bundle),
        dossier_path: workspace.fetch(:dossier_dir),
        source_root: workspace.fetch(:source_root),
        amc_path: workspace.fetch(:amc)
      )
      assert_equal result.sha256, validated.sha256
      assert_equal result.approval_id, validated.approval_id
    end
  end

  def test_freeze_approved_replay_reuses_exact_bytes_without_another_draft_or_approval
    with_approved_workspace do |workspace, approval_path|
      draft = File.join(workspace.fetch(:dir), "draft.yml")
      output = File.join(workspace.fetch(:dir), "frozen.yml")
      first = compose_approved(workspace, approval_path, draft, output)
      approval_bytes = File.binread(approval_path)
      frozen_bytes = File.binread(output)
      File.unlink(draft)

      replay = compose_approved(workspace, approval_path, draft, output)

      assert replay.reused
      refute replay.draft_initialized
      refute File.exist?(draft)
      assert_equal first.sha256, replay.sha256
      assert_equal approval_bytes, File.binread(approval_path)
      assert_equal frozen_bytes, File.binread(output)
    end
  end

  def test_freeze_approved_refuses_conflicting_existing_output_and_stale_or_wrong_approval
    with_approved_workspace do |workspace, approval_path|
      draft = File.join(workspace.fetch(:dir), "draft.yml")
      output = File.join(workspace.fetch(:dir), "frozen.yml")
      File.write(output, "preserve this conflicting output\n")
      prior = File.binread(output)

      error = assert_raises(AfDataPipeline::ValidationError) do
        compose_approved(workspace, approval_path, draft, output)
      end
      assert_match(/Invalid YAML|mapping|boundary freeze/, error.message)
      assert_equal prior, File.binread(output)
      refute File.exist?(draft)
    end

    with_approved_workspace do |workspace, approval_path|
      approval = JSON.parse(File.read(approval_path))
      approval["approval_id"] = "sha256:#{'0' * 64}"
      File.write(approval_path, JSON.pretty_generate(approval) + "\n")
      draft = File.join(workspace.fetch(:dir), "draft.yml")
      output = File.join(workspace.fetch(:dir), "frozen.yml")
      error = assert_raises(AfDataPipeline::ValidationError) do
        compose_approved(workspace, approval_path, draft, output)
      end
      assert_match(/identity does not match/, error.message)
      refute File.exist?(draft)
      refute File.exist?(output)
    end

    with_approved_workspace do |workspace, approval_path|
      decisions = File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
      File.open(decisions, "a") { |file| file.write("\n") }
      error = assert_raises(AfDataPipeline::ValidationError) do
        compose_approved(
          workspace,
          approval_path,
          File.join(workspace.fetch(:dir), "draft.yml"),
          File.join(workspace.fetch(:dir), "frozen.yml")
        )
      end
      assert_match(/stale/, error.message)
    end
  end

  def test_freeze_approved_preserves_reviewed_zero_accepted_result
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(workspace.fetch(:bundle), [rejected_candidate("FX-NONE", "Reviewed Non-Adventure")])
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      issue_approval(workspace, approval_path)
      output = File.join(workspace.fetch(:dir), "frozen.yml")

      result = compose_approved(
        workspace,
        approval_path,
        File.join(workspace.fetch(:dir), "draft.yml"),
        output
      )

      assert_equal 0, result.record_count
      assert_equal 1, result.counts.fetch("reject")
      assert_equal [], YAML.safe_load_file(output, permitted_classes: [Date, Time], aliases: false).fetch("records")
    end
  end

  def test_approved_freeze_validation_rejects_duplicate_keys_cycles_invalid_spans_and_content_drift
    mutations = {
      "duplicate key" => lambda do |artifact|
        artifact.fetch("records") << Marshal.load(Marshal.dump(artifact.fetch("records").first))
      end,
      "parent cycle" => lambda do |artifact|
        artifact.fetch("records").first["parent_key"] = "FX-CHILD"
        artifact.fetch("records").last["parent_key"] = "FX-PARENT"
      end,
      "invalid span" => lambda do |artifact|
        artifact.fetch("records").first.fetch("printed_pages")["start"] = 13
      end,
      "approved record drift" => lambda do |artifact|
        artifact.fetch("records").first["canonical_title"] = "Unapproved replacement title"
      end
    }

    mutations.each do |label, mutate|
      with_source do |workspace|
        AfDataPipeline::BoundaryEditorial.init!(
          dossier_path: workspace.fetch(:dossier_dir),
          output_dir: workspace.fetch(:bundle)
        )
        write_decisions(
          workspace.fetch(:bundle),
          [
            accepted_candidate("FX-PARENT", "Parent", 10, 12),
            accepted_candidate("FX-CHILD", "Child", 11, 12, parent_candidate_key: "FX-PARENT")
          ]
        )
        approval_path = File.join(workspace.fetch(:dir), "approval.json")
        issue_approval(workspace, approval_path)
        output = File.join(workspace.fetch(:dir), "frozen.yml")
        compose_approved(workspace, approval_path, File.join(workspace.fetch(:dir), "draft.yml"), output)
        artifact = YAML.safe_load_file(output, permitted_classes: [Date, Time], aliases: false)
        mutate.call(artifact)
        File.write(output, AfDataPipeline::BoundaryFreeze::HANDOFF_HEADER + YAML.dump(artifact))

        error = assert_raises(AfDataPipeline::ValidationError, label) do
          AfDataPipeline::BoundaryEditorial.validate_approved_freeze!(
            freeze_path: output,
            approval_path:,
            bundle_dir: workspace.fetch(:bundle),
            dossier_path: workspace.fetch(:dossier_dir),
            source_root: workspace.fetch(:source_root),
            amc_path: workspace.fetch(:amc)
          )
        end
        assert_match(/Duplicate|cycle|start exceeds end|does not exactly represent/, error.message, label)
      end
    end
  end

  def test_freeze_approved_does_not_publish_when_final_freeze_validation_fails
    with_segmented_source do |workspace|
      write_decisions(workspace.fetch(:bundle), [accepted_candidate("FX-OUTSIDE", "Outside", 99, 100)])
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      issue_approval(workspace, approval_path)
      output = File.join(workspace.fetch(:dir), "frozen.yml")

      error = assert_raises(AfDataPipeline::ValidationError) do
        compose_approved(
          workspace,
          approval_path,
          File.join(workspace.fetch(:dir), "draft.yml"),
          output
        )
      end
      assert_match(/not fully contained by a registered source segment/, error.message)
      refute File.exist?(output)
    end
  end

  def test_freeze_approved_removes_its_new_output_if_post_publication_validation_is_interrupted
    with_approved_workspace do |workspace, approval_path|
      draft = File.join(workspace.fetch(:dir), "draft.yml")
      output = File.join(workspace.fetch(:dir), "frozen.yml")
      before = input_hashes(workspace).merge(approval_path => Digest::SHA256.file(approval_path).hexdigest)
      failure = lambda do |**_arguments|
        raise AfDataPipeline::ValidationError, "injected final validation interruption"
      end

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::BoundaryEditorial.stub(:validate_approved_freeze!, failure) do
          compose_approved(workspace, approval_path, draft, output)
        end
      end

      assert_match(/injected final validation interruption/, error.message)
      refute File.exist?(output)
      assert File.file?(draft)
      assert_equal before, input_hashes(workspace).merge(approval_path => Digest::SHA256.file(approval_path).hexdigest)
    end
  end

  def test_freeze_approved_cli_stops_at_validated_frozen_boundaries
    with_approved_workspace do |workspace, approval_path|
      out = StringIO.new
      err = StringIO.new
      output = File.join(workspace.fetch(:dir), "frozen.yml")
      status = AfDataPipeline::BoundaryEditorial::CLI.run(
        [
          "freeze-approved", workspace.fetch(:bundle),
          "--approval", approval_path,
          "--dossier", workspace.fetch(:dossier_dir),
          "--freeze", File.join(workspace.fetch(:dir), "draft.yml"),
          "--source-root", workspace.fetch(:source_root),
          "--amc", workspace.fetch(:amc),
          "--output", output
        ],
        out:,
        err:
      )

      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "Terminal state: VALIDATED_FROZEN_BOUNDARIES"
      assert_includes out.string, "No AMC application, catalog promotion, scoring, or inference was performed."
      refute_includes out.string, "Next command:"
    end
  end

  private

  def compose_approved(workspace, approval_path, draft, output)
    AfDataPipeline::BoundaryEditorial.freeze_approved!(
      bundle_dir: workspace.fetch(:bundle),
      approval_path:,
      dossier_path: workspace.fetch(:dossier_dir),
      freeze_path: draft,
      source_root: workspace.fetch(:source_root),
      amc_path: workspace.fetch(:amc),
      output_path: output
    )
  end

  def with_approved_workspace
    with_source do |workspace|
      AfDataPipeline::BoundaryEditorial.init!(
        dossier_path: workspace.fetch(:dossier_dir),
        output_dir: workspace.fetch(:bundle)
      )
      write_decisions(
        workspace.fetch(:bundle),
        [
          accepted_candidate("FX-ONE", "Fixture Adventure", 10, 12),
          rejected_candidate("FX-REJECT", "Reviewed Rejection"),
          merged_candidate("FX-MERGE", "Reviewed Alias", "FX-ONE")
        ]
      )
      approval_path = File.join(workspace.fetch(:dir), "approval.json")
      issue_approval(workspace, approval_path)
      yield workspace, approval_path
    end
  end

  def issue_approval(workspace, approval_path)
    AfDataPipeline::BoundaryEditorial.approve!(
      bundle_dir: workspace.fetch(:bundle),
      dossier_path: workspace.fetch(:dossier_dir),
      source_root: workspace.fetch(:source_root),
      amc_path: workspace.fetch(:amc),
      approved_by: "David",
      output_path: approval_path,
      clock: -> { Time.iso8601("2026-10-07T01:02:03Z") }
    )
  end

  def validate_approval(workspace, approval_path)
    AfDataPipeline::BoundaryEditorial.validate_approval!(
      approval_path:,
      bundle_dir: workspace.fetch(:bundle),
      dossier_path: workspace.fetch(:dossier_dir),
      source_root: workspace.fetch(:source_root),
      amc_path: workspace.fetch(:amc)
    )
  end

  def input_hashes(workspace)
    paths = [
      File.join(workspace.fetch(:source_root), "source_registry.yml"),
      File.join(workspace.fetch(:source_root), "Fixture_Book.md"),
      workspace.fetch(:amc),
      File.join(workspace.fetch(:dossier_dir), "boundary_dossier.json"),
      File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::CONTEXT_FILENAME),
      File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME),
      File.join(workspace.fetch(:bundle), AfDataPipeline::BoundaryEditorial::REVIEW_FILENAME)
    ]
    paths.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  end

  def with_segmented_source
    Dir.mktmpdir("boundary-editorial-segments") do |dir|
      source_root = File.join(dir, "source")
      FileUtils.mkdir_p(source_root)
      markdown = File.join(source_root, "Fixture_Book.md")
      File.write(markdown, "<!-- Printed Page 10 -->\n# Fixture Adventure\n")
      registry = File.join(source_root, "source_registry.yml")
      File.write(
        registry,
        YAML.dump(
          "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
          "sources" => {
            "Fixture Book" => {
              "segments" => [
                {"start_page" => 10, "end_page" => 12, "file" => "Fixture_Book.md"}
              ]
            }
          }
        )
      )
      amc = File.join(dir, "5e_Adventure_Master_Catalog_9.9.xlsx")
      File.write(amc, "fixture AMC bytes")
      dossier_dir = File.join(dir, "dossier")
      FileUtils.mkdir_p(dossier_dir)
      dossier = {
        "schema_version" => "af-boundary-dossier/v0.2",
        "source" => {
          "canonical_source_id" => "Fixture Book",
          "registry_filename" => "source_registry.yml",
          "registry_sha256" => Digest::SHA256.file(registry).hexdigest,
          "markdown_files" => [
            {"filename" => "Fixture_Book.md", "sha256" => Digest::SHA256.file(markdown).hexdigest}
          ],
          "segments" => [
            {"start_page" => 10, "end_page" => 12, "file" => "Fixture_Book.md"}
          ]
        },
        "base_amc" => {
          "filename" => File.basename(amc),
          "sha256" => Digest::SHA256.file(amc).hexdigest
        }
      }
      File.write(File.join(dossier_dir, "boundary_dossier.json"), JSON.pretty_generate(dossier) + "\n")
      workspace = {
        dir:,
        source_root:,
        amc:,
        dossier_dir:,
        bundle: File.join(dir, "editorial-bundle")
      }
      AfDataPipeline::BoundaryEditorial.init!(dossier_path: dossier_dir, output_dir: workspace.fetch(:bundle))
      write_decisions(workspace.fetch(:bundle), [accepted_candidate("FX-ONE", "Fixture Adventure", 10, 12)])
      yield workspace
    end
  end

  def with_source
    Dir.mktmpdir("boundary-editorial") do |dir|
      source_root = File.join(dir, "source")
      FileUtils.mkdir_p(source_root)
      markdown = File.join(source_root, "Fixture_Book.md")
      File.write(
        markdown,
        <<~MD
          <!-- PDF Page 1 -->
          <!-- Printed Page 10 -->
          # Fixture Adventure
          Adventure for level 3 characters.
        MD
      )
      registry = File.join(source_root, "source_registry.yml")
      File.write(
        registry,
        YAML.dump(
          "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
          "sources" => {"Fixture Book" => {"file" => "Fixture_Book.md"}}
        )
      )
      amc = File.join(dir, "5e_Adventure_Master_Catalog_9.9.xlsx")
      File.write(amc, "fixture AMC bytes")
      dossier_dir = write_dossier(
        dir: File.join(dir, "dossier"),
        source_root:,
        amc:,
        source_id: "Fixture Book"
      )
      yield(
        dir:,
        source_root:,
        amc:,
        dossier_dir:,
        bundle: File.join(dir, "editorial-bundle")
      )
    end
  end

  def write_dossier(dir:, source_root:, amc:, source_id:)
    FileUtils.mkdir_p(dir)
    markdown = File.join(source_root, "Fixture_Book.md")
    registry = File.join(source_root, "source_registry.yml")
    dossier = {
      "schema_version" => "af-boundary-dossier/v0.2",
      "purpose" => "fixture",
      "source" => {
        "canonical_source_id" => source_id,
        "registry_filename" => "source_registry.yml",
        "registry_sha256" => Digest::SHA256.file(registry).hexdigest,
        "markdown_files" => [
          {
            "filename" => "Fixture_Book.md",
            "sha256" => Digest::SHA256.file(markdown).hexdigest
          }
        ]
      },
      "base_amc" => {
        "filename" => File.basename(amc),
        "sha256" => Digest::SHA256.file(amc).hexdigest
      },
      "amc_evidence" => {},
      "source_files" => [],
      "review_contract" => {}
    }
    File.write(
      File.join(dir, "boundary_dossier.json"),
      JSON.pretty_generate(dossier) + "\n"
    )
    dir
  end

  def base_candidate(key, title)
    {
      "candidate_key" => key,
      "provisional_title" => title,
      "playability_evidence" => "Source-grounded reason this candidate deserves review.",
      "open_questions" => [],
      "review_history" => [
        {
          "phase" => "phase1",
          "status" => "retained",
          "rationale" => "High-recall candidate retained for explicit adjudication."
        }
      ],
      "disposition" => "pending"
    }
  end

  def accepted_candidate(key, title, start_page, end_page, parent_candidate_key: nil)
    candidate = base_candidate(key, title)
    candidate["disposition"] = "accept"
    decision = {
      "canonical_title" => title,
      "printed_pages" => {"start" => start_page, "end" => end_page},
      "editorial_rationale" => "Source-grounded final boundary decision."
    }
    decision["parent_candidate_key"] = parent_candidate_key if parent_candidate_key
    candidate["decision"] = decision
    candidate["review_history"] << {
      "phase" => "phase2",
      "status" => "accepted",
      "rationale" => "Canonical title and boundary accepted."
    }
    candidate
  end

  def rejected_candidate(key, title)
    candidate = base_candidate(key, title)
    candidate["disposition"] = "reject"
    candidate["decision_rationale"] = "Rich source material, but not an independently runnable adventure."
    candidate["review_history"] << {
      "phase" => "phase1b",
      "status" => "rejected",
      "rationale" => candidate.fetch("decision_rationale")
    }
    candidate
  end

  def merged_candidate(key, title, target)
    candidate = base_candidate(key, title)
    candidate["disposition"] = "merge"
    candidate["merge_into_candidate_key"] = target
    candidate["decision_rationale"] = "Same canonical adventure identity as the accepted target."
    candidate["review_history"] << {
      "phase" => "phase2",
      "status" => "merged",
      "rationale" => candidate.fetch("decision_rationale")
    }
    candidate
  end

  def write_decisions(bundle, candidates)
    path = File.join(bundle, AfDataPipeline::BoundaryEditorial::DECISIONS_FILENAME)
    decisions = {
      "schema_version" => AfDataPipeline::BoundaryEditorial::DECISIONS_SCHEMA_VERSION,
      "candidates" => candidates
    }
    File.write(path, YAML.dump(decisions))
  end

  def complete_editorial_review
    {
      "evidence" => {
        "source_supported" => ["A structural source marker establishes the entry."],
        "editorial_inferences" => ["The nested sequence appears independently runnable."],
        "unresolved_ambiguities" => ["The exact relationship to the parent requires approval."]
      },
      "survivor_play_spine" => {
        "entry" => "A clear player-facing entry is present.",
        "authored_middle" => "The fixture records a sustained authored middle.",
        "resolution_exit" => "A source-supported exit is present.",
        "reviewer_completion" => "The reviewer records why the unit is coherent."
      },
      "sibling_calibration" => {
        "candidate_keys" => ["FX-REJECT"],
        "comparison" => "Compare the weakest retained and strongest rejected cases.",
        "controlling_distinction" => "Only one case has a complete play spine."
      },
      "pairwise_identity" => [
        {
          "candidate_key" => "FX-PARENT",
          "incremental_playable_identity" => "The nested unit adds a distinct playable objective.",
          "boundary_before_identity" => "Its source-supported start and end can be identified first."
        }
      ],
      "precedents" => [
        {"reference" => "ABDS-example", "relevance" => "Structurally similar nested material."}
      ],
      "competing_interpretations" => [
        {"interpretation" => "Child adventure", "implications" => "Retain a parent relationship."},
        {"interpretation" => "Parent episode", "implications" => "Merge into the parent."
        }
      ],
      "boundary_evidence" => {
        "start" => "Printed page 12 heading.",
        "end" => "Printed page 15 resolution marker.",
        "disagreements" => ["One interpretation extends through printed page 16."]
      }
    }
  end
end
