# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../lib/af_data_pipeline/ingest_next"

class IngestNextOperationInputTest < Minitest::Test
  Error = AfDataPipeline::IngestNext::OperationInput::Error

  def setup
    @tmpdir = Dir.mktmpdir("af-ingest-operation-input")
    @source_root = File.join(@tmpdir, "md-for-llm-book-content")
    @catalog_root = File.join(@tmpdir, "af-xlsx-data-sources")
    FileUtils.mkdir_p(@source_root)
    FileUtils.mkdir_p(@catalog_root)

    @markdown = File.join(@source_root, "Fixture_LLM_Edition.md")
    @base = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.0.xlsx")
    File.write(@markdown, "# Fixture\n")
    File.write(@base, "catalog-head")
    write_project_state(@base)

    @intake = File.join(@tmpdir, "source_intake.json")
    write_intake
    @operation_input = write_operation_input(@intake)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_operation_bound_inputs_produce_the_same_route_as_legacy_explicit_inputs
    legacy = router.inspect(artifact_path: @intake, source_id: "Fixture Book")
    operation = operation_router.inspect(
      artifact_path: @intake,
      source_id: "Fixture Book",
      canonical_markdown: @markdown,
      publisher: "Fixture Press"
    )

    assert_equal legacy.state, operation.state
    assert_equal legacy.commands, operation.commands
    assert_includes operation.evidence, "Operation routing input: 11111111-1111-4111-8111-111111111111 revision 3"
    assert_includes operation.evidence, "Edition declaration bound: first edition"
    assert_includes operation.evidence, "Pagination authority bound: printed page labels"
    assert operation.evidence.any? { |line| line.include?("Policy bound for coordination only") }
  end

  def test_unset_source_choice_preserves_the_existing_review_gate
    input = operation_document(@intake)
    input["source"]["source_id"] = nil
    write_json(@operation_input, input)

    result = operation_router.inspect(artifact_path: @intake)

    assert_equal "NEEDS_SOURCE_IDENTITY", result.state
    assert_empty result.commands
    error = assert_raises(Error) do
      operation_router.inspect(artifact_path: @intake, source_id: "Independent choice")
    end
    assert_equal "UNBOUND_INDEPENDENT_INPUT", error.code
  end

  def test_conflicting_independent_inputs_fail_closed
    conflicts = {
      source_id: "Another Source",
      canonical_markdown: File.join(@source_root, "another.md"),
      publisher: "Another Publisher"
    }

    conflicts.each do |key, value|
      error = assert_raises(Error) do
        operation_router.inspect(artifact_path: @intake, **{key => value})
      end
      assert_equal "CONFLICTING_INPUT", error.code, key
    end
  end

  def test_unsupported_or_incomplete_contract_fails_closed
    input = operation_document(@intake)
    input["schema_version"] = "af-ingest-routing-input/v9"
    write_json(@operation_input, input)
    error = assert_raises(Error) { operation_router }
    assert_equal "UNSUPPORTED_VERSION", error.code

    input = operation_document(@intake)
    input.fetch("base_catalog").delete("sha256")
    write_json(@operation_input, input)
    error = assert_raises(Error) { operation_router }
    assert_equal "MALFORMED_OPERATION_INPUT", error.code
  end

  def test_artifact_and_source_digest_mismatches_fail_closed
    File.write(@intake, File.read(@intake) + "\n")
    error = assert_raises(Error) { operation_router.inspect(artifact_path: @intake) }
    assert_equal "DIGEST_MISMATCH", error.code

    write_intake
    @operation_input = write_operation_input(@intake)
    File.write(@markdown, "# Changed\n")
    error = assert_raises(Error) { operation_router.inspect(artifact_path: @intake) }
    assert_equal "DIGEST_MISMATCH", error.code
  end

  def test_bound_locations_cannot_escape_the_configured_root_through_a_symlink
    outside = File.join(@tmpdir, "outside.md")
    linked = File.join(@source_root, "linked.md")
    File.write(outside, "# Outside\n")
    File.symlink(outside, linked)
    input = operation_document(@intake)
    input["source"]["canonical_markdown"] = content(outside).merge("filename" => "linked.md")
    write_json(@operation_input, input)

    error = assert_raises(Error) { operation_router.inspect(artifact_path: @intake) }

    assert_equal "MALFORMED_OPERATION_INPUT", error.code
    assert_match(/symlink/, error.message)
  end

  def test_moved_catalog_head_cannot_rebind_the_frozen_operation_base
    newer = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.1.xlsx")
    File.write(newer, "newer-catalog")
    write_project_state(newer)

    error = assert_raises(Error) { operation_router.inspect(artifact_path: @intake) }

    assert_equal "STALE_OPERATION_BASE", error.code
    assert_match(/frozen base catalog/, error.message)
  end

  def test_component_source_and_catalog_conflicts_fail_closed
    registered = JSON.parse(File.read(@intake))
    registered["registry"] = {
      "registration_status" => "registered",
      "source_ids_referencing_file" => ["Different Source"]
    }
    write_json(@intake, registered)
    @operation_input = write_operation_input(@intake)
    error = assert_raises(Error) { operation_router.inspect(artifact_path: @intake) }
    assert_equal "COMPONENT_ARTIFACT_CONFLICT", error.code

    dossier = File.join(@tmpdir, "boundary_dossier.json")
    write_json(
      dossier,
      {
        "schema_version" => "af-boundary-dossier/v0.2",
        "source" => {
          "canonical_source_id" => "Fixture Book",
          "markdown_files" => [
            {
              "filename" => File.basename(@markdown),
              "sha256" => Digest::SHA256.file(@markdown).hexdigest
            }
          ]
        },
        "base_amc" => {
          "filename" => File.basename(@base),
          "sha256" => "f" * 64
        }
      }
    )
    @operation_input = write_operation_input(dossier)
    error = assert_raises(Error) { operation_router.inspect(artifact_path: dossier) }
    assert_equal "COMPONENT_ARTIFACT_CONFLICT", error.code
  end

  def test_identical_replay_is_deterministic_read_only_and_versioned
    before = snapshot
    first = operation_router.inspect(artifact_path: @intake)
    second = operation_router.inspect(artifact_path: @intake)
    assert_equal first.to_h, second.to_h
    assert_equal before, snapshot

    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::IngestNext::CLI.run(
      [
        @intake,
        "--source-root", @source_root,
        "--catalog-root", @catalog_root,
        "--operation-input", @operation_input,
        "--json"
      ],
      out:,
      err:
    )
    payload = JSON.parse(out.string)
    assert_equal 0, status
    assert_empty err.string
    assert_equal "af-ingest-routing-result/v0.1", payload.fetch("schema_version")
    assert_equal "READY_FOR_SOURCE_REGISTRATION", payload.dig("route", "state")
    assert_equal "11111111-1111-4111-8111-111111111111", payload.dig("operation", "operation_id")
    refute payload.fetch("operation").key?("lifecycle_state")
    assert_equal before, snapshot
  end

  def test_operation_input_never_enables_auto_execution
    out = StringIO.new
    err = StringIO.new
    executed = false
    status = AfDataPipeline::IngestNext::CLI.run(
      [@intake, "--operation-input", @operation_input, "--auto"],
      out:,
      err:,
      executor: ->(*) { executed = true }
    )

    assert_equal 2, status
    refute executed
    assert_match(/read-only/, err.string)
  end

  def test_json_errors_have_a_versioned_fail_closed_contract
    input = operation_document(@intake)
    input["schema_version"] = "af-ingest-routing-input/v9"
    write_json(@operation_input, input)
    out = StringIO.new
    err = StringIO.new

    status = AfDataPipeline::IngestNext::CLI.run(
      [@intake, "--operation-input", @operation_input, "--json"],
      out:,
      err:
    )
    payload = JSON.parse(err.string)

    assert_equal 2, status
    assert_empty out.string
    assert_equal "af-ingest-routing-error/v0.1", payload.fetch("schema_version")
    assert_equal "UNSUPPORTED_VERSION", payload.dig("error", "code")
  end

  private

  def router
    AfDataPipeline::IngestNext.new(
      source_root: @source_root,
      catalog_root: @catalog_root
    )
  end

  def operation_router
    AfDataPipeline::IngestNext.new(
      source_root: @source_root,
      catalog_root: @catalog_root,
      operation_input: @operation_input
    )
  end

  def write_intake
    write_json(
      @intake,
      {
        "schema_version" => "af-source-intake/v0.1",
        "source_root" => @source_root,
        "markdown" => {
          "filename" => File.basename(@markdown),
          "sha256" => Digest::SHA256.file(@markdown).hexdigest
        },
        "registry" => {
          "registration_status" => "unregistered",
          "source_ids_referencing_file" => []
        },
        "conversion_provenance" => {
          "receipt_status" => "accepted",
          "conversion_acceptance_verified" => true
        }
      }
    )
  end

  def write_project_state(head)
    write_yaml(
      File.join(@catalog_root, "PROJECT_STATE.yml"),
      {
        "schema_version" => "adventurefinder-project-state/v0.2",
        "catalog_head" => role(head),
        "matcher_authorized_baseline" => role(@base || head),
        "production_dependency_floor" => role(@base || head)
      }
    )
  end

  def write_operation_input(artifact)
    path = File.join(@tmpdir, "operation-routing-input.json")
    write_json(path, operation_document(artifact))
    path
  end

  def operation_document(artifact)
    project_state = File.join(@catalog_root, "PROJECT_STATE.yml")
    {
      "schema_version" => "af-ingest-routing-input/v0.1",
      "operation" => {
        "contract_version" => "adventurefinder-ingest-operation/v0.1",
        "operation_id" => "11111111-1111-4111-8111-111111111111",
        "revision" => 3,
        "document_sha256" => "a" * 64
      },
      "artifact" => {
        "kind" => "file",
        "sha256" => Digest::SHA256.file(artifact).hexdigest,
        "bytes" => File.size(artifact)
      },
      "source" => {
        "source_id" => "Fixture Book",
        "canonical_markdown" => content(@markdown),
        "edition" => "first edition",
        "pagination_authority" => "printed page labels",
        "publisher" => "Fixture Press"
      },
      "base_catalog" => content(@base).merge(
        "selection_method" => "catalog_head",
        "project_state_sha256" => Digest::SHA256.file(project_state).hexdigest
      ),
      "policy" => {
        "policy_id" => "standard-local-production",
        "policy_version" => "1",
        "definition_sha256" => "b" * 64,
        "selected_values" => {"execution" => "local"}
      }
    }
  end

  def content(path)
    {
      "filename" => File.basename(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end

  def role(path)
    {
      "version" => "fixture",
      "filename" => File.basename(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end

  def snapshot
    [@intake, @operation_input, @markdown, @base].to_h do |path|
      [path, [File.size(path), Digest::SHA256.file(path).hexdigest]]
    end
  end

  def write_json(path, value)
    File.write(path, JSON.pretty_generate(value))
  end

  def write_yaml(path, value)
    File.write(path, value.to_yaml)
  end
end
