# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/staged_scoring_fixture"

class StagedScoringAuthorityStaleBaseAcceptanceTest < Minitest::Test
  include StagedScoringFixture

  MATRIX_PATH = File.expand_path("fixtures/ig13c_staged_authority_cases.json", __dir__)
  MATRIX = JSON.parse(File.binread(MATRIX_PATH)).fetch("cases").freeze
  EXPECTED_CASE_IDS = %w[
    unchanged-head compatible-unrelated-score protected-parent-change protected-source-change
    protected-page-change concurrent-id-collision unprovable-structure
    byte-identical-staged-regeneration changed-staged-content changed-authority-bytes
    changed-authority-version changed-authority-binding missing-original-base newer-base-rebind
    adventure-id-reallocation workload-rebind fresh-process-relocated-cwd
  ].freeze

  def test_matrix_declares_every_required_case_and_operator_disposition
    document = JSON.parse(File.binread(MATRIX_PATH))
    assert_equal "af-staged-scoring-authority-ig13c-cases/v0.1", document.fetch("schema_version")
    assert_equal EXPECTED_CASE_IDS.sort, MATRIX.map { |entry| entry.fetch("id") }.sort
    MATRIX.each do |entry|
      assert %w[head identity restart].include?(entry.fetch("group")), entry.fetch("id")
      assert entry.key?("decision") ^ entry.key?("error"), entry.fetch("id")
      %w[preserves forbids next_action].each do |field|
        assert_operator entry.fetch(field).length, :>, 10, "#{entry.fetch('id')}: #{field}"
      end
    end
  end

  def test_head_matrix_before_issuance_uses_content_proof_and_never_mutates_inputs
    head_cases.each do |entry|
      with_fixture do |fixture|
        set_head(fixture, entry.fetch("mutation"))
        before = snapshot(fixture.fetch(:root), except_prefixes: ["authorities/"])
        if entry.fetch("decision") == "SAFE_REUSE"
          result = fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
          assert_head_result(entry, result)
          assert_equal ["ADV-0003"], result.dig("authority", "allocation").map { |record| record.fetch("adventure_id") }
          assert_equal "ADV-0002", result.dig("authority", "allocation", 0, "resolved_parent_adventure_id")
          refute result.fetch("execution_authorized")
          refute result.fetch("catalog_adoption_authorized")
        else
          error = assert_raises(AUTH::Failure) do
            fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
          end
          assert_equal "STALE_INPUT", error.code
          assert_includes error.message, entry.fetch("reason")
          refute Dir.exist?(fixture.fetch(:store))
        end
        assert_equal before, snapshot(fixture.fetch(:root), except_prefixes: ["authorities/"]), entry.fetch("id")
      end
    end
  end

  def test_head_matrix_after_workload_freeze_preserves_authority_workload_and_roles
    with_fixture do |fixture|
      issued = fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
      authority = issued.fetch("authority")
      binding, paths = frozen_workload(fixture, authority)
      immutable = snapshot(
        fixture.fetch(:root),
        except_names: ["PROJECT_STATE.yml", "5e_Adventure_Master_Catalog_0.3.xlsx"]
      )

      head_cases.each do |entry|
        set_head(fixture, entry.fetch("mutation"))
        state_before = File.binread(fixture.fetch(:state))
        role_bytes = catalog_role_bytes(fixture.fetch(:state), fixture.fetch(:root))
        result = fixture.fetch(:service).validate!(
          current_state_path: fixture.fetch(:state),
          frozen_workload: binding,
          workload_paths: paths
        )

        assert_head_result(entry, result)
        assert result.fetch("workload_frozen"), entry.fetch("id")
        assert_equal authority, result.fetch("authority"), entry.fetch("id")
        assert_equal state_before, File.binread(fixture.fetch(:state)), entry.fetch("id")
        assert_equal role_bytes, catalog_role_bytes(fixture.fetch(:state), fixture.fetch(:root)), entry.fetch("id")
        assert_equal immutable, snapshot(
          fixture.fetch(:root),
          except_names: ["PROJECT_STATE.yml", "5e_Adventure_Master_Catalog_0.3.xlsx"]
        ), entry.fetch("id")
      end
    end
  end

  def test_identical_replay_regeneration_and_fresh_process_from_other_cwd_are_safe
    with_fixture do |fixture|
      first = fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
      assert_equal first, fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))

      staged = fixture.fetch(:staged)
      identical = File.binread(staged)
      File.binwrite(staged, identical)
      restarted = AUTH.new(evidence: fixture.fetch(:evidence), store_root: fixture.fetch(:store), mode: "synthetic")
      assert_equal first, restarted.validate!(current_state_path: fixture.fetch(:state))

      binding, paths = frozen_workload(fixture, first.fetch("authority"))
      locator_path = File.join(fixture.fetch(:root), "locators.json")
      binding_path = File.join(fixture.fetch(:root), "workload-binding.json")
      paths_path = File.join(fixture.fetch(:root), "workload-paths.json")
      write_json(locator_path, {
        "schema_version" => "af-staged-scoring-evidence-locators/v0.1",
        "evidence" => fixture.fetch(:evidence)
      })
      write_json(binding_path, binding)
      write_json(paths_path, paths)
      before = snapshot(fixture.fetch(:root))

      Dir.mktmpdir("ig13c-other-cwd") do |other_cwd|
        executable = File.expand_path("../bin/af-staged-scoring-authority", __dir__)
        stdout, stderr, status = Open3.capture3(
          RbConfig.ruby, executable, "validate",
          "--inputs", locator_path, "--store", fixture.fetch(:store),
          "--project-state", fixture.fetch(:state), "--synthetic",
          "--workload-binding", binding_path, "--workload-paths", paths_path,
          chdir: other_cwd
        )
        assert status.success?, stderr
        assert_empty stderr
        replay = JSON.parse(stdout)
        assert replay.fetch("workload_frozen")
        assert replay.fetch("preparation_allowed")
        assert_equal first.fetch("authority"), replay.fetch("authority")
        assert_equal "UNCHANGED", replay.dig("concurrency", "reason")
      end
      assert_equal before, snapshot(fixture.fetch(:root))
    end
  end

  def test_changed_staged_content_and_missing_original_base_fail_closed
    with_fixture do |fixture|
      issued = fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
      store_before = snapshot(fixture.fetch(:store))
      staged_bytes = File.binread(fixture.fetch(:staged))
      File.binwrite(fixture.fetch(:staged), staged_bytes + "changed")
      error = assert_raises(AfDataPipeline::ValidationError) do
        fixture.fetch(:service).validate!(current_state_path: fixture.fetch(:state))
      end
      assert_match(/staged|successor|hash|evidence|zip/i, error.message)
      assert_equal store_before, snapshot(fixture.fetch(:store))
      File.binwrite(fixture.fetch(:staged), staged_bytes)
      assert_equal issued, fixture.fetch(:service).validate!(current_state_path: fixture.fetch(:state))
    end

    with_fixture do |fixture|
      fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
      base = fixture.fetch(:base)
      retained = "#{base}.retained"
      File.rename(base, retained)
      error = assert_raises(AUTH::Failure) do
        fixture.fetch(:service).validate!(current_state_path: fixture.fetch(:state))
      end
      assert_equal case_by_id("missing-original-base").fetch("error"), error.code
      File.rename(retained, base)
    end
  end

  def test_changed_authority_bytes_version_and_binding_are_conflicts
    %w[changed-authority-bytes changed-authority-version changed-authority-binding].each do |case_id|
      with_fixture do |fixture|
        issued = fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
        path = authority_path(fixture, issued.fetch("authority"))
        saved = File.binread(path)
        mutate_authority(path, case_id)
        error = assert_raises(AUTH::Failure) do
          fixture.fetch(:service).validate!(current_state_path: fixture.fetch(:state))
        end
        assert_equal case_by_id(case_id).fetch("error"), error.code
        File.binwrite(path, saved)
        assert_equal issued, fixture.fetch(:service).validate!(current_state_path: fixture.fetch(:state))
      end
    end
  end

  def test_newer_base_rebind_allocation_rewrite_and_workload_rebind_are_refused
    with_fixture do |fixture|
      intent = JSON.parse(File.binread(fixture.dig(:evidence, :intent_path)))
      intent["base_amc"] = {
        "filename" => File.basename(fixture.fetch(:staged)),
        **AUTH.file_binding(fixture.fetch(:staged))
      }
      intent["intent_id"] = AUTH.digest(intent.except("intent_id"))
      write_json(fixture.dig(:evidence, :intent_path), intent)
      error = assert_raises(AUTH::Failure) do
        fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
      end
      assert_equal case_by_id("newer-base-rebind").fetch("error"), error.code
      refute Dir.exist?(fixture.fetch(:store))
    end

    with_fixture do |fixture|
      forge_allocation(fixture)
      error = assert_raises(AUTH::Failure) do
        fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state))
      end
      assert_equal case_by_id("adventure-id-reallocation").fetch("error"), error.code
      refute Dir.exist?(fixture.fetch(:store))
    end

    with_fixture do |fixture|
      authority = fixture.fetch(:service).issue!(current_state_path: fixture.fetch(:state)).fetch("authority")
      binding, paths = frozen_workload(fixture, authority)
      workload_before = paths.transform_values { |path| File.binread(path) }
      rebound = Marshal.load(Marshal.dump(binding))
      rebound["workload_id"] = "replacement-workload"
      error = assert_raises(AUTH::Failure) do
        fixture.fetch(:service).validate!(
          current_state_path: fixture.fetch(:state),
          frozen_workload: rebound,
          workload_paths: paths
        )
      end
      assert_equal case_by_id("workload-rebind").fetch("error"), error.code
      assert_equal workload_before, paths.transform_values { |path| File.binread(path) }
    end
  end

  private

  def with_fixture
    Dir.mktmpdir("ig13c-staged-authority") do |root|
      evidence = build_authority_fixture(root, cache_namespace: "ig13c")
      state = File.join(root, "PROJECT_STATE.yml")
      fixture = {
        root:, evidence:, state:,
        store: File.join(root, "authorities"),
        base: File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx"),
        staged: staged_catalog_path(root)
      }
      fixture[:service] = AUTH.new(evidence:, store_root: fixture.fetch(:store), mode: "synthetic")
      yield fixture
    end
  end

  def head_cases
    MATRIX.select { |entry| entry.fetch("group") == "head" }
  end

  def case_by_id(id)
    MATRIX.find { |entry| entry.fetch("id") == id } || raise("unknown matrix case #{id}")
  end

  def assert_head_result(entry, result)
    assert_equal entry.fetch("decision"), result.dig("concurrency", "decision"), entry.fetch("id")
    assert_equal entry.fetch("reason"), result.dig("concurrency", "reason"), entry.fetch("id")
    assert_equal(entry.fetch("decision") == "SAFE_REUSE", result.fetch("preparation_allowed"), entry.fetch("id"))
    assert_equal %w[ADV-0002 ADV-0003], result.dig("authority", "protected_ids"), entry.fetch("id")
    if entry.fetch("mutation") == "unrelated"
      assert_equal 1, result.dig("concurrency", "changed_cells").length
      assert_equal "L2", result.dig("concurrency", "changed_cells", 0, 1)
    end
  end

  def set_head(fixture, mutation)
    if mutation == "unchanged"
      write_state(fixture.fetch(:state), fixture.fetch(:base))
      return
    end
    head = File.join(fixture.fetch(:root), "5e_Adventure_Master_Catalog_0.3.xlsx")
    FileUtils.cp(fixture.fetch(:base), head)
    case mutation
    when "unrelated" then change_cell(head, "L2", 3)
    when "parent" then change_cell(head, "B3", "Changed parent")
    when "source" then change_cell(head, "E3", "Changed source")
    when "pages" then change_cell(head, "G3", 99)
    when "collision" then change_cell(head, "A2", "ADV-0003")
    when "structure"
      Zip::File.open(head) { |zip| zip.get_output_stream("unsupported.xml") { |file| file.write("<x/>") } }
    else
      raise "unknown matrix mutation #{mutation}"
    end
    write_state(fixture.fetch(:state), head, fixture.fetch(:base))
  end

  def frozen_workload(fixture, authority)
    core = {
      "schema_version" => AUTH::WORKLOAD_VERSION,
      "authority_id" => authority.fetch("authority_id"),
      "operation_id" => authority.dig("operation", "operation_id"),
      "workload_id" => authority.dig("intent", "workload_id"),
      "staged_amc" => authority.fetch("staged_amc"),
      "intended_ids" => authority.fetch("allocation").map { |record| record.fetch("adventure_id") }
    }
    paths = %w[plan snapshot index].to_h do |name|
      [name, File.join(fixture.fetch(:root), "frozen-#{name}.yml")]
    end
    File.write(paths.fetch("plan"), "synthetic plan\n")
    File.write(paths.fetch("index"), "synthetic index\n")
    File.write(paths.fetch("snapshot"), YAML.dump("staged_scoring" => core))
    [core.merge("artifacts" => paths.transform_values { |path| AUTH.file_binding(path) }), paths]
  end

  def mutate_authority(path, case_id)
    if case_id == "changed-authority-bytes"
      File.binwrite(path, File.binread(path) + "\n")
      return
    end
    document = JSON.parse(File.binread(path))
    if case_id == "changed-authority-version"
      document["schema_version"] = "af-staged-scoring-authority/v9"
    else
      document["staged_amc"]["sha256"] = "f" * 64
    end
    document["authority_id"] = AUTH.digest(document.except("authority_id"))
    File.binwrite(path, AUTH.document_bytes(document))
  end

  def authority_path(fixture, authority)
    File.join(fixture.fetch(:store), authority.dig("operation", "operation_id"), "authority.json")
  end

  def forge_allocation(fixture)
    report_path = Dir[File.join(fixture.fetch(:root), "*apply-report*.json")].fetch(0)
    receipt_path = Dir[File.join(fixture.fetch(:root), "*verified-staged*.json")].fetch(0)
    report = JSON.parse(File.binread(report_path))
    receipt = JSON.parse(File.binread(receipt_path))
    report["records"][0]["adventure_id"] = "ADV-0004"
    report["allocation"]["first_adventure_id"] = "ADV-0004"
    report["allocation"]["last_adventure_id"] = "ADV-0004"
    change_cell(fixture.fetch(:staged), "A4", "ADV-0004")
    report["output_amc"]["sha256"] = AUTH.file_binding(fixture.fetch(:staged)).fetch("sha256")
    write_json(report_path, report)
    receipt["successor"].merge!(AUTH.file_binding(fixture.fetch(:staged)))
    receipt["successor"]["apply_report_sha256"] = AUTH.file_binding(report_path).fetch("sha256")
    receipt["successor"]["apply_report_bytes"] = File.size(report_path)
    receipt["successor"]["records"] = report.fetch("records")
    receipt["successor"]["allocation"] = report.fetch("allocation")
    write_json(receipt_path, receipt)
  end

  def catalog_role_bytes(state_path, root)
    state = YAML.safe_load_file(state_path)
    AfDataPipeline::ProjectState::ROLES.to_h do |role|
      filename = state.fetch(role).fetch("filename")
      [role, File.binread(File.join(root, filename))]
    end
  end

  def snapshot(root, except_prefixes: [], except_names: [])
    return {} unless Dir.exist?(root)
    Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }.sort.each_with_object({}) do |path, result|
      relative = path.delete_prefix("#{root}/")
      next if except_names.include?(relative)
      next if except_prefixes.any? { |prefix| relative.start_with?(prefix) }
      result[relative] = Digest::SHA256.file(path).hexdigest
    end
  end
end
