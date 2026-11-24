# frozen_string_literal: true

module AfDataPipeline
  # Consumer-side evidence contract only. This neither prepares a frontier
  # question nor applies a returned value. The original IG-17 proof is required.
  class FrontierReleaseEvidence
    SCHEMA = "af-frontier-derived-release-evidence/v0.1"
    HANDOFF_SCHEMA = "af-frontier-residual-handoff/v0.1"
    RETURN_SCHEMA = "af-frontier-residual-return/v0.1"
    AUTHORIZATION_SCHEMA = "af-frontier-application-authorization/v0.1"
    Result = Data.define(:document, :candidate_path, :proof, :references, :writes, :no_writes, :no_write_keys)

    def self.validate!(path:, release_manifest_path:, staged_path:, base_path:, replay_observation: nil)
      new(path:).validate!(release_manifest_path:, staged_path:, base_path:, replay_observation:)
    end

    # Only blank, writer-supported terminal gaps are writable. A populated
    # unsupported-scope cell remains an accounted residual, never an overwrite.
    def self.residual_targets(manifest:, original:)
      eligible = manifest.fetch("residuals").select { |row| row["category"] == "unsupported_scope" }
      sheet = AmcApply::Workbook.new(original).catalog_sheet!
      sheet.resolve_headers!(eligible.map { |row| row.fetch("dimension") }.uniq)
      eligible.filter_map do |target|
        row = sheet.row_for_adventure(target.fetch("adventure_id"))
        raise ValidationError, "frontier residual Adventure ID is missing" unless row
        next unless sheet.blank_cell?(sheet.cell("#{sheet.column_for_dimension(target.fetch('dimension'))}#{row}"))
        target.slice("candidate_key", "adventure_id", "dimension").merge("original_value" => nil)
      end.sort_by { |row| row.fetch("candidate_key") }
    end

    def initialize(path:)
      @path = File.expand_path(path)
      @references = {}
    end

    def validate!(release_manifest_path:, staged_path:, base_path:, replay_observation: nil)
      check!(replay_observation.nil? || replay_observation.instance_of?(CatalogReplayObservation),
             "invalid historical catalog observation")
      @replay_observation = replay_observation
      document = read_json(@path)
      identity!(document, SCHEMA, "result_id")
      keys!(document, %w[schema_version result_id disposition original_manifest original_candidate artifacts version counts])
      manifest = read_json(release_manifest_path)
      original = File.join(File.dirname(release_manifest_path), manifest.dig("artifacts", "final_workbook", "filename"))
      exact_file!("original_manifest", release_manifest_path, document.fetch("original_manifest"))
      exact_file!("original_candidate", original, document.fetch("original_candidate"))
      proof = AmcScoredNewIdAuthorization.validate!(release_manifest_path:, candidate_path: original, staged_path:, base_path:)
      artifacts = document.fetch("artifacts")
      paths = artifacts.to_h { |name, binding| [name, artifact!(name, binding)] }
      handoff = read_json(paths.fetch("handoff"))
      v2 = handoff["schema_version"] == FrontierResidualScoring::HANDOFF_SCHEMA
      expected_artifacts = document["disposition"] == "DECLINED" ? %w[handoff] : %w[handoff return authorization intermediate apply_report finalize_report candidate]
      expected_artifacts += ["accounting"] if v2 && document["disposition"] == "APPLIED"
      keys!(artifacts, expected_artifacts)
      identity!(handoff, v2 ? FrontierResidualScoring::HANDOFF_SCHEMA : HANDOFF_SCHEMA, "handoff_id")
      handoff_keys = %w[schema_version handoff_id release_id manifest_id lineage original_candidate targets references]
      handoff_keys += %w[operation source rubric successor_version population] if v2
      keys!(handoff, handoff_keys)
      check!(handoff["release_id"] == manifest["release_id"] && handoff["manifest_id"] == manifest["manifest_id"] &&
             handoff["lineage"] == manifest["lineage"] && handoff["original_candidate"] == document["original_candidate"], "frontier lineage differs from the original release")
      check!(handoff["references"].is_a?(Hash) && handoff["references"].key?("rubric"), "frontier frozen rubric reference is missing")
      handoff.fetch("references").each { |name, binding| artifact!("handoff:#{name}", binding) }
      if v2
        request_path = @references.fetch("handoff:frontier_request").fetch("path")
        expected = FrontierResidualScoring.new(request_path:).handoff!(replay_observation: @replay_observation)
        check!(handoff == expected, "frontier V2 handoff differs from exact original package and frozen rubric")
        check!(document["disposition"] == "DECLINED" || document["version"] == handoff["successor_version"],
               "frontier successor version differs from handoff")
      end
      release_authorization = read_json(File.join(File.dirname(release_manifest_path), manifest.dig("artifacts", "authorization", "filename")))
      snapshot = release_authorization.fetch("input_snapshot")
      snapshot.except("current_project_state").each do |name, binding|
        check!(handoff.dig("references", name)&.slice("sha256", "bytes") == binding, "frontier handoff omits or changes immutable release reference #{name}")
      end
      locator_path = @references.fetch("handoff:release_inputs").fetch("path")
      inputs = read_json(locator_path)
      staged = inputs.fetch("staged_scoring")
      authority = StagedScoringAuthority.new(evidence: staged.fetch("evidence").transform_keys(&:to_sym),
                                            store_root: staged.fetch("store_root"), mode: inputs.fetch("mode"),
                                            selection_afw_root: staged["selection_afw_root"],
                                            selection_project_root: staged["selection_project_root"],
                                            selection_scorer_root: staged["selection_scorer_root"],
                                            selection_scorer_config: staged["selection_scorer_config"]).validate!(
        current_state_path: staged.fetch("current_project_state_path"), frozen_workload: read_json(staged.fetch("workload_binding_path")),
        workload_paths: staged.fetch("workload_paths"), selection_path: staged["selection_path"]
      ).fetch("authority")
      check!(authority["authority_id"] == manifest.dig("lineage", "workload_authority", "authority_id"), "frontier canonical authority changed")
      authority.fetch("evidence").each do |name, binding|
        check!(handoff.dig("references", "authority:#{name}")&.slice("sha256", "bytes") == binding, "frontier canonical reference missing or changed #{name}")
      end
      eligible = self.class.residual_targets(manifest:, original:)
      targets = handoff.fetch("targets")
      check!(targets.is_a?(Array) && !targets.empty?, "frontier handoff has no terminal writable residuals")
      target_keys = targets.map { |row| row.fetch("candidate_key") }
      check!(target_keys == target_keys.sort && target_keys.uniq == target_keys &&
             target_keys == eligible.map { |row| row.fetch("candidate_key") }.sort, "frontier targets differ from exact terminal residual population")
      sheet = AmcApply::Workbook.new(original).catalog_sheet!
      sheet.resolve_headers!(targets.map { |row| row.fetch("dimension") })
      targets.each do |target|
        keys!(target, %w[candidate_key adventure_id dimension original_value] + (v2 ? %w[reason original_state] : []))
        check!(target["candidate_key"] == "#{target['adventure_id']}::#{target['dimension']}" &&
               eligible.any? { |row| row == target.slice("candidate_key", "adventure_id", "dimension", "original_value") }, "frontier target identity differs")
        row = sheet.row_for_adventure(target.fetch("adventure_id"))
        check!(row && target["original_value"].nil? && sheet.blank_cell?(sheet.cell("#{sheet.column_for_dimension(target.fetch('dimension'))}#{row}")), "frontier target would overwrite an existing value")
      end
      if document["disposition"] == "DECLINED"
        check!(document["version"].nil? && document["counts"] == {"writes" => 0, "no_writes" => targets.length}, "declined frontier accounting differs")
        return Result.new(document:, candidate_path: original, proof:, references: @references, writes: 0,
                          no_writes: targets.length, no_write_keys: [])
      end
      check!(document["disposition"] == "APPLIED", "unsupported frontier disposition")
      returned = read_json(paths.fetch("return"))
      FrontierResidualScoring.validate_return!(handoff:, returned:, original:) if v2
      identity!(returned, RETURN_SCHEMA, "return_id")
      keys!(returned, %w[schema_version handoff_id return_id records])
      check!(returned["handoff_id"] == handoff["handoff_id"], "frontier return handoff identity differs")
      records = returned.fetch("records")
      check!(records.is_a?(Array) && records.map { |row| row.fetch("candidate_key") }.sort == target_keys &&
             records.map { |row| row.fetch("candidate_key") }.uniq.length == records.length, "frontier return population differs")
      records.each do |record|
        keys!(record, %w[candidate_key proposed_value reason source_references])
        check!(record["reason"].is_a?(String) && !record["reason"].strip.empty? && record["source_references"].is_a?(Array) &&
               !record["source_references"].empty? && (record["source_references"] - handoff.fetch("references").keys).empty?, "frontier reasoning/source references are missing or unbound")
        value = record["proposed_value"]
        check!(value.nil? || (value.is_a?(Numeric) && value.finite?), "frontier returned value is not finite numeric or an explicit no-write")
      end
      accepted = records.reject { |row| row["proposed_value"].nil? }.sort_by { |row| row.fetch("candidate_key") }.map do |record|
        target = targets.find { |row| row["candidate_key"] == record["candidate_key"] }
        target.slice("candidate_key", "adventure_id", "dimension").merge("proposed_value" => record.fetch("proposed_value"))
      end
      expected_authorization = {"schema_version" => AUTHORIZATION_SCHEMA, "release_id" => manifest.fetch("release_id"),
                                "handoff_id" => handoff.fetch("handoff_id"), "return_id" => returned.fetch("return_id"),
                                "authority" => "frontier_manual", "accepted_candidates" => accepted}
      expected_authorization["authorization_id"] = StandingBulkScorePolicy.digest(expected_authorization)
      authorization = read_json(paths.fetch("authorization"))
      check!(authorization == expected_authorization, "frontier application authority differs from exact return")
      apply = read_json(paths.fetch("apply_report"))
      check!(apply["schema_version"] == AmcApply::REPORT_SCHEMA && apply["status"] == "complete" &&
             apply.dig("candidate_authorization", "authority") == authorization, "frontier application report authority differs")
      applied = apply.fetch("records")
      check!(applied.map { |row| row.slice("candidate_key", "adventure_id", "dimension", "proposed_value") }.sort_by { |row| row.fetch("candidate_key") } == accepted &&
             applied.all? { |row| row["action"] == "written" }, "frontier writes differ from authorized blank targets")
      verify = AmcApply.verify!(source_amc: original, output_amc: paths.fetch("intermediate"), records: applied,
                               styles_appended: apply.dig("style_mutation", "cell_xfs_appended"))
      check!(verify == apply["verification"] && apply.dig("source_amc", "sha256") == document.dig("original_candidate", "sha256") &&
             apply.dig("output_amc", "sha256") == artifacts.dig("intermediate", "sha256"), "frontier workbook apply proof differs")
      candidate_identity = StandingBulkScorePolicy.digest("authorization" => authorization, "candidates" => accepted,
                                                         "accounting" => apply.fetch("counts").slice("source_holds", "held_candidates", "rejected_candidates", "pending_candidates"))
      check!(apply.dig("candidate_authorization", "sha256") == candidate_identity, "frontier apply candidate-set identity differs")
      AmcFinalize.verify_existing!(amc_path: paths.fetch("intermediate"), apply_report_path: paths.fetch("apply_report"),
                                  output_path: paths.fetch("candidate"), report_path: paths.fetch("finalize_report"))
      writes = accepted.length
      no_writes = records.length - writes
      check!(document["counts"] == {"writes" => writes, "no_writes" => no_writes} &&
             apply.dig("counts", "new_cells_written") == writes && apply.dig("counts", "already_present_exact_matches") == 0,
             "frontier write/no-write accounting differs")
      if v2
        check!(read_json(paths.fetch("accounting")) ==
               FrontierResidualScoring.accounting(handoff:, returned:, candidate_path: paths.fetch("candidate")),
               "frontier supplemental accounting differs")
      end
      version = document["version"]
      prior_version = manifest.dig("lineage", "staged_amc", "filename")[/Catalog_(.*)\.xlsx\z/, 1]
      check!(version.is_a?(String) && ProjectState::VERSION_RE.match?(version) &&
             Gem::Version.new(version) > Gem::Version.new(prior_version), "derived candidate must have an exact successor version")
      validator = AmcScoredNewIdAuthorization.new(release_manifest_path:, candidate_path: paths.fetch("candidate"), staged_path: original, base_path:)
      # Reuse the canonical cell/metric/ID resolver with explicit frontier
      # attribution, preserving every target and workbook integrity check.
      cells = validator.send(:validate_authorized_cells!, applied,
                             {"accepted_candidates" => accepted.map { |row| row.merge("candidate_sha256" => StandingBulkScorePolicy.digest(row), "authority" => "frontier_manual", "authority_id" => authorization.fetch("authorization_id")) }},
                             proof.boundary_created_ids, authority_classes: ["frontier_manual"])
      combined = AmcScoredNewIdAuthorization::Result.new(
        release_id: proof.release_id, manifest_id: proof.manifest_id, boundary_created_ids: proof.boundary_created_ids,
        authorized_cells: proof.authorized_cells + cells, candidate_binding: StandingBulkScorePolicy.file_binding(paths.fetch("candidate")),
        staged_binding: proof.staged_binding, base_binding: proof.base_binding
      )
      Result.new(document:, candidate_path: paths.fetch("candidate"), proof: combined, references: @references, writes:, no_writes:,
                 no_write_keys: v2 ? records.select { |row| row["proposed_value"].nil? }.map { |row| row.fetch("candidate_key") } : [])
    rescue SystemCallError, JSON::ParserError, KeyError, TypeError, NoMethodError, ArgumentError => e
      raise ValidationError, "invalid optional frontier evidence: #{e.message}"
    end

    private

    def identity!(document, schema, field)
      check!(document["schema_version"] == schema && document[field] == StandingBulkScorePolicy.digest(document.except(field)), "frontier #{field} identity differs")
    end

    def artifact!(name, binding)
      if name.start_with?("handoff:") && binding.is_a?(Hash) && binding.key?("path")
        keys!(binding, %w[path sha256 bytes])
        check!(binding["path"].is_a?(String) && Pathname.new(binding["path"]).absolute?, "frontier external reference requires an explicit absolute locator")
        exact_file!(name, binding.fetch("path"), binding)
        return binding.fetch("path")
      end
      keys!(binding, %w[filename sha256 bytes])
      filename = binding.fetch("filename")
      check!(filename.is_a?(String) && File.basename(filename) == filename && !%w[. ..].include?(filename), "frontier reference is not a basename")
      path = File.join(File.dirname(@path), filename)
      exact_file!(name, path, binding)
      path
    end

    def exact_file!(name, path, binding)
      actual = @replay_observation ? @replay_observation.file_binding(path) : StandingBulkScorePolicy.file_binding(path)
      check!(binding.slice("sha256", "bytes") == actual, "frontier reference changed: #{name}")
      @references[name] = {"path" => File.expand_path(path), **actual}
    end

    def read_json(path)
      JSON.parse(File.binread(path), object_class: StagedScoringAuthority::UniqueObject)
    end

    def keys!(value, keys)
      check!(value.is_a?(Hash) && value.keys.sort == keys.sort, "frontier object has unexpected or missing fields")
    end

    def check!(condition, message)
      raise ValidationError, message unless condition
    end
  end
end
