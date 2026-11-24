# frozen_string_literal: true

require_relative "test_helper"

# Real storage-to-public-retrieval handoff using generated mechanical bytes.
# No inference, scoring result, private archive, Git fixture or validator fake.
class EvidenceOwnerIntegrationTest < Minitest::Test
  BATCH = "prod-batch-mechanical"
  RAW = "mechanical/runs/job/native/raw/ADV-TEST/run-one"
  BINARY = (0..255).to_a.pack("C*") + "\0\xff".b

  # Yields an isolated source, canonical archive and operational output root.
  # Removes the generated world after the block. Filesystem errors propagate.
  def with_world
    Dir.mktmpdir("pl-ev-handoff-", File.realpath(Dir.tmpdir)) do |world|
      source = File.join(world, "source")
      archive = File.join(world, "archive")
      selected = File.join(world, "selected")
      FileUtils.mkdir_p([source, archive, selected])
      write_member(source, "mechanical/runs/job/metadata.json", JSON.generate(
        "job_id" => "job", "adventure" => "ADV-TEST", "dimension" => "mechanical", "status" => "complete"))
      write_member(source, "#{RAW}/run_metadata.json", JSON.generate(
        "run_id" => "run-one", "adventure_id" => "ADV-TEST", "selected_dimension" => "mechanical"))
      write_member(source, "#{RAW}/binary.bin", BINARY)
      write_member(source, "#{RAW}/empty.bin", "")
      yield world, source, archive, selected, File.join(world, "evidence-index.sqlite")
    end
  end

  # Writes exact fixture bytes; filesystem failures propagate.
  def write_member(root, relative, bytes)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
  end

  # Returns exact published pair and index bytes. Filesystem errors propagate.
  def stored_bytes(pair, index)
    paths = pair.values_at("manifest", "bundle").map { |item| item.fetch("path") }
    (paths + [index]).to_h { |path| [path, File.binread(path)] }
  end

  # Runs the public executable for one member and returns exit status, summary
  # and stderr. Spawn errors and malformed summary JSON propagate.
  def retrieve(archive, index, output, data_root:, member: "binary.bin")
    stdout, stderr, status = Open3.capture3(
      {"AF_DATA_PIPELINE_DATA_ROOT" => data_root}, RbConfig.ruby, File.expand_path("../bin/af-data", __dir__),
      "evidence-retrieve", "--index", index, "--evidence-root", archive, "--run-id", "run-one",
      "--member-path", "#{RAW}/#{member}", "--output", output
    )
    [status.exitstatus, stdout.empty? ? nil : JSON.parse(stdout), stderr]
  end

  # Proves exact binary/empty retrieval, verified pair reuse and owner provenance.
  def test_public_retrieval_of_verified_owner_store
    with_world do |_world, source, archive, selected, index|
      inputs = {batch_id: BATCH, source_root: source, evidence_root: archive, index_path: index}
      store = AfEvidence::EvidenceStore.new(**inputs)
      pair = store.ensure_pair!
      assert_equal true, pair.fetch("source_verified")
      assert_equal 4, pair.fetch("member_count")
      assert_equal true, store.rebuild_index!.fetch("verified")
      before = stored_bytes(pair, index)
      equivalence = AfEvidence::EvidenceEquivalenceChecker.new(**inputs).verify!
      assert_equal AfEvidence::EvidenceEquivalenceChecker::CHECK_NAMES, equivalence.checks.keys
      assert_equal %w[pass pass pass pass], equivalence.checks.values.map { |check| check.fetch("status") }
      {"binary.bin" => BINARY, "empty.bin" => "".b}.each do |member, bytes|
        output = File.join(selected, member)
        status, summary, error = retrieve(archive, index, output, data_root: selected, member:)
        assert_equal 0, status, error
        assert_empty error
        assert_equal bytes, File.binread(output)
        assert_equal Digest::SHA256.hexdigest(bytes), summary.fetch("sha256")
      end
      assert_equal pair, AfEvidence::EvidenceStore.new(**inputs).ensure_pair!
      assert_equal before, stored_bytes(pair, index)
      assert_equal AfEvidence::EvidenceBundleBuilder, AfDataPipeline::EvidenceBundleBuilder.superclass
      assert_equal AfEvidence::EvidenceRetriever, AfDataPipeline::EvidenceRetriever.superclass
      assert_equal AfEvidence::EvidenceIndexBuilder::SCHEMA_PATH, AfDataPipeline::EvidenceIndexBuilder::SCHEMA_PATH
    end
  end

  # Confirms the public store refuses unsafe archive selections before writes.
  def test_store_refuses_unsafe_archive_selection_before_writes
    with_world do |world, source, archive, selected, index|
      inputs = {batch_id: BATCH, source_root: source, index_path: index}
      invalid_roots = [nil, "", "archive", "#{archive}/.", "#{archive}/../selected"]
      invalid_roots.each do |root|
        error = assert_raises(AfEvidence::ValidationError) do
          AfEvidence::EvidenceStore.new(**inputs, evidence_root: root).ensure_pair!
        end
        assert_match(/explicit absolute paths without traversal/, error.message)
        assert_empty Dir.children(archive)
        assert_empty Dir.children(selected)
      end
      error = assert_raises(ArgumentError) do
        AfEvidence::EvidenceStore.new(**inputs, evidence_root: "#{archive}\0").ensure_pair!
      end
      assert_match(/null byte/, error.message)
      assert_empty Dir.children(archive)
      assert_empty Dir.children(selected)
      assert_equal %w[archive selected source], Dir.children(world).sort
      assert_equal BINARY, File.binread(File.join(source, "#{RAW}/binary.bin"))
    end
  end

  # Checks the executable's required root and both layers of output validation.
  def test_selected_root_and_ev_safety_both_remain_required
    with_world do |world, source, archive, selected, index|
      store = AfEvidence::EvidenceStore.new(batch_id: BATCH, source_root: source, evidence_root: archive, index_path: index)
      pair = store.ensure_pair!
      store.rebuild_index!
      before = stored_bytes(pair, index)
      output = File.join(selected, "selected.bin")
      status, summary, error = retrieve(archive, index, output, data_root: nil)
      assert_equal 2, status
      assert_nil summary
      assert_match(/set AF_DATA_PIPELINE_DATA_ROOT/, error)
      refute File.exist?(output)
      outside = File.join(world, "outside")
      status, summary, error = retrieve(archive, index, outside, data_root: selected)
      assert_equal 2, status
      assert_nil summary
      assert_match(/escapes private data root/, error)
      refute File.exist?(outside)
      archive_output = File.join(archive, "retrieved.bin")
      status, summary, error = retrieve(archive, index, archive_output, data_root: world)
      assert_equal 2, status
      assert_nil summary
      assert_match(/outside the canonical evidence root/, error)
      refute File.exist?(archive_output)
      assert_equal 0, retrieve(archive, index, output, data_root: selected).first
      assert_equal BINARY, File.binread(output)
      status, _summary, error = retrieve(archive, index, output, data_root: selected)
      assert_equal 2, status
      assert_match(/already exists/, error)
      assert_equal BINARY, File.binread(output)
      missing = File.join(selected, "no-fallback")
      status, _summary, error = retrieve(archive, index, missing, data_root: "")
      assert_equal 2, status
      assert_match(/empty or contains traversal/, error)
      refute File.exist?(missing)
      link = File.join(selected, "dangling")
      target = File.join(selected, "absent")
      File.symlink(target, link)
      status, _summary, error = retrieve(archive, index, link, data_root: selected)
      assert_equal 2, status
      assert_match(/symlink/, error)
      assert_equal target, File.readlink(link)
      refute File.exist?(target)
      assert_equal before, stored_bytes(pair, index)
    end
  end

  # Conflicting replay preserves published bytes and the public PL verifier maps
  # the owner's real source mismatch to the pipeline exception identity.
  def test_conflicting_replay_retains_canonical_pair_and_pipeline_error_identity
    with_world do |_world, source, archive, _selected, index|
      store = AfEvidence::EvidenceStore.new(batch_id: BATCH, source_root: source, evidence_root: archive, index_path: index)
      pair = store.ensure_pair!
      store.rebuild_index!
      before = stored_bytes(pair, index)
      File.binwrite(File.join(source, "#{RAW}/binary.bin"), "conflict")
      owner_error = assert_raises(AfEvidence::ValidationError) { store.ensure_pair! }
      assert_match(/source member byte size mismatch/, owner_error.message)
      pipeline_error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceBundleVerifier.new.verify!(manifest_path: pair.dig("manifest", "path"),
          bundle_path: pair.dig("bundle", "path"), source_root: source)
      end
      assert_equal owner_error.message, pipeline_error.message
      assert_equal before, stored_bytes(pair, index)
    end
  end

  # A source change after publication fails mechanical equivalence and preserves
  # both the published evidence and the changed expanded input for inspection.
  def test_equivalence_refuses_changed_source_and_preserves_published_evidence
    with_world do |_world, source, archive, _selected, index|
      inputs = {batch_id: BATCH, source_root: source, evidence_root: archive, index_path: index}
      store = AfEvidence::EvidenceStore.new(**inputs)
      pair = store.ensure_pair!
      store.rebuild_index!
      before = stored_bytes(pair, index)
      member = File.join(source, "#{RAW}/binary.bin")
      File.binwrite(member, "changed at handoff")
      failure = assert_raises(AfEvidence::EvidenceEquivalenceChecker::Failure) do
        AfEvidence::EvidenceEquivalenceChecker.new(**inputs).verify!
      end
      assert_match(/expanded evidence differs from manifest/, failure.message)
      assert_includes failure.message, "#{RAW}/binary.bin"
      assert_equal %w[fail not_run not_run not_run], failure.checks.values.map { |check| check.fetch("status") }
      assert_equal before, stored_bytes(pair, index)
      assert_equal "changed at handoff", File.binread(member)
    end
  end
end
