# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/staged_scoring_fixture"
require "stringio"

class StagedScoringAuthorityTest < Minitest::Test
  include StagedScoringFixture

  # Reuse one process-local verified proof, not mutable fixture bytes. Each
  # test restores the exact fixture tree and deletes all generated state.
  # The cold-process CLI and relocated-service cases independently exercise
  # complete owner validation; mutation cases exercise cache invalidation.
  SHARED = {}

  def setup
    @root = SHARED[:root] ||= Dir.mktmpdir("staged-scoring-contract")
    Dir.mkdir(@root) unless Dir.exist?(@root)
    @evidence = build_authority_fixture(@root)
    @state = File.join(@root, "PROJECT_STATE.yml")
    @store = File.join(@root, "authorities")
    @service = SHARED[:service] ||= AUTH.new(evidence: @evidence, store_root: @store, mode: "synthetic")
    @base = File.join(@root, "5e_Adventure_Master_Catalog_0.1.xlsx")
    @staged = staged_catalog_path(@root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_issues_and_replays_without_mutating_inputs_or_granting_execution
    before = inputs
    first = @service.issue!(current_state_path: @state)
    replay = @service.issue!(current_state_path: @state)
    assert_equal first, replay
    assert_equal before, inputs
    assert first.fetch("preparation_allowed")
    refute first.fetch("execution_authorized")
    refute first.fetch("catalog_adoption_authorized")
    assert_equal %w[ADV-0002 ADV-0003], first.dig("authority", "protected_ids")
    assert_equal ["ADV-0003"], first.dig("authority", "allocation").map { |r| r.fetch("adventure_id") }
    assert_equal "ADV-0002", first.dig("authority", "allocation", 0, "resolved_parent_adventure_id")
  end

  def test_concurrency_decisions_before_and_after_workload_freezing
    authority = @service.issue!(current_state_path: @state).fetch("authority")
    binding, paths = frozen_workload(authority)
    original = inputs
    cases = JSON.parse(File.read(File.expand_path("../contracts/staged-scoring/v0.1/concurrency-cases.json", __dir__)))
    cases.each do |entry|
      kind = entry.fetch("mutation").to_sym
      expected = entry.fetch("decision")
      advance_head(kind)
      plain = @service.validate!(current_state_path: @state)
      frozen = @service.validate!(current_state_path: @state, frozen_workload: binding, workload_paths: paths)
      assert_equal expected, plain.dig("concurrency", "decision"), kind.to_s
      assert_equal entry.fetch("reason"), plain.dig("concurrency", "reason")
      assert_equal plain.fetch("authority"), frozen.fetch("authority")
      assert_equal plain.fetch("preparation_allowed"), frozen.fetch("preparation_allowed")
      assert_equal(expected == "SAFE_REUSE", frozen.fetch("preparation_allowed"))
      assert frozen.fetch("workload_frozen")
      assert_equal authority, frozen.fetch("authority")
    end
    assert_equal original.except(@state), inputs.slice(*original.keys).except(@state)
  end

  def test_issuance_against_compatible_head_and_refusal_against_collision
    advance_head(:collision)
    error = assert_raises(AUTH::Failure) { @service.issue!(current_state_path: @state) }
    assert_equal "STALE_INPUT", error.code
    refute Dir.exist?(@store)
    advance_head(:unrelated)
    result = @service.issue!(current_state_path: @state)
    assert_equal "UNRELATED_SCALAR_SCORES", result.dig("concurrency", "reason")
    assert_equal AUTH.file_binding(@base), result.dig("authority", "base_amc").except("filename")
  end

  def test_changed_staged_bytes_and_missing_original_base_fail_closed
    @service.issue!(current_state_path: @state)
    saved = File.binread(@staged)
    File.binwrite(@staged, saved + "changed")
    assert_raises(AfDataPipeline::ValidationError) { @service.validate!(current_state_path: @state) }
    File.binwrite(@staged, saved)
    File.rename(@base, @base + ".retained")
    assert_raises(AUTH::Failure) { @service.validate!(current_state_path: @state) }
  end

  def test_changed_authority_and_lineage_cannot_inherit_authorization
    result = @service.issue!(current_state_path: @state)
    authority_path = File.join(@store, result.dig("authority", "operation", "operation_id"), "authority.json")
    paths = [authority_path, @evidence[:approval_path], @evidence[:freeze_path],
             @evidence[:intent_path], @evidence[:policy_path], @evidence[:dossier_path],
             File.join(@evidence[:bundle_dir], "editorial_decisions.yml"),
             Dir[File.join(@root, "*apply-report*.json")].fetch(0),
             @evidence[:project_state_path], @evidence[:operation_input_path],
             @evidence[:successor_authorization_path]]
    source = YAML.safe_load_file(@evidence[:freeze_path]).fetch("source")
    paths << File.join(@evidence[:source_root], source.fetch("registry_filename"))
    paths.concat(source.fetch("markdown_files").map { |ref| File.join(@evidence[:source_root], ref.fetch("filename")) })
    paths.each do |path|
      saved = File.binread(path)
      File.binwrite(path, saved + "\nchanged")
      assert_raises(AfDataPipeline::Error, Psych::Exception) { @service.validate!(current_state_path: @state) }
      File.binwrite(path, saved)
    end
    assert_equal result, @service.validate!(current_state_path: @state)
  end

  def test_rehashed_conflicting_intent_and_workload_reallocation_are_refused
    authority = @service.issue!(current_state_path: @state).fetch("authority")
    binding, paths = frozen_workload(authority)
    bad = Marshal.load(Marshal.dump(binding))
    bad["workload_id"] = "evade-stale-input"
    advance_head(:collision)
    assert_raises(AUTH::Failure) { @service.validate!(current_state_path: @state, frozen_workload: bad, workload_paths: paths) }
    intent = JSON.parse(File.read(@evidence[:intent_path]))
    intent["workload_id"] = "evade-stale-input"
    intent["intent_id"] = AUTH.digest(intent.except("intent_id"))
    write_json(@evidence[:intent_path], intent)
    assert_raises(AUTH::Failure) { @service.validate!(current_state_path: @state) }
  end

  def test_relocation_and_identical_bytes_preserve_identity
    first = @service.issue!(current_state_path: @state)
    Dir.mktmpdir("authority-relocation") do |destination|
      FileUtils.cp_r(Dir[File.join(@root, "*")], destination)
      relocated = @evidence.transform_values { |path| path.sub(@root, destination) }
      service = AUTH.new(evidence: relocated, store_root: File.join(destination, "authorities"), mode: "synthetic")
      assert_equal first, service.validate!(current_state_path: File.join(destination, "PROJECT_STATE.yml"))
      saved = File.binread(@staged)
      File.binwrite(@staged, saved)
      assert_equal first, @service.validate!(current_state_path: @state)
    end
  end

  def test_synthetic_intent_missing_intent_and_duplicate_keys_are_not_production_authority
    service = AUTH.new(evidence: @evidence, store_root: @store)
    error = assert_raises(AUTH::Failure) { service.issue!(current_state_path: @state) }
    assert_equal "INTENT_MODE_MISMATCH", error.code
    File.write(@evidence[:intent_path], '{"schema_version":"a","schema_version":"b"}')
    assert_raises(AUTH::Failure) { @service.issue!(current_state_path: @state) }
    File.unlink(@evidence[:intent_path])
    assert_raises(AUTH::Failure) { @service.issue!(current_state_path: @state) }
    refute Dir.exist?(@store)
  end

  def test_zero_record_approval_produces_neither_authority_nor_workload
    Dir.mktmpdir("zero-authority") do |root|
      evidence = build_authority_fixture(root, zero: true)
      store = File.join(root, "authorities")
      result = AUTH.new(evidence:, store_root: store, mode: "synthetic").issue!(current_state_path: File.join(root, "PROJECT_STATE.yml"))
      assert_equal "NO_SUCCESSOR_NEEDED", result.fetch("status")
      assert_nil result.fetch("authority")
      refute result.fetch("preparation_allowed")
      refute Dir.exist?(store)
      refute File.exist?(File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx"))
    end
  end

  def test_newer_base_rebind_and_unattributed_or_inert_intent_are_refused
    original = File.binread(@evidence[:intent_path])
    ["base", "attribution", "purpose", "schema", "source", "policy"].each do |change|
      intent = JSON.parse(original)
      case change
      when "base" then intent["base_amc"] = {"filename" => File.basename(@staged), **AUTH.file_binding(@staged)}
      when "attribution" then intent["selected_by"] = ""
      when "purpose" then intent["purpose"] = "inert-policy-selection"
      when "schema" then intent["schema_version"] = "unsupported/v99"
      when "source" then intent["source"]["pagination_authority"] = "different bounds"
      when "policy" then intent["policy"]["sha256"] = "f" * 64
      end
      intent["intent_id"] = AUTH.digest(intent.except("intent_id"))
      write_json(@evidence[:intent_path], intent)
      assert_raises(AfDataPipeline::ValidationError) { @service.issue!(current_state_path: @state) }
      refute Dir.exist?(@store)
    end
  end

  def test_forged_self_consistent_allocation_is_checked_against_frozen_record_order
    report_path = Dir[File.join(@root, "*apply-report*.json")].fetch(0)
    receipt_path = Dir[File.join(@root, "*verified-staged*.json")].fetch(0)
    report = JSON.parse(File.read(report_path))
    receipt = JSON.parse(File.read(receipt_path))
    report["records"][0]["adventure_id"] = "ADV-0004"
    report["allocation"]["first_adventure_id"] = "ADV-0004"
    report["allocation"]["last_adventure_id"] = "ADV-0004"
    change_cell(@staged, "A4", "ADV-0004")
    report["output_amc"]["sha256"] = AUTH.file_binding(@staged).fetch("sha256")
    write_json(report_path, report)
    receipt["successor"].merge!(AUTH.file_binding(@staged))
    receipt["successor"]["apply_report_sha256"] = AUTH.file_binding(report_path).fetch("sha256")
    receipt["successor"]["apply_report_bytes"] = File.size(report_path)
    receipt["successor"]["records"] = report.fetch("records")
    receipt["successor"]["allocation"] = report.fetch("allocation")
    write_json(receipt_path, receipt)
    error = assert_raises(AUTH::Failure) { @service.issue!(current_state_path: @state) }
    assert_equal "ALLOCATION_CONFLICT", error.code
    refute Dir.exist?(@store)
  end

  def test_fresh_process_cli_reads_the_public_evidence_envelope
    inputs = File.join(@root, "inputs.json")
    write_json(inputs, {"schema_version" => "af-staged-scoring-evidence-locators/v0.1", "evidence" => @evidence})
    executable = File.expand_path("../bin/af-staged-scoring-authority", __dir__)
    stdout, stderr, status = Open3.capture3({"AF_DATA_PIPELINE_DATA_ROOT" => @root}, RbConfig.ruby, executable, "issue", "--inputs", inputs,
                                          "--store", @store, "--project-state", @state, "--synthetic")
    assert status.success?, stderr
    assert_empty stderr
    result = JSON.parse(stdout)
    assert result.fetch("preparation_allowed")
    assert_equal result, @service.validate!(current_state_path: @state)
    out = StringIO.new
    err = StringIO.new
    assert_equal 2, AUTH.run(["invalid"], out:, err:)
    assert_empty out.string
    assert_equal "USAGE", JSON.parse(err.string).dig("error", "code")
  end

  def test_publication_race_and_partial_publication_never_reissue
    publisher = @service.method(:publish)
    staged = @staged
    injected = lambda do |path, document|
      publisher.call(path, document)
      File.open(staged, "ab") { |file| file.write("race") } if File.basename(path) == "authority.json"
    end
    @service.define_singleton_method(:publish, injected)
    begin
      error = assert_raises(AUTH::Failure) { @service.issue!(current_state_path: @state) }
      assert_equal "INPUT_RACE", error.code, error.message
    ensure
      @service.singleton_class.send(:remove_method, :publish)
    end
    refute File.exist?(File.join(@store, "11111111-1111-4111-8111-111111111111", "publication.json"))
    bytes = File.binread(@staged)
    File.binwrite(@staged, bytes.delete_suffix("race"))
    assert_raises(AUTH::Failure) { @service.issue!(current_state_path: @state) }
  end

  def test_rehashed_authority_or_changed_workload_artifact_is_refused
    authority = @service.issue!(current_state_path: @state).fetch("authority")
    binding, paths = frozen_workload(authority)
    File.write(paths.fetch("plan"), "different plan")
    assert_raises(AUTH::Failure) { @service.validate!(current_state_path: @state, frozen_workload: binding, workload_paths: paths) }
    path = File.join(@store, authority.dig("operation", "operation_id"), "authority.json")
    authority["permissions"] << "inference"
    authority["authority_id"] = AUTH.digest(authority.except("authority_id"))
    write_json(path, authority)
    error = assert_raises(AUTH::Failure) { @service.validate!(current_state_path: @state) }
    assert_equal "AUTHORITY_CONFLICT", error.code
  end

  private

  def inputs
    Dir[File.join(@root, "**", "*")].select { |p| File.file?(p) && !p.start_with?(@store + "/") }
      .to_h { |p| [p, Digest::SHA256.file(p).hexdigest] }
  end

  def advance_head(kind)
    head = File.join(@root, "5e_Adventure_Master_Catalog_0.3.xlsx")
    FileUtils.cp(@base, head)
    case kind
    when :unrelated then change_cell(head, "L2", 3)
    when :parent then change_cell(head, "B3", "Changed parent")
    when :source then change_cell(head, "E3", "Changed source")
    when :pages then change_cell(head, "G3", 99)
    when :collision then change_cell(head, "A2", "ADV-0003")
    when :structure
      Zip::File.open(head) { |zip| zip.get_output_stream("unsupported.xml") { |f| f.write("<x/>") } }
    end
    write_state(@state, head, @base)
  end

  def frozen_workload(authority)
    core = {"schema_version" => AUTH::WORKLOAD_VERSION, "authority_id" => authority.fetch("authority_id"),
            "operation_id" => authority.dig("operation", "operation_id"), "workload_id" => authority.dig("intent", "workload_id"),
            "staged_amc" => authority.fetch("staged_amc"), "intended_ids" => ["ADV-0003"]}
    paths = %w[plan snapshot index].to_h { |name| [name, File.join(@root, "#{name}.yml")] }
    File.write(paths.fetch("plan"), "synthetic plan\n")
    File.write(paths.fetch("index"), "synthetic index\n")
    File.write(paths.fetch("snapshot"), YAML.dump("staged_scoring" => core))
    [core.merge("artifacts" => paths.transform_values { |p| AUTH.file_binding(p) }), paths]
  end
end
