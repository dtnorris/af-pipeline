# frozen_string_literal: true
require_relative "test_helper"

class ProjectStateTest < Minitest::Test
  # Named pipeline exceptions remain distinct from owner failures after load;
  # actual owner validation is translated, preserving its message and cause.
  def test_owner_errors_preserve_named_pipeline_contracts
    assert_equal "AfDataPipeline::Error", AfDataPipeline::Error.name
    assert_equal "AfDataPipeline::ValidationError", AfDataPipeline::ValidationError.name
    assert_equal AfDataPipeline::Error, AfDataPipeline::ValidationError.superclass
    refute_equal AfXlsxFiles::Error, AfDataPipeline::Error
    refute_equal AfXlsxFiles::ValidationError, AfDataPipeline::ValidationError
    with_state do |_dir, manifest|
      state = AfDataPipeline::ProjectState.new(manifest_path: manifest)
      error = assert_raises(AfDataPipeline::Error) { state.resolve("unknown") }
      assert_instance_of AfDataPipeline::Error, error
      assert_instance_of AfXlsxFiles::Error, error.cause
      assert_equal error.cause.message, error.message
      assert_equal error.cause.backtrace, error.backtrace
      owner = AfXlsxFiles::ProjectState.new(manifest_path: manifest)
      assert_instance_of AfXlsxFiles::Error, assert_raises(AfXlsxFiles::Error) { owner.resolve("unknown") }
    end
    error = assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::AmcApply.reference_parts("invalid") }
    assert_instance_of AfDataPipeline::ValidationError, error
    assert_instance_of AfXlsxFiles::ValidationError, error.cause
    assert_equal error.cause.message, error.message
  end

  def test_resolves_named_roles_and_verifies_integrity
    with_state do |dir, manifest|
      state = AfDataPipeline::ProjectState.new(manifest_path: manifest)

      assert state.validate!
      assert_equal File.join(dir, "5e_Adventure_Master_Catalog_2.0.xlsx"), state.resolve("catalog_head").path
      assert_equal "1.0", state.resolve("matcher_authorized_baseline").version
      assert_equal "1.0", state.resolve("production_dependency_floor").version
    end
  end

  def test_sha_mismatch_fails_closed
    with_state do |dir, manifest|
      File.write(File.join(dir, "5e_Adventure_Master_Catalog_2.0.xlsx"), "mutated")
      error = assert_raises(AfDataPipeline::Error) do
        AfDataPipeline::ProjectState.new(manifest_path: manifest).validate!
      end
      assert_includes error.message, "catalog_head SHA-256 mismatch"
    end
  end

  def test_promoting_catalog_head_does_not_move_other_roles
    with_state do |dir, manifest|
      next_head = write_artifact(dir, "3.0", "head-v3")
      state = AfDataPipeline::ProjectState.new(manifest_path: manifest)

      state.promote!(role: "catalog_head", artifact_path: next_head, version: "3.0")

      reloaded = AfDataPipeline::ProjectState.new(manifest_path: manifest)
      assert_equal "3.0", reloaded.resolve("catalog_head").version
      assert_equal "1.0", reloaded.resolve("matcher_authorized_baseline").version
      assert_equal "1.0", reloaded.resolve("production_dependency_floor").version
    end
  end

  def test_non_head_roles_cannot_advance_beyond_catalog_head
    with_state do |dir, manifest|
      artifact = write_artifact(dir, "3.0", "future-role")
      state = AfDataPipeline::ProjectState.new(manifest_path: manifest)

      %w[matcher_authorized_baseline production_dependency_floor].each do |role|
        error = assert_raises(AfDataPipeline::Error) do
          state.promote!(role: role, artifact_path: artifact, version: "3.0")
        end
        assert_includes error.message, "#{role} 3.0 cannot be newer than catalog_head 2.0"
      end
    end
  end

  def test_role_cannot_move_backward
    with_state do |dir, manifest|
      old = write_artifact(dir, "0.9", "old")
      state = AfDataPipeline::ProjectState.new(manifest_path: manifest)

      error = assert_raises(AfDataPipeline::Error) do
        state.promote!(role: "production_dependency_floor", artifact_path: old, version: "0.9")
      end
      assert_includes error.message, "production_dependency_floor cannot move backward"
    end
  end

  private

  def with_state
    Dir.mktmpdir do |dir|
      head = write_artifact(dir, "2.0", "head-v2")
      baseline = write_artifact(dir, "1.0", "baseline-v1")
      manifest = File.join(dir, "PROJECT_STATE.yml")
      File.write(
        manifest,
        {
          "schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
          "catalog_head" => role_entry(head, "2.0"),
          "matcher_authorized_baseline" => role_entry(baseline, "1.0"),
          "production_dependency_floor" => role_entry(baseline, "1.0")
        }.to_yaml
      )
      yield dir, manifest
    end
  end

  def write_artifact(dir, version, content)
    path = File.join(dir, "5e_Adventure_Master_Catalog_#{version}.xlsx")
    File.write(path, content)
    path
  end

  def role_entry(path, version)
    {
      "version" => version,
      "filename" => File.basename(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end
end
