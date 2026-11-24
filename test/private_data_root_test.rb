# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/staged_scoring_fixture"
require_relative "support/amc_fixture"
require "open3"
require "stringio"

# Disposable, invented source text plus the existing synthetic staged-authority
# fixture. No real editorial authorization or historical source data is used.
class PrivateDataRootTest < Minitest::Test
  include StagedScoringFixture
  include AmcFixture
  ROOTS = AfDataPipeline::PrivateDataRoot

  # Creates isolated input/data directories and saves the caller's selector.
  def setup
    @saved_selector = ENV[ROOTS::ENV_KEY]
    ENV.delete(ROOTS::ENV_KEY)
    @world = Dir.mktmpdir("private-data-root-", File.realpath(Dir.tmpdir))
    @data = File.join(@world, "private-data")
    @source = File.join(@world, "source")
    @catalog = File.join(@world, "catalog")
    FileUtils.mkdir_p([@data, @source, @catalog])
  end

  # Restores the environment and deletes only this test's disposable world.
  def teardown
    ENV.delete(ROOTS::ENV_KEY)
    ENV[ROOTS::ENV_KEY] = @saved_selector if @saved_selector
    FileUtils.remove_entry(@world)
  end

  # Proves real CLI execution, portable content bindings and fresh-process replay
  # after invalid selection, with no changes to executable inputs or output bytes.
  def test_source_transition_fails_before_placement_then_replays_in_fresh_process
    receipt, operation, canonical = source_inputs
    before = inventory(ROOTS::CODE_ROOT)
    arguments = ["bin/af-source-progress", receipt, "--operation-input", operation,
                 "--source-root", @source, "--catalog-root", @catalog,
                 "--canonical-destination", canonical, "--json"]
    _stdout, stderr, status = invoke(arguments, "")
    refute status.success?
    assert_includes stderr, "private data path is empty"
    refute File.exist?(canonical)
    assert_empty Dir.children(@data)

    stdout, stderr, status = invoke(arguments, @data)
    assert status.success?, stderr
    first = JSON.parse(stdout)
    assert_equal "SOURCE_INTAKE_READY", first.fetch("state")
    binding = first.fetch("outputs").find { |item| item["role"] == "operation_artifact" }.fetch("content")
    assert_equal "pipeline", binding.dig("locator", "root")
    output = File.join(@data, binding.dig("locator", "path"))
    assert_equal binding.fetch("sha256"), Digest::SHA256.file(output).hexdigest
    persisted = inventory(@data)
    stdout, stderr, status = invoke(arguments, @data)
    assert status.success?, stderr
    assert_equal first.fetch("outputs"), JSON.parse(stdout).fetch("outputs")
    assert_equal persisted, inventory(@data)
    assert_equal before, inventory(ROOTS::CODE_ROOT)

    original = File.binread(output)
    File.binwrite(output, original + "tampered")
    _stdout, _stderr, status = invoke(arguments, @data)
    refute status.success?
    assert_equal original + "tampered", File.binread(output)
    File.binwrite(output, original)
    _stdout, stderr, status = invoke(arguments, @data)
    assert status.success?, stderr
    assert_equal before, inventory(ROOTS::CODE_ROOT)
  end

  # Refuses each invalid root/selector before creating destination directories.
  def test_invalid_roots_and_conflicting_selectors_have_no_fallback
    assert_nil ROOTS.selected
    assert_equal ROOTS::CODE_ROOT, ROOTS.resolve
    assert_equal "output/scan", ROOTS.default_path("output/scan")
    alias_path = File.join(@world, "alias")
    File.symlink(@data, alias_path)
    readonly = File.join(@world, "readonly")
    Dir.mkdir(readonly, 0o500)
    invalid = ["", " ", "relative", File.join(@world, "missing"), readonly, alias_path,
               ROOTS::CODE_ROOT, File.join(ROOTS::CODE_ROOT, "lib"), File.dirname(ROOTS::CODE_ROOT),
               File.join(@data, "..", "private-data")]
    invalid.each do |root|
      ENV[ROOTS::ENV_KEY] = root
      assert_raises(AfDataPipeline::ValidationError, root.inspect) { ROOTS.selected }
    end
    ENV[ROOTS::ENV_KEY] = @data
    assert_equal @data, ROOTS.resolve(@data)
    assert_raises(AfDataPipeline::ValidationError) { ROOTS.resolve(ROOTS::CODE_ROOT) }
    assert_empty Dir.children(@data)
  ensure
    File.chmod(0o700, readonly) if readonly && File.directory?(readonly)
  end

  # Rejects output spelling and existing child links, including dangling links;
  # restoration permits the original safe output without changing code bytes.
  def test_destination_escape_and_unsafe_entries_are_rejected
    ENV[ROOTS::ENV_KEY] = @data
    outside = File.join(@world, "outside")
    Dir.mkdir(outside)
    File.symlink(outside, File.join(@data, "escape"))
    File.symlink(File.join(@world, "missing"), File.join(@data, "dangling"))
    paths = [outside, ROOTS::CODE_ROOT, "", File.join(@data, "..", "outside"),
             File.join(@data, "escape", "new.json"), File.join(@data, "dangling"), @data]
    paths.each do |path|
      assert_raises(AfDataPipeline::ValidationError, path) { ROOTS.destination!(path) }
    end
    assert_empty Dir.children(outside)
    File.unlink(File.join(@data, "escape"))
    File.unlink(File.join(@data, "dangling"))
    assert_equal File.join(@data, "new.json"), ROOTS.destination!(File.join(@data, "new.json"))
  end

  # Uses the real synthetic editorial and staging producers, then issues and
  # cold-validates an immutable authority under the selected private store.
  def test_authority_replay_and_editorial_publication_stay_in_selected_root
    evidence_root = File.join(@world, "synthetic-evidence")
    Dir.mkdir(evidence_root)
    evidence = build_authority_fixture(evidence_root, cache_namespace: :private_root)
    state = File.join(evidence_root, "PROJECT_STATE.yml")
    protected = inventory(evidence_root)
    ENV[ROOTS::ENV_KEY] = @data
    bundle = File.join(@data, "editorial")
    result = AfDataPipeline::BoundaryEditorial.init!(dossier_path: evidence.fetch(:dossier_path), output_dir: bundle)
    assert_empty result.decisions.fetch("candidates")
    store = File.join(@data, "authority")
    service = AUTH.new(evidence:, store_root: store, mode: "synthetic")
    issued = service.issue!(current_state_path: state)
    refute issued.fetch("execution_authorized")
    refute issued.fetch("catalog_adoption_authorized")
    envelope = File.join(@world, "inputs.json")
    write_json(envelope, {"schema_version" => "af-staged-scoring-evidence-locators/v0.1", "evidence" => evidence})
    persisted = inventory(@data)
    stdout, stderr, status = invoke(["bin/af-staged-scoring-authority", "validate", "--inputs", envelope,
                                    "--store", store, "--project-state", state, "--synthetic"], @data)
    assert status.success?, stderr
    assert_equal issued, JSON.parse(stdout)
    assert_equal persisted, inventory(@data)
    assert_equal protected, inventory(evidence_root)

    other = File.join(@world, "other-private-data")
    Dir.mkdir(other)
    ENV[ROOTS::ENV_KEY] = other
    assert_raises(AfDataPipeline::ValidationError) { service.issue!(current_state_path: state) }
    assert_empty Dir.children(other)
    ENV[ROOTS::ENV_KEY] = @data
    approval = evidence.fetch(:approval_path)
    original = File.binread(approval)
    File.unlink(approval)
    assert_raises(AfDataPipeline::ValidationError) { service.issue!(current_state_path: state) }
    assert_equal persisted, inventory(@data)
    File.binwrite(approval, original)
    assert_equal issued, service.validate!(current_state_path: state)
  end

  # Exercises default review output and retained-state readers, including stale
  # root bindings. Canonical component discovery stays tied to executable code.
  def test_review_defaults_and_router_data_resolution
    ENV[ROOTS::ENV_KEY] = @data
    source = File.join(@source, "empty.json")
    File.write(source, "{}")
    stdout, stderr, status = invoke(["bin/af-data", "scan", source], @data)
    assert status.success?, stderr
    assert_includes stdout, File.join(@data, "output", "scan")
    assert File.file?(File.join(@data, "output", "scan", "inventory.jsonl"))
    router = AfDataPipeline::IngestNext.new
    assert_equal File.join(@data, "audits", "pre-scoring", "unit-boundary-dossier"), router.send(:dossier_output_dir, "Unit")
  end

  private

  def inventory(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      next if File.directory?(path)
      raise "unexpected fixture link: #{path}" if File.symlink?(path)

      [path.delete_prefix(root + "/"), [File.stat(path).mode & 0o777, Digest::SHA256.file(path).hexdigest]]
    end.to_h
  end

  # Executes the actual code-root CLI with a per-process selector. Returns raw
  # stdout/stderr and Process::Status; process-launch errors propagate.
  def invoke(arguments, selector)
    Open3.capture3({ROOTS::ENV_KEY => selector}, RbConfig.ruby, *arguments, chdir: ROOTS::CODE_ROOT, binmode: true)
  end

  # Builds a minimal independently invented conversion/routing input. The first
  # transition needs only the catalog's exact byte identity, never workbook data.
  def source_inputs
    markdown = File.join(@world, "converted.md")
    File.write(markdown, "<!-- Printed Page 1 -->\n# Invented Root Boundary Fixture\n")
    File.write(File.join(@source, "source_registry.yml"), YAML.dump(
      "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION, "sources" => {}))
    base = File.join(@catalog, "5e_Adventure_Master_Catalog_0.1.xlsx")
    File.binwrite(base, "invented catalog identity; no workbook is opened")
    role = {"version" => "0.1", "filename" => File.basename(base), **AUTH.file_binding(base)}
    state = File.join(@catalog, "PROJECT_STATE.yml")
    File.write(state, YAML.dump("schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
                              "catalog_head" => role, "matcher_authorized_baseline" => role, "production_dependency_floor" => role))
    receipt = File.join(@world, "receipt.json")
    write_json(receipt, {"schema" => AfDataPipeline::IngestNext::CONVERSION_RECEIPT_SCHEMA, "state" => "ready", "downstream_ready" => true,
                         "source" => {"path" => File.join(@world, "invented.pdf")},
                         "output" => {"path" => markdown, "sha256" => Digest::SHA256.file(markdown).hexdigest}})
    operation = File.join(@world, "operation.json")
    write_json(operation, {"schema_version" => "af-ingest-routing-input/v0.1",
                           "operation" => {"contract_version" => "adventurefinder-ingest-operation/v0.1",
                                           "operation_id" => "11111111-1111-4111-8111-111111111111", "revision" => 1, "document_sha256" => "a" * 64},
                           "artifact" => {"kind" => "file", **AUTH.file_binding(receipt)},
                           "source" => {"source_id" => "Invented Root Fixture", "canonical_markdown" => nil,
                                        "edition" => "invented", "pagination_authority" => "printed labels", "publisher" => "Invented Press"},
                           "base_catalog" => role.except("version").merge("selection_method" => "catalog_head", "project_state_sha256" => Digest::SHA256.file(state).hexdigest),
                           "policy" => nil})
    [receipt, operation, File.join(@source, "invented.md")]
  end
end
