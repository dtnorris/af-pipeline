# frozen_string_literal: true

module AfDataPipeline
  # Composes exact staged lineage, complete workload evidence, standing/human/
  # optional machine authority, AMC apply, accepted-style finalization and
  # release accounting. It never promotes a shared catalog role.
  class StandingBulkScoreRelease
    INPUT_SCHEMA = "af-standing-bulk-score-release-inputs/v0.1"
    SELECTION_INPUT_SCHEMA = "af-standing-bulk-score-release-inputs/v0.2"
    AUTHORIZATION_SCHEMA = "af-standing-bulk-score-application-authorization/v0.1"
    RELEASE_SCHEMA = "af-standing-bulk-score-release-candidate/v0.1"
    HEX_SHA256 = /\A[0-9a-f]{64}\z/
    OUTPUTS = {
      "authorization" => "release-authorization.json",
      "apply_intermediate" => ".apply-intermediate.xlsx",
      "apply_report" => "amc-apply-report.json",
      "final_workbook" => "release-candidate.xlsx",
      "finalize_report" => "amc-finalize-report.json",
      "release_manifest" => "release-accounting.json"
    }.freeze
    PREVIEW_NAME = "red-cell-preview.xlsx"

    Result = Data.define(:output_dir, :workbook_path, :manifest_path, :manifest, :reused)
    Verification = Data.define(:release, :projection)

    def self.generated_files(root)
      raise ValidationError, "generated workload directory is invalid" unless File.directory?(root) && !File.symlink?(root)
      expanded = File.expand_path(root)
      Dir.glob(File.join(expanded, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
        next if %w[. ..].include?(File.basename(path))
        raise ValidationError, "generated workload contains a symlink" if File.symlink?(path)
        raise ValidationError, "generated workload contains an unsupported entry" unless File.file?(path) || File.directory?(path)
        [path.delete_prefix(expanded + "/"), path] if File.file?(path)
      end.to_h
    rescue SystemCallError => e
      raise ValidationError, "generated workload is unavailable: #{e.message}"
    end

    def self.run(argv, out: $stdout, err: $stderr)
      preview = argv.delete("--preview")
      unless argv.length == 4 && argv[0] == "--inputs" && argv[2] == "--output"
        err.puts "usage: af-standing-bulk-score-release --inputs INPUTS.json --output OUTPUT_DIR [--preview]"
        return 64
      end
      result = new(inputs_path: argv[1], output_dir: argv[3], preview: !preview.nil?).release!
      out.puts "Release candidate: #{result.workbook_path}"
      out.puts "Release accounting: #{result.manifest_path}"
      out.puts "Replay: #{result.reused ? 'verified existing release' : 'published new release'}"
      0
    rescue ValidationError => e
      err.puts "BLOCKED: #{e.message}"
      2
    end

    def initialize(inputs_path:, output_dir:, preview: false, fault_injector: nil)
      @inputs_path = File.expand_path(inputs_path)
      @output_dir = File.expand_path(PrivateDataRoot.destination!(output_dir))
      @preview = preview
      @fault_injector = fault_injector
    end

    def release!
      inputs = load_inputs!
      context = validate_inputs!(inputs)
      return verify_existing!(context) if File.exist?(@output_dir)

      parent = File.dirname(@output_dir)
      raise ValidationError, "release parent directory does not exist: #{parent}" unless File.directory?(parent)
      Dir.mkdir(@output_dir)
      published = false
      begin
        authorization_path = output_path("authorization")
        write_new_json!(authorization_path, context.fetch(:authorization))

        apply_result = AmcApply.apply_authorized!(
          authorized_candidates: context.fetch(:authorized_candidates),
          authorization: context.fetch(:authorization),
          accounting: writer_accounting(context),
          amc_path: context.fetch(:staged_amc_path),
          output_path: output_path("apply_intermediate"),
          report_path: output_path("apply_report")
        )
        fault!(:after_apply)

        finalize_result = AmcFinalize.finalize!(
          amc_path: apply_result.output_path,
          apply_report_path: apply_result.report_path,
          output_path: output_path("final_workbook"),
          report_path: output_path("finalize_report"),
          expected_cells: apply_result.report.dig("counts", "new_cells_written")
        )
        fault!(:after_finalize)

        if @preview
          File.link(apply_result.output_path, File.join(@output_dir, PREVIEW_NAME))
        end
        revalidate_before_publication!(inputs, context)
        manifest = build_release_manifest(context, apply_result.report, finalize_result.report)
        write_new_json!(output_path("release_manifest"), manifest)
        published = true
        Result.new(
          output_dir: @output_dir,
          workbook_path: output_path("final_workbook"),
          manifest_path: output_path("release_manifest"),
          manifest:,
          reused: false
        )
      ensure
        FileUtils.remove_entry(@output_dir) if !published && File.directory?(@output_dir)
      end
    rescue Errno::EEXIST, Errno::ENOTEMPTY
      raise ValidationError, "release output was created concurrently: #{@output_dir}"
    end

    # Read-only replay for package consumers. Missing retained evidence is a
    # defect, never an instruction to reconstruct a review package or ledger.
    def validate_existing!(current_project_state_path: nil, replay_observation: nil)
      unless replay_observation.nil? || replay_observation.instance_of?(CatalogReplayObservation)
        raise ValidationError, "invalid historical catalog observation"
      end
      inputs = load_inputs!
      review = inputs.fetch("workload_review")
      required = WorkloadScoringReviewPackage::PACKAGE_FILES.map { |name| File.join(review.fetch("review_dir"), name) }
      required += %w[audit_manifest.json editorial_decisions.csv].map { |name| File.join(review.fetch("audit_dir"), name) }
      unless required.all? { |path| File.file?(path) }
        raise ValidationError, "release validation requires all retained review and audit artifacts"
      end
      context = validate_inputs!(inputs, replay_observation:)
      release = verify_existing!(context, preview_required: false)
      projection = if current_project_state_path
                     context.fetch(:authority).validate!(current_state_path: current_project_state_path, replay_observation:,
                                                         frozen_workload: context.fetch(:workload_binding),
                                                         workload_paths: inputs.dig("staged_scoring", "workload_paths"),
                                                         selection_path: inputs.dig("staged_scoring", "selection_path"))
                   else
                     context.fetch(:projection)
                   end
      replay_observation&.assert_current!
      Verification.new(release:, projection:)
    end

    private

    def load_inputs!
      value = JSON.parse(File.binread(@inputs_path), object_class: StagedScoringAuthority::UniqueObject)
      exact_keys!(value, %w[
        schema_version mode staged_scoring workload_review standing_policy_path owner_selection_path
        machine_acceptance
      ], "release inputs")
      unless [INPUT_SCHEMA, SELECTION_INPUT_SCHEMA].include?(value["schema_version"])
        raise ValidationError, "release inputs schema_version is invalid"
      end
      unless %w[production synthetic].include?(value["mode"])
        raise ValidationError, "release input mode is invalid"
      end
      value
    rescue Errno::ENOENT, JSON::ParserError => e
      raise ValidationError, "invalid release inputs: #{e.message}"
    end

    # Reconstruct release authority from exact inputs. Only read-only adoption
    # replay supplies the existing exact-promotion observation; release! always
    # observes live state. All other evidence remains at its original bytes.
    def validate_inputs!(inputs, replay_observation: nil)
      staged = inputs["staged_scoring"]
      review = inputs["workload_review"]
      staged_keys = %w[
        evidence store_root current_project_state_path workload_binding_path workload_paths
      ]
      if inputs.fetch("schema_version") == SELECTION_INPUT_SCHEMA
        staged_keys += %w[selection_path selection_afw_root selection_project_root selection_scorer_root]
        staged_keys << "selection_scorer_config" if staged.key?("selection_scorer_config")
      end
      exact_keys!(staged, staged_keys, "staged scoring inputs")
      exact_keys!(review, %w[manifest_path afw_root review_dir audit_dir], "workload review inputs")
      exact_keys!(staged["workload_paths"], inputs.fetch("schema_version") == SELECTION_INPUT_SCHEMA ?
        %w[plan snapshot index generated] : %w[plan snapshot index], "workload paths")
      if inputs.fetch("schema_version") == SELECTION_INPUT_SCHEMA
        staged_keys.grep(/\Aselection_/).each do |key|
          unless staged.fetch(key).is_a?(String) && !staged.fetch(key).empty?
            raise ValidationError, "staged scoring #{key} is invalid"
          end
        end
      end

      authority = StagedScoringAuthority.new(
        evidence: staged.fetch("evidence").transform_keys(&:to_sym),
        store_root: staged.fetch("store_root"),
        mode: inputs.fetch("mode"),
        selection_afw_root: staged["selection_afw_root"],
        selection_project_root: staged["selection_project_root"],
        selection_scorer_root: staged["selection_scorer_root"],
        selection_scorer_config: staged["selection_scorer_config"]
      )
      workload_binding = read_json(staged.fetch("workload_binding_path"), "frozen workload binding")
      validate_selection_locators!(staged, review, workload_binding) if inputs.fetch("schema_version") == SELECTION_INPUT_SCHEMA
      projection = authority.validate!(
        current_state_path: staged.fetch("current_project_state_path"),
        replay_observation:,
        frozen_workload: workload_binding,
        workload_paths: staged.fetch("workload_paths"),
        selection_path: staged["selection_path"]
      )
      unless projection["workload_frozen"] && projection["preparation_allowed"] &&
             projection["execution_authorized"] == false && projection["catalog_adoption_authorized"] == false
        raise ValidationError, "staged scoring authority does not permit exact frozen workload reuse"
      end

      package = WorkloadScoringReviewPackage.prepare!(
        manifest_path: review.fetch("manifest_path"),
        afw_root: review.fetch("afw_root"),
        review_dir: review.fetch("review_dir"),
        audit_dir: review.fetch("audit_dir")
      )
      manifest = read_json(review.fetch("manifest_path"), "workload evidence manifest")
      validate_workload_link!(manifest, staged.fetch("workload_paths"), workload_binding, projection)
      unresolved = read_jsonl(File.join(package.review_dir, "unresolved_cases.jsonl"), "unresolved workload cases")
      unless unresolved.empty?
        identities = unresolved.map { |entry| "#{entry['case_id']}:#{entry.dig('classification', 'reason')}" }
        raise ValidationError, "workload has nonterminal unresolved execution/evidence cases: #{identities.join(', ')}"
      end

      policy_result = StandingBulkScorePolicy.validate!(
        policy_path: inputs.fetch("standing_policy_path"),
        selection_path: inputs.fetch("owner_selection_path")
      )
      candidates = read_jsonl(File.join(package.review_dir, "candidates.jsonl"), "workload candidates")
      source_holds = read_jsonl(File.join(package.review_dir, "holds.jsonl"), "workload source holds")
      audit = validate_editorial_audit!(package.audit_dir)
      classification = classify_candidates!(
        candidates:,
        source_holds:,
        audit:,
        manifest:,
        projection:,
        policy_result:,
        machine: inputs["machine_acceptance"]
      )
      raise ValidationError, "release has no accounted workload cases" unless package.intended_cases.positive?

      staged_amc = projection.fetch("authority").fetch("staged_amc")
      staged_path = File.join(staged.fetch("evidence").fetch("catalog_root"), staged_amc.fetch("filename"))
      unless File.file?(staged_path) && StandingBulkScorePolicy.file_binding(staged_path) == staged_amc.slice("sha256", "bytes")
        raise ValidationError, "exact staged AMC is missing or changed"
      end
      input_snapshot = capture_input_snapshot(inputs, package, staged_path, replay_observation:)
      authorization = build_authorization(
        projection:,
        workload_binding:,
        manifest:,
        package:,
        policy_result:,
        classification:,
        staged_amc:,
        input_snapshot:
      )

      {
        inputs:,
        authority:,
        projection:,
        workload_binding:,
        package:,
        manifest:,
        policy_result:,
        classification:,
        authorized_candidates: classification.fetch(:accepted).map do |entry|
          candidate = entry.fetch("candidate")
          {
            "candidate_key" => candidate.fetch("candidate_key"),
            "adventure_id" => candidate.fetch("adventure_id"),
            "dimension" => candidate.fetch("dimension"),
            "proposed_value" => candidate.fetch("value")
          }
        end,
        authorization:,
        staged_amc_path: staged_path,
        input_snapshot:
      }
    end

    def validate_selection_locators!(staged, review, binding)
      root = File.expand_path(staged.fetch("selection_project_root"))
      real_root = File.realpath(root)
      unless real_root == File.realpath(review.fetch("afw_root"))
        raise ValidationError, "AFW selection and workload review roots differ"
      end
      workload_id = binding.fetch("workload_id")
      unless workload_id.is_a?(String) && workload_id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/) &&
             binding["schema_version"] == "af-staged-scoring-workload-binding/v0.2"
        raise ValidationError, "v0.2 release requires an exact AFW frozen workload"
      end
      expected = {
        "selection_path" => File.join(root, "workloads", ".selections", workload_id, "selection.json"),
        "workload_binding_path" => File.join(root, "workloads", ".selections", workload_id, "frozen-workload.json"),
        "plan" => File.join(root, "workloads", workload_id, "execution-plan.json"),
        "snapshot" => File.join(root, "workloads", workload_id, "snapshot.yml"),
        "index" => File.join(root, "workloads", workload_id, "case_index.csv"),
        "generated" => File.join(root, "build", "workloads", workload_id)
      }
      expected.each do |name, path|
        supplied = %w[selection_path workload_binding_path].include?(name) ? staged.fetch(name) : staged.fetch("workload_paths").fetch(name)
        real_path = path.sub(/\A#{Regexp.escape(root)}(?=\/)/, real_root)
        unless File.expand_path(supplied) == path && File.realpath(supplied) == real_path
          raise ValidationError, "AFW #{name} is not the exact frozen workload locator"
        end
      end
    rescue SystemCallError => e
      raise ValidationError, "invalid AFW selection locator: #{e.message}"
    end

    def validate_workload_link!(manifest, paths, binding, projection)
      references = manifest.dig("workload", "afw")
      expected = {
        "plan" => references&.dig("execution_plan", "sha256"),
        "snapshot" => references&.dig("snapshot", "sha256"),
        "index" => references&.dig("case_index", "sha256")
      }
      frozen_paths = paths.except("generated")
      actual = frozen_paths.to_h { |name, path| [name, Digest::SHA256.file(path).hexdigest] }
      unless expected == actual && binding.fetch("artifacts") == frozen_paths.to_h { |name, path|
        [name, StandingBulkScorePolicy.file_binding(path)]
      }
        raise ValidationError, "workload manifest, frozen binding and artifact identities differ"
      end
      unless manifest.dig("workload", "plan_id") == binding["workload_id"] &&
             manifest.dig("summary", "accounting_complete") == true &&
             projection.dig("authority", "intent", "workload_id") == binding["workload_id"]
        raise ValidationError, "frozen workload denominator or identity is inconsistent"
      end
    rescue Errno::ENOENT => e
      raise ValidationError, "missing frozen workload artifact: #{e.message}"
    end

    def validate_editorial_audit!(audit_dir)
      validation = nil
      Dir.mktmpdir("standing-bulk-editorial-validation-", PrivateDataRoot.selected) do |output|
        validation = EditorialAudit.validate!(audit_dir:, output_dir: output)
      end
      unless validation.errors.empty?
        raise ValidationError, "editorial audit is invalid: #{validation.errors.join('; ')}"
      end
      validation
    end

    def classify_candidates!(candidates:, source_holds:, audit:, manifest:, projection:, policy_result:, machine:)
      duplicates = candidates.map { |candidate| candidate["candidate_key"] }.tally.select { |_key, count| count > 1 }.keys
      raise ValidationError, "duplicate score candidate identities: #{duplicates.join(', ')}" unless duplicates.empty?
      decisions = audit.rows.to_h { |row| [row.fetch("record_key"), row] }
      intended_ids = projection.fetch("authority").fetch("allocation").map { |row| row.fetch("adventure_id") }
      cases = manifest.fetch("cases").to_h { |entry| [entry.fetch("case_id"), entry] }
      policy = policy_result.policy
      accepted = []
      residuals = source_holds.map do |hold|
        residual(hold.fetch("hold_key"), "source_hold", "source hold is locked", hold)
      end

      candidates.each do |candidate|
        key = candidate.fetch("candidate_key")
        decision = decisions.fetch(key) { raise ValidationError, "editorial ledger is missing #{key}" }
        unless intended_ids.include?(candidate.fetch("adventure_id"))
          raise ValidationError, "#{key}: candidate is outside the staged authority allocation"
        end
        unless decision["record_sha256"] == Digest::SHA256.hexdigest(JSON.generate(candidate))
          raise ValidationError, "#{key}: candidate/ledger immutable identity mismatch"
        end
        if !candidate["hold_reason"].to_s.strip.empty? || candidate["review_disposition"] == "SOURCE_HOLD"
          residuals << residual(key, "source_hold", candidate["hold_reason"] || "source-defined hold", candidate)
          next
        end
        case decision["editorial_decision"]
        when "HOLD"
          residuals << residual(key, "human_hold", decision["editorial_note"], candidate)
        when "REJECT"
          residuals << residual(key, "human_reject", decision["editorial_note"], candidate)
        when "ACCEPT"
          accepted << acceptance(candidate, "individual_human", decision["record_sha256"])
        when nil
          machine_record = machine_record_for(machine, key)
          if machine_record
            machine_acceptance = validate_machine_acceptance!(machine_record, machine, candidate, manifest)
            if machine_acceptance
              accepted << machine_acceptance
              next
            end
          end
          case_entry = cases.fetch(candidate.fetch("afw_workload_case_id"))
          scope_reason = unsupported_scope_reason(candidate, case_entry, projection, policy)
          if scope_reason
            residuals << residual(key, "unsupported_scope", scope_reason, candidate)
            next
          end
          flags = standing_advisory_flags!(candidate, policy)
          unless candidate["assessment_state"] == "resolved" && numeric?(candidate["value"]) &&
                 candidate["mechanical_status"] == "valid"
            raise ValidationError, "#{key}: candidate is unresolved, nonnumeric or mechanically invalid"
          end
          accepted << acceptance(candidate, "standing_directive", policy.fetch("policy_digest"), flags:)
        else
          raise ValidationError, "#{key}: unsupported editorial decision"
        end
      end
      accounted = accepted.length + residuals.count { |row| row["candidate_key"] }
      unless accounted == candidates.length
        raise ValidationError, "metric-candidate accounting is incomplete"
      end
      {
        accepted:,
        residuals:,
        candidates:,
        source_holds:,
        human_accepts: accepted.count { |row| row["authority"] == "individual_human" },
        standing_accepts: accepted.count { |row| row["authority"] == "standing_directive" },
        machine_accepts: accepted.count { |row| row["authority"] == "ig16b_machine" },
        human_holds: residuals.count { |row| row["category"] == "human_hold" },
        human_rejects: residuals.count { |row| row["category"] == "human_reject" },
        source_hold_count: residuals.count { |row| row["category"] == "source_hold" },
        unsupported: residuals.count { |row| row["category"] == "unsupported_scope" }
      }
    end

    def unsupported_scope_reason(candidate, manifest_case, projection, policy)
      scope = policy.fetch("scope")
      row = manifest_case.dig("intent", "case_index_row")
      checks = {
        "profile #{row['profile'].inspect}" => scope["profiles"].include?(row["profile"]),
        "model alias #{row['model_alias'].inspect}" => scope["model_aliases"].include?(row["model_alias"]),
        "model #{row['ollama_model'].inspect}" => scope["models"].include?(row["ollama_model"]),
        "dimension #{candidate['dimension'].inspect}" => scope["dimensions"].include?(candidate["dimension"])
      }
      failed = checks.find { |_label, supported| !supported }
      return "#{failed.first} is outside standing scope" if failed
      exact_source = projection.dig("authority", "intent", "source", "source_id")
      unless candidate["source_book"] == exact_source
        raise ValidationError, "#{candidate['candidate_key']}: source identity differs from operation-bound source"
      end
      nil
    end

    def candidate_flags(candidate)
      %w[metric_review_flags package_review_flags].flat_map do |field|
        value = candidate[field]
        next [] if value.nil? || value.to_s.strip.empty?
        parsed = value.is_a?(Array) ? value : value.to_s.split(/[;,]/)
        parsed.map(&:strip).reject(&:empty?)
      end.uniq.sort
    end

    def standing_advisory_flags!(candidate, policy)
      flags = candidate_flags(candidate)
      hard = flags & policy.dig("flag_rules", "hard_refusal")
      unknown = flags - policy.dig("flag_rules", "hard_refusal") - policy.dig("flag_rules", "advisory")
      key = candidate.fetch("candidate_key")
      raise ValidationError, "#{key}: hard-refusal flags: #{hard.join(', ')}" unless hard.empty?
      raise ValidationError, "#{key}: flags have ambiguous severity: #{unknown.join(', ')}" unless unknown.empty?

      flags
    end

    def machine_record_for(machine, key)
      return nil if machine.nil?
      exact_keys!(machine, %w[records roots], "machine acceptance inputs")
      records = machine["records"]
      roots = machine["roots"]
      unless records.is_a?(Hash) && roots.is_a?(Hash)
        raise ValidationError, "machine acceptance inputs are malformed"
      end
      records[key]
    end

    def validate_machine_acceptance!(path, machine, candidate, manifest)
      document = read_json(path, "machine acceptance record")
      validation = MachinePolicyAcceptance.validate_file!(path:, roots: machine.fetch("roots"))
      unless document.dig("candidate", "key") == candidate["candidate_key"] &&
             document.dig("candidate", "adventure_id") == candidate["adventure_id"] &&
             document.dig("candidate", "metric") == candidate["dimension"] &&
             AmcApply.numeric_equal?(document.dig("candidate", "proposed_value"), candidate["value"]) &&
             document.dig("evidence", "receipt", "receipt_id") == candidate["afw_receipt_id"] &&
             document.dig("workload", "manifest_id") == manifest["manifest_id"] &&
             document.dig("workload", "case_id") == candidate["afw_workload_case_id"]
        raise ValidationError, "#{candidate['candidate_key']}: machine authority does not bind the current candidate"
      end
      return nil unless validation.authoritative && validation.state == "ACCEPTED"

      acceptance(candidate, "ig16b_machine", validation.record_id)
    end

    def acceptance(candidate, authority, authority_id, flags: [])
      {
        "candidate_key" => candidate.fetch("candidate_key"),
        "candidate_sha256" => Digest::SHA256.hexdigest(JSON.generate(candidate)),
        "authority" => authority,
        "authority_id" => authority_id,
        "advisory_flags" => flags,
        "candidate" => candidate
      }
    end

    def residual(key, category, reason, source)
      {
        "candidate_key" => source["candidate_key"],
        "record_key" => key,
        "category" => category,
        "reason" => reason,
        "adventure_id" => source["adventure_id"],
        "dimension" => source["dimension"],
        "source_reference" => source["provenance"],
        "workbook_binding" => {
          "adventure_id" => source["adventure_id"],
          "dimension" => source["dimension"]
        }
      }
    end

    def build_authorization(projection:, workload_binding:, manifest:, package:, policy_result:, classification:,
                            staged_amc:, input_snapshot:)
      body = {
        "schema_version" => AUTHORIZATION_SCHEMA,
        "operation" => projection.dig("authority", "operation"),
        "staged_authority_id" => projection.dig("authority", "authority_id"),
        "standing_policy" => policy_result.policy.slice(
          "policy_id", "policy_version", "status", "activation", "revision_id", "policy_digest"
        ).merge("artifact" => policy_result.policy_binding),
        "owner_selection" => {
          "selection_id" => policy_result.selection.fetch("selection_id"),
          "selected_by" => policy_result.selection.fetch("selected_by"),
          "artifact" => policy_result.selection_binding
        },
        "lineage" => {
          "base_amc" => projection.dig("authority", "base_amc"),
          "staged_amc" => staged_amc,
          "approval_id" => projection.dig("authority", "approval_id"),
          "workload_authority" => workload_binding.slice("authority_id", "operation_id", "workload_id", "selection_id", "artifacts"),
          "workload_manifest_id" => manifest.fetch("manifest_id"),
          "review_package_id" => JSON.parse(File.binread(File.join(package.review_dir, "review_package.json"))).fetch("package_id")
        },
        "accepted_candidates" => classification.fetch(:accepted).map { |entry| entry.except("candidate") },
        "residuals" => classification.fetch(:residuals),
        "counts" => authorization_counts(classification, manifest),
        "input_snapshot" => input_snapshot
      }
      body["authorization_id"] = StandingBulkScorePolicy.digest(body)
      body
    end

    def authorization_counts(classification, manifest)
      {
        "intended_cases" => manifest.dig("summary", "intended_cases"),
        "execution_evidence_ready_cases" => manifest.dig("summary", "receipt_count"),
        "execution_evidence_unresolved_cases" =>
          manifest.dig("summary", "intended_cases") - manifest.dig("summary", "receipt_count"),
        "metric_candidates" => classification.fetch(:candidates).length,
        "standing_directive_accepted" => classification.fetch(:standing_accepts),
        "individual_human_accepted" => classification.fetch(:human_accepts),
        "ig16b_machine_accepted" => classification.fetch(:machine_accepts),
        "historical_mechanical_accepted" => 0,
        "human_hold" => classification.fetch(:human_holds),
        "human_reject" => classification.fetch(:human_rejects),
        "source_holds" => classification.fetch(:source_hold_count),
        "deferred_or_unsupported" => classification.fetch(:unsupported),
        "unscored_or_unresolved" => 0,
        "conflicting_targets" => 0
      }
    end

    def writer_accounting(context)
      counts = context.dig(:authorization, "counts")
      {
        "source_holds" => counts.fetch("source_holds"),
        "held_candidates" => counts.fetch("human_hold"),
        "rejected_candidates" => counts.fetch("human_reject"),
        "pending_candidates" => 0
      }
    end

    def build_release_manifest(context, apply_report, finalize_report)
      counts = context.fetch(:authorization).fetch("counts").merge(
        "authorized_candidates" => context.fetch(:authorized_candidates).length,
        "new_cells_written" => apply_report.dig("counts", "new_cells_written"),
        "already_present_exact" => apply_report.dig("counts", "already_present_exact_matches"),
        "finalized_cells" => finalize_report.dig("counts", "finalized_cells"),
        "boundary_created_ids" => context.dig(:projection, "authority", "allocation").length
      )
      artifacts = OUTPUTS.except("release_manifest").to_h do |kind, name|
        [kind, {"filename" => name, **StandingBulkScorePolicy.file_binding(File.join(@output_dir, name))}]
      end
      if @preview
        artifacts["explicit_red_cell_preview"] = {
          "filename" => PREVIEW_NAME,
          **StandingBulkScorePolicy.file_binding(File.join(@output_dir, PREVIEW_NAME)),
          "authority_effect" => "none"
        }
      end
      manifest = {
        "schema_version" => RELEASE_SCHEMA,
        "status" => "VERIFIED_RELEASE_CANDIDATE",
        "release_id" => context.fetch(:authorization).fetch("authorization_id"),
        "shared_catalog_promotion" => false,
        "release_complete" => true,
        "every_intended_score_present" =>
          counts["authorized_candidates"] == counts["metric_candidates"] &&
          counts["execution_evidence_unresolved_cases"].zero?,
        "authorization" => {
          "authorization_id" => context.fetch(:authorization).fetch("authorization_id"),
          "sha256" => Digest::SHA256.file(output_path("authorization")).hexdigest
        },
        "lineage" => context.fetch(:authorization).fetch("lineage"),
        "counts" => counts,
        "residuals" => context.dig(:classification, :residuals),
        "boundary_created_ids" => context.dig(:projection, "authority", "allocation").map do |record|
          record.slice("local_key", "adventure_id", "parent_key", "resolved_parent_adventure_id")
        end,
        "artifacts" => artifacts,
        "verification" => {
          "amc_apply" => apply_report.fetch("verification"),
          "amc_finalize" => finalize_report.fetch("verification"),
          "unauthorized_cell_changes" => 0,
          "shared_roles_mutated" => 0,
          "git_mutations" => 0
        }
      }
      manifest["manifest_id"] = StandingBulkScorePolicy.digest(manifest)
      manifest
    end

    def revalidate_before_publication!(inputs, context)
      current = capture_input_snapshot(inputs, context.fetch(:package), context.fetch(:staged_amc_path))
      raise ValidationError, "release inputs changed during application" unless current == context.fetch(:input_snapshot)
      staged = inputs.fetch("staged_scoring")
      projection = context.fetch(:authority).validate!(
        current_state_path: staged.fetch("current_project_state_path"),
        frozen_workload: context.fetch(:workload_binding),
        workload_paths: staged.fetch("workload_paths"),
        selection_path: staged["selection_path"]
      )
      unless projection.dig("authority", "authority_id") == context.dig(:projection, "authority", "authority_id")
        raise ValidationError, "staged authority changed during application"
      end
      StandingBulkScorePolicy.validate!(
        policy_path: inputs.fetch("standing_policy_path"),
        selection_path: inputs.fetch("owner_selection_path")
      )
      inputs.fetch("machine_acceptance", nil)&.then do |machine|
        machine.fetch("records").each_value do |path|
          MachinePolicyAcceptance.validate_file!(path:, roots: machine.fetch("roots"))
        end
      end
    end

    def verify_existing!(context, preview_required: true)
      manifest_path = output_path("release_manifest")
      raise ValidationError, "existing release publication is partial" unless File.file?(manifest_path)
      manifest = read_json(manifest_path, "release accounting")
      unless manifest["schema_version"] == RELEASE_SCHEMA &&
             manifest["release_id"] == context.dig(:authorization, "authorization_id") &&
             manifest["manifest_id"] == StandingBulkScorePolicy.digest(manifest.except("manifest_id"))
        raise ValidationError, "existing release accounting conflicts with current authority"
      end
      expected_names = OUTPUTS.values
      preview = manifest.dig("artifacts", "explicit_red_cell_preview")
      expected_names << PREVIEW_NAME if preview && (preview_required || File.file?(File.join(@output_dir, PREVIEW_NAME)))
      unless Dir.children(@output_dir).sort == expected_names.sort
        raise ValidationError, "existing release artifact set is incomplete or unexpected"
      end
      manifest.fetch("artifacts").each do |kind, binding|
        next if kind == "explicit_red_cell_preview" && !preview_required
        path = File.join(@output_dir, binding.fetch("filename"))
        unless StandingBulkScorePolicy.file_binding(path) == binding.slice("sha256", "bytes")
          raise ValidationError, "existing release artifact changed: #{binding.fetch('filename')}"
        end
      end
      authorization = read_json(output_path("authorization"), "release authorization")
      unless authorization == context.fetch(:authorization)
        raise ValidationError, "existing release authorization conflicts with current inputs"
      end
      apply_report = read_json(output_path("apply_report"), "AMC apply report")
      AmcApply.verify!(
        source_amc: context.fetch(:staged_amc_path),
        output_amc: output_path("apply_intermediate"),
        records: apply_report.fetch("records"),
        styles_appended: apply_report.dig("style_mutation", "cell_xfs_appended")
      )
      AmcFinalize.verify_existing!(
        amc_path: output_path("apply_intermediate"),
        apply_report_path: output_path("apply_report"),
        output_path: output_path("final_workbook"),
        report_path: output_path("finalize_report")
      )
      finalize_report = read_json(output_path("finalize_report"), "AMC finalize report")
      # Recompute every count, residual, lineage and artifact binding from
      # independently replayed immutable inputs; a rehashed summary is no proof.
      @preview = preview != nil && preview_required
      expected_manifest = build_release_manifest(context, apply_report, finalize_report)
      if preview && !preview_required
        expected_manifest["artifacts"]["explicit_red_cell_preview"] = preview
        expected_manifest["manifest_id"] = StandingBulkScorePolicy.digest(expected_manifest.except("manifest_id"))
      end
      unless manifest == expected_manifest
        raise ValidationError, "release accounting does not reconcile with complete workload and application evidence"
      end
      Result.new(
        output_dir: @output_dir,
        workbook_path: output_path("final_workbook"),
        manifest_path:,
        manifest:,
        reused: true
      )
    end

    # Hash every immutable release input. The existing replay observation maps
    # only its exact approved catalog manifest to reviewed historical bytes;
    # all other locators continue to use live file hashing.
    def capture_input_snapshot(inputs, package, staged_path, replay_observation: nil)
      paths = {
        "release_inputs" => @inputs_path,
        "standing_policy" => inputs.fetch("standing_policy_path"),
        "owner_selection" => inputs.fetch("owner_selection_path"),
        "workload_manifest" => inputs.dig("workload_review", "manifest_path"),
        "review_package" => File.join(package.review_dir, "review_package.json"),
        "review_candidates" => File.join(package.review_dir, "candidates.jsonl"),
        "review_holds" => File.join(package.review_dir, "holds.jsonl"),
        "review_unresolved" => File.join(package.review_dir, "unresolved_cases.jsonl"),
        "review_integrity" => File.join(package.review_dir, "integrity_report.json"),
        "audit_manifest" => File.join(package.audit_dir, "audit_manifest.json"),
        "editorial_ledger" => File.join(package.audit_dir, "editorial_decisions.csv"),
        "workload_binding" => inputs.dig("staged_scoring", "workload_binding_path"),
        "current_project_state" => inputs.dig("staged_scoring", "current_project_state_path"),
        "staged_amc" => staged_path
      }
      staged = inputs.fetch("staged_scoring")
      if (selection_path = staged["selection_path"])
        paths["afw_selection"] = selection_path
        paths["afw_selection_publication"] = File.join(File.dirname(selection_path), "publication.json")
      end
      staged.fetch("workload_paths").except("generated").each { |name, path| paths["workload_#{name}"] = path }
      if (generated = staged.dig("workload_paths", "generated"))
        self.class.generated_files(generated).each { |name, path| paths["workload_generated:#{name}"] = path }
      end
      inputs.fetch("machine_acceptance", nil)&.fetch("records", {})&.each do |key, path|
        paths["machine:#{key}"] = path
      end
      paths.sort.to_h do |name, path|
        [name, replay_observation ? replay_observation.file_binding(path) : StandingBulkScorePolicy.file_binding(path)]
      end
    rescue SystemCallError => e
      raise ValidationError, "release input snapshot is unavailable: #{e.message}"
    end

    def output_path(kind)
      File.join(@output_dir, OUTPUTS.fetch(kind))
    end

    def write_new_json!(path, value)
      Tempfile.create([".standing-release-", ".json"], File.dirname(path)) do |temp|
        temp.write(JSON.pretty_generate(StandingBulkScorePolicy.canonical(value)) + "\n")
        temp.flush
        temp.fsync
        File.link(temp.path, path)
      end
    rescue Errno::EEXIST
      raise ValidationError, "refusing to overwrite release artifact: #{path}"
    end

    def read_json(path, label)
      value = JSON.parse(File.binread(path), object_class: StagedScoringAuthority::UniqueObject)
      raise ValidationError, "#{label} must be an object" unless value.is_a?(Hash)
      value
    rescue Errno::ENOENT, JSON::ParserError => e
      raise ValidationError, "invalid #{label}: #{e.message}"
    end

    def read_jsonl(path, label)
      File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
    rescue Errno::ENOENT, JSON::ParserError => e
      raise ValidationError, "invalid #{label}: #{e.message}"
    end

    def exact_keys!(value, keys, label)
      unless value.is_a?(Hash) && value.keys.sort == keys.sort
        raise ValidationError, "#{label} has unexpected fields"
      end
    end

    def require_value!(value, key, expected, label)
      raise ValidationError, "#{label} #{key} is invalid" unless value[key] == expected
    end

    def numeric?(value)
      value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
    end

    def fault!(phase)
      @fault_injector&.call(phase)
    end
  end
end
