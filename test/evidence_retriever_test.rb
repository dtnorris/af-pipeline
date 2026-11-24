# frozen_string_literal: true
require_relative "test_helper"
require "stringio"

class EvidenceRetrieverTest < Minitest::Test
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

  def test_extracts_one_lookup_member_and_verifies_exact_bytes
    with_corpus do |workspace, evidence_root, index_path, source|
      before_evidence = tree_state(evidence_root)
      before_index = Digest::SHA256.file(index_path).hexdigest
      rows = AfDataPipeline::EvidenceIndexLookup.new(index_path:).lookup(run_id: "run-social")
      locator = rows.find { |row| row.fetch("member_path").end_with?("dimension_social_interaction_emphasis.json") }
      output = File.join(workspace, "selected.json")

      result = retriever(evidence_root).extract_member!(locator:, output_path: output)

      assert_equal File.binread(File.join(source, locator.fetch("member_path"))), File.binread(output)
      assert_equal locator.fetch("member_sha256"), Digest::SHA256.file(output).hexdigest
      assert_equal locator.fetch("member_path"), result.member_path
      assert_equal output, result.output_path
      assert_equal before_evidence, tree_state(evidence_root)
      assert_equal before_index, Digest::SHA256.file(index_path).hexdigest
    end
  end

  def test_extracts_one_run_preserving_canonical_member_paths
    with_corpus do |workspace, evidence_root, index_path, source|
      rows = AfDataPipeline::EvidenceIndexLookup.new(index_path:).lookup(run_id: "run-social")
      output = File.join(workspace, "run-output")

      result = retriever(evidence_root).extract_run!(locators: rows, output_dir: output)

      assert_equal "prod-batch-029-fixture", result.batch_id
      assert_equal "run-social", result.run_id
      assert_equal rows.length, result.members.length
      assert_equal rows.map { |row| row.fetch("member_path") }.sort,
                   result.members.map(&:member_path)
      result.members.each do |member|
        destination = File.join(output, *member.member_path.split("/"))
        assert_equal destination, member.output_path
        assert_equal File.binread(File.join(source, member.member_path)), File.binread(destination)
        assert_equal member.sha256, Digest::SHA256.file(destination).hexdigest
      end
    end
  end

  def test_fails_closed_on_bundle_or_member_hash_mismatch_without_retaining_output
    with_corpus do |workspace, evidence_root, index_path, _source|
      rows = AfDataPipeline::EvidenceIndexLookup.new(index_path:).lookup(run_id: "run-social")
      locator = rows.first.merge("bundle_sha256" => "0" * 64)
      output = File.join(workspace, "bad-bundle.json")
      error = assert_raises(AfDataPipeline::ValidationError) do
        retriever(evidence_root).extract_member!(locator:, output_path: output)
      end
      assert_match(/bundle sha256 mismatch/, error.message)
      refute File.exist?(output)

      locator = rows.first.merge("member_sha256" => "0" * 64)
      output = File.join(workspace, "bad-member.json")
      error = assert_raises(AfDataPipeline::ValidationError) do
        retriever(evidence_root).extract_member!(locator:, output_path: output)
      end
      assert_match(/member sha256 mismatch/, error.message)
      refute File.exist?(output)
    end
  end

  def test_rejects_ambiguous_run_or_output_inside_canonical_evidence
    with_corpus do |workspace, evidence_root, index_path, _source|
      rows = AfDataPipeline::EvidenceIndexLookup.new(index_path:).lookup(run_id: "run-social")
      other = rows.first.merge("batch_id" => "prod-batch-other", "bundle_path" => "prod-batch-other/other.tar.zst")
      error = assert_raises(AfDataPipeline::ValidationError) do
        retriever(evidence_root).extract_run!(locators: rows + [other], output_dir: File.join(workspace, "ambiguous"))
      end
      assert_match(/multiple batches/, error.message)

      output = File.join(evidence_root, "should-not-write.json")
      error = assert_raises(AfDataPipeline::ValidationError) do
        retriever(evidence_root).extract_member!(locator: rows.first, output_path: output)
      end
      assert_match(/outside the canonical evidence root/, error.message)
      refute File.exist?(output)
    end
  end

  def test_cli_retrieves_member_and_run_from_explicit_index_and_evidence_root
    with_corpus do |workspace, evidence_root, index_path, source|
      cli_retriever = retriever(evidence_root)
      member_path = "social-experiment/runs/shared-job/native/raw/ADV-0701/run-social/dimension_social_interaction_emphasis.json"
      output = File.join(workspace, "cli-member.json")
      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::EvidenceRetriever.stub(:new, cli_retriever) do
        AfDataPipeline::CLI.run(
          [
            "evidence-retrieve", "--index", index_path, "--evidence-root", evidence_root,
            "--batch", "prod-batch-029-fixture", "--run-id", "run-social",
            "--member-path", member_path, "--output", output
          ],
          out:, err:
        )
      end
      assert_equal 0, status
      assert_empty err.string
      summary = JSON.parse(out.string)
      assert_equal member_path, summary.fetch("member_path")
      assert_equal File.binread(File.join(source, member_path)), File.binread(output)

      run_output = File.join(workspace, "cli-run")
      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::EvidenceRetriever.stub(:new, cli_retriever) do
        AfDataPipeline::CLI.run(
          [
            "evidence-retrieve", "--index", index_path, "--evidence-root", evidence_root,
            "--batch", "prod-batch-029-fixture", "--run-id", "run-social", "--output", run_output
          ],
          out:, err:
        )
      end
      assert_equal 0, status
      assert_empty err.string
      summary = JSON.parse(out.string)
      assert_equal "run-social", summary.fetch("run_id")
      assert_equal 3, summary.fetch("member_count")
    end
  end

  private

  def retriever(evidence_root)
    AfDataPipeline::EvidenceRetriever.new(
      evidence_root:,
      decompressor: PassthroughDecompressor.new
    )
  end

  def with_corpus
    Dir.mktmpdir("evidence-retrieval", File.realpath(Dir.tmpdir)) do |workspace|
      evidence_root = File.join(workspace, "prod-evidence")
      source = File.join(workspace, "expanded")
      FileUtils.mkdir_p(source)
      experiment = "social-experiment"
      job_root = "#{experiment}/runs/shared-job"
      run_id = "run-social"
      raw_root = "#{job_root}/native/raw/ADV-0701/#{run_id}"
      write_file(source, "#{experiment}/experiment.yml", "name: social-experiment\n")
      write_json(source, "#{job_root}/metadata.json", {
        "job_id" => "shared-job",
        "worker" => "fixture",
        "model_alias" => "qwen",
        "ollama_model" => "qwen3.6:35b-a3b",
        "adventure" => "ADV-0701",
        "replicate" => 1,
        "dimension" => "Social Interaction Emphasis",
        "status" => "complete"
      })
      write_json(source, "#{raw_root}/run_metadata.json", {
        "run_id" => run_id,
        "adventure_id" => "ADV-0701",
        "selected_dimension" => "Social Interaction Emphasis",
        "provider" => "ollama",
        "model" => "qwen3.6:35b-a3b",
        "prompt_profile" => "fixture",
        "afao_version" => "1.6",
        "assessment_spec_version" => "0.1"
      })
      write_json(source, "#{raw_root}/dimension_social_interaction_emphasis.json", { "score" => 2 })
      write_json(source, "#{raw_root}/dimension_social_interaction_emphasis_request.json", { "request" => true })

      batch_id = "prod-batch-029-fixture"
      canonical = File.join(evidence_root, batch_id)
      FileUtils.mkdir_p(canonical)
      manifest_builder = AfDataPipeline::EvidenceManifestBuilder.new(batch_root: source, batch_id:)
      inventory = manifest_builder.member_inventory
      bundle = AfDataPipeline::EvidenceBundleBuilder.new(
        batch_root: source,
        batch_id:,
        compressor: PassthroughCompressor.new
      ).build!(output_path: File.join(canonical, "#{batch_id}.tar.zst"), members: inventory)
      manifest_builder.write!(
        output_path: File.join(canonical, "manifest.json"),
        bundle: bundle.bundle,
        members: bundle.members
      )

      decompressor = PassthroughDecompressor.new
      index_path = File.join(workspace, "evidence-index.sqlite")
      AfDataPipeline::EvidenceIndexBuilder.new(
        verifier: AfDataPipeline::EvidenceBundleVerifier.new(decompressor:),
        decompressor:
      ).build!(evidence_root:, output_path: index_path)

      yield workspace, evidence_root, index_path, source
    end
  end

  def write_file(root, relative, contents)
    path = File.join(root, *relative.split("/"))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
  end

  def write_json(root, relative, value)
    write_file(root, relative, JSON.pretty_generate(value) + "\n")
  end

  def tree_state(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) }
      .sort
      .map { |path| [path.delete_prefix("#{root}/"), File.size(path), Digest::SHA256.file(path).hexdigest] }
  end
end
