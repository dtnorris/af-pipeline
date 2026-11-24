# frozen_string_literal: true

require_relative "catalog_replay_observation"

module AfDataPipeline
  # A read-only decision input, not an approval or an adoption transaction.
  class FinalReleasePackage
    INPUT_SCHEMA = "af-final-release-package-inputs/v0.1"
    SCHEMA = "af-final-release-package/v0.1"
    INPUT_KEYS = %w[schema_version release_inputs_path release_manifest_path catalog_repository_root
                    current_project_state_path frontier_result_path].freeze
    Result = Data.define(:package, :path, :reused)
    # Bounded, process-local semantic proofs. Only this validator populates it;
    # every referenced byte and repository observation is checked on reuse.
    PROOFS = {}
    private_constant :PROOFS

    def self.prepare!(inputs_path:, output_path:)
      new(inputs_path:).prepare!(output_path:)
    end

    def self.validate!(inputs_path:, package_path:, replay_observation: nil)
      new(inputs_path:).validate!(package_path:, replay_observation:)
    end

    def self.run(argv, out: $stdout, err: $stderr)
      action = argv.shift
      unless %w[prepare validate].include?(action) && argv.length == 4 && argv[0] == "--inputs" &&
             argv[2] == (action == "prepare" ? "--output" : "--package")
        raise ValidationError, "usage: af-final-release-package prepare|validate --inputs INPUTS.json --output|--package PACKAGE.json"
      end
      result = action == "prepare" ? prepare!(inputs_path: argv[1], output_path: argv[3]) :
                                    validate!(inputs_path: argv[1], package_path: argv[3])
      out.puts JSON.pretty_generate(result.package)
      result.package.dig("readiness", "ready") ? 0 : 2
    rescue Error, SystemCallError, JSON::ParserError, Psych::Exception, KeyError, TypeError, ArgumentError => e
      err.puts JSON.generate("schema_version" => SCHEMA, "status" => "BLOCKED", "reason" => e.message)
      2
    end

    def initialize(inputs_path:)
      @inputs_path = File.expand_path(inputs_path)
    end

    def prepare!(output_path:)
      PrivateDataRoot.destination!(output_path)
      check!(@replay_observation.nil?, "historical catalog observations are validation-only")
      package = build!
      path = File.expand_path(output_path)
      return validate!(package_path: path) if File.exist?(path)
      bytes = StagedScoringAuthority.document_bytes(package)
      Tempfile.create([".final-release-", ".json"], File.dirname(path)) do |temp|
        temp.write(bytes)
        temp.flush
        temp.fsync
        assert_unchanged!
        File.link(temp.path, path)
      end
      Result.new(package:, path:, reused: false)
    rescue Errno::EEXIST
      raise ValidationError, "package output was created concurrently"
    end

    def validate!(package_path:, replay_observation: nil)
      check!(replay_observation.nil? || replay_observation.instance_of?(CatalogReplayObservation),
             "invalid historical catalog observation")
      @replay_observation = replay_observation
      actual = read_json(package_path)
      # Reject stale retained references before the more expensive independent
      # semantic replay. This is only a refusal shortcut, never a PASS cache.
      actual.fetch("provenance").fetch("nodes").each do |name, ref|
        next unless ref["path"]
        check!(file_binding(ref.fetch("path")) == ref.slice("sha256", "bytes"), "package reference changed: #{name}")
      end
      expected = build!
      unless actual == expected && File.binread(package_path) == StagedScoringAuthority.document_bytes(expected)
        raise ValidationError, "package content, identity or current inputs changed; prepare a fresh decision input"
      end
      Result.new(package: expected, path: File.expand_path(package_path), reused: true)
    rescue SystemCallError, KeyError, TypeError, NoMethodError => e
      raise ValidationError, "invalid package reference: #{e.message}"
    end

    private

    def build!
      cached = cached_proof
      return cached if cached
      @refs = {}
      inputs = read_json(@inputs_path)
      exact_keys!(inputs, INPUT_KEYS)
      check!(inputs["schema_version"] == INPUT_SCHEMA, "unsupported package input contract")
      add_file("package_inputs", @inputs_path)
      release_inputs_path = inputs.fetch("release_inputs_path")
      release_path = inputs.fetch("release_manifest_path")
      release_inputs = read_json(release_inputs_path)
      add_file("release_inputs", release_inputs_path)
      add_file("release_manifest", release_path)
      read_json(release_path)
      verified = StandingBulkScoreRelease.new(inputs_path: release_inputs_path, output_dir: File.dirname(release_path)).validate_existing!(
        current_project_state_path: inputs.fetch("current_project_state_path"), replay_observation: @replay_observation
      )
      release = verified.release
      check!(File.expand_path(release.manifest_path) == File.expand_path(release_path), "release manifest locator differs")
      manifest = release.manifest
      # IG-16A defines individual record structure; the IG-16B application and
      # suspension-control publication has not landed. A record alone cannot
      # prove that unavailable per-release authority, even when well formed.
      check!(manifest.dig("counts", "ig16b_machine_accepted") == 0,
             "unsupported IG-16B authority: exact application and suspension/follow-up publication required; record-only acceptance is insufficient")
      staged = release_inputs.fetch("staged_scoring")
      projection = verified.projection
      authority = projection.fetch("authority")
      check!(authority["authority_id"] == manifest.dig("lineage", "workload_authority", "authority_id"), "release authority lineage differs")
      catalog_root = staged.dig("evidence", "catalog_root")
      base_path = File.join(catalog_root, authority.dig("base_amc", "filename"))
      staged_path = File.join(catalog_root, authority.dig("staged_amc", "filename"))
      bind_release_evidence!(release_inputs, manifest, authority)
      workload = read_json(release_inputs.dig("workload_review", "manifest_path"))
      candidates = read_jsonl(File.join(release_inputs.dig("workload_review", "review_dir"), "candidates.jsonl"))
      population = reconcile_population!(workload, candidates, manifest, release.output_dir)
      state_path = inputs.fetch("current_project_state_path")
      state = @replay_observation ? @replay_observation.project_state(state_path) : ProjectState.new(manifest_path: state_path)
      state.validate!
      roles = ProjectState::ROLES.to_h do |role|
        resolved = state.resolve(role)
        add_file("current_role:#{role}", resolved.path)
        [role, {"version" => resolved.version, "filename" => resolved.filename, "sha256" => resolved.sha256, "bytes" => resolved.bytes}]
      end
      add_file("current_project_state", state_path)
      repository = repository_observation!(inputs.fetch("catalog_repository_root"), state_path, roles)
      candidate_path = release.workbook_path
      frontier = nil
      if inputs["frontier_result_path"]
        add_file("frontier_result", inputs.fetch("frontier_result_path"))
        envelope = read_json(inputs.fetch("frontier_result_path"))
        if envelope["disposition"] == "APPLIED"
          filename = envelope.dig("artifacts", "candidate", "filename")
          check!(filename.is_a?(String) && File.basename(filename) == filename, "invalid frontier candidate locator")
          candidate_path = File.join(File.dirname(inputs.fetch("frontier_result_path")), filename)
        end
      end
      checker = AmcCompatibilityCheck.new(candidate_path:, base_path:, staged_path:, release_manifest_path: release_path,
                                          frontier_result_path: inputs["frontier_result_path"], replay_observation: @replay_observation)
      compatibility = checker.check
      if inputs["frontier_result_path"]
        frontier = checker.frontier_evidence
        check!(frontier && compatibility["status"] == "PASS", "invalid optional frontier candidate: #{compatibility['errors'].join('; ')}")
        frontier.references.each { |name, ref| add_file("frontier:#{name}", ref.fetch("path"), ref) }
        candidate_path = frontier.candidate_path
        population["remaining_blank_metrics"] -= frontier.writes
        population["present_metrics"] += frontier.writes
      end
      population["frontier_written_metrics"] = frontier&.writes || 0
      population["frontier_no_write_metrics"] = frontier&.no_writes || 0
      population["residual_gap_metrics"] = population.fetch("terminal_gap_metrics") - population.fetch("frontier_written_metrics")
      selected = frontier&.document&.fetch("disposition") == "APPLIED" ? @refs.fetch("frontier:candidate") : @refs.fetch("release_artifact:final_workbook")
      compatibility["candidate"] = selected
      compatibility["against"] = @refs.fetch("authority:base")
      transition = catalog_transition(state.resolve("catalog_head").path, candidate_path, base_path)
      reasons = []
      if projection.dig("concurrency", "decision") != "SAFE_REUSE"
        reasons << {"code" => "SCORING_LINEAGE_UNSAFE", "detail" => projection.fetch("concurrency").slice("decision", "reason", "details")}
      end
      unless compatibility["status"] == "PASS"
        reasons << {"code" => "WORKBOOK_INCOMPATIBLE", "detail" => compatibility.fetch("errors")}
      end
      unless transition["concurrent_changes_preserved"]
        reasons << {"code" => "PROMOTION_WOULD_LOSE_CURRENT_CHANGES", "detail" => transition.fetch("unpreserved")}
      end
      original_version = authority.dig("staged_amc", "filename")[/Catalog_(.*)\.xlsx\z/, 1]
      check!(original_version && ProjectState::VERSION_RE.match?(original_version), "candidate version is unresolvable")
      selected_version = frontier&.document&.fetch("version") || original_version
      proposed = {"version" => selected_version, "filename" => "5e_Adventure_Master_Catalog_#{selected_version}.xlsx",
                  **StandingBulkScorePolicy.file_binding(candidate_path)}
      if (version_parts(proposed["version"]) <=> version_parts(roles.dig("catalog_head", "version"))) == -1
        reasons << {"code" => "PROPOSED_VERSION_BEHIND_CURRENT", "detail" => "successor must not move catalog_head backward"}
      end
      if proposed["version"] == roles.dig("catalog_head", "version") && proposed != roles["catalog_head"]
        reasons << {"code" => "CURRENT_VERSION_CONFLICT", "detail" => "proposed bytes conflict with the current version identity"}
      end
      package = {
        "schema_version" => SCHEMA, "issuer" => "af-data-pipeline", "mode" => release_inputs.fetch("mode"),
        "operation" => authority.fetch("operation"), "source" => authority.dig("intent", "source"),
        "boundary" => {"approval_id" => authority.fetch("approval_id"), "approved_boundary_reference" => "authority:freeze_path",
                       "allocation" => manifest.fetch("boundary_created_ids")},
        "candidate" => {"selection" => frontier&.document&.fetch("disposition") == "APPLIED" ? "ig17f_derived" : "original_ig17", "version" => selected_version,
                         "original" => @refs.fetch("release_artifact:final_workbook"), "selected" => selected,
                         "frontier" => frontier && {"result_id" => frontier.document.fetch("result_id"), "disposition" => frontier.document.fetch("disposition"),
                                                   "writes" => frontier.writes, "no_writes" => frontier.no_writes, "authority" => "frontier_manual"}},
        "release" => {"release_id" => manifest.fetch("release_id"), "manifest_id" => manifest.fetch("manifest_id"),
                      "counts" => manifest.fetch("counts"), "population" => population,
                      "terminal_gap_authority" => {"application_reference" => "release_artifact:authorization", "residual_count" => manifest.fetch("residuals").length},
                      "preview" => {"requested" => manifest.dig("artifacts", "explicit_red_cell_preview") != nil,
                                    "available" => File.file?(File.join(release.output_dir, StandingBulkScoreRelease::PREVIEW_NAME)), "authority_effect" => "none"}},
        "verification" => manifest.fetch("verification"), "compatibility" => compatibility,
        "transition" => {"catalog_repository" => repository, "current_project_state" => @refs.fetch("current_project_state"),
                         "original_frozen_base" => authority.fetch("base_amc"), "current_roles" => roles,
                         "proposed_catalog_head" => proposed, "independent_roles_preserved" => true,
                         "delta" => transition},
        "scoring_concurrency" => projection.fetch("concurrency"),
        "readiness" => {"ready" => reasons.empty?, "reasons" => reasons, "full_scoring" => population["remaining_blank_metrics"].zero? && population["residual_gap_metrics"].zero?,
                        "approval_authorized" => false, "catalog_adoption_authorized" => false},
        "provenance" => {"nodes" => @refs.sort.to_h, "edges" => @refs.keys.sort.map { |name| {"from" => "package", "to" => name, "relation" => "validated_input"} }}
      }
      edges = package.dig("provenance", "edges")
      [["release_artifact:final_workbook", "release_artifact:apply_intermediate", "finalized_from"],
       ["release_artifact:apply_intermediate", "authority:staged", "applied_from"],
       ["authority:staged", "authority:base", "staged_from"],
       ["authority:staged", "authority:freeze_path", "approved_boundary_set"],
       ["release_artifact:authorization", "release_input:standing_policy", "standing_policy"],
       ["release_artifact:authorization", "release_input:owner_selection", "owner_selection"],
       ["release_artifact:authorization", "release_input:editorial_ledger", "individual_decisions"],
       ["release_artifact:authorization", "release_input:workload_manifest", "complete_workload"]].each do |from, to, relation|
        edges << {"from" => from, "to" => to, "relation" => relation}
      end
      if frontier
        edges << {"from" => "frontier_result", "to" => "release_manifest", "relation" => "supplements_exact_release"}
        edges << {"from" => "frontier:candidate", "to" => "release_artifact:final_workbook", "relation" => "derived_from"} if frontier.document["disposition"] == "APPLIED"
      end
      edges.sort_by! { |edge| [edge.fetch("from"), edge.fetch("to"), edge.fetch("relation")] }
      package["human_summary"] = summary(package)
      assert_unchanged!
      package["package_id"] = StandingBulkScorePolicy.digest(package)
      PROOFS.shift if PROOFS.length >= 8
      PROOFS[@inputs_path] = {bytes: JSON.generate(package), root: @repository_root,
                             head: @repository_head, remote: @repository_remote,
                             preview_path: File.join(release.output_dir, StandingBulkScoreRelease::PREVIEW_NAME)}
      package
    rescue SystemCallError, JSON::ParserError, Psych::Exception, KeyError, TypeError, NoMethodError, ArgumentError => e
      raise ValidationError, "invalid final-release evidence: #{e.message}"
    end

    def bind_release_evidence!(inputs, manifest, authority)
      review = inputs.fetch("workload_review")
      paths = {"standing_policy" => inputs.fetch("standing_policy_path"), "owner_selection" => inputs.fetch("owner_selection_path"),
               "workload_manifest" => review.fetch("manifest_path"), "workload_binding" => inputs.dig("staged_scoring", "workload_binding_path"),
               "current_project_state" => inputs.dig("staged_scoring", "current_project_state_path"),
               "staged_amc" => File.join(inputs.dig("staged_scoring", "evidence", "catalog_root"), authority.dig("staged_amc", "filename"))}
      %w[package candidates holds unresolved integrity].zip(%w[review_package.json candidates.jsonl holds.jsonl unresolved_cases.jsonl integrity_report.json]).each do |key, name|
        paths["review_#{key}"] = File.join(review.fetch("review_dir"), name)
      end
      paths["audit_manifest"] = File.join(review.fetch("audit_dir"), "audit_manifest.json")
      paths["editorial_ledger"] = File.join(review.fetch("audit_dir"), "editorial_decisions.csv")
      staged = inputs.fetch("staged_scoring")
      if (selection_path = staged["selection_path"])
        paths["afw_selection"] = selection_path
        paths["afw_selection_publication"] = File.join(File.dirname(selection_path), "publication.json")
      end
      staged.fetch("workload_paths").except("generated").each { |name, path| paths["workload_#{name}"] = path }
      if (generated = staged.dig("workload_paths", "generated"))
        StandingBulkScoreRelease.generated_files(generated).each do |name, path|
          paths["workload_generated:#{name}"] = path
        end
      end
      inputs["machine_acceptance"]&.fetch("records")&.each { |key, path| paths["machine:#{key}"] = path }
      paths["release_inputs"] = inputs_path_for_snapshot = @refs.fetch("release_inputs").fetch("path")
      authorization_path = File.join(File.dirname(@refs.fetch("release_manifest").fetch("path")), manifest.dig("artifacts", "authorization", "filename"))
      snapshot = read_json(authorization_path).fetch("input_snapshot")
      check!(paths.keys.sort == snapshot.keys.sort && inputs_path_for_snapshot, "release snapshot references are incomplete")
      paths.each { |name, path| add_file("release_input:#{name}", path, snapshot.fetch(name)) }
      manifest.fetch("artifacts").each do |name, binding|
        next if name == "explicit_red_cell_preview" # Informational, not an acceptance dependency.
        add_file("release_artifact:#{name}", File.join(File.dirname(authorization_path), binding.fetch("filename")), binding)
        read_json(File.join(File.dirname(authorization_path), binding.fetch("filename"))) if %w[authorization apply_report finalize_report].include?(name)
      end
      evidence = inputs.dig("staged_scoring", "evidence")
      stage_result = nil
      authority.fetch("evidence").each do |name, binding|
        path = case name
               when "base" then File.join(evidence.fetch("catalog_root"), authority.dig("base_amc", "filename"))
               when "source_registry", /\Asource:/
                 source = YAML.safe_load_file(evidence.fetch("freeze_path")).fetch("source")
                 filename = name == "source_registry" ? source.fetch("registry_filename") : name.delete_prefix("source:")
                 BoundaryFreeze.source_file!(evidence.fetch("source_root"), filename)
               when *[BoundaryEditorial::CONTEXT_FILENAME, BoundaryEditorial::DECISIONS_FILENAME, BoundaryEditorial::REVIEW_FILENAME]
                 File.join(evidence.fetch("bundle_dir"), name)
               when "dossier"
                 File.directory?(evidence.fetch("dossier_path")) ? File.join(evidence.fetch("dossier_path"), "boundary_dossier.json") : evidence.fetch("dossier_path")
               when "stage", "integrity", "staged"
                 stage = stage_result ||= BoundaryFreezeStage.verify!(**evidence.slice("freeze_path", "operation_input_path", "successor_authorization_path", "source_root", "catalog_root", "project_state_path").transform_keys(&:to_sym))
                 {"stage" => stage.stage_path, "integrity" => stage.report_path, "staged" => stage.output_path}.fetch(name)
               else evidence.fetch(name)
               end
        add_file("authority:#{name}", path, binding)
      end
      directory = File.join(inputs.dig("staged_scoring", "store_root"), authority.dig("operation", "operation_id"))
      %w[authority.json publication.json].each { |name| add_file("authority_publication:#{name}", File.join(directory, name)) }
      collect_references!(read_json(review.fetch("manifest_path")), {"afw" => review.fetch("afw_root")}, "workload")
      inputs["machine_acceptance"]&.fetch("records")&.each do |key, path|
        collect_references!(read_json(path), inputs.dig("machine_acceptance", "roots"), "machine:#{key}")
      end
    end

    def reconcile_population!(workload, candidates, manifest, release_dir)
      expected = workload.fetch("cases").flat_map do |record|
        metrics = record["dimension"] == "Levels" ? ["Level Start", "Level End"] : [record.fetch("dimension")]
        metrics.map { |metric| "#{record.fetch('adventure_id')}::#{metric}" }
      end.sort
      check!(expected.uniq == expected && expected == candidates.map { |row| row.fetch("candidate_key") }.sort,
             "metric population differs from complete frozen intent, including Levels siblings")
      check!(expected.length == manifest.dig("counts", "metric_candidates"), "release metric denominator differs")
      authorization = read_json(File.join(release_dir, manifest.dig("artifacts", "authorization", "filename")))
      accepted = authorization.fetch("accepted_candidates")
      residuals = manifest.fetch("residuals")
      keys = accepted.map { |row| row.fetch("candidate_key") } + residuals.map { |row| row.fetch("candidate_key") }
      check!(keys.sort == expected && keys.uniq.length == keys.length, "release authority/gap population is missing or double counted")
      records = read_json(File.join(release_dir, manifest.dig("artifacts", "apply_report", "filename"))).fetch("records")
      counts = manifest.fetch("counts")
      check!(counts["new_cells_written"] == records.count { |row| row["action"] == "written" } &&
             counts["already_present_exact"] == records.count { |row| row["action"] == "already_present" } &&
             counts["finalized_cells"] == counts["new_cells_written"], "write/no-write/finalize counts differ from exact cells")
      workbook = AmcApply::Workbook.new(File.join(release_dir, manifest.dig("artifacts", "final_workbook", "filename")))
      sheet = workbook.catalog_sheet!
      sheet.resolve_headers!(candidates.map { |row| row.fetch("dimension") }.uniq)
      prior = AmcApply::Workbook.new(@refs.fetch("authority:staged").fetch("path")).catalog_sheet!
      prior.resolve_headers!(candidates.map { |row| row.fetch("dimension") }.uniq)
      preserved = candidates.filter_map do |candidate|
        row = prior.row_for_adventure(candidate.fetch("adventure_id"))
        ref = "#{prior.column_for_dimension(candidate.fetch('dimension'))}#{row}"
        next if prior.blank_cell?(prior.cell(ref))
        {"candidate_key" => candidate.fetch("candidate_key"), "value" => prior.display_value(prior.cell(ref))}
      end
      blanks = candidates.count do |candidate|
        row = sheet.row_for_adventure(candidate.fetch("adventure_id"))
        check!(row, "candidate Adventure ID is missing from final workbook")
        ref = "#{sheet.column_for_dimension(candidate.fetch('dimension'))}#{row}"
        sheet.blank_cell?(sheet.cell(ref))
      end
      {"intended_cases" => workload.fetch("cases").length, "intended_metrics" => expected.length,
       "accepted_metrics" => accepted.length, "terminal_gap_metrics" => residuals.length,
       "remaining_blank_metrics" => blanks, "present_metrics" => expected.length - blanks,
       "preserved_existing_metrics" => preserved.length, "preserved_existing_values" => preserved,
       "accepted_already_present_metrics" => counts.fetch("already_present_exact"),
       "hard_exceptions" => residuals.count { |row| %w[source_hold human_hold human_reject].include?(row["category"]) },
       "unresolved_execution_cases" => counts.fetch("execution_evidence_unresolved_cases"),
       "conflicting_targets" => counts.fetch("conflicting_targets"),
       "acceptance" => accepted.map do |entry|
         candidate = candidates.find { |row| row["candidate_key"] == entry["candidate_key"] }
         entry.slice("candidate_key", "candidate_sha256", "authority", "authority_id").merge(
           "accepted_value" => candidate.fetch("value"), "application_reference" => "release_artifact:authorization",
           "individual_decision_reference" => entry["authority"] == "individual_human" ? {"reference" => "release_input:editorial_ledger", "record_key" => entry.fetch("candidate_key")} : nil
         )
       end,
       "gaps" => residuals.map { |row| row.slice("candidate_key", "category", "reason", "adventure_id", "dimension") },
       "coverage_scope" => "complete_frozen_workload",
       "authority_references" => {"standing_directive" => %w[release_input:standing_policy release_input:owner_selection release_artifact:authorization],
                                  "individual_human" => ["release_input:editorial_ledger"], "ig16b_machine" => @refs.keys.grep(/\Arelease_input:machine:/).sort}}
    end

    def repository_observation!(root, state_path, roles)
      root = File.realpath(root)
      check!(File.dirname(File.realpath(state_path)) == root, "current PROJECT_STATE.yml must belong to the catalog repository root")
      head = git!(root, "rev-parse", "HEAD").strip
      check!(head.match?(/\A[0-9a-f]{40}\z/), "invalid catalog repository HEAD")
      remote = git!(root, "remote", "get-url", "origin").strip
      paths = [File.basename(state_path), *roles.values.map { |role| role.fetch("filename") }].uniq.sort
      paths.each do |path|
        bytes = git!(root, "show", "#{head}:#{path}")
        # Historical manifest bindings require the exact validated locator,
        # even when the catalog root resolves through a filesystem alias.
        binding_path = path == File.basename(state_path) ? state_path : File.join(root, path)
        check!(Digest::SHA256.hexdigest(bytes) == file_binding(binding_path).fetch("sha256"),
               "current catalog repository HEAD differs from #{path} bytes")
      end
      @repository_root = root
      @repository_head = head
      @repository_remote = remote
      {"remote_url" => remote, "head" => head}
    end

    def catalog_transition(current_path, proposed_path, base_path)
      before = catalog_view(current_path)
      after = catalog_view(proposed_path)
      base = catalog_view(base_path)
      added = (after.keys - before.keys).sort
      removed = (before.keys - after.keys).sort
      changed = (before.keys & after.keys).sort.flat_map do |id|
        (before[id].keys | after[id].keys).sort.filter_map do |field|
          next if before[id][field] == after[id][field]
          {"adventure_id" => id, "field" => field, "before" => before[id][field], "after" => after[id][field]}
        end
      end
      unpreserved = before.keys.sort.flat_map do |id|
        if !after.key?(id)
          [{"adventure_id" => id, "reason" => "CURRENT_ID_REMOVED"}]
        elsif !base.key?(id)
          before[id] == after[id] ? [] : [{"adventure_id" => id, "reason" => "CONCURRENT_ID_CONFLICT"}]
        else
          before[id].keys.sort.filter_map do |field|
            next if before[id][field] == base[id][field] || before[id][field] == after[id][field]
            {"adventure_id" => id, "field" => field, "reason" => "CONCURRENT_UPDATE_LOST"}
          end
        end
      end
      # Exact workbook member preservation outside catalog worksheets is
      # independently covered by IG-13A and the canonical writer verifiers.
      {"current_ids" => before.length, "proposed_ids" => after.length, "added_ids" => added,
       "removed_ids" => removed, "changed_cells" => changed, "unpreserved" => unpreserved,
       "concurrent_changes_preserved" => unpreserved.empty?}
    end

    def catalog_view(path)
      workbook = BoundaryFreezeApply::Workbook.new(path)
      rows = {}
      StagedScoringConcurrency::CATALOGS.each do |name|
        sheet = workbook.sheet_by_name!(name)
        sheet.validate_catalog_schema!
        sheet.catalog_records.each do |record|
          id = record.fetch("adventure_id")
          signature = sheet.cell_references.select { |ref| AmcApply.reference_parts(ref)[1] == record.fetch("row") }.to_h do |ref|
            column = AmcApply.reference_parts(ref)[0]
            cell = sheet.cell(ref)
            ["#{name}:#{column}", {"value" => sheet.cell_value(ref), "formula" => sheet.cell_formula(cell), "attributes" => cell.attributes.to_h.transform_values(&:to_s).except("r")}]
          end
          # A legitimate large-record mirror retains both worksheet identities.
          check!(!rows.fetch(id, {}).keys.any? { |key| key.start_with?(name + ":") }, "duplicate Adventure ID #{id} in #{name}")
          rows[id] = rows.fetch(id, {}).merge(signature)
        end
      end
      rows
    end

    def collect_references!(value, roots, label)
      case value
      when Hash
        if value["root"] == "afw" || (value.key?("root") && roots.key?(value["root"]))
          root = roots.fetch(value.fetch("root"))
          relative = value.fetch("path")
          check!(relative.is_a?(String) && !Pathname.new(relative).absolute? &&
                 Pathname.new(relative).cleanpath.to_s == relative && !relative.split("/").include?(".."), "unsafe reference #{label}")
          path = File.expand_path(relative, root)
          check!(File.realpath(path).start_with?(File.realpath(root) + "/"), "reference escapes root #{label}")
          add_file(label, path, value)
          if label.end_with?("receipt/reference")
            collect_references!(read_json(path).fetch("artifacts"), roots, "#{label}/artifacts")
          end
        elsif value["encoding"] == "hex" && value["source"]
          content = value.fetch("content")
          check!(content.match?(/\A(?:[0-9a-f]{2})*\z/), "malformed embedded evidence #{label}")
          bytes = [content].pack("H*")
          check!(Digest::SHA256.hexdigest(bytes) == value.dig("source", "sha256"), "embedded evidence changed #{label}")
          @refs[label] = {"container" => "release_input:workload_manifest", "selector" => label, "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize}
        elsif value.key?("path") && value.key?("sha256") && !value.key?("root") && label.include?("/artifacts/")
          collect_references!(value.merge("root" => "afw"), roots, label)
        else
          value.sort.each { |key, entry| collect_references!(entry, roots, "#{label}/#{key}") }
        end
      when Array
        value.each_with_index { |entry, index| collect_references!(entry, roots, "#{label}/#{index}") }
      end
    end

    def add_file(name, path, expected = nil)
      path = File.expand_path(path)
      actual = file_binding(path)
      check!(actual == expected.slice("sha256", "bytes") || (!expected.key?("bytes") && actual["sha256"] == expected["sha256"]), "reference changed: #{name}") if expected
      binding = {"path" => path, **actual}
      check!(!@refs.key?(name) || @refs[name] == binding, "conflicting reference identity: #{name}")
      @refs[name] = binding
    end

    def assert_unchanged!
      @refs.each do |name, reference|
        next unless reference["path"]
        check!(file_binding(reference["path"]) == reference.slice("sha256", "bytes"), "evidence changed during validation: #{name}")
      end
      check!(git!(@repository_root, "rev-parse", "HEAD").strip == @repository_head, "catalog repository HEAD changed during validation")
      check!(git!(@repository_root, "remote", "get-url", "origin").strip == @repository_remote, "catalog repository remote changed during validation")
    end

    def cached_proof
      proof = PROOFS[@inputs_path]
      return unless proof
      package = JSON.parse(proof.fetch(:bytes))
      return if package.dig("release", "preview", "available") != File.file?(proof.fetch(:preview_path))
      @refs = package.dig("provenance", "nodes")
      @repository_root = proof.fetch(:root)
      @repository_head = proof.fetch(:head)
      @repository_remote = proof.fetch(:remote)
      assert_unchanged!
      package
    rescue Error, SystemCallError
      # A changed input always triggers a complete fresh semantic proof.
      nil
    end

    def file_binding(path)
      @replay_observation ? @replay_observation.file_binding(path) : StandingBulkScorePolicy.file_binding(path)
    end

    def git!(root, *args)
      stdout, stderr, status = Open3.capture3("git", "-C", root, *args)
      check!(status.success?, "catalog Git observation failed: #{stderr.strip}")
      stdout
    end

    def version_parts(version)
      Gem::Version.new(version)
    end

    def summary(package)
      counts = package.dig("release", "counts")
      population = package.dig("release", "population")
      "#{package.dig('readiness', 'ready') ? 'READY_FOR_FINAL_DECISION' : 'BLOCKED'}: " \
        "#{population['intended_cases']} cases / #{population['intended_metrics']} metrics; " \
        "standing #{counts['standing_directive_accepted']}, human #{counts['individual_human_accepted']}, machine #{counts['ig16b_machine_accepted']}; " \
        "#{population['remaining_blank_metrics']} blanks, #{population['hard_exceptions']} hard exceptions; " \
        "+#{package.dig('transition', 'delta', 'added_ids').length}/-#{package.dig('transition', 'delta', 'removed_ids').length} IDs, " \
        "#{package.dig('transition', 'delta', 'changed_cells').length} existing cells changed. Approval and adoption remain separate."
    end

    def read_json(path)
      value = JSON.parse(File.binread(path), object_class: StagedScoringAuthority::UniqueObject)
      check!(value.is_a?(Hash), "JSON reference must contain an object: #{path}")
      value
    end

    def read_jsonl(path)
      File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line, object_class: StagedScoringAuthority::UniqueObject) }
    end

    def exact_keys!(value, keys)
      check!(value.is_a?(Hash) && value.keys.sort == keys.sort, "unexpected or missing package input fields")
    end

    def check!(condition, reason)
      raise ValidationError, reason unless condition
    end
  end
end
