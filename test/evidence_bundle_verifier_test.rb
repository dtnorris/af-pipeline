# frozen_string_literal: true
require_relative "test_helper"

class EvidenceBundleVerifierTest < Minitest::Test
  class PassthroughCompressor
    def compress!(source_path:, output_path:)
      FileUtils.cp(source_path, output_path)
    end
  end

  class PassthroughDecompressor
    def decompress!(bundle_path:, output_path:)
      FileUtils.cp(bundle_path, output_path)
    end
  end

  def test_verifies_bundle_manifest_round_trip_and_expanded_source_without_mutation
    Dir.mktmpdir("evidence-verify-test") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "experiment.yml", "name: fixture\n")
      write_file(root, "runs/abc/metadata.json", "{\"status\":\"complete\"}\n")
      write_file(root, "runs/abc/stderr.log", "")
      write_file(root, "runs/abc/._metadata.json", "appledouble")
      write_file(root, ".DS_Store", "finder")
      before = source_state(root)

      manifest_path, bundle_path = build_fixture_artifacts(workspace, root)
      result = AfDataPipeline::EvidenceBundleVerifier.new(
        decompressor: PassthroughDecompressor.new
      ).verify!(manifest_path:, bundle_path:, source_root: root)

      assert_equal "prod-batch-fixture", result.batch_id
      assert_equal 3, result.member_count
      assert_equal Digest::SHA256.file(bundle_path).hexdigest, result.bundle_sha256
      assert result.source_verified
      assert_equal before, source_state(root)
    end
  end

  def test_rejects_bundle_bytes_that_do_not_match_manifest
    Dir.mktmpdir("evidence-verify-bundle-drift") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "result.json", "{}\n")
      manifest_path, bundle_path = build_fixture_artifacts(workspace, root)
      bytes = File.binread(bundle_path)
      bytes.setbyte(0, bytes.getbyte(0) ^ 0xff)
      File.binwrite(bundle_path, bytes)

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceBundleVerifier.new(
          decompressor: PassthroughDecompressor.new
        ).verify!(manifest_path:, bundle_path:)
      end
      assert_match(/bundle sha256 mismatch/, error.message)
    end
  end

  def test_rejects_undeclared_archive_member
    Dir.mktmpdir("evidence-verify-extra-member") do |workspace|
      bundle_path = File.join(workspace, "prod-batch-fixture.tar.zst")
      write_tar(bundle_path, [["result.json", "{}\n"], ["extra.txt", "extra\n"]])
      manifest_path = write_manifest(
        workspace,
        bundle_path,
        [["declared.txt", "extra\n"], ["result.json", "{}\n"]]
      )

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceBundleVerifier.new(
          decompressor: PassthroughDecompressor.new
        ).verify!(manifest_path:, bundle_path:)
      end
      assert_match(/undeclared member "extra.txt"/, error.message)
    end
  end

  def test_rejects_source_tree_that_no_longer_matches_manifest
    Dir.mktmpdir("evidence-verify-source-drift") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "result.json", "before\n")
      manifest_path, bundle_path = build_fixture_artifacts(workspace, root)
      File.binwrite(File.join(root, "result.json"), "after\n")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceBundleVerifier.new(
          decompressor: PassthroughDecompressor.new
        ).verify!(manifest_path:, bundle_path:, source_root: root)
      end
      assert_match(/source member .* mismatch/, error.message)
    end
  end

  def test_rejects_noncanonical_tar_metadata
    Dir.mktmpdir("evidence-verify-metadata") do |workspace|
      bundle_path = File.join(workspace, "prod-batch-fixture.tar.zst")
      contents = "{}\n"
      write_tar(bundle_path, [["result.json", contents]], mode: 0o600)
      manifest_path = write_manifest(workspace, bundle_path, [["result.json", contents]])

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceBundleVerifier.new(
          decompressor: PassthroughDecompressor.new
        ).verify!(manifest_path:, bundle_path:)
      end
      assert_match(/non-canonical tar metadata/, error.message)
    end
  end

  def test_default_zstd_decompressor_verifies_builder_output_when_available
    skip "zstd executable not available" unless system("zstd", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir("evidence-verify-zstd") do |workspace|
      root = File.join(workspace, "prod-batch-fixture")
      FileUtils.mkdir_p(root)
      write_file(root, "result.json", "{\"ok\":true}\n")
      manifest_builder = AfDataPipeline::EvidenceManifestBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-fixture"
      )
      inventory = manifest_builder.member_inventory
      bundle_result = AfDataPipeline::EvidenceBundleBuilder.new(
        batch_root: root,
        batch_id: "prod-batch-fixture"
      ).build!(output_path: File.join(workspace, "prod-batch-fixture.tar.zst"), members: inventory)
      manifest_path = File.join(workspace, "manifest.json")
      manifest_builder.write!(
        output_path: manifest_path,
        bundle: bundle_result.bundle,
        members: bundle_result.members
      )

      result = AfDataPipeline::EvidenceBundleVerifier.new.verify!(
        manifest_path:,
        bundle_path: bundle_result.path,
        source_root: root
      )
      assert_equal 1, result.member_count
      assert result.source_verified
    end
  end

  private

  def build_fixture_artifacts(workspace, root)
    manifest_builder = AfDataPipeline::EvidenceManifestBuilder.new(
      batch_root: root,
      batch_id: "prod-batch-fixture"
    )
    inventory = manifest_builder.member_inventory
    bundle_path = File.join(workspace, "prod-batch-fixture.tar.zst")
    bundle_result = AfDataPipeline::EvidenceBundleBuilder.new(
      batch_root: root,
      batch_id: "prod-batch-fixture",
      compressor: PassthroughCompressor.new
    ).build!(output_path: bundle_path, members: inventory)
    manifest_path = File.join(workspace, "manifest.json")
    manifest_builder.write!(
      output_path: manifest_path,
      bundle: bundle_result.bundle,
      members: bundle_result.members
    )
    [manifest_path, bundle_path]
  end

  def write_file(root, relative, contents)
    path = File.join(root, *relative.split("/"))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
  end

  def write_tar(path, members, mode: AfDataPipeline::EvidenceBundleBuilder::TAR_MODE)
    File.open(path, "wb") do |io|
      members.each do |name, contents|
        header = Gem::Package::TarHeader.new(
          name: name,
          prefix: "",
          mode: mode,
          uid: 0,
          gid: 0,
          size: contents.bytesize,
          mtime: 0,
          typeflag: "0",
          uname: "",
          gname: ""
        )
        io.write(header.to_s)
        io.write(contents)
        io.write("\0" * ((512 - (contents.bytesize % 512)) % 512))
      end
      io.write("\0" * 1024)
    end
  end

  def write_manifest(workspace, bundle_path, members)
    manifest = {
      "schema_version" => "af-evidence-manifest/v0.1",
      "batch_id" => "prod-batch-fixture",
      "bundle" => {
        "filename" => File.basename(bundle_path),
        "format" => AfDataPipeline::EvidenceBundleBuilder::FORMAT,
        "profile_version" => AfDataPipeline::EvidenceBundleBuilder::PROFILE_VERSION,
        "byte_size" => File.size(bundle_path),
        "sha256" => Digest::SHA256.file(bundle_path).hexdigest
      },
      "member_count" => members.length,
      "members" => members.map do |name, contents|
        {
          "path" => name,
          "byte_size" => contents.bytesize,
          "sha256" => Digest::SHA256.hexdigest(contents)
        }
      end
    }
    path = File.join(workspace, "manifest.json")
    File.write(path, JSON.pretty_generate(manifest) + "\n")
    path
  end

  def source_state(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) }
      .sort
      .map do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        [relative, File.size(path), Digest::SHA256.file(path).hexdigest]
      end
  end
end
