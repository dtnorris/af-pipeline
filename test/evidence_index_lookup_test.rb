# frozen_string_literal: true
require_relative "test_helper"
require "stringio"

class EvidenceIndexLookupTest < Minitest::Test
  def test_lookup_filters_are_exact_composable_and_return_canonical_locators
    with_index do |path|
      lookup = AfDataPipeline::EvidenceIndexLookup.new(index_path: path)

      rows = lookup.lookup(adventure_id: "ADV-0701", dimension: "Social Interaction Emphasis")
      assert_equal 3, rows.length
      assert_equal rows.map { |row| row.fetch("member_path") }.sort,
                   rows.map { |row| row.fetch("member_path") }
      rows.each do |row|
        assert_equal "prod-batch-029", row.fetch("batch_id")
        assert_equal "prod-batch-029/prod-batch-029.tar.zst", row.fetch("bundle_path")
        assert_equal "a" * 64, row.fetch("bundle_sha256")
        assert_equal "shared-job", row.fetch("job_id")
        assert_equal "Social Interaction Emphasis", row.fetch("dimension")
      end

      assert_equal 3, lookup.lookup(model: "qwen").length
      assert_equal 3, lookup.lookup(model: "qwen3.6:35b-a3b").length
      assert_equal 2, lookup.lookup(status: "failed").length
      assert_equal 5, lookup.lookup(job_id: "shared-job").length
      assert_equal 2, lookup.lookup(run_id: "run-social").length
      assert_equal 2, lookup.lookup(batch_id: "prod-batch-029", status: "failed").length
      assert_empty lookup.lookup(adventure_id: "ADV-9999")
    end
  end

  def test_lookup_is_read_only_and_rejects_invalid_filters_or_schema
    with_index do |path|
      before = Digest::SHA256.file(path).hexdigest
      lookup = AfDataPipeline::EvidenceIndexLookup.new(index_path: path)
      lookup.lookup(batch_id: "prod-batch-029")
      assert_equal before, Digest::SHA256.file(path).hexdigest
      refute File.exist?("#{path}-wal")
      refute File.exist?("#{path}-shm")

      assert_raises(AfDataPipeline::ValidationError) { lookup.lookup }
      assert_raises(AfDataPipeline::ValidationError) { lookup.lookup(nope: "x") }
      assert_raises(AfDataPipeline::ValidationError) { lookup.lookup(status: "") }
    end

    Dir.mktmpdir("evidence-lookup-schema") do |dir|
      path = File.join(dir, "bad.sqlite")
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE index_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      database.execute("INSERT INTO index_metadata(key, value) VALUES ('schema_version', 'wrong')")
      database.execute("PRAGMA user_version = 1")
      database.close

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::EvidenceIndexLookup.new(index_path: path).lookup(batch_id: "prod-batch-029")
      end
      assert_match(/Unsupported evidence index schema/, error.message)
    end
  end

  def test_cli_emits_deterministic_jsonl_and_requires_explicit_index_and_filter
    with_index do |path|
      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        [
          "evidence-lookup", "--index", path,
          "--adventure", "ADV-0701",
          "--dimension", "Social Interaction Emphasis"
        ],
        out:,
        err:
      )

      assert_equal 0, status
      assert_empty err.string
      rows = out.string.lines.map { |line| JSON.parse(line) }
      assert_equal 3, rows.length
      assert_equal rows.map { |row| row.fetch("member_path") }.sort,
                   rows.map { |row| row.fetch("member_path") }

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(["evidence-lookup", "--index", path], out:, err:)
      assert_equal 2, status
      assert_empty out.string
      assert_match(/at least one lookup filter is required/, err.string)

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(["evidence-lookup", "--batch", "prod-batch-029"], out:, err:)
      assert_equal 2, status
      assert_match(/--index PATH/, err.string)
    end
  end

  private

  def with_index
    Dir.mktmpdir("evidence-lookup") do |dir|
      path = File.join(dir, "evidence-index.sqlite")
      database = SQLite3::Database.new(path)
      database.execute_batch(File.read(AfDataPipeline::EvidenceIndexBuilder::SCHEMA_PATH))
      database.execute("INSERT INTO index_metadata(key, value) VALUES (?, ?)", ["schema_version", AfDataPipeline::EvidenceIndexBuilder::SCHEMA_VERSION])
      database.execute("INSERT INTO index_metadata(key, value) VALUES (?, ?)", ["manifest_schema_version", AfDataPipeline::EvidenceManifestBuilder::SCHEMA_VERSION])
      insert_batch(database)
      database.close
      yield path
    ensure
      database&.close rescue nil
    end
  end

  def insert_batch(database)
    database.execute(
      <<~SQL,
        INSERT INTO batches(
          batch_id, manifest_schema_version, manifest_sha256,
          bundle_filename, bundle_format, bundle_profile_version,
          bundle_byte_size, bundle_sha256, member_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        "prod-batch-029", AfDataPipeline::EvidenceManifestBuilder::SCHEMA_VERSION, "b" * 64,
        "prod-batch-029.tar.zst", AfDataPipeline::EvidenceBundleBuilder::FORMAT,
        AfDataPipeline::EvidenceBundleBuilder::PROFILE_VERSION, 100, "a" * 64, 6
      ]
    )

    social_key = "social-experiment/runs/shared-job"
    failed_key = "gmbs-experiment/runs/shared-job"
    members = [
      ["social-experiment/runs/shared-job/metadata.json", social_key, nil],
      ["social-experiment/runs/shared-job/native/raw/ADV-0701/run-social/run_metadata.json", social_key, "run-social"],
      ["social-experiment/runs/shared-job/native/raw/ADV-0701/run-social/dimension_social_interaction_emphasis.json", social_key, "run-social"],
      ["gmbs-experiment/runs/shared-job/metadata.json", failed_key, nil],
      ["gmbs-experiment/runs/shared-job/stderr.log", failed_key, nil],
      ["batch-summary.md", nil, nil]
    ]
    members.each_with_index do |(member_path, job_key, run_id), index|
      database.execute(
        "INSERT INTO members(batch_id, member_path, byte_size, sha256, job_key, run_id) VALUES (?, ?, ?, ?, ?, ?)",
        ["prod-batch-029", member_path, index, index.to_s(16).rjust(64, "0"), job_key, run_id]
      )
    end

    database.execute(
      "INSERT INTO jobs(batch_id, job_key, job_id, adventure_id, dimension, model_alias, model, status, metadata_member_path) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      ["prod-batch-029", social_key, "shared-job", "ADV-0701", "Social Interaction Emphasis", "qwen", "qwen3.6:35b-a3b", "complete", "social-experiment/runs/shared-job/metadata.json"]
    )
    database.execute(
      "INSERT INTO jobs(batch_id, job_key, job_id, adventure_id, dimension, model_alias, model, status, metadata_member_path) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      ["prod-batch-029", failed_key, "shared-job", "ADV-0702", "GM Beginner Suitability", "gemma", "gemma4:26b-a4b-it-mtp", "failed", "gmbs-experiment/runs/shared-job/metadata.json"]
    )
    database.execute(
      "INSERT INTO runs(batch_id, run_id, job_key, job_id, adventure_id, dimension, provider, model, run_metadata_member_path) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      ["prod-batch-029", "run-social", social_key, "shared-job", "ADV-0701", "Social Interaction Emphasis", "ollama", "qwen3.6:35b-a3b", "social-experiment/runs/shared-job/native/raw/ADV-0701/run-social/run_metadata.json"]
    )
  end
end
