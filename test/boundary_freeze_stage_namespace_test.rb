# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/staged_scoring_fixture"

# Exercises new namespace publication and byte-exact replay of an actual
# pre-BUG-02E producer fixture, without adapting its receipts or workbooks.
class BoundaryFreezeStageNamespaceTest < Minitest::Test
  include StagedScoringFixture

  def test_new_stage_uses_authoritative_noncanonical_basename_and_replays_without_writes
    Dir.mktmpdir("stage-namespace-") do |root|
      evidence = build_authority_fixture(root, cache_namespace: :namespace)
      result = verify_stage(evidence)
      assert_equal "staged-5e_Adventure_Master_Catalog_0.2.xlsx", File.basename(result.output_path)
      assert_equal "0.2", result.receipt.dig("successor_version_authorization", "successor_version")
      assert_equal File.basename(result.output_path), result.receipt.dig("successor", "filename")
      refute_path_exists File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx")
      before = snapshot(root)
      assert_equal result.receipt, verify_stage(evidence).receipt
      assert_equal before, snapshot(root)
      # A published canonical artifact never substitutes for staged evidence.
      File.binwrite(File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx"), "different published bytes")
      before = snapshot(root)
      assert_equal result.output_path, verify_stage(evidence).output_path
      assert_equal before, snapshot(root)
    end
  end

  def test_original_legacy_receipt_workbook_and_authority_keep_exact_identities
    with_legacy_stage do |root, evidence|
      before = snapshot(root)
      result = verify_stage(evidence)
      assert_equal File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx"), result.output_path
      assert result.reused
      assert_equal before, snapshot(root)
      assert_equal result.receipt, AfDataPipeline::BoundaryFreezeStage.stage!(**stage_options(evidence)).receipt
      assert_equal before, snapshot(root)
      authority = AUTH.new(evidence:, store_root: File.join(root, "authority"), mode: "synthetic")
        .issue!(current_state_path: File.join(root, "PROJECT_STATE.yml")).fetch("authority")
      assert_equal result.receipt.fetch("successor").slice("filename", "sha256", "bytes"), authority.fetch("staged_amc")
      assert_equal before, snapshot(root).slice(*before.keys)
      refute_path_exists File.join(root, "staged-5e_Adventure_Master_Catalog_0.2.xlsx")
    end
  end

  def test_partial_legacy_publication_is_never_migrated_or_recreated
    with_legacy_stage do |root, evidence|
      receipt_path = Dir[File.join(root, "*verified-staged-successor*.json")].fetch(0)
      File.unlink(receipt_path)
      before = snapshot(root)
      assert_raises(AfDataPipeline::ValidationError) { verify_stage(evidence) }
      assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::BoundaryFreezeStage.stage!(**stage_options(evidence)) }
      assert_equal before, snapshot(root)
    end
  end

  def test_changed_or_malformed_receipt_and_missing_staged_bytes_fail_closed
    Dir.mktmpdir("stage-namespace-negative-") do |root|
      evidence = build_authority_fixture(root, cache_namespace: :namespace)
      result = verify_stage(evidence)
      original = File.binread(result.stage_path)
      changed = JSON.parse(original)
      changed.fetch("successor")["filename"] = "../5e_Adventure_Master_Catalog_0.2.xlsx"
      [JSON.generate(changed), "{", "[]", JSON.generate("successor" => "malformed")].each do |bytes|
        File.binwrite(result.stage_path, bytes)
        before = snapshot(root)
        assert_raises(AfDataPipeline::ValidationError) { verify_stage(evidence) }
        assert_equal before, snapshot(root)
      end
      File.binwrite(result.stage_path, original)
      File.unlink(result.output_path)
      before = snapshot(root)
      assert_raises(AfDataPipeline::ValidationError) { verify_stage(evidence) }
      assert_equal before, snapshot(root)
    end
  end

  private

  # Restore exact historical producer bytes into a disposable root. The JSON
  # fixture binds its origin; embedded historical report paths are unedited.
  def with_legacy_stage
    document = JSON.parse(File.binread(File.join(__dir__, "fixtures/legacy_staged_successor_v0_1.json")))
    Dir.mktmpdir("legacy-stage-") do |root|
      document.fetch("files_base64").each do |relative, encoded|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, encoded.unpack1("m0"))
      end
      evidence = {
        freeze_path: File.join(root, "frozen.yml"), operation_input_path: File.join(root, "operation.json"),
        successor_authorization_path: File.join(root, "version.json"), source_root: File.join(root, "source"),
        catalog_root: root, project_state_path: File.join(root, "HISTORICAL_PROJECT_STATE.yml"),
        approval_path: File.join(root, "approval.json"), bundle_dir: File.join(root, "editorial"),
        dossier_path: File.join(root, "boundary_dossier.json"), intent_path: File.join(root, "intent.json"),
        policy_path: File.join(root, "policy.json")
      }
      yield root, evidence
    end
  end

  # Select only the public stage verifier's supported evidence locators.
  def stage_options(evidence)
    evidence.slice(:freeze_path, :operation_input_path, :successor_authorization_path,
      :source_root, :catalog_root, :project_state_path)
  end

  # Recompute real stage validation without repairing or authorizing inputs.
  def verify_stage(evidence)
    AfDataPipeline::BoundaryFreezeStage.verify!(**stage_options(evidence))
  end

  # Capture every file identity so negative/replay results also prove no writes.
  def snapshot(root)
    Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }
      .to_h { |path| [path, File.binread(path)] }
  end
end
