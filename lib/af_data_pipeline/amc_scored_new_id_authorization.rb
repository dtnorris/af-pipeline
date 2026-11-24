# frozen_string_literal: true

module AfDataPipeline
  # Read-only proof that an IG-17 release candidate differs from its exact
  # staged AMC only at explicitly authorized score cells, and that every such
  # cell belongs to a canonically allocated boundary-created Adventure ID.
  class AmcScoredNewIdAuthorization
    Result = Data.define(
      :release_id,
      :manifest_id,
      :boundary_created_ids,
      :authorized_cells,
      :candidate_binding,
      :staged_binding,
      :base_binding
    ) do
      def authorizes?(sheet:, adventure_id:, dimension:, cell:, value:)
        authorized_cells.any? do |record|
          record.fetch("sheet") == sheet &&
            record.fetch("adventure_id") == adventure_id &&
            record.fetch("header") == AmcApply::DIMENSION_HEADERS.fetch(dimension, dimension) &&
            record.fetch("cell") == cell &&
            AmcApply.numeric_equal?(record.fetch("proposed_value"), value)
        end
      end

      def scored_id?(adventure_id)
        authorized_cells.any? { |record| record.fetch("adventure_id") == adventure_id }
      end

      def summary
        {
          "schema_version" => "af-amc-scored-new-id-authorization-result/v0.1",
          "release_id" => release_id,
          "manifest_id" => manifest_id,
          "boundary_created_ids" => boundary_created_ids,
          "authorized_cells" => authorized_cells.map do |record|
            record.slice("candidate_key", "sheet", "cell", "adventure_id", "dimension", "header", "proposed_value", "action")
          end,
          "candidate" => candidate_binding,
          "staged_amc" => staged_binding,
          "base_amc" => base_binding
        }
      end
    end

    REQUIRED_ARTIFACTS = %w[
      authorization apply_intermediate apply_report final_workbook finalize_report
    ].freeze

    def self.validate!(release_manifest_path:, candidate_path:, staged_path:, base_path:, frontier_result_path: nil)
      if frontier_result_path
        result = FrontierReleaseEvidence.validate!(path: frontier_result_path, release_manifest_path:, staged_path:, base_path:)
        unless File.expand_path(candidate_path) == File.expand_path(result.candidate_path)
          raise ValidationError, "candidate differs from the exact optional frontier result"
        end
        return result.proof
      end
      new(
        release_manifest_path:,
        candidate_path:,
        staged_path:,
        base_path:
      ).validate!
    end

    def initialize(release_manifest_path:, candidate_path:, staged_path:, base_path:)
      @release_manifest_path = File.expand_path(release_manifest_path)
      @candidate_path = File.expand_path(candidate_path)
      @staged_path = File.expand_path(staged_path)
      @base_path = File.expand_path(base_path)
      @release_dir = File.dirname(@release_manifest_path)
    end

    def validate!
      [@release_manifest_path, @candidate_path, @staged_path, @base_path].each do |path|
        raise ValidationError, "required compatibility artifact does not exist: #{path}" unless File.file?(path)
      end

      manifest = read_json(@release_manifest_path, "release accounting")
      validate_manifest!(manifest)
      paths = validate_artifact_bindings!(manifest.fetch("artifacts"))
      validate_exact_file!(@candidate_path, manifest.dig("artifacts", "final_workbook"), "candidate workbook")
      validate_exact_file!(@base_path, manifest.dig("lineage", "base_amc"), "base AMC", filename: true)
      validate_exact_file!(@staged_path, manifest.dig("lineage", "staged_amc"), "staged AMC", filename: true)

      authorization = read_json(paths.fetch("authorization"), "release authorization")
      validate_authorization!(authorization, manifest)
      apply_report = read_json(paths.fetch("apply_report"), "AMC apply report")
      records = validate_apply_report!(apply_report, authorization, manifest, paths)
      boundary_ids = validate_boundary_ids!(manifest)
      authorized_cells = validate_authorized_cells!(records, authorization, boundary_ids)
      validate_finalize_report!(manifest, paths)

      Result.new(
        release_id: deep_freeze(manifest.fetch("release_id")),
        manifest_id: deep_freeze(manifest.fetch("manifest_id")),
        boundary_created_ids: deep_freeze(boundary_ids),
        authorized_cells: deep_freeze(authorized_cells),
        candidate_binding: deep_freeze(file_binding(@candidate_path)),
        staged_binding: deep_freeze(file_binding(@staged_path)),
        base_binding: deep_freeze(file_binding(@base_path))
      )
    rescue KeyError, TypeError, NoMethodError => e
      raise ValidationError, "malformed scored-new-ID authorization package: #{e.message}"
    end

    private

    def validate_manifest!(manifest)
      unless manifest["schema_version"] == StandingBulkScoreRelease::RELEASE_SCHEMA &&
             manifest["status"] == "VERIFIED_RELEASE_CANDIDATE" &&
             manifest["shared_catalog_promotion"] == false
        raise ValidationError, "release accounting is not a verified unpromoted IG-17 candidate"
      end
      expected_id = StandingBulkScorePolicy.digest(manifest.except("manifest_id"))
      unless manifest["manifest_id"] == expected_id
        raise ValidationError, "release accounting manifest identity mismatch"
      end
      verification = manifest.fetch("verification")
      unless verification.dig("amc_apply", "passed") == true &&
             verification.dig("amc_finalize", "passed") == true &&
             verification["unauthorized_cell_changes"] == 0 &&
             verification["shared_roles_mutated"] == 0 &&
             verification["git_mutations"] == 0
        raise ValidationError, "release accounting does not carry clean workbook verification"
      end
    end

    def validate_artifact_bindings!(artifacts)
      unless artifacts.is_a?(Hash) && (REQUIRED_ARTIFACTS - artifacts.keys).empty?
        raise ValidationError, "release accounting is missing required artifacts"
      end
      REQUIRED_ARTIFACTS.to_h do |kind|
        binding = artifacts.fetch(kind)
        filename = binding.fetch("filename")
        unless filename.is_a?(String) && !filename.empty? && File.basename(filename) == filename
          raise ValidationError, "#{kind} artifact filename is not a local basename"
        end
        path = File.join(@release_dir, filename)
        validate_exact_file!(path, binding, "#{kind} artifact")
        [kind, path]
      end
    end

    def validate_authorization!(authorization, manifest)
      unless authorization["schema_version"] == StandingBulkScoreRelease::AUTHORIZATION_SCHEMA
        raise ValidationError, "release authorization schema is unsupported"
      end
      expected_id = StandingBulkScorePolicy.digest(authorization.except("authorization_id"))
      unless authorization["authorization_id"] == expected_id &&
             authorization["authorization_id"] == manifest["release_id"] &&
             authorization["authorization_id"] == manifest.dig("authorization", "authorization_id") &&
             file_binding(File.join(@release_dir, manifest.dig("artifacts", "authorization", "filename"))).fetch("sha256") ==
               manifest.dig("authorization", "sha256") &&
             authorization == manifest_authority_from_apply(manifest)
        raise ValidationError, "release authorization identity or release binding mismatch"
      end
      unless manifest["lineage"] == authorization["lineage"]
        raise ValidationError, "release lineage differs from the application authorization"
      end
      lineage = authorization.fetch("lineage")
      unless lineage["approval_id"].to_s.start_with?("sha256:") &&
             !lineage.dig("workload_authority", "authority_id").to_s.empty? &&
             !lineage["workload_manifest_id"].to_s.empty? &&
             !lineage["review_package_id"].to_s.empty?
        raise ValidationError, "release authorization has incomplete boundary/workload lineage"
      end
    end

    # The apply report retains the exact authorization object. Loading it here
    # lets the authorization validator compare that independent retained copy
    # before the report is trusted for cell-level permissions.
    def manifest_authority_from_apply(manifest)
      binding = manifest.fetch("artifacts").fetch("apply_report")
      path = File.join(@release_dir, binding.fetch("filename"))
      read_json(path, "AMC apply report").dig("candidate_authorization", "authority")
    end

    def validate_apply_report!(report, authorization, manifest, paths)
      unless report["schema_version"] == AmcApply::REPORT_SCHEMA && report["status"] == "complete" &&
             report.dig("verification", "passed") == true &&
             report.dig("candidate_authorization", "authority") == authorization
        raise ValidationError, "AMC apply report does not retain the exact release authorization"
      end
      unless report.dig("source_amc", "sha256") == file_binding(@staged_path).fetch("sha256") &&
             report.dig("output_amc", "sha256") == file_binding(paths.fetch("apply_intermediate")).fetch("sha256")
        raise ValidationError, "AMC apply report lineage does not match the staged/intermediate artifacts"
      end
      records = report.fetch("records")
      unless records.is_a?(Array) && records.length == report.dig("counts", "accepted_candidates_considered")
        raise ValidationError, "AMC apply report record accounting is incomplete"
      end
      actual = AmcApply.verify!(
        source_amc: @staged_path,
        output_amc: paths.fetch("apply_intermediate"),
        records:,
        styles_appended: report.dig("style_mutation", "cell_xfs_appended")
      )
      unless actual == report["verification"] && actual == manifest.dig("verification", "amc_apply")
        raise ValidationError, "AMC apply verification differs from retained release evidence"
      end
      candidate_identity = StandingBulkScorePolicy.digest(
        "authorization" => authorization,
        "candidates" => records.map do |record|
          record.slice("candidate_key", "adventure_id", "dimension", "proposed_value")
        end,
        "accounting" => report.fetch("counts").slice(
          "source_holds", "held_candidates", "rejected_candidates", "pending_candidates"
        )
      )
      unless candidate_identity == report.dig("candidate_authorization", "sha256")
        raise ValidationError, "AMC apply candidate-set identity differs from retained application evidence"
      end
      records
    end

    def validate_finalize_report!(manifest, paths)
      actual = AmcFinalize.verify_existing!(
        amc_path: paths.fetch("apply_intermediate"),
        apply_report_path: paths.fetch("apply_report"),
        output_path: @candidate_path,
        report_path: paths.fetch("finalize_report")
      )
      unless actual == manifest.dig("verification", "amc_finalize")
        raise ValidationError, "AMC finalization verification differs from retained release evidence"
      end
    end

    def validate_boundary_ids!(manifest)
      rows = manifest.fetch("boundary_created_ids")
      unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
        raise ValidationError, "boundary-created ID accounting is malformed"
      end
      ids = rows.map { |row| row["adventure_id"] }
      unless ids.all? { |id| id.to_s.match?(AmcCompatibilityCheck::ADV_ID_RE) } && ids.uniq == ids
        raise ValidationError, "boundary-created Adventure IDs are invalid or duplicated"
      end
      unless manifest.dig("counts", "boundary_created_ids") == ids.length
        raise ValidationError, "boundary-created Adventure ID count mismatch"
      end
      ids.sort
    end

    def validate_authorized_cells!(records, authorization, boundary_ids, authority_classes: %w[standing_directive individual_human ig16b_machine])
      accepted = authorization.fetch("accepted_candidates")
      unless accepted.is_a?(Array) && accepted.all? { |row| row.is_a?(Hash) }
        raise ValidationError, "accepted candidate authorization is malformed"
      end
      accepted_keys = accepted.map { |row| row["candidate_key"] }
      record_keys = records.map { |row| row["candidate_key"] }
      unless accepted_keys.uniq == accepted_keys && record_keys.uniq == record_keys && accepted_keys.sort == record_keys.sort
        raise ValidationError, "accepted candidate and AMC apply record identities differ"
      end

      accepted.each do |entry|
        unless entry["candidate_sha256"].is_a?(String) && entry["candidate_sha256"].match?(/\A[0-9a-f]{64}\z/) &&
               authority_classes.include?(entry["authority"]) &&
               !entry["authority_id"].to_s.empty?
          raise ValidationError, "accepted candidate authority is malformed"
        end
      end
      dimensions = records.map { |record| record.fetch("dimension") }
      unless dimensions.all? { |dimension| AmcApply::DIMENSION_HEADERS.key?(dimension) }
        raise ValidationError, "accepted AMC apply record has an unsupported metric identity"
      end
      staged = AmcApply::Workbook.new(@staged_path).catalog_sheet!
      final = AmcApply::Workbook.new(@candidate_path).catalog_sheet!
      [staged, final].each do |sheet|
        sheet.resolve_headers!(dimensions)
        sheet.validate_unique_adventure_ids!
      end
      targets = records.map { |record| [record["sheet_part"], record["cell"]] }
      unless targets.uniq == targets
        raise ValidationError, "accepted AMC apply records have conflicting cell targets"
      end

      records.filter_map do |record|
        id = record.fetch("adventure_id")
        dimension = record.fetch("dimension")
        value = record["proposed_value"]
        unless record["candidate_key"] == "#{id}::#{dimension}" &&
               %w[written already_present].include?(record["action"]) &&
               (!record.key?("header") || record["header"] == AmcApply::DIMENSION_HEADERS.fetch(dimension)) &&
               (value.is_a?(Integer) || (value.is_a?(Float) && value.finite?))
          raise ValidationError, "#{record['candidate_key']}: scored-new-ID cell authorization is malformed"
        end
        [staged, final].each do |sheet|
          row = sheet.row_for_adventure(id)
          reference = "#{sheet.column_for_dimension(dimension)}#{row}"
          unless row && record["sheet"] == sheet.name && record["sheet_part"] == sheet.part &&
                 record["cell"] == reference && sheet.cell_formula(sheet.cell(reference)).nil?
            raise ValidationError, "#{record['candidate_key']}: metric/header/Adventure ID target binding mismatch"
          end
        end
        previous = staged.cell(record.fetch("cell"))
        valid_previous = if record["action"] == "written"
          staged.blank_cell?(previous)
        else
          AmcApply.numeric_equal?(staged.cell_numeric_value(previous), value)
        end
        unless valid_previous && AmcApply.numeric_equal?(final.cell_numeric_value(final.cell(record.fetch("cell"))), value)
          raise ValidationError, "#{record['candidate_key']}: writer action or numeric value binding mismatch"
        end
        next unless boundary_ids.include?(id)

        record.merge("header" => AmcApply::DIMENSION_HEADERS.fetch(dimension)).freeze
      end
    end

    def validate_exact_file!(path, expected, label, filename: false)
      unless File.file?(path) && expected.is_a?(Hash) &&
             file_binding(path) == expected.slice("sha256", "bytes")
        raise ValidationError, "#{label} is missing or changed"
      end
      if filename && expected["filename"] != File.basename(path)
        raise ValidationError, "#{label} filename does not match release lineage"
      end
    end

    def file_binding(path)
      StandingBulkScorePolicy.file_binding(path)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, entry| deep_freeze(key); deep_freeze(entry) }
      when Array
        value.each { |entry| deep_freeze(entry) }
      end
      value.freeze
    end

    def read_json(path, label)
      JSON.parse(File.binread(path))
    rescue Errno::ENOENT, JSON::ParserError => e
      raise ValidationError, "invalid #{label}: #{e.message}"
    end
  end
end
