# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../../lib/af_data_pipeline/error"
require_relative "../../lib/af_data_pipeline/boundary_freeze"
require_relative "../../lib/af_data_pipeline/evidence_bundle_builder"

# Drives the real public CLI, selected owner, and prior freeze validator in a disposable store.
class ApprovedSourceOperationTest < Minitest::Test
  REGISTER = File.expand_path("../../bin/af-source-register", __dir__)
  D02 = "<!-- Printed Page 1 -->\nα\n<!-- Printed Page 2 -->\nΩ\n"
  D02_SHA256 = "b71d7a597ee169616c05015d7836d7252fc87d6ca1bb24df92009bc8c0bc979f"

  # Creates a content-free store and explicitly selects the owner; setup failures fail the test.
  def setup
    @scratch = File.realpath(Dir.mktmpdir("approved-source-operation-"))
    @root = File.join(@scratch, "store")
    Dir.mkdir(@root)
    @registry = File.join(@root, "source_registry.yml")
    write_file(@registry, "# preserved\nschema_version: adventurefinder-source-registry/v0.1\nsources: {} # preserved\n", 0o640)
    @owner_root = ENV.fetch("AF_SOURCE_MD_ROOT")
  end

  # Disposes only the test's own content-free files.
  def teardown
    FileUtils.remove_entry(@scratch) if @scratch
  end

  # Proves legacy registration, approved registration and correction, and a fresh-process retry.
  def test_public_registration_correction_and_cold_recovery
    first, second = %w[first second].map do |name|
      path = write_file(File.join(@root, "#{name}.md"), D02)
      stdout = cli_pass(path, "--source-root", @root, "--source-id", name)
      assert_includes stdout, Digest::SHA256.file(@registry).hexdigest
      snapshot(path)
    end
    assert_equal({"first" => {"file" => "first.md"}, "second" => {"file" => "second.md"}}, sources(@registry))
    assert_match(/\A# preserved.*# preserved/m, File.binread(@registry))
    assert_equal 0o640, File.stat(@registry).mode & 0o777
    assert_equal first, snapshot(File.join(@root, "first.md"))
    assert_equal second, snapshot(File.join(@root, "second.md"))

    accepted_registry = snapshot(@registry)
    registration = intent("register", "third", prior_registry: File.basename(@registry))
    registration_decision = decide(registration)
    registered = JSON.parse(cli_pass("apply-approved", registration, "--decision", registration_decision))
    assert_equal "operator", registered.dig("decision", "decided_by")
    assert_equal "af-source-md-operation/v0.1", registered.dig("owner", "api_version")
    assert_equal File.realpath(@owner_root), registered.dig("owner", "root")
    owner_file = "lib/af_source_md/source_operation.rb"
    assert_equal Digest::SHA256.file(File.join(@owner_root, owner_file)).hexdigest, registered.dig("owner", "files", owner_file)
    assert_equal accepted_registry.fetch("sha256"), registered.dig("prior_registry", "sha256")
    assert_equal accepted_registry, snapshot(@registry)
    published_registry = registered.dig("registry", "path")
    assert_equal "first.md", sources(published_registry).dig("first", "file")
    assert_equal "third.md", sources(published_registry).dig("third", "file")
    check_result(registered)

    freeze, base = freeze_first_source(published_registry)
    evidence = build_evidence
    evidence_before = AfEvidence::EvidenceBundleVerifier.new.verify!(**evidence)
    assert evidence_before.source_verified
    evidence_paths = evidence.values_at(:manifest_path, :bundle_path)
    prior_paths = [@registry, published_registry, freeze, base, *evidence_paths, File.join(@root, "first.md"),
                   File.join(@root, "second.md"), File.join(@root, "third.md"), registration_decision]
    prior = prior_paths.map { |path| snapshot(path) }
    correction = intent("correct", "first-revision-2", prior_registry: File.basename(published_registry),
                        extra: {"prior_source_id" => "first", "prior_freeze_path" => freeze, "base_amc_path" => base})
    decision = decide(correction)
    correction_data = JSON.parse(File.binread(correction))
    pending_registry = File.join(@root, correction_data.fetch("registry"))
    pending_file = File.join(@root, correction_data.fetch("destination"))
    journal = "#{pending_registry}.source-operation.json"
    trace = write_file(File.join(@scratch, "stop_before_registry.rb"), <<~RUBY)
      TracePoint.new(:call) do |event|
        next unless event.method_id == :publish_file! && event.path.end_with?("/af_source_md/source_operation.rb")
        next unless event.binding.local_variable_get(:target).fetch("path") == ENV.fetch("STOP_BEFORE_REGISTRY")
        unavailable = system(RbConfig.ruby, "-e",
          'File.open(ARGV.fetch(0)) { |root| exit(root.flock(File::LOCK_EX | File::LOCK_NB) ? 1 : 0) }',
          ENV.fetch("LOCKED_STORE_ROOT"))
        exit! 75 unless unavailable
        exit! 74
      end.enable
    RUBY
    _, stderr, status = invoke("apply-approved", correction, "--decision", decision,
                               env: {"STOP_BEFORE_REGISTRY" => pending_registry, "LOCKED_STORE_ROOT" => @root},
                               preload: trace)
    assert_equal 74, status.exitstatus, stderr
    refute File.exist?(pending_registry)
    assert File.file?(journal)
    placed = snapshot(pending_file)
    pending = store_snapshot

    receipt = correction_data.fetch("conversion_receipt_path")
    receipt_bytes = File.binread(receipt)
    File.write(receipt, receipt_bytes + "\n")
    refusal(/stale source operation decision/i, "apply-approved", correction, "--decision", decision)
    assert_equal pending, store_snapshot
    File.binwrite(receipt, receipt_bytes)
    prior_source = File.join(@root, "first.md")
    File.chmod(0o640, prior_source)
    changed_prior = store_snapshot
    refusal(/stale source operation decision/i, "apply-approved", correction, "--decision", decision)
    assert_equal changed_prior, store_snapshot
    File.chmod(first.fetch("mode"), prior_source)
    alternate = decide(correction, name: "alternate", actor: "another operator")
    refusal(/operation record does not match/i, "apply-approved", correction, "--decision", alternate)
    assert_equal pending, store_snapshot

    recovered = JSON.parse(cli_pass("apply-approved", correction, "--decision", decision))
    refute recovered.fetch("reused")
    assert_equal placed, snapshot(pending_file)
    assert_equal pending.fetch(journal), snapshot(journal)
    assert_equal prior, prior_paths.map { |path| snapshot(path) }
    assert_equal [first.fetch("sha256")], recovered.fetch("prior_sources").map { |file| file.fetch("sha256") }
    assert_equal "first.md", sources(pending_registry).dig("first", "file")
    assert_equal "first-revision-2.md", sources(pending_registry).dig("first-revision-2", "file")
    check_result(recovered)

    final = store_snapshot
    replay = JSON.parse(cli_pass("apply-approved", correction, "--decision", decision))
    assert_equal recovered.merge("reused" => true), replay
    assert_equal final, store_snapshot
    assert_equal evidence_before, AfEvidence::EvidenceBundleVerifier.new.verify!(**evidence)
    normalize = AfDataPipeline::BoundaryFreeze.validate!(freeze_path: freeze, source_root: @root,
                                                         amc_path: base, registry_path: published_registry)
    assert_equal "first", normalize.artifact.dig("source", "canonical_source_id")
    assert_raises(AfDataPipeline::ValidationError) do
      AfDataPipeline::BoundaryFreeze.validate!(freeze_path: freeze, source_root: @root,
                                              amc_path: base, registry_path: pending_registry)
    end
    owner_read = [RbConfig.ruby, "-I", File.join(@owner_root, "lib"), "-raf_source_md", "-e", <<~RUBY]
      request = Data.define(:source_book, :start_page, :end_page).new("first", 1, 2)
      found = AFSourceMD::SourceResolver.new(source_root: ARGV[0], registry_path: ARGV[1]).resolve(request)
      abort "expected explicit mapping" unless found.strategy == "explicit_mapping"
      STDOUT.binmode
      STDOUT.write(AFSourceMD::SourceDocument.new(found.path).extract(start_page: 1, end_page: 2).text)
    RUBY
    output, errors, result = Open3.capture3(*owner_read, @root, published_registry, binmode: true)
    assert result.success?, errors
    assert_equal 54, output.bytesize
    assert_equal D02_SHA256, Digest::SHA256.hexdigest(output)
  end

  # Verifies refused writes leave bytes and modes intact, then proves exact restoration succeeds.
  def test_approval_prior_state_destination_and_owner_refusals
    initial = store_snapshot
    operation = intent("register", "guarded", prior_registry: File.basename(@registry))
    decision_path = File.join(@scratch, "missing.json")
    refusal(/decision is missing/i, "apply-approved", operation, "--decision", decision_path)
    declined = decide(operation, name: "declined", disposition: "declined")
    refusal(/was declined/i, "apply-approved", operation, "--decision", declined)
    decision = decide(operation)
    assert_equal initial, store_snapshot

    refusal(/require explicit AF_SOURCE_MD_ROOT/, "apply-approved", operation, "--decision", decision,
            env: {"AF_SOURCE_MD_ROOT" => nil})
    refusal(/Cannot load source Markdown owner/, "apply-approved", operation, "--decision", decision,
            env: {"AF_SOURCE_MD_ROOT" => File.join(@scratch, "invalid-owner")})
    assert_equal initial, store_snapshot
    document = JSON.parse(File.binread(operation))
    original = File.binread(operation)
    File.write(operation, JSON.generate(document.merge("revision" => 2)))
    refusal(/stale source operation decision/i, "apply-approved", operation, "--decision", decision)
    File.binwrite(operation, original)
    candidate = document.fetch("candidate_path")
    original_candidate = File.binread(candidate)
    File.write(candidate, "changed\n")
    refusal(/output SHA-256 does not match/i, "apply-approved", operation, "--decision", decision)
    File.binwrite(candidate, original_candidate)
    assert_equal initial, store_snapshot

    competing = write_file(File.join(@root, "competing.md"), "competing\n")
    prior_bytes = File.binread(@registry)
    cli_pass(competing, "--source-root", @root, "--source-id", "competing")
    winner = store_snapshot
    refusal(/stale source operation decision/i, "apply-approved", operation, "--decision", decision)
    assert_equal winner, store_snapshot
    assert_equal "competing.md", sources(@registry).dig("competing", "file")
    File.binwrite(@registry, prior_bytes)
    File.unlink(competing)

    registry_path = write_file(File.join(@root, document.fetch("registry")), "conflicting registry\n", 0o640)
    conflict = store_snapshot
    refusal(/conflicting or incomplete published registry/i, "apply-approved", operation, "--decision", decision)
    assert_equal conflict, store_snapshot
    File.unlink(registry_path)
    destination = write_file(File.join(@root, document.fetch("destination")), "conflict\n", 0o640)
    conflict = store_snapshot
    refusal(/conflicting Markdown destination/i, "apply-approved", operation, "--decision", decision)
    assert_equal conflict, store_snapshot
    File.binwrite(destination, original_candidate)
    exact_existing = snapshot(destination)
    output = JSON.parse(cli_pass("apply-approved", operation, "--decision", decision))
    assert_equal exact_existing, snapshot(destination)
    assert_equal 0o640, output.dig("source", "mode")
    check_result(output)
  end

  private

  # Build an operation and converter QA receipt using real public schemas; return the intent path.
  def intent(action, source, prior_registry:, extra: {})
    candidate = write_file(File.join(@scratch, "#{source}-converted.md"), "<!-- Printed Page 1 -->\n#{source}\n")
    receipt = write_file(File.join(@scratch, "#{source}-receipt.json"), JSON.generate(
      {"schema" => "pdf-to-llm-md/conversion-receipt/v0.1", "state" => "ready", "downstream_ready" => true,
       "output" => {"path" => candidate, "sha256" => Digest::SHA256.file(candidate).hexdigest}}
    ))
    write_file(File.join(@scratch, "#{source}-intent.json"), JSON.generate(
      {"schema_version" => "af-source-operation-intent/v0.1", "library_id" => "fixture-library",
       "source_root" => @root, "operation_id" => "fixture-#{source}", "revision" => 1,
       "action" => action, "source_id" => source, "edition" => "fixture edition",
       "destination" => "#{source}.md", "registry" => "#{source}-registry.yml", "prior_registry" => prior_registry,
       "candidate_path" => candidate, "conversion_receipt_path" => receipt}.merge(extra)
    ))
  end

  # Use the public decision issuance entry and return the exact operator decision path.
  def decide(operation, name: File.basename(operation), actor: "operator", disposition: "approved")
    decision = File.join(@scratch, "#{name}.decision.json")
    cli_pass("decide", operation, "--decision", decision, "--decided-by", actor, "--disposition", disposition)
    decision
  end

  # Generate a fixture using the real draft constructor, then mark it frozen and validate it.
  def freeze_first_source(registry)
    base = write_file(File.join(@scratch, "fixture-amc.xlsx"), "content-free base identity\n")
    directory = File.join(@scratch, "pipeline-data")
    Dir.mkdir(directory)
    path = File.join(directory, "freeze.yml")
    draft = AfDataPipeline::BoundaryFreeze.init!(source_root: @root, source_id: "first", amc_path: base,
                                                 output_path: path, registry_path: registry)
    frozen = draft.artifact.merge("state" => "frozen", "approval" => {"approved_by" => "prior reviewer",
                                                                      "approved_at" => "2026-01-01"})
    write_file(path, YAML.dump(frozen))
    AfDataPipeline::BoundaryFreeze.validate!(freeze_path: path, source_root: @root, amc_path: base,
                                            registry_path: registry)
    [path, base]
  end

  # Build a content-free EV bundle and manifest; return the real verifier's inputs.
  def build_evidence
    source_root = File.join(@scratch, "evidence-source")
    Dir.mkdir(source_root)
    write_file(File.join(source_root, "fixture.bin"), "evidence\0\xff".b)
    bundle_path = File.join(@scratch, "fixture.tar.zst")
    manifest_path = File.join(@scratch, "manifest.json")
    bundle = AfEvidence::EvidenceBundleBuilder.new(batch_root: source_root, batch_id: "mechanical")
                                          .build!(output_path: bundle_path)
    AfEvidence::EvidenceManifestBuilder.new(batch_root: source_root, batch_id: "mechanical")
                                       .write!(output_path: manifest_path, bundle: bundle.bundle, members: bundle.members)
    {manifest_path:, bundle_path:, source_root:}
  end

  # Execute the real CLI in a fresh process, with an optional interruption observer.
  # Return its exact stdout, stderr and Process::Status.
  def invoke(*arguments, env: {}, preload: nil)
    ruby = [RbConfig.ruby]
    ruby.concat(["-r", preload]) if preload
    Open3.capture3({"AF_SOURCE_MD_ROOT" => @owner_root, "AF_DATA_PIPELINE_DATA_ROOT" => @scratch}.merge(env), *ruby, REGISTER, *arguments)
  end

  # Require a successful real CLI invocation and return stdout.
  def cli_pass(*arguments, **options)
    stdout, stderr, status = invoke(*arguments, **options)
    assert status.success?, stderr
    stdout
  end

  # Require an explicit validation refusal with no successful output.
  def refusal(message, *arguments, **options)
    stdout, stderr, status = invoke(*arguments, **options)
    assert_equal 2, status.exitstatus, stderr
    assert_empty stdout
    assert_match message, stderr
  end

  # Verify returned content identities still bind the exact source and the exact registry.
  def check_result(result)
    %w[source registry journal].each do |key|
      binding = result.fetch(key)
      assert_equal binding, snapshot(binding.fetch("path")).reject { |name, _| name == "inode" }
    end
  end

  # Return all files' bindings and inodes to detect rewrites and leftover temporaries.
  def store_snapshot
    Dir.glob(File.join(@root, "*"), File::FNM_DOTMATCH).reject { |path| File.directory?(path) }.to_h do |path|
      [path, snapshot(path)]
    end
  end

  # Return path, bytes, SHA-256, mode and inode for a test file; read errors fail the check.
  def snapshot(path)
    {"path" => path, "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path),
     "mode" => File.stat(path).mode & 0o777, "inode" => File.stat(path).ino}
  end

  # Return exact persisted v0.1 mappings for the selected fixture registry.
  def sources(path)
    YAML.safe_load_file(path).fetch("sources")
  end

  # Write fixture bytes and mode, returning the supplied filename.
  def write_file(path, bytes, mode = 0o600)
    File.binwrite(path, bytes)
    File.chmod(mode, path)
    path
  end
end
