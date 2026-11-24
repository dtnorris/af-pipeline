# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Real storage-to-public-retrieval handoff using generated mechanical bytes.
# No inference, scoring result, private archive, Git fixture or validator fake.
class EvidenceOwnerIntegrationTest < Minitest::Test
  BATCH = "prod-batch-mechanical"
  RAW = "mechanical/runs/job/native/raw/ADV-TEST/run-one"
  BINARY = (0..255).to_a.pack("C*") + "\0\xff".b

  # Supplies isolated source, canonical archive and opt-in operational output.
  # Restores caller authorization and removes only this test's generated world.
  def with_world
    previous = ENV.delete("AF_DATA_PIPELINE_DATA_ROOT")
    Dir.mktmpdir("pl-ev-handoff-", File.realpath(Dir.tmpdir)) do |world|
      source = File.join(world, "source")
      response = File.join(world, "response")
      selected = File.join(world, "selected")
      FileUtils.mkdir_p([source, response, selected])
      write_member(source, "mechanical/runs/job/metadata.json", JSON.generate(
        "job_id" => "job", "adventure" => "ADV-TEST", "dimension" => "mechanical", "status" => "complete"))
      write_member(source, "#{RAW}/run_metadata.json", JSON.generate(
        "run_id" => "run-one", "adventure_id" => "ADV-TEST", "selected_dimension" => "mechanical"))
      write_member(source, "#{RAW}/binary.bin", BINARY)
      write_member(source, "#{RAW}/empty.bin", "")
      yield world, source, response, selected
    end
  ensure
    ENV.delete("AF_DATA_PIPELINE_DATA_ROOT")
    ENV["AF_DATA_PIPELINE_DATA_ROOT"] = previous if previous
  end

  # Writes exact fixture bytes; filesystem failures propagate.
  def write_member(root, relative, bytes)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
  end

  # Publishes through the actual PL writer and real EV validators.
  def publish(source, response, authoritative: false)
    AfDataPipeline::ProductionEvidenceShadowWriter.write!(
      batch_id: BATCH, source_root: source, response_root: response, authoritative: authoritative)
  end

  # Invokes the public retrieval dispatcher with explicit archive/index locators.
  # Returns status, parsed-or-raw stdout, and stderr without replacing any owner.
  def retrieve(response, output, member: "binary.bin")
    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::CLI.run([
      "evidence-retrieve", "--index", File.join(response, "indexes/evidence-index.sqlite"),
      "--evidence-root", File.join(response, "prod-evidence"), "--run-id", "run-one",
      "--member-path", "#{RAW}/#{member}", "--output", output
    ], out: out, err: err)
    [status, out.string.empty? ? nil : JSON.parse(out.string), err.string]
  end

  # Proves exact binary/empty retrieval and repeat semantics, with authoritative
  # and diagnostic policy preserved and unchanged EV implementation provenance.
  def test_writer_and_public_dispatcher_share_the_ev_owner
    with_world do |world, source, response, _selected|
      first = publish(source, response)
      assert_equal "complete", first.fetch("status")
      assert_equal "shadow_dual_write", first.fetch("mode")
      assert_equal false, first.fetch("authoritative")
      assert_equal "valid", first.dig("equivalence_gate", "status")
      {"binary.bin" => BINARY, "empty.bin" => "".b}.each do |member, bytes|
        output = File.join(world, member)
        status, summary, error = retrieve(response, output, member: member)
        assert_equal 0, status, error
        assert_empty error
        assert_equal bytes, File.binread(output)
        assert_equal Digest::SHA256.hexdigest(bytes), summary.fetch("sha256")
      end
      second = publish(source, response, authoritative: true)
      assert_equal "complete", second.fetch("status")
      assert_equal "compact_canonical", second.fetch("mode")
      assert_equal true, second.fetch("authoritative")
      assert_equal first.fetch("canonical_batch"), second.fetch("canonical_batch")
      assert_equal AfEvidence::EvidenceBundleBuilder, AfDataPipeline::EvidenceBundleBuilder.superclass
      assert_equal AfEvidence::EvidenceRetriever, AfDataPipeline::EvidenceRetriever.superclass
      assert_equal AfEvidence::EvidenceIndexBuilder::SCHEMA_PATH, AfDataPipeline::EvidenceIndexBuilder::SCHEMA_PATH
    end
  end

  # Refuses absent/relative/traversing archive selections before PL can normalize
  # them into an unintended archive; neither archive receives any output.
  def test_writer_refuses_unsafe_archive_selection_before_writes
    with_world do |world, source, response, selected|
      invalid_roots = [nil, "", "response", "#{response}/.", "#{response}/../selected", "#{response}\0"]
      invalid_roots.each do |archive|
        error = assert_raises(AfDataPipeline::ValidationError) { publish(source, archive) }
        assert_match(/archive root must be an explicit absolute path without traversal/, error.message)
        assert_empty Dir.children(response)
        assert_empty Dir.children(selected)
      end
      assert_equal %w[selected response source].sort, Dir.children(world).sort
      assert_equal BINARY, File.binread(File.join(source, "#{RAW}/binary.bin"))
    end
  end

  # Exercises legacy/default and opt-in refusals through the same dispatcher.
  # A selected PL root authorizes placement only; EV still refuses unsafe output.
  def test_selected_root_and_ev_safety_both_remain_required
    with_world do |world, source, response, selected|
      publish(source, response)
      ENV["AF_DATA_PIPELINE_DATA_ROOT"] = selected
      outside = File.join(world, "outside")
      status, summary, error = retrieve(response, outside)
      assert_equal 2, status
      assert_nil summary
      assert_match(/escapes private data root/, error)
      refute File.exist?(outside)
      output = File.join(selected, "selected.bin")
      assert_equal 0, retrieve(response, output).first
      assert_equal BINARY, File.binread(output)
      status, _summary, error = retrieve(response, output)
      assert_equal 2, status
      assert_match(/already exists/, error)
      assert_equal BINARY, File.binread(output)
      ENV["AF_DATA_PIPELINE_DATA_ROOT"] = ""
      status, _summary, error = retrieve(response, File.join(selected, "no-fallback"))
      assert_equal 2, status
      assert_match(/empty or contains traversal/, error)
      ENV.delete("AF_DATA_PIPELINE_DATA_ROOT")
      link = File.join(world, "dangling")
      File.symlink(File.join(world, "absent"), link)
      status, _summary, error = retrieve(response, link)
      assert_equal 2, status
      assert_match(/symlink/, error)
      assert File.symlink?(link)
    end
  end

  # Conflicting replay cannot replace a canonical identity or claim completion;
  # real EV validation is translated back to the existing PL exception identity.
  def test_conflicting_replay_retains_canonical_pair_and_pipeline_error_identity
    with_world do |_world, source, response, _selected|
      state = publish(source, response)
      pair = state.fetch("canonical_batch").values_at("manifest", "bundle").to_h do |item|
        [item.fetch("path"), File.binread(item.fetch("path"))]
      end
      File.binwrite(File.join(source, "#{RAW}/binary.bin"), "conflict")
      error = assert_raises(AfDataPipeline::ValidationError) { publish(source, response) }
      assert_equal "AfDataPipeline::ValidationError", error.class.name
      assert_match(/source member byte size mismatch/, error.message)
      pair.each { |path, bytes| assert_equal bytes, File.binread(path) }
    end
  end

  # A source change at the equivalence handoff returns the existing failed receipt
  # shape, including the PL Failure identity, without weakening owner checks.
  def test_equivalence_failure_remains_a_failed_non_authoritative_receipt
    with_world do |_world, source, response, _selected|
      progress = lambda do |message|
        if message.include?("running production equivalence gate")
          File.binwrite(File.join(source, "#{RAW}/binary.bin"), "changed at handoff")
        end
      end
      state = AfDataPipeline::ProductionEvidenceShadowWriter.write!(
        batch_id: BATCH, source_root: source, response_root: response, authoritative: true, progress: progress)
      assert_equal "failed", state.fetch("status")
      assert_equal false, state.fetch("authoritative")
      assert_equal true, state.fetch("requested_authoritative")
      assert_equal false, state.fetch("representation_valid")
      assert_equal "AfDataPipeline::ProductionEvidenceEquivalenceGate::Failure", state.fetch("error_class")
      assert_equal "invalid", state.dig("equivalence_gate", "status")
      assert_equal "fail", state.dig("equivalence_gate", "checks", "expanded_manifest_inventory", "status")
      assert File.file?(state.dig("canonical_batch", "bundle", "path"))
      assert_equal "changed at handoff", File.binread(File.join(source, "#{RAW}/binary.bin"))
    end
  end
end
