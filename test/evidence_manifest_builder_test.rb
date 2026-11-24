# frozen_string_literal: true
require_relative "test_helper"

class EvidenceManifestBuilderTest < Minitest::Test
  BUNDLE = {
    "filename" => "prod-batch-fixture.tar.gz",
    "format" => "tar+gzip",
    "profile_version" => "fixture-only/v0.1",
    "byte_size" => 1234,
    "sha256" => "a" * 64
  }.freeze

  def test_member_inventory_is_deterministic_complete_and_read_only
    with_batch do |root|
      write_file(root, "z-last.txt", "last\n")
      write_file(root, "nested/request.json", "{\"request\":true}\n")
      write_file(root, "nested/empty.log", "")
      write_file(root, ".hidden-evidence", "hidden\n")
      write_file(root, "nested/._request.json", "appledouble")
      write_file(root, "nested/.DS_Store", "finder metadata")
      write_file(root, "__MACOSX/nested/._request.json", "resource fork")
      before = source_state(root)

      builder = AfDataPipeline::EvidenceManifestBuilder.new(batch_root: root, batch_id: "prod-batch-fixture")
      first = builder.member_inventory
      second = builder.member_inventory

      assert_equal first, second
      assert_equal [
        ".hidden-evidence",
        "nested/empty.log",
        "nested/request.json",
        "z-last.txt"
      ], first.map { |member| member.fetch("path") }
      assert_equal source_state(root), before

      request = first.find { |member| member.fetch("path") == "nested/request.json" }
      request_path = File.join(root, "nested", "request.json")
      assert_equal File.binread(request_path).bytesize, request.fetch("byte_size")
      assert_equal Digest::SHA256.file(request_path).hexdigest, request.fetch("sha256")

      empty = first.find { |member| member.fetch("path") == "nested/empty.log" }
      assert_equal 0, empty.fetch("byte_size")
      assert_equal Digest::SHA256.hexdigest(""), empty.fetch("sha256")
    end
  end

  def test_build_emits_schema_shaped_manifest_from_explicit_bundle_metadata
    with_batch do |root|
      write_file(root, "experiment.yml", "name: fixture\n")
      write_file(root, "runs/abc/metadata.json", "{}\n")

      manifest = AfDataPipeline::EvidenceManifestBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-029-fixture"
      ).build(bundle: BUNDLE)

      assert_equal "af-evidence-manifest/v0.1", manifest.fetch("schema_version")
      assert_equal "prod-batch-029-fixture", manifest.fetch("batch_id")
      assert_equal BUNDLE, manifest.fetch("bundle")
      assert_equal manifest.fetch("members").length, manifest.fetch("member_count")
      assert_equal %w[experiment.yml runs/abc/metadata.json], manifest.fetch("members").map { |item| item.fetch("path") }
    end
  end

  def test_write_refuses_to_mutate_source_or_overwrite_existing_manifest
    Dir.mktmpdir("evidence-manifest-test") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "result.json", "{}\n")
      builder = AfDataPipeline::EvidenceManifestBuilder.new(batch_root: root, batch_id: "prod-batch-fixture")

      inside = File.join(root, "manifest.json")
      error = assert_raises(AfDataPipeline::ValidationError) do
        builder.write!(output_path: inside, bundle: BUNDLE)
      end
      assert_match(/outside the source batch/, error.message)
      refute File.exist?(inside)

      output = File.join(workspace, "output", "manifest.json")
      before = source_state(root)
      manifest = builder.write!(output_path: output, bundle: BUNDLE)
      assert_equal before, source_state(root)
      assert_equal manifest, JSON.parse(File.read(output))

      error = assert_raises(AfDataPipeline::ValidationError) do
        builder.write!(output_path: output, bundle: BUNDLE)
      end
      assert_match(/already exists/, error.message)
    end
  end

  def test_rejects_symlink_members_and_empty_batches
    with_batch do |root|
      target = File.join(root, "target.txt")
      File.write(target, "target\n")
      File.symlink(target, File.join(root, "link.txt"))

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceManifestBuilder.new(batch_root: root, batch_id: "prod-batch-fixture").member_inventory
      end
      assert_match(/may not be a symlink/, error.message)
    end

    with_batch do |root|
      real_dir = File.join(root, "real")
      FileUtils.mkdir_p(real_dir)
      File.write(File.join(real_dir, "result.json"), "{}\n")
      File.symlink(real_dir, File.join(root, "linked-dir"))

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceManifestBuilder.new(batch_root: root, batch_id: "prod-batch-fixture").member_inventory
      end
      assert_match(/may not be a symlink/, error.message)
    end

    with_batch do |root|
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceManifestBuilder.new(batch_root: root, batch_id: "prod-batch-fixture").member_inventory
      end
      assert_match(/no canonical evidence files/, error.message)
    end
  end

  private

  def with_batch
    Dir.mktmpdir("evidence-manifest-batch") do |root|
      yield root
    end
  end

  def write_file(root, relative, contents)
    path = File.join(root, *relative.split("/"))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
  end

  def source_state(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) || File.symlink?(path) }
      .sort
      .map do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        if File.symlink?(path)
          [relative, :symlink, File.readlink(path)]
        else
          [relative, :file, File.size(path), Digest::SHA256.file(path).hexdigest]
        end
      end
  end
end
