# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class CatalogReplayObservationTest < Minitest::Test
  Snapshot = Data.define(:manifest_path, :repository_root, :repository_head, :repository_remote,
                         :roles, :candidate, :destination)

  def test_only_the_exact_manifest_is_historical_and_cannot_be_promoted
    with_catalog do |snapshot, observed, binding|
      before = tree_bytes(snapshot.repository_root)
      observation = AfDataPipeline::CatalogReplayObservation.new(snapshot:, historical_binding: binding)
      assert_equal binding.slice("sha256", "bytes"), observation.file_binding(snapshot.manifest_path)
      state = observation.project_state(snapshot.manifest_path)
      assert state.validate!
      assert_equal "0.1", state.resolve("catalog_head").version
      assert_raises(AfDataPipeline::ValidationError) do
        state.promote!(role: "catalog_head", artifact_path: snapshot.destination, version: "0.2")
      end
      original_path = File.join(snapshot.repository_root, snapshot.roles.dig("catalog_head", "filename"))
      assert_equal AfDataPipeline::StandingBulkScorePolicy.file_binding(original_path), observation.file_binding(original_path)
      retained = File.join(snapshot.repository_root, "historical.yml")
      File.binwrite(retained, observed.fetch("manifest"))
      assert observation.project_state(retained).validate!
      assert_equal "0.1", observation.project_state(retained).resolve("catalog_head").version
      File.unlink(retained)
      assert_equal before, tree_bytes(snapshot.repository_root)
      assert_equal "0.2", AfDataPipeline::ProjectState.new(manifest_path: snapshot.manifest_path).resolve("catalog_head").version
    end
  end

  def test_live_manifest_and_published_candidate_changes_are_rejected_on_every_read
    with_catalog do |snapshot, _observed, binding|
      observation = AfDataPipeline::CatalogReplayObservation.new(snapshot:, historical_binding: binding)
      original = File.binread(snapshot.manifest_path)
      File.binwrite(snapshot.manifest_path, original + "# unauthorized edit\n")
      before = tree_bytes(snapshot.repository_root)
      error = assert_raises(AfDataPipeline::ValidationError) { observation.file_binding(snapshot.manifest_path) }
      assert_includes error.message, "exact approved promotion"
      assert_raises(AfDataPipeline::ValidationError) { observation.project_state(snapshot.manifest_path) }
      assert_equal before, tree_bytes(snapshot.repository_root)
      File.binwrite(snapshot.manifest_path, original)
      File.binwrite(snapshot.destination, "changed candidate")
      before = tree_bytes(snapshot.repository_root)
      error = assert_raises(AfDataPipeline::ValidationError) { observation.assert_current! }
      assert_includes error.message, "promoted catalog artifact changed"
      assert_equal before, tree_bytes(snapshot.repository_root)
    end
  end

  def test_historical_binding_roles_destination_and_repository_are_exact
    with_catalog do |snapshot, observed, binding|
      variants = [
        [snapshot, binding.merge("sha256" => "0" * 64), "historical catalog manifest"],
        [snapshot, binding.merge("path" => snapshot.manifest_path + ".other"), "manifest locator differs"],
        [snapshot.with(roles: snapshot.roles.merge("catalog_head" => snapshot.candidate)), binding, "historical catalog roles"],
        [snapshot.with(destination: snapshot.destination + ".other"), binding, "replay destination"],
        [snapshot.with(repository_head: "c" * 40), binding, "repository changed"],
        [snapshot.with(repository_remote: "fixture://different"), binding, "repository changed"],
        [snapshot.with(repository_head: "invalid"), binding, "repository changed"]
      ]
      before = tree_bytes(snapshot.repository_root)
      variants.each do |value, historical, message|
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::CatalogReplayObservation.new(snapshot: value, historical_binding: historical)
        end
        assert_includes error.message, message
      end
      observed["manifest"] += "# different committed bytes\n"
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::CatalogReplayObservation.new(snapshot:, historical_binding: binding)
      end
      assert_equal before, tree_bytes(snapshot.repository_root)
    end
  end

  def test_invalid_git_observations_and_historical_documents_fail_closed
    with_catalog do |snapshot, observed, binding|
      before = tree_bytes(snapshot.repository_root)
      observed["success"] = false
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::CatalogReplayObservation.new(snapshot:, historical_binding: binding)
      end
      observed["success"] = true
      observed["manifest"] = "[]\n"
      invalid = {"path" => snapshot.manifest_path, "sha256" => Digest::SHA256.hexdigest(observed.fetch("manifest")), "bytes" => observed.fetch("manifest").bytesize}
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::CatalogReplayObservation.new(snapshot:, historical_binding: invalid)
      end
      other = File.join(snapshot.repository_root, "other")
      FileUtils.mkdir_p(other)
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::CatalogReplayObservation.new(snapshot: snapshot.with(repository_root: other), historical_binding: binding)
      end
      observed["head"] = "invalid"
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::CatalogReplayObservation.new(snapshot: snapshot.with(repository_head: "invalid"), historical_binding: binding)
      end
      assert_equal before, tree_bytes(snapshot.repository_root)
    end
  end

  def test_a_historical_consumer_instance_cannot_publish_a_package
    with_catalog do |snapshot, _observed, binding|
      observation = AfDataPipeline::CatalogReplayObservation.new(snapshot:, historical_binding: binding)
      service = AfDataPipeline::FinalReleasePackage.new(inputs_path: "unused")
      assert_raises(AfDataPipeline::ValidationError) do
        service.validate!(package_path: File.join(snapshot.repository_root, "missing.json"), replay_observation: observation)
      end
      output = File.join(snapshot.repository_root, "forbidden-package.json")
      error = assert_raises(AfDataPipeline::ValidationError) { service.prepare!(output_path: output) }
      assert_includes error.message, "validation-only"
      refute_path_exists output
    end
  end

  def test_serialized_pass_is_not_a_historical_observation
    assert_raises(AfDataPipeline::ValidationError) do
      AfDataPipeline::FinalReleasePackage.validate!(inputs_path: "unused", package_path: "unused",
        replay_observation: {"status" => "PASS"})
    end
    assert_raises(AfDataPipeline::ValidationError) do
      AfDataPipeline::FrontierReleaseEvidence.validate!(path: "unused", release_manifest_path: "unused",
        staged_path: "unused", base_path: "unused", replay_observation: {"status" => "PASS"})
    end
    authority = AfDataPipeline::StagedScoringAuthority.new(
      evidence: AfDataPipeline::StagedScoringAuthority::INPUT_KEYS.to_h { |key| [key, "unused"] },
      store_root: "unused", mode: "synthetic")
    error = assert_raises(AfDataPipeline::StagedScoringAuthority::Failure) do
      authority.validate!(current_state_path: "unused", replay_observation: {"status" => "PASS"})
    end
    assert_includes error.message, "invalid historical catalog observation"
  end

  def test_symlinked_root_retains_exact_manifest_and_destination_locators
    Dir.mktmpdir("catalog-replay-alias-") do |parent|
      physical = File.join(parent, "physical")
      logical = File.join(parent, "alias")
      FileUtils.mkdir_p(physical)
      File.symlink(physical, logical)
      with_catalog(tmpdir: logical) do |snapshot, _observed, binding|
        refute_equal File.realpath(snapshot.repository_root), snapshot.repository_root
        before = tree_bytes(snapshot.repository_root)
        observation = AfDataPipeline::CatalogReplayObservation.new(snapshot:, historical_binding: binding)
        assert_equal binding.slice("sha256", "bytes"), observation.file_binding(snapshot.manifest_path)
        assert_equal "0.1", observation.project_state(snapshot.manifest_path).resolve("catalog_head").version
        assert observation.assert_current!
        # Physical aliases cannot replace the exact reviewed locators.
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::CatalogReplayObservation.new(snapshot:,
            historical_binding: binding.merge("path" => File.realpath(snapshot.manifest_path)))
        end
        assert_includes error.message, "manifest locator differs"
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::CatalogReplayObservation.new(
            snapshot: snapshot.with(destination: File.realpath(snapshot.destination)), historical_binding: binding)
        end
        assert_includes error.message, "replay destination"
        assert_equal before, tree_bytes(snapshot.repository_root)
      end
    end
  end

  private

  def tree_bytes(root)
    Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
  end

  def with_catalog(tmpdir: nil)
    Dir.mktmpdir("catalog-replay-observation-", tmpdir) do |root|
      original = File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx")
      candidate = File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx")
      File.binwrite(original, "synthetic original artifact\n")
      File.binwrite(candidate, "synthetic proposed artifact\n")
      role = {"version" => "0.1", "filename" => File.basename(original),
              **AfDataPipeline::StandingBulkScorePolicy.file_binding(original)}
      roles = AfDataPipeline::ProjectState::ROLES.to_h { |name| [name, role.dup] }
      manifest_path = File.join(root, "PROJECT_STATE.yml")
      document = {"schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION, **roles}
      bytes = YAML.dump(document) + "# exact reviewed bytes\n"
      File.binwrite(manifest_path, bytes)
      historical_binding = {"path" => manifest_path, **AfDataPipeline::StandingBulkScorePolicy.file_binding(manifest_path)}
      proposed = {"version" => "0.2", "filename" => File.basename(candidate),
                  **AfDataPipeline::StandingBulkScorePolicy.file_binding(candidate)}
      snapshot = Snapshot.new(manifest_path:, repository_root: root, repository_head: "b" * 40,
        repository_remote: "fixture://catalog", roles:, candidate: proposed, destination: candidate)
      # Explicit disposable publication through the real manifest owner.
      AfDataPipeline::ProjectState.new(manifest_path:).promote!(role: "catalog_head", artifact_path: candidate, version: "0.2")
      observed = {"manifest" => bytes, "head" => "b" * 40, "success" => true}
      git_root = File.realpath(root)
      git = lambda do |*argv|
        raise "unexpected Git IO #{argv.inspect}" unless argv[0, 3] == ["git", "-C", git_root]
        output = case argv.drop(3)
                 when ["rev-parse", "HEAD"] then observed.fetch("head") + "\n"
                 when ["remote", "get-url", "origin"] then "fixture://catalog\n"
                 when ["show", "#{observed.fetch('head')}:PROJECT_STATE.yml"] then observed.fetch("manifest")
                 else raise "prohibited Git operation #{argv.inspect}"
                 end
        [output, "read-only fixture", Struct.new(:success?).new(observed.fetch("success"))]
      end
      Open3.stub(:capture3, git) { yield snapshot, observed, historical_binding }
    end
  end
end
