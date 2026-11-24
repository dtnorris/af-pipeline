# frozen_string_literal: true
require_relative "test_helper"
require "stringio"

class EvidenceBundleBuilderTest < Minitest::Test
  class CaptureCompressor
    attr_reader :tar_bytes

    def compress!(source_path:, output_path:)
      @tar_bytes = File.binread(source_path)
      File.binwrite(output_path, "fixture-zstd\0" + Digest::SHA256.digest(@tar_bytes))
    end
  end

  def test_builds_deterministic_normalized_tar_from_canonical_inventory
    Dir.mktmpdir("evidence-bundle-test") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "z-last.txt", "last\n", mode: 0o755)
      write_file(root, "nested/request.json", "{\"request\":true}\n", mode: 0o600)
      write_file(root, "nested/empty.log", "")
      write_file(root, "nested/._request.json", "appledouble")
      write_file(root, ".DS_Store", "finder")
      before = source_state(root)
      inventory = AfDataPipeline::EvidenceManifestBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-fixture"
      ).member_inventory

      first_compressor = CaptureCompressor.new
      first = AfDataPipeline::EvidenceBundleBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-fixture",
        compressor: first_compressor
      ).build!(output_path: File.join(workspace, "first.tar.zst"), members: inventory)

      second_compressor = CaptureCompressor.new
      second = AfDataPipeline::EvidenceBundleBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-fixture",
        compressor: second_compressor
      ).build!(output_path: File.join(workspace, "second.tar.zst"), members: inventory)

      assert_equal first_compressor.tar_bytes, second_compressor.tar_bytes
      assert_equal File.binread(first.path), File.binread(second.path)
      assert_equal before, source_state(root)
      assert_equal "tar+zstd", first.bundle.fetch("format")
      assert_equal "af-evidence-bundle/tar-zstd-v0.1", first.bundle.fetch("profile_version")
      assert_equal File.size(first.path), first.bundle.fetch("byte_size")
      assert_equal Digest::SHA256.file(first.path).hexdigest, first.bundle.fetch("sha256")

      entries = tar_entries(first_compressor.tar_bytes)
      assert_equal ["nested/empty.log", "nested/request.json", "z-last.txt"], entries.map { |entry| entry.fetch(:name) }
      entries.each do |entry|
        assert_equal 0o644, entry.fetch(:mode)
        assert_equal 0, entry.fetch(:uid)
        assert_equal 0, entry.fetch(:gid)
        assert_equal 0, entry.fetch(:mtime)
        assert_equal "", entry.fetch(:uname)
        assert_equal "", entry.fetch(:gname)
      end
      request = entries.find { |entry| entry.fetch(:name) == "nested/request.json" }
      assert_equal "{\"request\":true}\n", request.fetch(:contents)
    end
  end

  def test_rejects_source_drift_after_inventory_without_leaving_bundle
    Dir.mktmpdir("evidence-bundle-drift") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "result.json", "before\n")
      manifest_builder = AfDataPipeline::EvidenceManifestBuilder.new(batch_root: root, batch_id: "prod-batch-fixture")
      inventory = manifest_builder.member_inventory
      File.binwrite(File.join(root, "result.json"), "after\n")
      output = File.join(workspace, "bundle.tar.zst")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceBundleBuilder.new(
          batch_root: root,
          batch_id: "prod-batch-fixture",
          compressor: CaptureCompressor.new
        ).build!(output_path: output, members: inventory)
      end
      assert_match(/changed after inventory/, error.message)
      refute File.exist?(output)
    end
  end

  def test_refuses_output_inside_source_or_overwrite
    Dir.mktmpdir("evidence-bundle-output") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "result.json", "{}\n")
      builder = AfDataPipeline::EvidenceBundleBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-fixture",
        compressor: CaptureCompressor.new
      )

      inside = File.join(root, "bundle.tar.zst")
      error = assert_raises(AfDataPipeline::ValidationError) { builder.build!(output_path: inside) }
      assert_match(/outside the source batch/, error.message)

      output = File.join(workspace, "bundle.tar.zst")
      File.binwrite(output, "keep me")
      error = assert_raises(AfDataPipeline::ValidationError) { builder.build!(output_path: output) }
      assert_match(/already exists/, error.message)
      assert_equal "keep me", File.binread(output)
    end
  end

  def test_manifest_builder_can_use_exact_inventory_that_was_bundled
    Dir.mktmpdir("evidence-bundle-manifest") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "experiment.yml", "name: fixture\n")
      manifest_builder = AfDataPipeline::EvidenceManifestBuilder.new(batch_root: root, batch_id: "prod-batch-fixture")
      inventory = manifest_builder.member_inventory
      result = AfDataPipeline::EvidenceBundleBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-fixture",
        compressor: CaptureCompressor.new
      ).build!(output_path: File.join(workspace, "bundle.tar.zst"), members: inventory)

      manifest = manifest_builder.build(bundle: result.bundle, members: result.members)
      assert_equal inventory, manifest.fetch("members")
      assert_equal 1, manifest.fetch("member_count")
      assert_equal result.bundle, manifest.fetch("bundle")
    end
  end

  def test_default_zstd_compressor_produces_readable_zstd_when_available
    skip "zstd executable not available" unless system("zstd", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir("evidence-bundle-zstd") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "result.json", "{\"ok\":true}\n")
      result = AfDataPipeline::EvidenceBundleBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-fixture"
      ).build!(output_path: File.join(workspace, "bundle.tar.zst"))

      tar_bytes, stderr, status = Open3.capture3("zstd", "-q", "-d", "-c", result.path)
      assert status.success?, stderr
      entries = tar_entries(tar_bytes)
      assert_equal ["result.json"], entries.map { |entry| entry.fetch(:name) }
      assert_equal "{\"ok\":true}\n", entries.first.fetch(:contents)
    end
  end

  def test_zstd_compressor_fails_closed_when_executable_is_missing
    compressor = AfDataPipeline::EvidenceBundleBuilder::ZstdCompressor.new(command: "/definitely/missing/zstd")
    Dir.mktmpdir("missing-zstd") do |workspace|
      source = File.join(workspace, "source.tar")
      output = File.join(workspace, "output.tar.zst")
      File.binwrite(source, "tar bytes")
      error = assert_raises(AfDataPipeline::ValidationError) do
        compressor.compress!(source_path: source, output_path: output)
      end
      assert_match(/zstd compressor not found/, error.message)
    end
  end

  private

  def write_file(root, relative, contents, mode: 0o644)
    path = File.join(root, *relative.split("/"))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
    File.chmod(mode, path)
  end

  def source_state(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) }
      .sort
      .map do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        [relative, File.size(path), Digest::SHA256.file(path).hexdigest, File.stat(path).mode & 0o777]
      end
  end

  def tar_entries(bytes)
    entries = []
    Gem::Package::TarReader.new(StringIO.new(bytes)) do |tar|
      tar.each do |entry|
        entries << {
          name: entry.full_name,
          mode: entry.header.mode,
          uid: entry.header.uid,
          gid: entry.header.gid,
          mtime: entry.header.mtime,
          uname: entry.header.uname,
          gname: entry.header.gname,
          contents: entry.read
        }
      end
    end
    entries
  end
end
