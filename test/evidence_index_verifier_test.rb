# frozen_string_literal: true
require_relative "test_helper"
require "stringio"

class EvidenceIndexVerifierTest < Minitest::Test
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

  def test_verifies_committed_index_against_clean_rebuild_without_mutation
    with_corpus do |_workspace, evidence_root, index_path|
      before_index = file_state(index_path)
      before_evidence = tree_state(evidence_root)

      result = verifier.verify!(evidence_root:, index_path:)

      assert_equal index_path, result.index_path
      assert_equal before_index.fetch(:sha256), result.index_sha256
      assert_equal 1, result.batch_count
      assert_equal 4, result.member_count
      assert_equal 1, result.job_count
      assert_equal 1, result.run_count
      assert_equal before_index, file_state(index_path)
      assert_equal before_evidence, tree_state(evidence_root)
    end
  end

  def test_rejects_logically_tampered_committed_index
    with_corpus do |_workspace, evidence_root, index_path|
      database = SQLite3::Database.new(index_path)
      database.execute(
        "UPDATE jobs SET status = ? WHERE batch_id = ?",
        ["tampered", "prod-batch-029-fixture"]
      )
      database.close

      error = assert_raises(AfDataPipeline::ValidationError) do
        verifier.verify!(evidence_root:, index_path:)
      end
      assert_match(/differs from deterministic rebuild in jobs/, error.message)
    ensure
      database&.close rescue nil
    end
  end

  def test_cli_verifies_explicit_committed_index_and_evidence_root
    with_corpus do |_workspace, evidence_root, index_path|
      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::EvidenceIndexVerifier.stub(:new, verifier) do
        AfDataPipeline::CLI.run(
          [
            "evidence-index-verify",
            "--index", index_path,
            "--evidence-root", evidence_root
          ],
          out:,
          err:
        )
      end

      assert_equal 0, status
      assert_empty err.string
      summary = JSON.parse(out.string)
      assert_equal true, summary.fetch("verified")
      assert_equal index_path, summary.fetch("index_path")
      assert_equal 1, summary.fetch("batch_count")
      assert_equal 4, summary.fetch("member_count")
      assert_equal 1, summary.fetch("job_count")
      assert_equal 1, summary.fetch("run_count")
    end
  end

  def test_cli_requires_explicit_index_and_evidence_root
    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::CLI.run(
      ["evidence-index-verify", "--evidence-root", "/tmp/evidence"],
      out:,
      err:
    )
    assert_equal 2, status
    assert_match(/--index PATH/, err.string)

    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::CLI.run(
      ["evidence-index-verify", "--index", "/tmp/index.sqlite"],
      out:,
      err:
    )
    assert_equal 2, status
    assert_match(/--evidence-root DIR/, err.string)
  end

  private

  def verifier
    decompressor = PassthroughDecompressor.new
    AfDataPipeline::EvidenceIndexVerifier.new(
      builder: AfDataPipeline::EvidenceIndexBuilder.new(
        verifier: AfDataPipeline::EvidenceBundleVerifier.new(decompressor:),
        decompressor:
      )
    )
  end

  def with_corpus
    Dir.mktmpdir("evidence-index-verifier") do |workspace|
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

      yield workspace, evidence_root, index_path
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

  def file_state(path)
    {
      size: File.size(path),
      sha256: Digest::SHA256.file(path).hexdigest
    }
  end

  def tree_state(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) }
      .sort
      .map { |path| [path.delete_prefix("#{root}/"), File.size(path), Digest::SHA256.file(path).hexdigest] }
  end
end
