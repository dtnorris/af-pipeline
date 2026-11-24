# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/compatibility_amc_fixture"
require_relative "support/standing_bulk_score_release_fixture"
require "minitest/mock"

class AmcScoredNewIdAuthorizationTest < Minitest::Test
  include CompatibilityAmcFixture

  class << self
    attr_accessor :release_template, :catalog_schema
  end

  # The real writer's header/ID resolver supplies the schema. Only cell reads
  # and workbook loading are faked for tests of authorization decisions.
  class MemoryCatalog
    Cell = Data.define(:reference, :value)
    attr_reader :name, :part

    def initialize(schema, values)
      @schema = schema
      @values = values
      @name = schema.name
      @part = schema.part
    end

    def resolve_headers!(dimensions)
      dimensions.each { |dimension| @schema.column_for_dimension(dimension) }
    end

    def validate_unique_adventure_ids!
      @schema.validate_unique_adventure_ids!
    end

    def row_for_adventure(id)
      @schema.row_for_adventure(id)
    end

    def column_for_dimension(dimension)
      @schema.column_for_dimension(dimension)
    end
    alias column_for_header column_for_dimension

    def cell(reference)
      Cell.new(reference:, value: @values[reference])
    end

    def cell_value(reference)
      @values[reference]
    end

    def cell_numeric_value(cell)
      cell.value
    end

    def blank_cell?(cell)
      cell.value.nil?
    end

    def cell_formula(_cell)
      nil
    end
  end

  def test_exact_ig17_release_authorizes_only_its_scored_boundary_cells_and_replays_identically
    with_release do |fixture, result, base|
      # The template's proof comes from the public validator over real retained
      # apply/finalize artifacts. Reuse that immutable proof when testing the
      # checker; tampering tests below always invoke the real validator again.
      first, second = AfDataPipeline::AmcScoredNewIdAuthorization.stub(:validate!, release_template.fetch(:proof)) do
        [compatibility(fixture, result, base), compatibility(fixture, result, base)]
      end

      assert_equal "PASS", first.fetch("status"), first.fetch("errors").join("\n")
      assert_equal first, second
      assert_equal ["ADV-0003"], first.fetch("added_adventure_ids")
      authority = first.fetch("scored_new_id_authorization")
      assert_equal result.manifest.fetch("manifest_id"), authority.fetch("manifest_id")
      assert_equal ["J4", "K4", "L4", "P4"], authority.fetch("authorized_cells").map { |row| row.fetch("cell") }.sort
      assert_equal [1, 3, 4, 5], authority.fetch("authorized_cells").map { |row| row.fetch("proposed_value") }.sort
    end
  end

  def test_no_free_standing_flag_or_missing_package_can_bypass_blank_field_contract
    with_release do |_fixture, result, base|
      report = AfDataPipeline::AmcCompatibilityCheck.check(
        candidate_path: result.workbook_path,
        base_path: base
      )

      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("Combat Emphasis") && error.include?("must be blank") }

      incomplete = AfDataPipeline::AmcCompatibilityCheck.check(
        candidate_path: result.workbook_path,
        base_path: base,
        release_manifest_path: result.manifest_path
      )
      assert_equal "FAIL", incomplete.fetch("status")
      assert_includes incomplete.fetch("errors"), "release_manifest_path and staged_path must be supplied together"
    end
  end

  def test_current_comparison_path_does_not_replace_the_exact_release_base
    with_release do |fixture, result, base|
      current = File.join(fixture.root, "5e_Adventure_Master_Catalog_0.1.1.xlsx")
      FileUtils.cp(base, current)
      report = AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: result.workbook_path,
        base_path: current, release_base_path: base, staged_path: fixture.staged_path,
        release_manifest_path: result.manifest_path)
      assert_equal "PASS", report.fetch("status")
      assert_equal AfDataPipeline::StandingBulkScorePolicy.file_binding(base),
                   report.dig("scored_new_id_authorization", "base_amc")
      missing = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: result.workbook_path,
        base_path: current, release_base_path: base)
      assert_includes missing.fetch("errors"), "release_base_path requires scored-release provenance"
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: result.workbook_path,
          base_path: current, release_base_path: current, staged_path: fixture.staged_path,
          release_manifest_path: result.manifest_path)
      end
    end
  end

  def test_changed_candidate_unrelated_cell_formula_or_style_is_rejected_by_exact_bytes
    mutations = {
      "score" => ["xl/worksheets/sheet1.xml", "<v>3</v>", "<v>5</v>"],
      "unrelated cell" => ["xl/worksheets/sheet1.xml", "Unit A", "Changed Unit"],
      "formula" => ["xl/worksheets/sheet1.xml", "<f>COUNT(I4:U4)</f>", "<f>COUNT(I4:T4)</f>"],
      "style" => ["xl/styles.xml", "D0E0E3", "D0E0E4"]
    }
    mutations.each do |label, (member, before, after)|
      with_release do |fixture, result, base|
        replace_zip_text(result.workbook_path, member, before, after)

        error = assert_raises(AfDataPipeline::ValidationError, label) { validate_release(fixture, result, base) }
        assert_includes error.message, "final_workbook artifact is missing or changed", label
      end
    end
  end

  def test_changed_or_missing_authority_evidence_is_rejected
    with_release do |fixture, result, base|
      path = File.join(result.output_dir, "release-authorization.json")
      document = JSON.parse(File.binread(path))
      document["lineage"].delete("approval_id")
      File.write(path, JSON.pretty_generate(document) + "\n")

      error = assert_raises(AfDataPipeline::ValidationError) { validate_release(fixture, result, base) }
      assert_includes error.message, "authorization artifact is missing or changed"
    end
  end

  def test_extra_missing_or_conflicting_boundary_id_accounting_is_rejected
    [
      [{"local_key" => "unit-c", "adventure_id" => "ADV-0003"}, {"local_key" => "extra", "adventure_id" => "ADV-0999"}],
      []
    ].each do |rows|
      with_release do |fixture, result, base|
        rewrite_manifest(result.manifest_path) do |manifest|
          manifest["boundary_created_ids"] = rows
          manifest["counts"]["boundary_created_ids"] = rows.length
        end

        proof = result_proof(rows.map { |row| row.fetch("adventure_id") }, [])
        report = AfDataPipeline::AmcScoredNewIdAuthorization.stub(:validate!, proof) do
          compatibility(fixture, result, base)
        end

        assert_equal "FAIL", report.fetch("status")
        assert(report.fetch("errors").any? do |error|
          error.include?("boundary-created") || error.include?("added Adventure IDs")
        end)
      end
    end
    validator = authorization_validator
    duplicate = {"boundary_created_ids" => [{"adventure_id" => "ADV-0003"}, {"adventure_id" => "ADV-0003"}],
                 "counts" => {"boundary_created_ids" => 2}}
    error = assert_raises(AfDataPipeline::ValidationError) { without_disk { validator.send(:validate_boundary_ids!, duplicate) } }
    assert_includes error.message, "invalid or duplicated"
  end

  def test_missing_or_incompatible_lineage_and_unprovable_concurrency_are_rejected
    with_release do |fixture, result, base|
      changed_base = File.join(fixture.root, "changed-base.xlsx")
      FileUtils.cp(base, changed_base)
      replace_zip_text(changed_base, "xl/worksheets/sheet1.xml", "Unit A", "Concurrent Change")

      error = assert_raises(AfDataPipeline::ValidationError) { validate_release(fixture, result, changed_base) }
      assert_includes error.message, "base AMC is missing or changed"
    end

    with_release do |fixture, result, base|
      changed_staged = File.join(fixture.root, "changed-staged.xlsx")
      FileUtils.cp(fixture.staged_path, changed_staged)
      replace_zip_text(changed_staged, "xl/worksheets/sheet1.xml", "Unit A", "Changed Staged")

      error = assert_raises(AfDataPipeline::ValidationError) { validate_release(fixture, result, base, staged_path: changed_staged) }
      assert_includes error.message, "staged AMC is missing or changed"
    end

    with_release do |fixture, result, base|
      rewrite_manifest(result.manifest_path) { |manifest| manifest["lineage"].delete("approval_id") }

      error = assert_raises(AfDataPipeline::ValidationError) { validate_release(fixture, result, base) }
      assert_includes error.message, "release lineage differs"
    end
  end

  def test_changed_apply_value_cannot_be_rebound_by_rehashing_the_mutable_package
    with_release do |fixture, result, base|
      apply_path = File.join(result.output_dir, "amc-apply-report.json")
      apply = JSON.parse(File.binread(apply_path))
      apply.fetch("records").first["proposed_value"] = 5
      File.write(apply_path, JSON.pretty_generate(apply) + "\n")
      rewrite_manifest(result.manifest_path) do |manifest|
        manifest["artifacts"]["apply_report"].merge!(file_binding(apply_path))
      end

      error = assert_raises(AfDataPipeline::ValidationError) { validate_release(fixture, result, base) }
      assert_includes error.message, "written value verification failed"
    end
  end

  def test_writer_mapping_and_sessions_aliases_are_honored_without_expanding_standing_scope
    mapping = AfDataPipeline::AmcApply::DIMENSION_HEADERS
    [mapping.keys - ["Number of Sessions"], ["Number of Sessions"]].each do |dimensions|
      records = dimensions.map do |dimension|
        value = {"Level Start" => 1, "Level End" => 5}.fetch(dimension, 3)
        metric_record(dimension, value)
      end
      cells = authorize_cells(records)
      assert_equal dimensions.sort, cells.map { |row| row.fetch("dimension") }.sort
      cells.each do |row|
        assert_equal mapping.fetch(row.fetch("dimension")), row.fetch("header")
        assert_equal "ADV-0003::#{row.fetch('dimension')}", row.fetch("candidate_key")
      end
      sessions = cells.find { |row| row["header"] == "Number of Sessions" }
      assert_equal "I4", sessions.fetch("cell")
    end
  end

  def test_separate_levels_writes_from_blank_pair_are_verified_and_populated_levels_remain_exact
    records = [metric_record("Level Start", 1), metric_record("Level End", 5)]
    cells = authorize_cells(records)
    assert_equal ["Level Start", "Level End"], cells.map { |row| row.fetch("dimension") }
    assert_equal ["J4", "K4"], cells.map { |row| row.fetch("cell") }
    assert_equal ["written", "written"], cells.map { |row| row.fetch("action") }

    records.each { |row| row["action"] = "already_present" }
    staged = {"J4" => 1, "K4" => 5}
    assert_equal ["already_present", "already_present"], authorize_cells(records, staged_values: staged).map { |row| row.fetch("action") }
    assert_raises(AfDataPipeline::ValidationError) { authorize_cells(records, staged_values: staged.merge("K4" => 4)) }
    records.each { |row| row["action"] = "written" }
    assert_raises(AfDataPipeline::ValidationError) { authorize_cells(records, final_values: {"J4" => 5, "K4" => 1}) }
    assert_raises(AfDataPipeline::ValidationError) { authorize_cells(records, staged_values: staged) }
  end

  def test_asymmetric_or_malformed_new_levels_fail_compatibility
    [{"Level Start" => 1}, {"Level Start" => 6, "Level End" => 5},
     {"Level Start" => 1.5, "Level End" => 5}, {"Level Start" => 1, "Level End" => 21}].each do |metrics|
      records = metrics.map { |dimension, value| metric_record(dimension, value) }
      cells = authorize_cells(records)
      errors = blank_field_errors(records.to_h { |row| [row.fetch("cell"), row.fetch("proposed_value")] }, cells:)
      refute_empty errors
      assert errors.any? { |error| error.include?("Level") }, errors.join("\n")
    end
  end

  def test_metric_header_cell_sheet_and_action_mismatches_fail_closed
    mutations = {
      "wrong mapped header" => ->(row) { row["dimension"] = "Exploration Emphasis"; row["candidate_key"] = "ADV-0003::Exploration Emphasis" },
      "unknown dimension" => ->(row) { row["dimension"] = "Unsupported Metric"; row["candidate_key"] = "ADV-0003::Unsupported Metric" },
      "unsupported scorer spelling" => ->(row) { row["dimension"] = "Rules / System-Mastery Demand"; row["candidate_key"] = "ADV-0003::Rules / System-Mastery Demand" },
      "aggregate levels metric" => ->(row) { row["dimension"] = "Levels"; row["candidate_key"] = "ADV-0003::Levels" },
      "wrong adventure row" => ->(row) { row["adventure_id"] = "ADV-0001"; row["candidate_key"] = "ADV-0001::Combat Emphasis" },
      "wrong target cell" => ->(row) { row["cell"] = "P4" },
      "wrong explicit header" => ->(row) { row["header"] = "Exploration Emphasis" },
      "wrong sheet" => ->(row) { row["sheet"] = "AMC >100pg" },
      "wrong sheet part" => ->(row) { row["sheet_part"] = "xl/worksheets/sheet2.xml" },
      "wrong writer action" => ->(row) { row["action"] = "excluded" },
      "wrong candidate key" => ->(row) { row["candidate_key"] = "ADV-0003::Structural Openness" },
      "nonnumeric value" => ->(row) { row["proposed_value"] = "3" },
      "nonfinite value" => ->(row) { row["proposed_value"] = Float::INFINITY }
    }
    mutations.each do |label, mutate|
      row = metric_record("Combat Emphasis", 3)
      mutate.call(row)
      error = assert_raises(AfDataPipeline::ValidationError, label) do
        authorize_cells([row], final_values: {"L4" => 3})
      end
      refute_empty error.message, label
    end
  end

  def test_rehashed_dimension_cannot_authorize_a_different_mapped_workbook_cell
    with_release do |fixture, result, base|
      rewrite_application_evidence(result) do |apply, authorization|
        row = apply.fetch("records").find { |record| record["dimension"] == "Combat Emphasis" }
        entry = authorization.fetch("accepted_candidates").find { |record| record["candidate_key"] == row["candidate_key"] }
        row["dimension"] = "Exploration Emphasis"
        row["candidate_key"] = "ADV-0003::Exploration Emphasis"
        entry["candidate_key"] = row["candidate_key"]
      end
      report = compatibility(fixture, result, base)
      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("target binding mismatch") }, report.fetch("errors").join("\n")
      refute report.key?("scored_new_id_authorization")
    end
  end

  def test_sessions_aliases_cannot_grant_duplicate_cell_permissions_or_hide_missing_acceptance
    records = [metric_record("# of Sessions", 3), metric_record("Number of Sessions", 3)]
    error = assert_raises(AfDataPipeline::ValidationError) { authorize_cells(records) }
    assert_includes error.message, "conflicting cell targets"
    error = assert_raises(AfDataPipeline::ValidationError) do
      authorize_cells(records.first(1), authorization: {"accepted_candidates" => []})
    end
    assert_includes error.message, "identities differ"
  end

  def test_changed_candidate_content_identity_or_application_set_is_not_accepted
    with_release do |fixture, result, base|
      rewrite_application_evidence(result, rebind_candidate_set: false) do |_apply, authorization|
        authorization.fetch("accepted_candidates").first["candidate_sha256"] = "0" * 64
      end
      error = assert_raises(AfDataPipeline::ValidationError) { validate_release(fixture, result, base) }
      assert_includes error.message, "candidate-set identity"
    end
  end

  def test_legitimate_excluded_record_remains_a_residual_and_grants_no_cell_permission
    accepted = metric_record("Structural Openness", 4)
    authorization = {"accepted_candidates" => [accepted_authority(accepted)], "residuals" => [
      {"candidate_key" => "ADV-0003::Combat Emphasis", "category" => "human_hold"}
    ]}
    cells = authorize_cells([accepted], authorization:)
    assert_equal ["Structural Openness"], cells.map { |row| row.fetch("dimension") }
    refute cells.any? { |row| row["dimension"] == "Combat Emphasis" }
    assert_empty blank_field_errors({"P4" => 4}, cells:)
    assert blank_field_errors({"P4" => 4, "L4" => 3}, cells:).any? { |error| error.include?("Combat Emphasis") }
  end

  def test_reporting_describes_static_requirements_and_does_not_claim_current_afio_or_live_afw
    checker = AfDataPipeline::AmcCompatibilityCheck.new(candidate_path: "/virtual/candidate.xlsx")
    checker.stub(:artifact, {}) do
      report = checker.send(:report, errors: [])
      refute report.fetch("consumer_contracts").any? { |value| value.include?("af-inference-orchestrator") }
      assert_includes report.fetch("consumer_contracts").join(" "), "(static)"
      assert_equal "not validated by this static workbook gate", report.fetch("afw_execution_compatibility")
      assert_same AfDataPipeline::AmcCompatibilityCheck::REQUIRED_SCORE_HEADERS,
                  AfDataPipeline::AmcCompatibilityCheck::AFIO_SCORE_HEADERS
    end
  end

  def test_authorization_result_retains_immutable_nested_references
    proof = release_template.fetch(:proof)
    assert_raises(FrozenError) { proof.authorized_cells.first["cell"].replace("I4") }
    assert_raises(FrozenError) { proof.authorized_cells.first["dimension"] = "Exploration Emphasis" }
    assert_raises(FrozenError) { proof.boundary_created_ids.first.replace("ADV-0999") }
    assert_raises(FrozenError) { proof.candidate_binding["sha256"].replace("0" * 64) }
    assert_raises(FrozenError) { proof.release_id.replace("0" * 64) }
  end

  def test_without_authorization_blank_pair_and_valid_populated_levels_remain_supported
    [nil, [1, 5], [1, nil], [6, 5], [1.5, 5], [1, 21]].each do |levels|
      values = {"J4" => levels&.first, "K4" => levels&.last}
      errors = blank_field_errors(values)
      assert_equal [nil, [1, 5]].include?(levels), errors.empty?, levels.inspect
    end
  end

  private

  def validate_release(fixture, result, base, staged_path: fixture.staged_path)
    AfDataPipeline::AmcScoredNewIdAuthorization.validate!(
      release_manifest_path: result.manifest_path, candidate_path: result.workbook_path,
      staged_path:, base_path: base
    )
  end

  def authorization_validator
    AfDataPipeline::AmcScoredNewIdAuthorization.new(
      release_manifest_path: "/virtual/release.json", candidate_path: "/virtual/candidate.xlsx",
      staged_path: "/virtual/staged.xlsx", base_path: "/virtual/base.xlsx"
    )
  end

  def result_proof(ids, cells)
    AfDataPipeline::AmcScoredNewIdAuthorization::Result.new(
      release_id: "unit", manifest_id: "unit", boundary_created_ids: ids, authorized_cells: cells,
      candidate_binding: {}, staged_binding: {}, base_binding: {}
    )
  end

  def catalog_schema
    self.class.catalog_schema ||= begin
      xml = worksheet_xml([
        xml_row(1, header_cells(HEADERS)),
        xml_row(2, [text_cell("A2", "ADV-0001")]),
        xml_row(4, [text_cell("A4", "ADV-0003")])
      ])
      schema = AfDataPipeline::AmcApply::Worksheet.new(
        name: "Adventure Catalog", part: "xl/worksheets/sheet1.xml", xml:, shared_strings: []
      )
      schema.resolve_headers!(AfDataPipeline::AmcApply::DIMENSION_HEADERS.keys)
      schema
    end
  end

  def metric_record(dimension, value)
    {
      "candidate_key" => "ADV-0003::#{dimension}", "adventure_id" => "ADV-0003",
      "dimension" => dimension, "proposed_value" => value, "action" => "written",
      "sheet" => "Adventure Catalog", "sheet_part" => "xl/worksheets/sheet1.xml",
      "cell" => "#{catalog_schema.column_for_dimension(dimension)}4"
    }
  end

  def accepted_authority(record)
    {"candidate_key" => record.fetch("candidate_key"), "candidate_sha256" => "a" * 64,
     "authority" => "individual_human", "authority_id" => "b" * 64}
  end

  def authorize_cells(records, staged_values: {}, final_values: nil, authorization: nil)
    authorization ||= {"accepted_candidates" => records.map { |row| accepted_authority(row) }}
    final_values ||= records.to_h { |row| [row.fetch("cell"), row.fetch("proposed_value")] }
    sheets = {
      "/virtual/staged.xlsx" => MemoryCatalog.new(catalog_schema, staged_values),
      "/virtual/candidate.xlsx" => MemoryCatalog.new(catalog_schema, final_values)
    }
    workbook = Struct.new(:catalog_sheet!)
    loader = ->(path) { workbook.new(sheets.fetch(path)) }
    validator = authorization_validator
    AfDataPipeline::AmcApply::Workbook.stub(:new, loader) do
      without_disk do
        validator.send(:validate_authorized_cells!, records, authorization, ["ADV-0003"])
      end
    end
  end

  def blank_field_errors(values, cells: nil)
    sheet = MemoryCatalog.new(catalog_schema, values)
    proof = cells && result_proof(["ADV-0003"], cells)
    errors = []
    checker = AfDataPipeline::AmcCompatibilityCheck.new(candidate_path: "/virtual/candidate.xlsx")
    without_disk { checker.send(:validate_new_row_blank_fields, sheet, 4, "ADV-0003", proof, errors) }
    errors
  end

  def without_disk
    unexpected_io = ->(*_args) { raise "in-memory contract test attempted filesystem I/O" }
    File.stub(:binread, unexpected_io) do
      File.stub(:file?, unexpected_io) do
        File.stub(:write, unexpected_io) { yield }
      end
    end
  end

  def rewrite_application_evidence(result, rebind_candidate_set: true)
    apply_path = File.join(result.output_dir, "amc-apply-report.json")
    authorization_path = File.join(result.output_dir, "release-authorization.json")
    apply = JSON.parse(File.binread(apply_path))
    authorization = JSON.parse(File.binread(authorization_path))
    yield apply, authorization
    authorization["authorization_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(authorization.except("authorization_id"))
    apply["candidate_authorization"]["authority"] = authorization
    if rebind_candidate_set
      apply["candidate_authorization"]["sha256"] = AfDataPipeline::StandingBulkScorePolicy.digest(
        "authorization" => authorization,
        "candidates" => apply.fetch("records").map { |row| row.slice("candidate_key", "adventure_id", "dimension", "proposed_value") },
        "accounting" => apply.fetch("counts").slice("source_holds", "held_candidates", "rejected_candidates", "pending_candidates")
      )
    end
    File.write(authorization_path, JSON.pretty_generate(authorization) + "\n")
    File.write(apply_path, JSON.pretty_generate(apply) + "\n")
    rewrite_manifest(result.manifest_path) do |manifest|
      manifest["release_id"] = authorization.fetch("authorization_id")
      manifest["authorization"] = {"authorization_id" => authorization.fetch("authorization_id"), "sha256" => file_binding(authorization_path).fetch("sha256")}
      manifest["artifacts"]["authorization"].merge!(file_binding(authorization_path))
      manifest["artifacts"]["apply_report"].merge!(file_binding(apply_path))
    end
  end

  def with_release
    Dir.mktmpdir do |root|
      template = release_template
      template.fetch(:files).each do |relative, bytes|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
      end
      output_dir = File.join(root, "release")
      manifest_path = File.join(output_dir, "release-accounting.json")
      manifest = JSON.parse(File.binread(manifest_path))
      result = AfDataPipeline::StandingBulkScoreRelease::Result.new(
        output_dir:,
        workbook_path: File.join(output_dir, "release-candidate.xlsx"),
        manifest_path:,
        manifest:,
        reused: true
      )
      fixture = Struct.new(:root, :staged_path).new(root, File.join(root, template.fetch(:staged_filename)))
      base = File.join(root, template.fetch(:base_filename))
      yield fixture, result, base
    end
  end

  def release_template
    self.class.release_template ||= Dir.mktmpdir do |root|
      fixture = StandingBulkScoreReleaseFixture.new(root:)
      result = fixture.release
      base_filename = fixture.authority_projection.dig("authority", "base_amc", "filename")
      staged_filename = File.basename(fixture.staged_path)
      proof = validate_release(fixture, result, File.join(root, base_filename))
      retained = result.manifest.fetch("artifacts").values.map { |binding| File.join(fixture.output_dir, binding.fetch("filename")) }
      files = [*retained, result.manifest_path, File.join(root, base_filename), fixture.staged_path]
        .to_h { |path| [path.delete_prefix(root + "/"), File.binread(path).freeze] }
      {files:, base_filename:, staged_filename:, proof:}
    end
  end

  def compatibility(fixture, result, base)
    AfDataPipeline::AmcCompatibilityCheck.check(
      candidate_path: result.workbook_path,
      base_path: base,
      staged_path: fixture.staged_path,
      release_manifest_path: result.manifest_path
    )
  end

  def rewrite_manifest(path)
    manifest = JSON.parse(File.binread(path))
    yield manifest
    manifest["manifest_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(manifest.except("manifest_id"))
    File.write(path, JSON.pretty_generate(manifest) + "\n")
  end

  def file_binding(path)
    AfDataPipeline::StandingBulkScorePolicy.file_binding(path)
  end
end
