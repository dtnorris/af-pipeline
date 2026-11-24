# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "digest"
require "fileutils"
require "open3"
require "pathname"
require "tempfile"
require "yaml"
require_relative "../lib/af_data_pipeline/error"
require_relative "../lib/af_data_pipeline/boundary_freeze"
require_relative "../lib/af_data_pipeline/source_intake"

# Exercises the registration owner with content-free sources and real validators.
class SourceRegisterEmptyRegistryTest < Minitest::Test
  HEADER = "schema_version: adventurefinder-source-registry/v0.1\n"
  MARKDOWN = "<!-- Printed Page 1 -->\n1\n<!-- Printed Page 2 -->\n2\n"

  # Verifies first/second insertion, exact hashes, explicit offsets and byte/mode
  # preservation for supported empty-map spellings; owner errors fail the test.
  def test_first_and_second_registration_preserve_bytes_modes_and_explicit_offsets
    [
      [HEADER + "sources: {}\n", nil, HEADER + "sources: \n"],
      ["# mechanical registry\n\n" + HEADER + "sources: {} # keep\n\n# tail", "+9",
        "# mechanical registry\n\n" + HEADER + "sources:  # keep\n\n# tail"],
      [HEADER + "sources: {}", "-2", HEADER + "sources: "],
      [HEADER + "sources:\t{ }\t# keep\n", nil, HEADER + "sources:\t\t# keep\n"],
      [(HEADER + "sources: {} # keep\n").gsub("\n", "\r\n"), nil,
        (HEADER + "sources:  # keep\n").gsub("\n", "\r\n")]
    ].each do |original, offset, expected_prefix|
      with_registry(original) do |root, markdown, registry|
        source_before = snapshot(markdown)
        result = AfDataPipeline::SourceRegister.register!(
          source_root: root, source_id: "Mechanical Source", markdown_path: markdown,
          page_marker_offset: offset
        )
        after = File.binread(registry)
        expected = {"file" => "Mechanical.md"}
        expected["page_marker_offset"] = offset if offset
        context = AfDataPipeline::BoundaryFreeze.registry_context(root, nil)
        assert_equal({"Mechanical Source" => expected}, context.fetch("sources"))
        assert after.start_with?(expected_prefix), after.inspect
        assert_equal ["Mechanical.md"], AfDataPipeline::BoundaryFreeze.normalize_registry_entry(
          "Mechanical Source", context.fetch("sources").fetch("Mechanical Source")
        ).fetch(:files)
        assert_equal Digest::SHA256.hexdigest(original), result.registry_sha256_before
        assert_equal Digest::SHA256.hexdigest(after), result.registry_sha256_after
        assert_equal offset, result.page_marker_offset unless offset.nil?
        assert_nil result.page_marker_offset if offset.nil?
        assert_equal 0o640, File.stat(registry).mode & 0o777
        assert_equal source_before, snapshot(markdown)

        second = File.join(root, "Second.md")
        File.binwrite(second, MARKDOWN)
        AfDataPipeline::SourceRegister.register!(
          source_root: root, source_id: "Second Mechanical Source", markdown_path: second
        )
        assert File.binread(registry).start_with?(after)
        assert_equal({"Mechanical Source" => expected, "Second Mechanical Source" => {"file" => "Second.md"}},
          AfDataPipeline::BoundaryFreeze.registry_context(root, nil).fetch("sources"))
        assert_equal source_before, snapshot(markdown)
        assert_equal MARKDOWN, File.binread(second)
        assert_empty Dir.glob(File.join(root, ".source-registry-*"))
      end
    end
  end

  # Keeps the existing populated-map append path byte-for-byte, without offsets.
  def test_populated_registry_keeps_existing_mapping_and_comments
    original = "# keep\n" + HEADER + "sources:\n  Existing Mechanical:\n    file: Existing.md\n# tail\n"
    with_registry(original) do |root, markdown, registry|
      File.binwrite(File.join(root, "Existing.md"), MARKDOWN)
      AfDataPipeline::SourceRegister.register!(
        source_root: root, source_id: "Mechanical Source", markdown_path: markdown
      )
      assert File.binread(registry).start_with?(original)
      assert_equal ["Existing Mechanical", "Mechanical Source"],
        AfDataPipeline::BoundaryFreeze.registry_context(root, nil).fetch("sources").keys
    end
  end

  # Real validation must refuse duplicates, missing files and invalid offsets
  # while preserving the last accepted registry and protected Markdown snapshot.
  def test_refusals_preserve_accepted_registry_and_source
    with_registry(HEADER + "sources: {}\n") do |root, markdown, registry|
      AfDataPipeline::SourceRegister.register!(
        source_root: root, source_id: "Mechanical Source", markdown_path: markdown
      )
      [
        ["Mechanical Source", markdown, nil, /already contains source identity/],
        ["Other Mechanical Source", markdown, nil, /already registered/],
        ["Missing Mechanical Source", File.join(root, "Missing.md"), nil, /Missing Markdown source/],
        ["Other Mechanical Source", markdown, "9", /explicitly signed integer/]
      ].each do |source_id, path, offset, message|
        before = [snapshot(registry), snapshot(markdown)]
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::SourceRegister.register!(
            source_root: root, source_id: source_id, markdown_path: path, page_marker_offset: offset
          )
        end
        assert_match message, error.message
        assert_equal before, [snapshot(registry), snapshot(markdown)]
        assert_empty Dir.glob(File.join(root, ".source-registry-*"))
      end
    end
  end

  # Unsupported serialization stays a safe refusal, rather than reserializing
  # YAML or discarding comments. Malformed/schema errors use the same validators.
  def test_invalid_or_unsupported_registry_preserves_inputs
    [
      [HEADER + "sources: [\n", /Invalid YAML/],
      ["schema_version: unsupported\nsources: {}\n", /Unsupported source registry schema/],
      [HEADER + "sources: []\n", /must be a mapping/],
      [HEADER + "\"sources\": {} # keep\n", /Invalid YAML/]
    ].each do |original, message|
      with_registry(original) do |root, markdown, registry|
        before = [snapshot(registry), snapshot(markdown)]
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::SourceRegister.register!(
            source_root: root, source_id: "Mechanical Source", markdown_path: markdown
          )
        end
        assert_match message, error.message
        assert_equal before, [snapshot(registry), snapshot(markdown)]
        assert_empty Dir.glob(File.join(root, ".source-registry-*"))
      end
    end
  end

  # Injects an intervening writer after real staged validation; a refused
  # publication must preserve its bytes/mode and leave its separate file alone.
  def test_prior_registry_change_is_preserved_and_only_owned_temp_is_cleaned
    with_registry(HEADER + "sources: {}\n") do |root, markdown, registry|
      peer = File.join(root, ".source-registry-peer.yml")
      File.binwrite(peer, "peer-owned temporary bytes\n")
      peer_before = snapshot(peer)
      source_before = snapshot(markdown)
      intervening = HEADER + "sources:\n  Other Mechanical:\n    file: Other.md\n# accepted by another writer\n"
      owner_registry = AfDataPipeline::SourceMarkdownOwner.load!(error_class: AfDataPipeline::ValidationError)::Registry
      validator = owner_registry.method(:registry_context)
      observing_validator = lambda do |source_root, path|
        context = validator.call(source_root, path)
        File.binwrite(registry, intervening) if path && File.basename(path).start_with?(".source-registry-")
        context
      end
      owner_registry.stub(:registry_context, observing_validator) do
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::SourceRegister.register!(
            source_root: root, source_id: "Mechanical Source", markdown_path: markdown
          )
        end
        assert_match(/source registry changed during source-register/, error.message)
      end
      assert_equal [intervening, 0o640], snapshot(registry)
      assert_equal source_before, snapshot(markdown)
      assert_equal peer_before, snapshot(peer)
      assert_equal [peer], Dir.glob(File.join(root, ".source-registry-*"))
    end
  end

  # Runs the public executable in separate processes for first registration and
  # duplicate refusal; missing library dependencies surface as test failures.
  def test_public_cli_registers_first_source_and_refuses_duplicate_without_mutation
    with_registry("# keep\n" + HEADER + "sources: {} # keep\n\n# tail") do |root, markdown, registry|
      before = snapshot(markdown)
      command = [RbConfig.ruby, File.expand_path("../bin/af-source-register", __dir__),
        markdown, "--source-root", root, "--source-id", "Mechanical Source", "--page-marker-offset", "-2"]
      stdout, stderr, status = Open3.capture3(*command)
      assert status.success?, stderr
      assert_includes stdout, "Source registration: PASS"
      assert_equal({"Mechanical Source" => {"file" => "Mechanical.md", "page_marker_offset" => "-2"}},
        AfDataPipeline::BoundaryFreeze.registry_context(root, nil).fetch("sources"))
      registered = snapshot(registry)
      stdout, stderr, status = Open3.capture3(*command)
      assert_equal 2, status.exitstatus
      assert_empty stdout
      assert_match(/already contains source identity/, stderr)
      assert_equal registered, snapshot(registry)
      assert_equal before, snapshot(markdown)
    end
  end

  # The real CLI must honor an explicit owner selection even when a valid owner
  # is ambient; refused selections preserve both registry and Markdown bytes.
  def test_public_cli_refuses_invalid_explicit_owner_without_ambient_fallback
    owner = AfDataPipeline::SourceMarkdownOwner.load!(error_class: AfDataPipeline::ValidationError)
    with_registry(HEADER + "sources: {}\n") do |root, markdown, registry|
      invalid = File.join(root, "invalid-owner")
      FileUtils.mkdir_p(File.join(invalid, "lib"))
      File.write(File.join(invalid, "lib", "af_source_md.rb"), "# unsupported owner\n")
      before = [snapshot(registry), snapshot(markdown)]
      command = [RbConfig.ruby, File.expand_path("../bin/af-source-register", __dir__),
        markdown, "--source-root", root, "--source-id", "Mechanical Source"]
      ["", File.join(root, "missing-owner"), invalid].each do |selection|
        stdout, stderr, status = Open3.capture3(
          {"AF_SOURCE_MD_ROOT" => selection, "RUBYLIB" => File.join(owner::ROOT, "lib")}, *command
        )
        assert_equal 2, status.exitstatus
        assert_empty stdout
        assert_match(/source Markdown owner|AF_SOURCE_MD_ROOT/, stderr)
        assert_equal before, [snapshot(registry), snapshot(markdown)]
      end
      stdout, stderr, status = Open3.capture3({"AF_SOURCE_MD_ROOT" => owner::ROOT}, *command)
      assert status.success?, stderr
      assert_includes stdout, "Source registration: PASS"
    end
  end

  private

  # Yields a new disposable root, mechanical Markdown and selected registry
  # bytes with a nondefault mode; normal filesystem errors propagate.
  def with_registry(original)
    Dir.mktmpdir("empty-source-register-") do |root|
      markdown = File.join(root, "Mechanical.md")
      registry = File.join(root, "source_registry.yml")
      File.binwrite(markdown, MARKDOWN)
      File.binwrite(registry, original)
      File.chmod(0o640, registry)
      yield root, markdown, registry
    end
  end

  # Returns independent exact bytes and permission bits for a protected file;
  # raises the normal filesystem error if that file unexpectedly disappears.
  def snapshot(path)
    [File.binread(path), File.stat(path).mode & 0o777]
  end
end
