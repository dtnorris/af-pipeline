# frozen_string_literal: true
require_relative "test_helper"

class EvidenceIndexBuilderTest < Minitest::Test
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

  def test_builds_queryable_index_from_verified_canonical_evidence
    Dir.mktmpdir("evidence-index-test") do |workspace|
      evidence_root = File.join(workspace, "prod-evidence")
      build_batch(evidence_root:, batch_id: "prod-batch-029-fixture")
      before = tree_state(evidence_root)
      output = File.join(workspace, "indexes", "evidence-index.sqlite")

      result = index_builder.build!(evidence_root:, output_path: output)

      assert_equal 1, result.batch_count
      assert_equal 7, result.member_count
      assert_equal 2, result.job_count
      assert_equal 1, result.run_count
      assert File.file?(output)
      assert_equal before, tree_state(evidence_root)

      SQLite3::Database.new(output) do |database|
        assert_equal "af-evidence-index/v0.1",
                     database.get_first_value("SELECT value FROM index_metadata WHERE key = 'schema_version'")
        assert_equal "af-evidence-manifest/v0.1",
                     database.get_first_value("SELECT value FROM index_metadata WHERE key = 'manifest_schema_version'")
        assert_equal 1, database.get_first_value("PRAGMA user_version")

        jobs = database.execute(<<~SQL)
          SELECT job_key, job_id, adventure_id, dimension, model_alias, model, status
          FROM jobs
          ORDER BY job_key
        SQL
        assert_equal [
          ["production-backlog-029-gmbs-fixture/runs/shared-job", "shared-job", "ADV-0702", "GM Beginner Suitability", "qwen", "qwen3.6:35b-a3b", "failed"],
          ["production-backlog-029-social-fixture/runs/shared-job", "shared-job", "ADV-0701", "Social Interaction Emphasis", "qwen", "qwen3.6:35b-a3b", "complete"]
        ], jobs

        run = database.get_first_row(<<~SQL)
          SELECT run_id, job_id, adventure_id, dimension, provider, model
          FROM runs
        SQL
        assert_equal [
          "20260916T101714Z_fixture", "shared-job", "ADV-0701",
          "Social Interaction Emphasis", "ollama", "qwen3.6:35b-a3b"
        ], run

        member = database.get_first_row(<<~SQL)
          SELECT job_key, run_id
          FROM members
          WHERE member_path LIKE '%dimension_social_interaction_emphasis.json'
        SQL
        assert_equal [
          "production-backlog-029-social-fixture/runs/shared-job",
          "20260916T101714Z_fixture"
        ], member
      end
    end
  end

  def test_builds_queryable_index_from_legacy_flat_levels_evidence
    Dir.mktmpdir("evidence-index-legacy-levels") do |workspace|
      evidence_root = File.join(workspace, "prod-evidence")
      run_id = "20260906T085851Z_fixture"
      build_legacy_levels_batch(evidence_root:, batch_id: "prod-batch-013", run_id:)
      output = File.join(workspace, "indexes", "evidence-index.sqlite")

      result = index_builder.build!(evidence_root:, output_path: output)

      assert_equal 1, result.batch_count
      assert_equal 4, result.member_count
      assert_equal 1, result.job_count
      assert_equal 1, result.run_count

      SQLite3::Database.new(output) do |database|
        job = database.get_first_row(<<~SQL)
          SELECT job_key, job_id, adventure_id, dimension, model, status, metadata_member_path
          FROM jobs
        SQL
        assert_equal [
          "raw/ADV-0013/#{run_id}", run_id, "ADV-0013", "Levels",
          "qwen3.6:35b-a3b", "PROPOSED",
          "assessments/ADV-0013_#{run_id}.csv"
        ], job

        run = database.get_first_row(<<~SQL)
          SELECT run_id, job_key, adventure_id, dimension, provider, model,
                 afao_version, assessment_spec_version, source_scope, run_metadata_member_path
          FROM runs
        SQL
        assert_equal [
          run_id, "raw/ADV-0013/#{run_id}", "ADV-0013", "Levels",
          "ollama", "qwen3.6:35b-a3b", "1.6.1", "0.1", "canonical_page_slice",
          "assessments/ADV-0013_#{run_id}.csv"
        ], run

        linked = database.execute(<<~SQL)
          SELECT member_path, job_key, run_id
          FROM members
          WHERE job_key IS NOT NULL
          ORDER BY member_path
        SQL
        assert_equal [
          ["assessments/ADV-0013_#{run_id}.csv", "raw/ADV-0013/#{run_id}", run_id],
          ["raw/ADV-0013/#{run_id}/dimension_levels.json", "raw/ADV-0013/#{run_id}", run_id],
          ["raw/ADV-0013/#{run_id}/dimension_levels_request.json", "raw/ADV-0013/#{run_id}", run_id]
        ], linked

        unmatched = database.get_first_row(<<~SQL)
          SELECT job_key, run_id
          FROM members
          WHERE member_path = 'raw/ADV-0068/unmatched/dimension_levels.json'
        SQL
        assert_equal [nil, nil], unmatched
      end
    end
  end

  def test_rejects_legacy_flat_levels_filename_csv_identity_mismatch
    Dir.mktmpdir("evidence-index-legacy-levels-mismatch") do |workspace|
      evidence_root = File.join(workspace, "prod-evidence")
      build_legacy_levels_batch(
        evidence_root:,
        batch_id: "prod-batch-013",
        run_id: "20260906T085851Z_fixture",
        csv_run_id: "different-run"
      )
      output = File.join(workspace, "evidence-index.sqlite")

      error = assert_raises(AfDataPipeline::ValidationError) do
        index_builder.build!(evidence_root:, output_path: output)
      end
      assert_match(/filename\/CSV run_id mismatch/, error.message)
      refute File.exist?(output)
    end
  end

  def test_logical_rebuild_is_deterministic
    Dir.mktmpdir("evidence-index-rebuild") do |workspace|
      evidence_root = File.join(workspace, "prod-evidence")
      build_batch(evidence_root:, batch_id: "prod-batch-029-fixture")
      first = File.join(workspace, "first.sqlite")
      second = File.join(workspace, "second.sqlite")

      index_builder.build!(evidence_root:, output_path: first)
      index_builder.build!(evidence_root:, output_path: second)

      assert_equal logical_dump(first), logical_dump(second)
    end
  end

  def test_rejects_job_run_metadata_disagreement_without_leaving_index
    Dir.mktmpdir("evidence-index-mismatch") do |workspace|
      evidence_root = File.join(workspace, "prod-evidence")
      build_batch(
        evidence_root:,
        batch_id: "prod-batch-029-fixture",
        native_model: "different-model"
      )
      output = File.join(workspace, "evidence-index.sqlite")

      error = assert_raises(AfDataPipeline::ValidationError) do
        index_builder.build!(evidence_root:, output_path: output)
      end
      assert_match(/job\/run model mismatch/, error.message)
      refute File.exist?(output)
    end
  end

  def test_refuses_output_inside_evidence_root_or_overwrite
    Dir.mktmpdir("evidence-index-output") do |workspace|
      evidence_root = File.join(workspace, "prod-evidence")
      build_batch(evidence_root:, batch_id: "prod-batch-029-fixture")

      inside = File.join(evidence_root, "evidence-index.sqlite")
      error = assert_raises(AfDataPipeline::ValidationError) do
        index_builder.build!(evidence_root:, output_path: inside)
      end
      assert_match(/outside the canonical evidence root/, error.message)
      refute File.exist?(inside)

      output = File.join(workspace, "evidence-index.sqlite")
      File.binwrite(output, "keep me")
      error = assert_raises(AfDataPipeline::ValidationError) do
        index_builder.build!(evidence_root:, output_path: output)
      end
      assert_match(/already exists/, error.message)
      assert_equal "keep me", File.binread(output)
    end
  end

  private

  def index_builder
    decompressor = PassthroughDecompressor.new
    AfDataPipeline::EvidenceIndexBuilder.new(
      verifier: AfDataPipeline::EvidenceBundleVerifier.new(decompressor:),
      decompressor:
    )
  end

  def build_batch(evidence_root:, batch_id:, native_model: "qwen3.6:35b-a3b")
    source = File.join(File.dirname(evidence_root), "expanded-#{batch_id}")
    FileUtils.mkdir_p(source)
    complete_experiment = "production-backlog-029-social-fixture"
    failed_experiment = "production-backlog-029-gmbs-fixture"
    complete_root = "#{complete_experiment}/runs/shared-job"
    failed_root = "#{failed_experiment}/runs/shared-job"
    run_id = "20260916T101714Z_fixture"

    write_file(source, "#{complete_experiment}/experiment.yml", "name: #{complete_experiment}\n")
    write_file(source, "#{failed_experiment}/experiment.yml", "name: #{failed_experiment}\n")
    write_json(source, "#{complete_root}/metadata.json", job_metadata(
      job_id: "shared-job",
      adventure_id: "ADV-0701",
      dimension: "Social Interaction Emphasis",
      status: "complete"
    ))
    write_json(source, "#{failed_root}/metadata.json", job_metadata(
      job_id: "shared-job",
      adventure_id: "ADV-0702",
      dimension: "GM Beginner Suitability",
      status: "failed"
    ))
    raw_root = "#{complete_root}/native/raw/ADV-0701/#{run_id}"
    write_json(source, "#{raw_root}/run_metadata.json", {
      "run_id" => run_id,
      "adventure_id" => "ADV-0701",
      "selected_dimension" => "Social Interaction Emphasis",
      "provider" => "ollama",
      "model" => native_model,
      "prompt_profile" => "phase6-v0.3",
      "afao_version" => "1.6.1",
      "assessment_spec_version" => "0.1",
      "reasoning_effort" => "high",
      "source_scope" => "canonical_page_slice",
      "experimental" => true
    })
    write_json(source, "#{raw_root}/dimension_social_interaction_emphasis.json", { "score" => 2 })
    write_file(source, "#{failed_root}/stderr.log", "fixture failure\n")

    canonical_dir = File.join(evidence_root, batch_id)
    FileUtils.mkdir_p(canonical_dir)
    manifest_builder = AfDataPipeline::EvidenceManifestBuilder.new(batch_root: source, batch_id:)
    inventory = manifest_builder.member_inventory
    bundle_result = AfDataPipeline::EvidenceBundleBuilder.new(
      batch_root: source,
      batch_id:,
      compressor: PassthroughCompressor.new
    ).build!(output_path: File.join(canonical_dir, "#{batch_id}.tar.zst"), members: inventory)
    manifest_builder.write!(
      output_path: File.join(canonical_dir, "manifest.json"),
      bundle: bundle_result.bundle,
      members: bundle_result.members
    )
  end

  def job_metadata(job_id:, adventure_id:, dimension:, status:)
    {
      "job_id" => job_id,
      "worker" => "mac",
      "model_alias" => "qwen",
      "ollama_model" => "qwen3.6:35b-a3b",
      "adventure" => adventure_id,
      "replicate" => 1,
      "dimension" => dimension,
      "status" => status,
      "started_at" => "2026-09-16T06:17:12-04:00",
      "completed_at" => "2026-09-16T06:19:03-04:00",
      "elapsed_seconds" => 111.442,
      "exit_status" => status == "complete" ? 0 : 1,
      "estimated_cost_usd" => 0.0
    }
  end

  def build_legacy_levels_batch(evidence_root:, batch_id:, run_id:, csv_run_id: run_id)
    source = File.join(File.dirname(evidence_root), "expanded-#{batch_id}")
    FileUtils.mkdir_p(source)
    adventure_id = "ADV-0013"
    assessment_path = "assessments/#{adventure_id}_#{run_id}.csv"
    headers = %w[
      run_id status adventure_id afao_version assessment_spec_version
      provider model source_scope group metric_kind metric
    ]
    csv = CSV.generate do |rows|
      rows << headers
      ["Level Start", "Level End"].each do |metric|
        rows << [
          csv_run_id,
          "PROPOSED",
          adventure_id,
          "1.6.1",
          "0.1",
          "ollama",
          "qwen3.6:35b-a3b",
          "canonical_page_slice",
          "sessions_levels",
          "level",
          metric
        ]
      end
    end
    write_file(source, assessment_path, csv)

    raw_root = "raw/#{adventure_id}/#{run_id}"
    write_json(source, "#{raw_root}/dimension_levels.json", { "score" => nil })
    write_json(source, "#{raw_root}/dimension_levels_request.json", { "request" => true })

    write_json(
      source,
      "raw/ADV-0068/unmatched/dimension_levels.json",
      { "historical_unmatched_raw" => true }
    )

    canonical_dir = File.join(evidence_root, batch_id)
    FileUtils.mkdir_p(canonical_dir)
    manifest_builder = AfDataPipeline::EvidenceManifestBuilder.new(batch_root: source, batch_id:)
    inventory = manifest_builder.member_inventory
    bundle_result = AfDataPipeline::EvidenceBundleBuilder.new(
      batch_root: source,
      batch_id:,
      compressor: PassthroughCompressor.new
    ).build!(
      output_path: File.join(canonical_dir, "#{batch_id}.tar.zst"),
      members: inventory
    )
    manifest_builder.write!(
      output_path: File.join(canonical_dir, "manifest.json"),
      bundle: bundle_result.bundle,
      members: bundle_result.members
    )
  end

  def write_json(root, relative, value)
    write_file(root, relative, JSON.pretty_generate(value) + "\n")
  end

  def write_file(root, relative, contents)
    path = File.join(root, *relative.split("/"))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
  end

  def tree_state(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) }
      .sort
      .map do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        [relative, File.size(path), Digest::SHA256.file(path).hexdigest]
      end
  end

  def logical_dump(path)
    database = SQLite3::Database.new(path)
    {
      metadata: database.execute("SELECT key, value FROM index_metadata ORDER BY key"),
      batches: database.execute("SELECT * FROM batches ORDER BY batch_id"),
      members: database.execute("SELECT * FROM members ORDER BY batch_id, member_path"),
      jobs: database.execute("SELECT * FROM jobs ORDER BY batch_id, job_id"),
      runs: database.execute("SELECT * FROM runs ORDER BY batch_id, run_id")
    }
  ensure
    database&.close
  end
end
