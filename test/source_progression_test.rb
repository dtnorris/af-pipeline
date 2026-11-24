# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class SourceProgressionTest < Minitest::Test
  class FakeSheet
    def validate_catalog_schema! = true
    def catalog_records = []
    def column_for_header(_header) = "A"
    def cell_value(_reference) = nil
    def name = "5e Adventures"
  end

  class FakeWorkbook
    def initialize(_path); end
    def sheet_by_name!(_name) = FakeSheet.new
  end

  class DossierGenerator
    def self.generate!(**options)
      AfDataPipeline::BoundaryDossier.generate!(**options, workbook_class: FakeWorkbook)
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("source-progression", File.realpath(Dir.tmpdir))
    @source_root = File.join(@tmpdir, "source")
    @catalog_root = File.join(@tmpdir, "catalog")
    @pipeline_root = File.join(@tmpdir, "pipeline")
    FileUtils.mkdir_p([@source_root, @catalog_root, @pipeline_root])
    @registry = File.join(@source_root, "source_registry.yml")
    File.write(
      @registry,
      "schema_version: #{AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION}\n" \
      "sources:\n  \"Existing Fixture\":\n    file: \"Existing.md\"\n"
    )
    @base = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.0.xlsx")
    File.binwrite(@base, "synthetic catalog fixture")
    @project_state = File.join(@catalog_root, "PROJECT_STATE.yml")
    write_project_state
    @converted = File.join(@tmpdir, "converter-output.md")
    File.write(
      @converted,
      "<!-- PDF Page 1 -->\n<!-- Printed Page 10 -->\n# Structural Fixture\n"
    )
    @receipt = File.join(@tmpdir, "conversion-receipt.json")
    write_receipt
    @canonical = File.join(@source_root, "Fixture_Book_LLM_Edition.md")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_advances_exactly_one_transition_at_a_time_and_stops_at_editorial_handoff
    state_before = File.binread(@project_state)
    base_before = File.binread(@base)
    receipt_operation = write_operation(@receipt, canonical: nil, revision: 1)

    intake_result = advance(@receipt, receipt_operation, canonical_destination: @canonical)
    assert_pass intake_result, "SOURCE_INTAKE_READY", "accepted_conversion_to_source_intake"
    assert_equal File.binread(@converted), File.binread(@canonical)
    intake = operation_artifact_path(intake_result)

    dossier_result = advance(intake, write_operation(intake, revision: 2))
    assert_pass dossier_result, "BOUNDARY_DOSSIER_READY", "source_intake_to_boundary_dossier"
    assert_equal({"file" => File.basename(@canonical)}, YAML.safe_load_file(@registry).dig("sources", "Fixture Book"))
    dossier = operation_artifact_path(dossier_result)

    dossier_operation = write_operation(dossier, revision: 3)
    gate = advance(dossier, dossier_operation)
    assert_equal "GATE", gate.status
    assert_equal "NEEDS_EDITORIAL_SPECIFICATIONS", gate.state
    assert_empty gate.outputs
    refute_path_exists File.join(@pipeline_root, "audits/pre-scoring/fixture-book-boundary-editorial")
    initialize_historical_bundle(dossier)
    editorial_result = advance(dossier, dossier_operation)
    assert_pass editorial_result, "BOUNDARY_EDITORIAL_HANDOFF_READY", "boundary_dossier_to_editorial_handoff"
    assert_equal %w[editorial_context editorial_decisions], operation_artifacts(editorial_result).map { |item| item.fetch("kind") }
    decisions = YAML.safe_load_file(operation_artifact_path(editorial_result, "editorial_decisions"))
    assert_empty decisions.fetch("candidates")
    assert_equal state_before, File.binread(@project_state)
    assert_equal base_before, File.binread(@base)

    payload = AfDataPipeline::SourceProgression::CLI.payload(editorial_result)
    assert payload.dig("contract", "one_transition_maximum")
    refute payload.dig("contract", "operation_lifecycle_mutated")
    refute payload.dig("contract", "semantic_choices_created")
    refute payload.dig("contract", "catalog_roles_mutated")
    refute payload.dig("contract", "inference_or_scoring_executed")
  end

  def test_exact_replay_reuses_compatible_completed_outputs
    operation = write_operation(@receipt, canonical: nil, revision: 1)
    first = advance(@receipt, operation, canonical_destination: @canonical)
    second = advance(@receipt, operation, canonical_destination: @canonical)
    assert_equal %w[canonical_markdown source_intake], second.reused
    assert_equal first.outputs, second.outputs

    intake = operation_artifact_path(first)
    intake_operation = write_operation(intake, revision: 2)
    dossier_first = advance(intake, intake_operation)
    dossier_second = advance(intake, intake_operation)
    assert_equal %w[source_registration boundary_dossier], dossier_second.reused
    assert_equal dossier_first.outputs, dossier_second.outputs

    dossier = operation_artifact_path(dossier_first)
    dossier_operation = write_operation(dossier, revision: 3)
    initialize_historical_bundle(dossier)
    editorial_first = advance(dossier, dossier_operation)
    decisions = operation_artifact_path(editorial_first, "editorial_decisions")
    write_yaml(
      decisions,
      "schema_version" => AfDataPipeline::BoundaryEditorial::DECISIONS_SCHEMA_VERSION,
      "candidates" => [
        {
          "candidate_key" => "FX-HUMAN",
          "provisional_title" => "Human retained fixture",
          "playability_evidence" => "Explicit reviewer evidence.",
          "open_questions" => ["Human note retained verbatim."],
          "review_history" => [
            {"phase" => "phase1", "status" => "retained", "rationale" => "Human review remains pending."}
          ],
          "disposition" => "pending"
        }
      ]
    )
    ledger_before = File.binread(decisions)
    editorial_second = advance(dossier, dossier_operation)
    assert_equal ["editorial_bundle"], editorial_second.reused
    assert_equal ledger_before, File.binread(decisions)
  end

  # Starts from the canonical empty registry and simulates interruption after
  # registration. Fresh Ruby processes must reuse it and the editorial ledger;
  # fixture command/validator failures surface as assertions, never approvals.
  def test_resumes_after_exact_registration_from_an_interrupted_prior_call
    File.binwrite(@registry, "schema_version: adventurefinder-source-registry/v0.1\nsources: {}\n")
    File.binwrite(@converted, "<!-- Printed Page 1 -->\n1\n<!-- Printed Page 2 -->\n2\n")
    write_receipt
    protected_before = [File.binread(@base), File.binread(@project_state)]
    intake_result = advance(
      @receipt,
      write_operation(@receipt, canonical: nil, revision: 1),
      canonical_destination: @canonical
    )
    intake = operation_artifact_path(intake_result)
    AfDataPipeline::SourceRegister.register!(
      source_root: @source_root,
      source_id: "Fixture Book",
      markdown_path: @canonical,
      registry_path: @registry
    )

    registration_before = File.binread(@registry)
    canonical_before = File.binread(@canonical)
    intake_operation = write_operation(intake, revision: 2)
    payload = advance_in_fresh_process(intake, intake_operation)

    assert_equal "PASS", payload.fetch("status")
    assert_equal ["source_registration"], payload.fetch("reused")
    assert_equal registration_before, File.binread(@registry)
    assert_equal({"Fixture Book" => {"file" => File.basename(@canonical)}},
      YAML.safe_load_file(@registry).fetch("sources"))
    result = advance(intake, intake_operation)

    assert_equal "PASS", result.status
    assert_equal %w[source_registration boundary_dossier], result.reused
    assert File.file?(operation_artifact_path(result))
    dossier = operation_artifact_path(result)
    editorial_operation = write_operation(dossier, revision: 3)
    initialize_historical_bundle(dossier)
    editorial = advance(dossier, editorial_operation)
    decisions = operation_artifact_path(editorial, "editorial_decisions")
    assert_empty YAML.safe_load_file(decisions).fetch("candidates")
    File.open(decisions, "a") { |file| file.puts("# human review remains pending") }
    decisions_before = File.binread(decisions)
    replay = advance_in_fresh_process(dossier, editorial_operation)
    assert_equal ["editorial_bundle"], replay.fetch("reused")
    assert_equal decisions_before, File.binread(decisions)
    assert_equal canonical_before, File.binread(@canonical)
    assert_equal protected_before, [File.binread(@base), File.binread(@project_state)]
    assert_equal registration_before, File.binread(@registry)
    assert_equal "BOUNDARY_EDITORIAL_HANDOFF_READY", replay.fetch("state")
    refute replay.dig("contract", "inference_or_scoring_executed")
    refute replay.dig("contract", "catalog_roles_mutated")
  end

  def test_non_ready_conversion_remains_a_human_gate_without_side_effects
    write_receipt(state: "needs_page_review", downstream_ready: false)
    receipt = JSON.parse(File.binread(@receipt))
    receipt["extraction_quality"] = {"issues" => [{"page" => 1, "fingerprint" => "f" * 64}]}
    receipt["unresolved_issue_fingerprints"] = ["f" * 64]
    write_json(@receipt, receipt)
    operation = write_operation(@receipt, canonical: nil, revision: 1)
    executor = ->(*) { flunk "page review must not execute a continuation" }
    result = advance(@receipt, operation, canonical_destination: @canonical, executor:)

    assert_equal "GATE", result.status
    assert_equal "NEEDS_PAGE_REVIEW", result.state
    refute File.exist?(@canonical)
    assert_empty result.outputs
    assert_empty Dir.children(@pipeline_root)
  end

  def test_public_cli_emits_versioned_results_and_errors
    operation = write_operation(@receipt, canonical: nil, revision: 1)
    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::SourceProgression::CLI.run(
      [
        @receipt, "--operation-input", operation,
        "--source-root", @source_root, "--catalog-root", @catalog_root,
        "--pipeline-root", @pipeline_root, "--registry", @registry,
        "--canonical-destination", @canonical, "--json"
      ],
      out:, err:, executor: method(:execute_command)
    )
    payload = JSON.parse(out.string)
    assert_equal 0, status
    assert_empty err.string
    assert_equal AfDataPipeline::SourceProgression::RESULT_SCHEMA, payload.fetch("schema_version")
    assert_equal "SOURCE_INTAKE_READY", payload.fetch("state")

    malformed = File.join(@tmpdir, "malformed-operation.json")
    File.write(malformed, "{}")
    out = StringIO.new
    err = StringIO.new
    status = AfDataPipeline::SourceProgression::CLI.run(
      [
        @receipt, "--operation-input", malformed,
        "--source-root", @source_root, "--catalog-root", @catalog_root,
        "--pipeline-root", @pipeline_root, "--json"
      ],
      out:, err:, executor: method(:execute_command)
    )
    error = JSON.parse(err.string)
    assert_equal 2, status
    assert_empty out.string
    assert_equal AfDataPipeline::SourceProgression::ERROR_SCHEMA, error.fetch("schema_version")
    assert_equal "MALFORMED_OPERATION_INPUT", error.dig("error", "code")
  end

  def test_conflicting_canonical_bytes_and_zero_exit_without_output_fail_closed
    File.write(@canonical, "conflicting bytes")
    operation = write_operation(@receipt, canonical: nil, revision: 1)
    error = assert_raises(AfDataPipeline::SourceProgression::Error) do
      advance(@receipt, operation, canonical_destination: @canonical)
    end
    assert_equal "INVALID_CONTINUATION_EVIDENCE", error.code
    assert_match(/SHA-256 mismatch/, error.message)

    FileUtils.rm_f(@canonical)
    silent_executor = ->(_argv, _cwd) { [0, "", ""] }
    error = assert_raises(AfDataPipeline::SourceProgression::Error) do
      advance(@receipt, operation, canonical_destination: @canonical, executor: silent_executor)
    end
    assert_equal "INVALID_CONTINUATION_OUTPUT", error.code
    assert_match(/destination is missing/, error.message)
  end

  def test_corrupt_or_wrong_identity_generated_intake_never_advances
    operation = write_operation(@receipt, canonical: nil, revision: 1)
    corrupt_executor = lambda do |argv, _cwd|
      if File.basename(argv.first) == "af-source-place"
        AfDataPipeline::SourcePlacement.place!(
          receipt_path: argv[1], source_root: value_after(argv, "--source-root"),
          destination: value_after(argv, "--destination")
        )
      else
        output = value_after(argv, "--output")
        FileUtils.mkdir_p(output)
        File.write(File.join(output, AfDataPipeline::SourceIntake::JSON_FILENAME), JSON.generate("schema_version" => "wrong"))
        File.write(File.join(output, AfDataPipeline::SourceIntake::MARKDOWN_FILENAME), "corrupt")
      end
      [0, "", ""]
    end

    error = assert_raises(AfDataPipeline::SourceProgression::Error) do
      advance(@receipt, operation, canonical_destination: @canonical, executor: corrupt_executor)
    end
    assert_equal "INVALID_CONTINUATION_OUTPUT", error.code
    assert_match(/wrong schema/, error.message)
  end

  def test_unsupported_offset_registration_is_a_focused_operator_gate
    intake_result = advance(
      @receipt,
      write_operation(@receipt, canonical: nil, revision: 1),
      canonical_destination: @canonical
    )
    intake = operation_artifact_path(intake_result)
    write_yaml(
      @registry,
      "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
      "sources" => {
        "Fixture Book" => {"file" => File.basename(@canonical), "page_marker_offset" => "+9"}
      }
    )
    operation = write_operation(intake, revision: 2)

    error = assert_raises(AfDataPipeline::SourceProgression::Error) { advance(intake, operation) }
    assert_equal "NEEDS_MANUAL_SOURCE_REGISTRATION", error.code
  end

  def test_stale_base_and_source_qa_gaps_do_not_initialize_editorial_work
    intake_result = advance(
      @receipt,
      write_operation(@receipt, canonical: nil, revision: 1),
      canonical_destination: @canonical
    )
    intake = operation_artifact_path(intake_result)
    operation = write_operation(intake, revision: 2)
    moved = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.1.xlsx")
    File.write(moved, "moved head")
    write_project_state(moved)
    error = assert_raises(AfDataPipeline::SourceProgression::Error) { advance(intake, operation) }
    assert_equal "STALE_OPERATION_BASE", error.code

    write_project_state
    dossier_result = advance(intake, write_operation(intake, revision: 2))
    dossier = operation_artifact_path(dossier_result)
    dossier_json = JSON.parse(File.binread(dossier))
    dossier_json.fetch("source_files").first.fetch("navigation_evidence").fetch("page_mappings").first["mapping_status"] = "unknown"
    write_json(dossier, dossier_json)
    result = advance(dossier, write_operation(dossier, revision: 3))
    assert_equal "GATE", result.status
    assert_equal "NEEDS_SOURCE_QA_REVIEW", result.state
    refute Dir.exist?(File.join(@pipeline_root, "audits", "pre-scoring", "fixture-book-boundary-editorial"))
  end

  # The supported continuation CLI must carry selection into its router and
  # initializer; historical output cannot be relabeled by selecting later.
  def test_selected_cli_initializes_exact_public_bundle_and_refuses_historical_reselection
    intake = operation_artifact_path(advance(@receipt, write_operation(@receipt, canonical: nil, revision: 1),
                                            canonical_destination: @canonical))
    dossier = operation_artifact_path(advance(intake, write_operation(intake, revision: 2)))
    operation = write_operation(dossier, revision: 3)
    public_root = ENV.fetch("AF_PUBLIC_SPEC_ROOT", File.expand_path("../../af-specification-md", __dir__))
    expected = AfDataPipeline::EditorialSpecifications.bind!(public_root)
    environment = {"AF_DATA_PIPELINE_DATA_ROOT" => @pipeline_root}
    arguments = [File.expand_path("../bin/af-source-progress", __dir__), dossier,
                 "--operation-input", operation, "--source-root", @source_root,
                 "--catalog-root", @catalog_root, "--pipeline-root", @pipeline_root,
                 "--spec-root", public_root, "--json"]
    stdout, stderr, status = Open3.capture3(environment, *arguments)
    assert status.success?, stderr
    assert_equal "PASS", JSON.parse(stdout).fetch("status")
    bundle = File.join(@pipeline_root, "audits/pre-scoring/fixture-book-boundary-editorial")
    context = JSON.parse(File.binread(File.join(bundle, "editorial_context.json")))
    assert_equal expected, context.fetch("public_specifications")
    stdout, stderr, status = Open3.capture3(environment, *arguments)
    assert status.success?, stderr
    assert_equal ["editorial_bundle"], JSON.parse(stdout).fetch("reused")
    FileUtils.remove_entry(bundle)
    initialize_historical_bundle(dossier)
    stdout, stderr, status = Open3.capture3(environment, *arguments)
    assert_equal 2, status.exitstatus, stdout
    assert_includes stderr, "incompatible public specifications"
  end

  private

  # Reconstruct an already initialized historical bundle to keep exact replay
  # coverage independent of the forward selector. No historical binding changes.
  def initialize_historical_bundle(dossier)
    AfDataPipeline::BoundaryEditorial.init!(
      dossier_path: dossier,
      output_dir: File.join(@pipeline_root, "audits/pre-scoring/fixture-book-boundary-editorial")
    )
  end

  # Reuses this disposable operation fixture and its workbook-only fake in a
  # fresh Ruby interpreter. Returns the actual progression CLI payload, raising
  # an assertion on child errors or JSON::ParserError on malformed output.
  def advance_in_fresh_process(artifact, operation)
    context = %w[source_root catalog_root pipeline_root registry].to_h do |name|
      [name, instance_variable_get("@#{name}")]
    end
    script = <<~RUBY
      begin
        fixture = SourceProgressionTest.new("fresh process replay")
        JSON.parse(ARGV.fetch(0)).each { |name, path| fixture.instance_variable_set("@\#{name}", path) }
        result = fixture.send(:advance, ARGV.fetch(1), ARGV.fetch(2))
        STDOUT.write(JSON.generate(AfDataPipeline::SourceProgression::CLI.payload(result)))
        STDOUT.flush
        # This child runs one fixture transition, not the file's Minitest suite.
        exit! 0
      rescue StandardError => error
        warn error.full_message
        exit! 1
      end
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-r", File.expand_path(__FILE__), "-e", script,
      JSON.generate(context), artifact, operation
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def advance(artifact, operation, canonical_destination: nil, executor: method(:execute_command))
    AfDataPipeline::SourceProgression.advance!(
      artifact_path: artifact,
      operation_input_path: operation,
      source_root: @source_root,
      catalog_root: @catalog_root,
      pipeline_root: @pipeline_root,
      canonical_destination:,
      registry_path: @registry,
      executor:
    )
  end

  def execute_command(argv, _cwd)
    out = StringIO.new
    err = StringIO.new
    status = case File.basename(argv.first)
             when "af-source-place"
               AfDataPipeline::SourcePlacement::CLI.run(argv.drop(1), out:, err:)
             when "af-source-intake"
               AfDataPipeline::SourceIntake::CLI.run(argv.drop(1), out:, err:)
             when "af-source-register"
               AfDataPipeline::SourceRegister::CLI.run(argv.drop(1), out:, err:)
             when "af-boundary-dossier"
               AfDataPipeline::BoundaryDossier::CLI.run(argv.drop(1), out:, err:, generator: DossierGenerator)
             when "af-boundary-editorial"
               AfDataPipeline::BoundaryEditorial::CLI.run(argv.drop(1), out:, err:)
             else
               raise "unexpected command #{argv.first}"
             end
    [status, out.string, err.string]
  end

  def write_receipt(state: "ready", downstream_ready: true)
    write_json(
      @receipt,
      "schema" => AfDataPipeline::IngestNext::CONVERSION_RECEIPT_SCHEMA,
      "state" => state,
      "downstream_ready" => downstream_ready,
      "source" => {"path" => File.join(@tmpdir, "Fixture.pdf")},
      "output" => {
        "path" => @converted,
        "sha256" => Digest::SHA256.file(@converted).hexdigest
      }
    )
  end

  def write_operation(artifact, canonical: @canonical, revision:)
    path = File.join(@tmpdir, "operation-#{revision}-#{File.basename(artifact)}.json")
    source_content = canonical && content(canonical)
    write_json(
      path,
      "schema_version" => "af-ingest-routing-input/v0.1",
      "operation" => {
        "contract_version" => "adventurefinder-ingest-operation/v0.1",
        "operation_id" => "11111111-1111-4111-8111-111111111111",
        "revision" => revision,
        "document_sha256" => ("a" * 64)
      },
      "artifact" => {
        "kind" => "file", "sha256" => Digest::SHA256.file(artifact).hexdigest,
        "bytes" => File.size(artifact)
      },
      "source" => {
        "source_id" => "Fixture Book", "canonical_markdown" => source_content,
        "edition" => "fixture edition", "pagination_authority" => "printed labels",
        "publisher" => "Fixture Press"
      },
      "base_catalog" => content(@base).merge(
        "selection_method" => "catalog_head",
        "project_state_sha256" => Digest::SHA256.file(@project_state).hexdigest
      ),
      "policy" => {
        "policy_id" => "standard-local-production", "policy_version" => "1",
        "definition_sha256" => ("b" * 64), "selected_values" => {"execution" => "local"}
      }
    )
    path
  end

  def write_project_state(head = @base)
    role = ->(path) { {"version" => "fixture", **content(path)} }
    write_yaml(
      @project_state,
      "schema_version" => "adventurefinder-project-state/v0.2",
      "catalog_head" => role.call(head),
      "matcher_authorized_baseline" => role.call(@base),
      "production_dependency_floor" => role.call(@base)
    )
  end

  def content(path)
    {"filename" => File.basename(path), "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
  end

  def operation_artifacts(result)
    result.outputs.select { |item| item.fetch("role") == "operation_artifact" }
  end

  def operation_artifact_path(result, kind = nil)
    items = operation_artifacts(result)
    item = kind ? items.find { |candidate| candidate.fetch("kind") == kind } : items.first
    File.join(@pipeline_root, item.dig("content", "locator", "path"))
  end

  def assert_pass(result, state, transition)
    assert_equal "PASS", result.status
    assert_equal state, result.state
    assert_equal transition, result.transition
  end

  def value_after(argv, option)
    argv.fetch(argv.index(option) + 1)
  end

  def write_json(path, value)
    File.write(path, JSON.pretty_generate(value))
    path
  end

  def write_yaml(path, value)
    File.write(path, YAML.dump(value))
    path
  end
end
