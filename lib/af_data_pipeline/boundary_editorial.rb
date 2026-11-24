# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "shellwords"
require "tempfile"
require "time"
require "yaml"
require_relative "error"
require_relative "boundary_freeze"
require_relative "editorial_specifications"

module AfDataPipeline
  # Durable editorial ledger between deterministic boundary evidence and a frozen
  # boundary artifact. Software owns provenance; humans/frontier reasoning own
  # candidate discovery and semantic dispositions.
  module BoundaryEditorial
    CONTEXT_SCHEMA_VERSION = "af-boundary-editorial-context/v0.1"
    LEGACY_DECISIONS_SCHEMA_VERSION = "af-boundary-editorial-decisions/v0.1"
    DECISIONS_SCHEMA_VERSION = "af-boundary-editorial-decisions/v0.2"
    SUPPORTED_DECISIONS_SCHEMAS = [LEGACY_DECISIONS_SCHEMA_VERSION, DECISIONS_SCHEMA_VERSION].freeze
    SUPPORTED_DOSSIER_SCHEMAS = %w[
      af-boundary-dossier/v0.1
      af-boundary-dossier/v0.2
    ].freeze
    CONTEXT_FILENAME = "editorial_context.json"
    DECISIONS_FILENAME = "editorial_decisions.yml"
    REVIEW_FILENAME = "editorial_review.md"
    APPROVAL_FILENAME = "editorial_approval.json"
    APPROVAL_SCHEMA_VERSION = "af-boundary-editorial-approval/v0.1"
    RENDER_DERIVATION = "af-boundary-editorial-render/v0.1"
    CANDIDATE_KEY_RE = /\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/
    ADV_ID_RE = BoundaryFreeze::ADV_ID_RE
    LEGACY_DISPOSITIONS = %w[pending accept reject merge hold].freeze
    DISPOSITIONS = (LEGACY_DISPOSITIONS + ["split"]).freeze
    IMPORTABLE_DISPOSITIONS = %w[accept reject merge split].freeze

    BundleResult = Data.define(:output_dir, :context_path, :decisions_path, :review_path, :context, :decisions)
    ValidationResult = Data.define(:bundle_dir, :context, :decisions, :counts, :complete)
    ImportResult = Data.define(:output_path, :record_count, :sha256, :counts)
    RebindResult = Data.define(:output_dir, :context_path, :decisions_path, :review_path, :context)
    ApprovalResult = Data.define(:output_path, :approval, :sha256, :reused)
    ApprovalValidationResult = Data.define(:path, :approval, :sha256, :binding)
    ApprovedFreezeResult = Data.define(
      :output_path, :record_count, :sha256, :counts, :approval_id, :approval_sha256,
      :reused, :draft_path, :draft_initialized
    )
    ApprovedFreezeValidationResult = Data.define(
      :path, :artifact, :record_count, :sha256, :counts, :approval_id, :approval_sha256
    )

    module_function

    # Create a new bundle from a dossier and optional explicit public spec root.
    # Returns BundleResult; invalid provenance/definitions raise ValidationError.
    # Omission retains the historical contract; it never implies public adoption.
    def init!(dossier_path:, output_dir:, spec_root: nil)
      dossier_file, dossier = load_dossier!(dossier_path)
      context = context_for(dossier_file, dossier)
      context["public_specifications"] = EditorialSpecifications.bind!(spec_root) if spec_root
      decisions = {
        "schema_version" => DECISIONS_SCHEMA_VERSION,
        "candidates" => []
      }
      publish_bundle!(output_dir, context, decisions)
    end

    def validate!(bundle_dir:, complete: false)
      bundle = expanded_bundle_dir!(bundle_dir)
      context = load_context!(File.join(bundle, CONTEXT_FILENAME))
      decisions = load_decisions!(File.join(bundle, DECISIONS_FILENAME))
      validate_context!(context)
      counts = validate_candidates!(
        decisions.fetch("candidates"),
        complete:,
        schema_version: decisions.fetch("schema_version")
      )
      ValidationResult.new(
        bundle_dir: bundle,
        context:,
        decisions:,
        counts:,
        complete: counts.fetch("pending").zero? && counts.fetch("hold").zero?
      )
    end

    # Render a deterministic, read-only view of the editable ledger. Ordering is
    # driven only by explicit editorial state; it does not classify candidates.
    def render_workspace(bundle_dir:)
      validation = validate!(bundle_dir:)
      context = validation.context
      candidates = validation.decisions.fetch("candidates")
      lines = []
      lines << "# AdventureFinder boundary review workspace"
      lines << ""
      lines << "> Complete-set editorial view. Ambiguity-first ordering below is derived only from explicit ledger fields; every Phase 1 candidate remains in the full inventory."
      lines << ""
      lines << "## Bound provenance"
      lines << ""
      lines << "- Source: `#{context.dig('source', 'canonical_source_id')}`"
      lines << "- Dossier: `#{context.dig('dossier', 'filename')}` (`#{context.dig('dossier', 'sha256')}`)"
      lines << "- Base AMC: `#{context.dig('base_amc', 'filename')}` (`#{context.dig('base_amc', 'sha256')}`)"
      lines << "- Decision schema: `#{validation.decisions.fetch('schema_version')}`"
      lines << "- Candidate denominator: #{candidates.length}"
      if context["public_specifications"]
        lines.concat(EditorialSpecifications.lines(context.fetch("public_specifications")))
      end
      DISPOSITIONS.each { |disposition| lines << "- #{disposition.capitalize}: #{validation.counts.fetch(disposition)}" }
      lines << ""
      lines << "## Ambiguity-first review"
      lines << ""
      attention = candidates.each_with_index.filter_map do |candidate, index|
        reasons = attention_reasons(candidate)
        [attention_priority(candidate), index, candidate, reasons] unless reasons.empty?
      end.sort_by { |priority, index, _candidate, _reasons| [priority, index] }
      if attention.empty?
        lines << "No explicit unresolved or consequential review signals are recorded. Review the complete set below before approval."
        lines << ""
      else
        attention.each do |_priority, _index, candidate, reasons|
          lines << "### `#{candidate.fetch('candidate_key')}` — #{candidate.fetch('provisional_title')}"
          lines << ""
          lines << "- Disposition: `#{candidate.fetch('disposition')}`"
          lines << "- Foregrounded because: #{reasons.join('; ')}"
          lines << ""
          append_candidate_detail(lines, candidate)
        end
      end
      lines << "## Complete proposed canonical set"
      lines << ""
      accepted = candidates.select { |candidate| candidate.fetch("disposition") == "accept" }
      if accepted.empty?
        lines << "No candidate is accepted. A zero-adventure result is valid when every Phase 1 candidate remains accounted for below."
        lines << ""
      else
        accepted.each do |candidate|
          decision = candidate.fetch("decision")
          lines << "- `#{candidate.fetch('candidate_key')}` — #{decision.fetch('canonical_title')} " \
                   "(printed #{format_span(decision.fetch('printed_pages'))})"
        end
        lines << ""
      end
      lines << "## Full Phase 1 candidate inventory"
      lines << ""
      if candidates.empty?
        lines << "No candidates are recorded."
        lines << ""
      else
        candidates.each do |candidate|
          lines << "### `#{candidate.fetch('candidate_key')}` — #{candidate.fetch('provisional_title')}"
          lines << ""
          lines << "- Disposition: `#{candidate.fetch('disposition')}`"
          append_candidate_detail(lines, candidate)
        end
      end
      lines << "## Approval boundary"
      lines << ""
      lines << "This workspace is a review projection, not approval. David approves the exact complete ledger through the later provenance-bound approval/import seam. Pending or held candidates remain blockers; rendering never assigns Adventure IDs or changes the ledger."
      lines << ""
      lines.join("\n")
    end

    def attention_priority(candidate)
      {"hold" => 0, "pending" => 1, "split" => 2, "merge" => 3, "reject" => 4, "accept" => 5}.fetch(candidate.fetch("disposition"))
    end

    def attention_reasons(candidate)
      review = candidate["editorial_review"] || {}
      reasons = []
      disposition = candidate.fetch("disposition")
      reasons << "#{disposition} disposition" if %w[hold pending split merge reject].include?(disposition)
      reasons << "open questions" unless Array(candidate["open_questions"]).empty?
      reasons << "unresolved ambiguity" unless Array(review.dig("evidence", "unresolved_ambiguities")).empty?
      reasons << "parent/child or pairwise identity decision" if candidate.dig("decision", "parent_candidate_key") ||
                                                               candidate.dig("decision", "parent_adventure_id") ||
                                                               candidate["apparent_parent_context"] ||
                                                               review.key?("pairwise_identity")
      reasons << "sibling-set calibration" if review.key?("sibling_calibration")
      reasons << "precedent-sensitive decision" if review.key?("precedents")
      reasons << "competing canonical interpretations" if review.key?("competing_interpretations")
      reasons << "material page-boundary disagreement" unless Array(review.dig("boundary_evidence", "disagreements")).empty?
      reasons
    end

    def append_candidate_detail(lines, candidate)
      lines << "- Provisional printed pages: #{format_optional_span(candidate['provisional_printed_pages'])}"
      lines << "- Provisional PDF pages: #{format_optional_span(candidate['provisional_pdf_pages'])}"
      lines << "- Apparent parent context: #{candidate['apparent_parent_context'] || 'not recorded'}"
      lines << "- Playability evidence: #{candidate.fetch('playability_evidence')}"
      append_list(lines, "Open questions", candidate["open_questions"])
      lines << "- Review history:"
      candidate.fetch("review_history").each do |entry|
        lines << "  - `#{entry.fetch('phase')}` / `#{entry.fetch('status')}` — #{entry.fetch('rationale')}"
      end
      append_disposition_detail(lines, candidate)
      append_editorial_review(lines, candidate["editorial_review"]) if candidate["editorial_review"]
      lines << ""
    end

    def append_disposition_detail(lines, candidate)
      case candidate.fetch("disposition")
      when "accept"
        decision = candidate.fetch("decision")
        lines << "- Canonical result: #{decision.fetch('canonical_title')}"
        lines << "- Adjudicated printed pages: #{format_span(decision.fetch('printed_pages'))}"
        lines << "- Adjudicated PDF pages: #{format_optional_span(decision['pdf_pages'])}"
        lines << "- Parent candidate: #{decision['parent_candidate_key'] || 'none recorded'}"
        lines << "- Parent Adventure ID: #{decision['parent_adventure_id'] || 'none recorded'}"
        lines << "- Established levels: #{format_optional_span(decision['levels'])}"
        lines << "- Decision rationale: #{decision.fetch('editorial_rationale')}"
      when "merge"
        lines << "- Merge target: `#{candidate.fetch('merge_into_candidate_key')}`"
        lines << "- Decision rationale: #{candidate.fetch('decision_rationale')}"
      when "split"
        lines << "- Split review targets: #{candidate.fetch('split_into_candidate_keys').map { |key| "`#{key}`" }.join(', ')}"
        lines << "- Decision rationale: #{candidate.fetch('decision_rationale')}"
      when "reject", "hold"
        lines << "- Decision rationale: #{candidate.fetch('decision_rationale')}"
      end
    end

    def append_editorial_review(lines, review)
      evidence = review["evidence"]
      if evidence
        append_list(lines, "Source-supported facts", evidence["source_supported"])
        append_list(lines, "Editorial inferences", evidence["editorial_inferences"])
        append_list(lines, "Unresolved ambiguities", evidence["unresolved_ambiguities"])
      end
      if (proof = review["survivor_play_spine"])
        lines << "- Survivor Play-Spine Proof:"
        lines << "  - Entry: #{proof.fetch('entry')}"
        lines << "  - Authored middle: #{proof.fetch('authored_middle')}"
        lines << "  - Resolution / exit: #{proof.fetch('resolution_exit')}"
        lines << "  - Reviewer completion: #{proof.fetch('reviewer_completion')}"
      end
      if (calibration = review["sibling_calibration"])
        lines << "- Homogeneous sibling-set calibration: #{calibration.fetch('comparison')}"
        lines << "  - Compared candidates: #{calibration.fetch('candidate_keys').map { |key| "`#{key}`" }.join(', ')}"
        lines << "  - Controlling distinction: #{calibration.fetch('controlling_distinction')}"
      end
      Array(review["pairwise_identity"]).each do |entry|
        target = entry["candidate_key"] ? "candidate `#{entry['candidate_key']}`" : "Adventure `#{entry['adventure_id']}`"
        lines << "- Pairwise identity against #{target}:"
        lines << "  - Incremental Playable Identity: #{entry.fetch('incremental_playable_identity')}"
        lines << "  - Boundary Before Identity: #{entry.fetch('boundary_before_identity')}"
      end
      Array(review["precedents"]).each do |entry|
        lines << "- Precedent `#{entry.fetch('reference')}`: #{entry.fetch('relevance')}"
      end
      Array(review["competing_interpretations"]).each do |entry|
        lines << "- Competing interpretation: #{entry.fetch('interpretation')} — #{entry.fetch('implications')}"
      end
      if (boundary = review["boundary_evidence"])
        lines << "- Boundary evidence: start — #{boundary['start'] || 'not recorded'}; end — #{boundary['end'] || 'not recorded'}"
        append_list(lines, "Boundary disagreements", boundary["disagreements"])
      end
    end

    def append_list(lines, label, values)
      values = Array(values)
      return if values.empty?
      lines << "- #{label}:"
      values.each { |value| lines << "  - #{value}" }
    end

    def format_optional_span(span)
      span ? format_span(span) : "not recorded"
    end

    def format_span(span)
      "#{span.fetch('start')}–#{span.fetch('end')}"
    end

    def approve!(bundle_dir:, dossier_path:, source_root:, amc_path:, approved_by:,
                 output_path: nil, registry_path: nil, clock: -> { Time.now.utc })
      approved_by = BoundaryFreeze.nonblank_string!(approved_by, "approved_by")
      output = approval_output_path(bundle_dir, output_path)
      binding, input_hashes = approval_binding!(
        bundle_dir:,
        dossier_path:,
        source_root:,
        amc_path:,
        registry_path:
      )

      if File.exist?(output)
        existing = validate_approval!(
          approval_path: output,
          bundle_dir:,
          dossier_path:,
          source_root:,
          amc_path:,
          registry_path:
        )
        unless existing.approval.dig("approval", "approved_by") == approved_by
          raise ValidationError,
                "existing approval was issued for a different approver; refusing conflicting replay: #{output}"
        end
        return ApprovalResult.new(
          output_path: output,
          approval: existing.approval,
          sha256: existing.sha256,
          reused: true
        )
      end

      approved_at = software_timestamp!(clock.call)
      approval = {
        "schema_version" => APPROVAL_SCHEMA_VERSION,
        "approval_id" => approval_id(binding, approved_by, approved_at),
        "status" => "approved",
        "approval" => {
          "approved_by" => approved_by,
          "approved_at" => approved_at
        },
        "binding" => binding
      }
      verify_input_hashes!(input_hashes, "approval inputs changed while approval was being issued")
      publish_approval!(output, approval)

      validated = validate_approval!(
        approval_path: output,
        bundle_dir:,
        dossier_path:,
        source_root:,
        amc_path:,
        registry_path:
      )
      ApprovalResult.new(
        output_path: output,
        approval: validated.approval,
        sha256: validated.sha256,
        reused: false
      )
    end

    def validate_approval!(approval_path:, bundle_dir:, dossier_path:, source_root:, amc_path:, registry_path: nil)
      approval_file = BoundaryFreeze.existing_file!(approval_path, "boundary editorial approval")
      raw = JSON.parse(File.read(approval_file, encoding: "UTF-8"))
      validate_approval_record!(raw)
      binding, = approval_binding!(
        bundle_dir:,
        dossier_path:,
        source_root:,
        amc_path:,
        registry_path:
      )
      unless raw.fetch("binding") == binding
        raise ValidationError,
              "boundary editorial approval is stale: approval-relevant reviewed content or provenance changed"
      end
      expected_id = approval_id(
        binding,
        raw.dig("approval", "approved_by"),
        raw.dig("approval", "approved_at")
      )
      unless raw.fetch("approval_id") == expected_id
        raise ValidationError, "boundary editorial approval identity does not match its bound content"
      end
      ApprovalValidationResult.new(
        path: approval_file,
        approval: raw,
        sha256: BoundaryFreeze.sha256(approval_file),
        binding:
      )
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid JSON in boundary editorial approval #{approval_path}: #{e.message}"
    end

    def import!(bundle_dir:, dossier_path:, freeze_path:, source_root:, amc_path:,
                approval_path: nil, output_path:, registry_path: nil, approved_by: nil, approved_at: nil)
      if approved_by || approved_at
        raise ValidationError,
              "legacy loose approved_by/approved_at values cannot authorize import; provide a bound approval_path"
      end
      approval_validation = validate_approval!(
        approval_path:,
        bundle_dir:,
        dossier_path:,
        source_root:,
        amc_path:,
        registry_path:
      )
      validation = validate!(bundle_dir:, complete: true)
      dossier_file, dossier = load_dossier!(dossier_path)
      verify_context_binding!(validation.context, dossier_file, dossier)

      freeze_file = BoundaryFreeze.existing_file!(freeze_path, "draft boundary freeze")
      freeze = BoundaryFreeze.load_yaml_mapping(freeze_file, "draft boundary freeze")
      validate_clean_draft_freeze!(freeze)
      validate_dossier_freeze_alignment!(dossier, freeze)

      approval = approval_validation.approval.fetch("approval")

      accepted = validation.decisions.fetch("candidates").select { |candidate| candidate.fetch("disposition") == "accept" }
      records = accepted.map { |candidate| freeze_record(candidate) }
      artifact = deep_copy(freeze)
      artifact["state"] = "frozen"
      artifact["approval"] = {
        "approved_by" => approval.fetch("approved_by"),
        "approved_at" => approval.fetch("approved_at")
      }
      artifact["records"] = records

      output = File.expand_path(PrivateDataRoot.destination!(output_path).to_s)
      raise ValidationError, "output path is required" if output_path.nil? || output_path.to_s.strip.empty?
      raise ValidationError, "refusing to overwrite existing boundary freeze: #{output}" if File.exist?(output)
      FileUtils.mkdir_p(File.dirname(output))

      Tempfile.create([".af-boundary-editorial-import-", ".yml"], File.dirname(output)) do |temp|
        temp.write(BoundaryFreeze::HANDOFF_HEADER)
        temp.write(YAML.dump(artifact))
        temp.flush
        temp.fsync

        BoundaryFreeze.validate!(
          freeze_path: temp.path,
          source_root:,
          amc_path:,
          registry_path:
        )
        final_approval = validate_approval!(
          approval_path:,
          bundle_dir:,
          dossier_path:,
          source_root:,
          amc_path:,
          registry_path:
        )
        unless final_approval.sha256 == approval_validation.sha256
          raise ValidationError, "boundary editorial approval changed during import"
        end
        File.rename(temp.path, output)
      end

      ImportResult.new(
        output_path: output,
        record_count: records.length,
        sha256: BoundaryFreeze.sha256(output),
        counts: validation.counts
      )
    end

    # Compose the already-public approval, draft initialization, import, and
    # freeze validation seams. The approval remains the human authority; this
    # operation only proves that the frozen records are its exact deterministic
    # projection.
    def freeze_approved!(bundle_dir:, approval_path:, dossier_path:, freeze_path:, source_root:, amc_path:,
                         output_path:, registry_path: nil)
      initial_approval = validate_approval!(
        approval_path:,
        bundle_dir:,
        dossier_path:,
        source_root:,
        amc_path:,
        registry_path:
      )
      output = required_expanded_path(PrivateDataRoot.destination!(output_path), "frozen boundary output")
      draft = required_expanded_path(PrivateDataRoot.destination!(freeze_path), "draft boundary freeze")

      if File.exist?(output)
        validated = validate_approved_freeze!(
          freeze_path: output,
          approval_path:,
          bundle_dir:,
          dossier_path:,
          source_root:,
          amc_path:,
          registry_path:
        )
        unless validated.approval_sha256 == initial_approval.sha256
          raise ValidationError, "boundary editorial approval changed during approved-freeze replay"
        end
        return approved_freeze_result(validated, reused: true, draft_path: draft, draft_initialized: false)
      end

      dossier_file, dossier = load_dossier!(dossier_path)
      validation = validate!(bundle_dir:, complete: true)
      verify_context_binding!(validation.context, dossier_file, dossier)
      draft_initialized = ensure_clean_draft!(
        freeze_path: draft,
        dossier:,
        source_root:,
        source_id: validation.context.dig("source", "canonical_source_id"),
        amc_path:,
        registry_path:
      )

      imported = import!(
        bundle_dir:,
        dossier_path:,
        freeze_path: draft,
        source_root:,
        amc_path:,
        approval_path:,
        output_path: output,
        registry_path:
      )
      begin
        validated = validate_approved_freeze!(
          freeze_path: output,
          approval_path:,
          bundle_dir:,
          dossier_path:,
          source_root:,
          amc_path:,
          registry_path:
        )
        unless validated.sha256 == imported.sha256 && validated.approval_sha256 == initial_approval.sha256
          raise ValidationError, "approved boundary freeze or approval changed during publication"
        end
      rescue StandardError
        File.unlink(output) if File.file?(output) && BoundaryFreeze.sha256(output) == imported.sha256
        raise
      end

      approved_freeze_result(
        validated,
        reused: false,
        draft_path: draft,
        draft_initialized:
      )
    end

    def validate_approved_freeze!(freeze_path:, approval_path:, bundle_dir:, dossier_path:, source_root:, amc_path:,
                                  registry_path: nil)
      approval_validation = validate_approval!(
        approval_path:,
        bundle_dir:,
        dossier_path:,
        source_root:,
        amc_path:,
        registry_path:
      )
      validation = validate!(bundle_dir:, complete: true)
      dossier_file, dossier = load_dossier!(dossier_path)
      verify_context_binding!(validation.context, dossier_file, dossier)
      freeze_validation = BoundaryFreeze.validate!(
        freeze_path:,
        source_root:,
        amc_path:,
        registry_path:
      )
      expected = expected_frozen_artifact(validation, approval_validation.approval)
      unless freeze_validation.artifact == expected
        raise ValidationError,
              "frozen boundary artifact does not exactly represent the approved editorial result"
      end

      final_approval = validate_approval!(
        approval_path:,
        bundle_dir:,
        dossier_path:,
        source_root:,
        amc_path:,
        registry_path:
      )
      unless final_approval.sha256 == approval_validation.sha256
        raise ValidationError, "boundary editorial approval changed during frozen-boundary validation"
      end
      unless BoundaryFreeze.sha256(freeze_validation.path) == freeze_validation.sha256
        raise ValidationError, "frozen boundary artifact changed during validation"
      end

      ApprovedFreezeValidationResult.new(
        path: freeze_validation.path,
        artifact: freeze_validation.artifact,
        record_count: freeze_validation.record_count,
        sha256: freeze_validation.sha256,
        counts: validation.counts,
        approval_id: approval_validation.approval.fetch("approval_id"),
        approval_sha256: approval_validation.sha256
      )
    end

    def rebind!(bundle_dir:, dossier_path:, output_dir:, reason:, allow_source_id_change: false)
      validation = validate!(bundle_dir:)
      reason = BoundaryFreeze.nonblank_string!(reason, "reason")
      dossier_file, dossier = load_dossier!(dossier_path)
      old_source = validation.context.fetch("source")
      new_source = dossier.fetch("source")

      unless source_content_fingerprint(old_source) == source_content_fingerprint(new_source)
        raise ValidationError,
              "cannot rebind editorial decisions because registered source content/ranges changed"
      end

      old_source_id = old_source.fetch("canonical_source_id")
      new_source_id = new_source.fetch("canonical_source_id")
      if old_source_id != new_source_id && !allow_source_id_change
        raise ValidationError,
              "canonical source identity changed from #{old_source_id.inspect} to #{new_source_id.inspect}; " \
              "rerun with --allow-source-id-change after reviewing that correction"
      end

      new_context = context_for(dossier_file, dossier)
      if validation.context["public_specifications"]
        new_context["public_specifications"] = deep_copy(validation.context.fetch("public_specifications"))
      end
      new_context["rebind_history"] = validation.context.fetch("rebind_history") + [
        {
          "reason" => reason,
          "from" => binding_summary(validation.context),
          "to" => binding_summary(new_context)
        }
      ]

      publish_bundle!(
        output_dir,
        new_context,
        validation.decisions,
        decisions_source_path: File.join(validation.bundle_dir, DECISIONS_FILENAME)
      )
    end

    def context_for(dossier_file, dossier)
      {
        "schema_version" => CONTEXT_SCHEMA_VERSION,
        "dossier" => {
          "filename" => File.basename(dossier_file),
          "sha256" => BoundaryFreeze.sha256(dossier_file),
          "schema_version" => dossier.fetch("schema_version")
        },
        "source" => deep_copy(dossier.fetch("source")),
        "base_amc" => deep_copy(dossier.fetch("base_amc")),
        "rebind_history" => []
      }
    end

    def load_dossier!(path)
      dossier_file = resolve_dossier_path(path)
      raw = JSON.parse(File.read(dossier_file, encoding: "UTF-8"))
      BoundaryFreeze.mapping!(raw, "boundary dossier")
      schema = raw["schema_version"]
      unless SUPPORTED_DOSSIER_SCHEMAS.include?(schema)
        raise ValidationError,
              "Unsupported boundary dossier schema #{schema.inspect}; expected one of #{SUPPORTED_DOSSIER_SCHEMAS.join(', ')}"
      end
      %w[source base_amc].each do |key|
        raise ValidationError, "boundary dossier is missing #{key}" unless raw.key?(key)
      end
      validate_source_snapshot!(raw.fetch("source"), "boundary dossier source")
      validate_base_amc_snapshot!(raw.fetch("base_amc"), "boundary dossier base_amc")
      [dossier_file, raw]
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid JSON in boundary dossier #{path}: #{e.message}"
    end

    def resolve_dossier_path(path)
      raise ValidationError, "boundary dossier path is required" if path.nil? || path.to_s.strip.empty?
      expanded = File.expand_path(path.to_s)
      expanded = File.join(expanded, "boundary_dossier.json") if Dir.exist?(expanded)
      BoundaryFreeze.existing_file!(expanded, "boundary dossier")
    end

    def expanded_bundle_dir!(path)
      raise ValidationError, "editorial bundle directory is required" if path.nil? || path.to_s.strip.empty?
      expanded = File.expand_path(path.to_s)
      raise ValidationError, "editorial bundle directory does not exist: #{expanded}" unless Dir.exist?(expanded)
      expanded
    end

    def load_context!(path)
      raw = JSON.parse(File.read(BoundaryFreeze.existing_file!(path, "editorial context"), encoding: "UTF-8"))
      BoundaryFreeze.mapping!(raw, "editorial context")
      raw
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid JSON in editorial context #{path}: #{e.message}"
    end

    def load_decisions!(path)
      raw = YAML.safe_load_file(
        BoundaryFreeze.existing_file!(path, "editorial decisions"),
        permitted_classes: [Date, Time],
        aliases: false
      ) || {}
      BoundaryFreeze.mapping!(raw, "editorial decisions")
      BoundaryFreeze.exact_keys!(raw, %w[schema_version candidates], "editorial decisions")
      BoundaryFreeze.require_keys!(raw, %w[schema_version candidates], "editorial decisions")
      unless SUPPORTED_DECISIONS_SCHEMAS.include?(raw["schema_version"])
        raise ValidationError,
              "Unsupported editorial decisions schema #{raw['schema_version'].inspect}; " \
              "expected one of #{SUPPORTED_DECISIONS_SCHEMAS.join(', ')}"
      end
      unless raw["candidates"].is_a?(Array)
        raise ValidationError, "editorial decisions candidates must be a list"
      end
      raw
    rescue Psych::Exception => e
      raise ValidationError, "Invalid YAML in editorial decisions #{path}: #{e.message}"
    end

    def validate_context!(context)
      BoundaryFreeze.exact_keys!(
        context,
        %w[schema_version dossier source base_amc rebind_history public_specifications],
        "editorial context"
      )
      BoundaryFreeze.require_keys!(
        context,
        %w[schema_version dossier source base_amc rebind_history],
        "editorial context"
      )
      unless context["schema_version"] == CONTEXT_SCHEMA_VERSION
        raise ValidationError,
              "Unsupported editorial context schema #{context['schema_version'].inspect}; expected #{CONTEXT_SCHEMA_VERSION.inspect}"
      end

      dossier = context.fetch("dossier")
      BoundaryFreeze.mapping!(dossier, "editorial context dossier")
      BoundaryFreeze.exact_keys!(dossier, %w[filename sha256 schema_version], "editorial context dossier")
      BoundaryFreeze.require_keys!(dossier, %w[filename sha256 schema_version], "editorial context dossier")
      BoundaryFreeze.nonblank_string!(dossier["filename"], "editorial context dossier.filename")
      sha256_string!(dossier["sha256"], "editorial context dossier.sha256")
      unless SUPPORTED_DOSSIER_SCHEMAS.include?(dossier["schema_version"])
        raise ValidationError, "editorial context has unsupported dossier schema #{dossier['schema_version'].inspect}"
      end

      validate_source_snapshot!(context.fetch("source"), "editorial context source")
      validate_base_amc_snapshot!(context.fetch("base_amc"), "editorial context base_amc")
      history = context.fetch("rebind_history")
      raise ValidationError, "editorial context rebind_history must be a list" unless history.is_a?(Array)
      history.each_with_index { |entry, index| validate_rebind_history_entry!(entry, index) }
      EditorialSpecifications.validate!(context.fetch("public_specifications")) if context.key?("public_specifications")
      context
    end

    def validate_source_snapshot!(source, label)
      BoundaryFreeze.mapping!(source, label)
      required = %w[canonical_source_id registry_filename registry_sha256 markdown_files]
      allowed = required + %w[segments]
      BoundaryFreeze.exact_keys!(source, allowed, label)
      BoundaryFreeze.require_keys!(source, required, label)
      BoundaryFreeze.nonblank_string!(source["canonical_source_id"], "#{label}.canonical_source_id")
      BoundaryFreeze.nonblank_string!(source["registry_filename"], "#{label}.registry_filename")
      sha256_string!(source["registry_sha256"], "#{label}.registry_sha256")
      markdown_files = source["markdown_files"]
      unless markdown_files.is_a?(Array) && !markdown_files.empty?
        raise ValidationError, "#{label}.markdown_files must be a non-empty list"
      end
      markdown_files.each_with_index do |item, index|
        item_label = "#{label}.markdown_files[#{index}]"
        BoundaryFreeze.mapping!(item, item_label)
        BoundaryFreeze.exact_keys!(item, %w[filename sha256], item_label)
        BoundaryFreeze.require_keys!(item, %w[filename sha256], item_label)
        BoundaryFreeze.nonblank_string!(item["filename"], "#{item_label}.filename")
        sha256_string!(item["sha256"], "#{item_label}.sha256")
      end
      if source.key?("segments")
        segments = source["segments"]
        raise ValidationError, "#{label}.segments must be a non-empty list" unless segments.is_a?(Array) && !segments.empty?
        segments.each_with_index do |segment, index|
          segment_label = "#{label}.segments[#{index}]"
          BoundaryFreeze.mapping!(segment, segment_label)
          BoundaryFreeze.exact_keys!(segment, %w[start_page end_page file], segment_label)
          BoundaryFreeze.require_keys!(segment, %w[start_page end_page file], segment_label)
          page_span!({"start" => segment["start_page"], "end" => segment["end_page"]}, segment_label)
          BoundaryFreeze.nonblank_string!(segment["file"], "#{segment_label}.file")
        end
      end
      source
    end

    def validate_base_amc_snapshot!(base_amc, label)
      BoundaryFreeze.mapping!(base_amc, label)
      BoundaryFreeze.exact_keys!(base_amc, %w[filename sha256], label)
      BoundaryFreeze.require_keys!(base_amc, %w[filename sha256], label)
      BoundaryFreeze.nonblank_string!(base_amc["filename"], "#{label}.filename")
      sha256_string!(base_amc["sha256"], "#{label}.sha256")
      base_amc
    end

    def validate_candidates!(candidates, complete:, schema_version: DECISIONS_SCHEMA_VERSION)
      unless candidates.is_a?(Array)
        raise ValidationError, "editorial decisions candidates must be a list"
      end

      by_key = {}
      candidates.each_with_index do |candidate, index|
        label = "candidates[#{index}]"
        BoundaryFreeze.mapping!(candidate, label)
        allowed = %w[
          candidate_key provisional_title provisional_printed_pages provisional_pdf_pages
          apparent_parent_context playability_evidence open_questions review_history
          disposition decision merge_into_candidate_key split_into_candidate_keys decision_rationale
        ]
        allowed << "editorial_review" if schema_version == DECISIONS_SCHEMA_VERSION
        required = %w[
          candidate_key provisional_title playability_evidence review_history disposition
        ]
        BoundaryFreeze.exact_keys!(candidate, allowed, label)
        BoundaryFreeze.require_keys!(candidate, required, label)

        key = candidate_key!(candidate["candidate_key"], "#{label}.candidate_key")
        raise ValidationError, "duplicate candidate_key #{key.inspect}" if by_key.key?(key)
        by_key[key] = candidate

        BoundaryFreeze.nonblank_string!(candidate["provisional_title"], "#{label}.provisional_title")
        BoundaryFreeze.nonblank_string!(candidate["playability_evidence"], "#{label}.playability_evidence")
        optional_page_span!(candidate["provisional_printed_pages"], "#{label}.provisional_printed_pages")
        optional_page_span!(candidate["provisional_pdf_pages"], "#{label}.provisional_pdf_pages")
        optional_nonblank_string!(candidate["apparent_parent_context"], "#{label}.apparent_parent_context")
        validate_open_questions!(candidate["open_questions"], "#{label}.open_questions")
        validate_review_history!(candidate["review_history"], "#{label}.review_history")
        validate_editorial_review!(candidate["editorial_review"], "#{label}.editorial_review") if candidate.key?("editorial_review")

        disposition = candidate["disposition"]
        allowed_dispositions = schema_version == LEGACY_DECISIONS_SCHEMA_VERSION ? LEGACY_DISPOSITIONS : DISPOSITIONS
        unless allowed_dispositions.include?(disposition)
          raise ValidationError, "#{label}.disposition must be one of #{allowed_dispositions.join(', ')}"
        end
        validate_candidate_disposition!(candidate, label)
      end

      validate_candidate_references!(by_key)

      counts = DISPOSITIONS.to_h { |disposition| [disposition, candidates.count { |candidate| candidate["disposition"] == disposition }] }
      if complete && (counts.fetch("pending").positive? || counts.fetch("hold").positive?)
        raise ValidationError,
              "editorial decisions are incomplete: pending=#{counts.fetch('pending')} hold=#{counts.fetch('hold')}"
      end
      counts
    end

    def validate_candidate_disposition!(candidate, label)
      disposition = candidate.fetch("disposition")
      case disposition
      when "accept"
        raise ValidationError, "#{label}.decision is required for accept" unless candidate.key?("decision")
        validate_accept_decision!(candidate.fetch("decision"), "#{label}.decision")
        forbid_fields!(candidate, %w[merge_into_candidate_key split_into_candidate_keys decision_rationale], label)
      when "reject"
        BoundaryFreeze.nonblank_string!(candidate["decision_rationale"], "#{label}.decision_rationale")
        forbid_fields!(candidate, %w[decision merge_into_candidate_key split_into_candidate_keys], label)
      when "merge"
        candidate_key!(candidate["merge_into_candidate_key"], "#{label}.merge_into_candidate_key")
        BoundaryFreeze.nonblank_string!(candidate["decision_rationale"], "#{label}.decision_rationale")
        forbid_fields!(candidate, %w[decision split_into_candidate_keys], label)
      when "split"
        targets = candidate["split_into_candidate_keys"]
        unless targets.is_a?(Array) && targets.length >= 2
          raise ValidationError, "#{label}.split_into_candidate_keys must contain at least two candidate keys"
        end
        targets.each_with_index do |target, index|
          candidate_key!(target, "#{label}.split_into_candidate_keys[#{index}]")
        end
        if targets.uniq.length != targets.length
          raise ValidationError, "#{label}.split_into_candidate_keys must not contain duplicates"
        end
        BoundaryFreeze.nonblank_string!(candidate["decision_rationale"], "#{label}.decision_rationale")
        forbid_fields!(candidate, %w[decision merge_into_candidate_key], label)
      when "hold"
        BoundaryFreeze.nonblank_string!(candidate["decision_rationale"], "#{label}.decision_rationale")
        forbid_fields!(candidate, %w[decision merge_into_candidate_key split_into_candidate_keys], label)
      when "pending"
        forbid_fields!(candidate, %w[decision merge_into_candidate_key split_into_candidate_keys], label)
      end
    end

    def validate_accept_decision!(decision, label)
      BoundaryFreeze.mapping!(decision, label)
      allowed = %w[
        canonical_title printed_pages pdf_pages parent_candidate_key parent_adventure_id
        levels editorial_rationale
      ]
      required = %w[canonical_title printed_pages editorial_rationale]
      BoundaryFreeze.exact_keys!(decision, allowed, label)
      BoundaryFreeze.require_keys!(decision, required, label)
      BoundaryFreeze.nonblank_string!(decision["canonical_title"], "#{label}.canonical_title")
      page_span!(decision["printed_pages"], "#{label}.printed_pages")
      optional_page_span!(decision["pdf_pages"], "#{label}.pdf_pages")
      optional_levels!(decision["levels"], "#{label}.levels")
      BoundaryFreeze.nonblank_string!(decision["editorial_rationale"], "#{label}.editorial_rationale")

      parent_candidate = optional_candidate_key!(decision["parent_candidate_key"], "#{label}.parent_candidate_key")
      parent_adventure = optional_nonblank_string!(decision["parent_adventure_id"], "#{label}.parent_adventure_id")
      if parent_candidate && parent_adventure
        raise ValidationError, "#{label} cannot set both parent_candidate_key and parent_adventure_id"
      end
      if parent_adventure && !ADV_ID_RE.match?(parent_adventure)
        raise ValidationError, "#{label}.parent_adventure_id must match ADV-####"
      end
      decision
    end

    def validate_candidate_references!(by_key)
      by_key.each do |key, candidate|
        case candidate.fetch("disposition")
        when "merge"
          target_key = candidate.fetch("merge_into_candidate_key")
          target = by_key[target_key]
          raise ValidationError, "#{key.inspect} merges into unknown candidate #{target_key.inspect}" unless target
          unless target.fetch("disposition") == "accept"
            raise ValidationError, "#{key.inspect} merge target #{target_key.inspect} must be accepted"
          end
          raise ValidationError, "#{key.inspect} cannot merge into itself" if key == target_key
        when "split"
          candidate.fetch("split_into_candidate_keys").each do |target_key|
            target = by_key[target_key]
            raise ValidationError, "#{key.inspect} splits into unknown candidate #{target_key.inspect}" unless target
            raise ValidationError, "#{key.inspect} cannot split into itself" if key == target_key
            if target.fetch("disposition") == "split"
              raise ValidationError, "#{key.inspect} split target #{target_key.inspect} cannot itself be split"
            end
          end
        when "accept"
          decision = candidate.fetch("decision")
          parent_key = decision["parent_candidate_key"]
          if parent_key
            parent = by_key[parent_key]
            raise ValidationError, "#{key.inspect} references unknown parent candidate #{parent_key.inspect}" unless parent
            unless parent.fetch("disposition") == "accept"
              raise ValidationError, "#{key.inspect} parent candidate #{parent_key.inspect} must be accepted"
            end
            raise ValidationError, "#{key.inspect} cannot parent itself" if key == parent_key
          end
        end

        review = candidate["editorial_review"] || {}
        sibling_keys = review.dig("sibling_calibration", "candidate_keys") || []
        pairwise_keys = (review["pairwise_identity"] || []).filter_map { |entry| entry["candidate_key"] }
        (sibling_keys + pairwise_keys).each do |reference|
          unless by_key.key?(reference)
            raise ValidationError, "#{key.inspect} editorial review references unknown candidate #{reference.inspect}"
          end
          if reference == key
            raise ValidationError, "#{key.inspect} editorial review cannot reference itself as a comparison candidate"
          end
        end
      end

      states = {}
      visit = lambda do |key|
        case states[key]
        when :visiting
          raise ValidationError, "accepted parent_candidate_key cycle detected involving #{key.inspect}"
        when :done
          return
        end
        states[key] = :visiting
        candidate = by_key.fetch(key)
        if candidate.fetch("disposition") == "accept"
          parent = candidate.fetch("decision")["parent_candidate_key"]
          visit.call(parent) if parent
        end
        states[key] = :done
      end
      by_key.each_key { |key| visit.call(key) }
    end

    def validate_open_questions!(value, label)
      return if value.nil?
      raise ValidationError, "#{label} must be a list" unless value.is_a?(Array)
      value.each_with_index do |question, index|
        BoundaryFreeze.nonblank_string!(question, "#{label}[#{index}]")
      end
    end

    def validate_review_history!(history, label)
      unless history.is_a?(Array) && !history.empty?
        raise ValidationError, "#{label} must be a non-empty list"
      end
      history.each_with_index do |entry, index|
        item_label = "#{label}[#{index}]"
        BoundaryFreeze.mapping!(entry, item_label)
        BoundaryFreeze.exact_keys!(entry, %w[phase status rationale], item_label)
        BoundaryFreeze.require_keys!(entry, %w[phase status rationale], item_label)
        BoundaryFreeze.nonblank_string!(entry["phase"], "#{item_label}.phase")
        BoundaryFreeze.nonblank_string!(entry["status"], "#{item_label}.status")
        BoundaryFreeze.nonblank_string!(entry["rationale"], "#{item_label}.rationale")
      end
    end

    def validate_editorial_review!(review, label)
      BoundaryFreeze.mapping!(review, label)
      allowed = %w[
        evidence survivor_play_spine sibling_calibration pairwise_identity precedents
        competing_interpretations boundary_evidence
      ]
      BoundaryFreeze.exact_keys!(review, allowed, label)

      if review.key?("evidence")
        evidence = review.fetch("evidence")
        evidence_label = "#{label}.evidence"
        BoundaryFreeze.mapping!(evidence, evidence_label)
        keys = %w[source_supported editorial_inferences unresolved_ambiguities]
        BoundaryFreeze.exact_keys!(evidence, keys, evidence_label)
        evidence.each { |key, value| validate_nonblank_list!(value, "#{evidence_label}.#{key}") }
      end

      if review.key?("survivor_play_spine")
        proof = review.fetch("survivor_play_spine")
        proof_label = "#{label}.survivor_play_spine"
        BoundaryFreeze.mapping!(proof, proof_label)
        keys = %w[entry authored_middle resolution_exit reviewer_completion]
        BoundaryFreeze.exact_keys!(proof, keys, proof_label)
        BoundaryFreeze.require_keys!(proof, keys, proof_label)
        proof.each { |key, value| BoundaryFreeze.nonblank_string!(value, "#{proof_label}.#{key}") }
      end

      if review.key?("sibling_calibration")
        calibration = review.fetch("sibling_calibration")
        calibration_label = "#{label}.sibling_calibration"
        BoundaryFreeze.mapping!(calibration, calibration_label)
        keys = %w[candidate_keys comparison controlling_distinction]
        BoundaryFreeze.exact_keys!(calibration, keys, calibration_label)
        BoundaryFreeze.require_keys!(calibration, keys, calibration_label)
        validate_candidate_key_list!(calibration.fetch("candidate_keys"), "#{calibration_label}.candidate_keys")
        BoundaryFreeze.nonblank_string!(calibration["comparison"], "#{calibration_label}.comparison")
        BoundaryFreeze.nonblank_string!(calibration["controlling_distinction"], "#{calibration_label}.controlling_distinction")
      end

      if review.key?("pairwise_identity")
        entries = review.fetch("pairwise_identity")
        unless entries.is_a?(Array) && !entries.empty?
          raise ValidationError, "#{label}.pairwise_identity must be a non-empty list"
        end
        entries.each_with_index do |entry, index|
          entry_label = "#{label}.pairwise_identity[#{index}]"
          BoundaryFreeze.mapping!(entry, entry_label)
          keys = %w[candidate_key adventure_id incremental_playable_identity boundary_before_identity]
          BoundaryFreeze.exact_keys!(entry, keys, entry_label)
          BoundaryFreeze.require_keys!(entry, %w[incremental_playable_identity boundary_before_identity], entry_label)
          candidate_key = optional_candidate_key!(entry["candidate_key"], "#{entry_label}.candidate_key")
          adventure_id = optional_nonblank_string!(entry["adventure_id"], "#{entry_label}.adventure_id")
          unless [candidate_key, adventure_id].compact.length == 1
            raise ValidationError, "#{entry_label} must identify exactly one candidate_key or adventure_id"
          end
          if adventure_id && !ADV_ID_RE.match?(adventure_id)
            raise ValidationError, "#{entry_label}.adventure_id must match ADV-####"
          end
          BoundaryFreeze.nonblank_string!(entry["incremental_playable_identity"], "#{entry_label}.incremental_playable_identity")
          BoundaryFreeze.nonblank_string!(entry["boundary_before_identity"], "#{entry_label}.boundary_before_identity")
        end
      end

      %w[precedents competing_interpretations].each do |field|
        next unless review.key?(field)
        entries = review.fetch(field)
        unless entries.is_a?(Array) && !entries.empty?
          raise ValidationError, "#{label}.#{field} must be a non-empty list"
        end
        keys = field == "precedents" ? %w[reference relevance] : %w[interpretation implications]
        entries.each_with_index do |entry, index|
          entry_label = "#{label}.#{field}[#{index}]"
          BoundaryFreeze.mapping!(entry, entry_label)
          BoundaryFreeze.exact_keys!(entry, keys, entry_label)
          BoundaryFreeze.require_keys!(entry, keys, entry_label)
          keys.each { |key| BoundaryFreeze.nonblank_string!(entry[key], "#{entry_label}.#{key}") }
        end
      end

      if review.key?("boundary_evidence")
        evidence = review.fetch("boundary_evidence")
        evidence_label = "#{label}.boundary_evidence"
        BoundaryFreeze.mapping!(evidence, evidence_label)
        keys = %w[start end disagreements]
        BoundaryFreeze.exact_keys!(evidence, keys, evidence_label)
        evidence.each do |key, value|
          if key == "disagreements"
            validate_nonblank_list!(value, "#{evidence_label}.#{key}")
          else
            BoundaryFreeze.nonblank_string!(value, "#{evidence_label}.#{key}")
          end
        end
      end
      review
    end

    def validate_nonblank_list!(value, label)
      raise ValidationError, "#{label} must be a list" unless value.is_a?(Array)
      value.each_with_index { |item, index| BoundaryFreeze.nonblank_string!(item, "#{label}[#{index}]") }
      value
    end

    def validate_candidate_key_list!(value, label)
      unless value.is_a?(Array) && !value.empty?
        raise ValidationError, "#{label} must be a non-empty list"
      end
      value.each_with_index { |item, index| candidate_key!(item, "#{label}[#{index}]") }
      value
    end

    def validate_clean_draft_freeze!(freeze)
      BoundaryFreeze.mapping!(freeze, "draft boundary freeze")
      BoundaryFreeze.exact_keys!(freeze, %w[schema_version state source base_amc approval records], "draft boundary freeze")
      BoundaryFreeze.require_keys!(freeze, %w[schema_version state source base_amc approval records], "draft boundary freeze")
      unless freeze["schema_version"] == BoundaryFreeze::SCHEMA_VERSION
        raise ValidationError,
              "Unsupported boundary freeze schema #{freeze['schema_version'].inspect}; expected #{BoundaryFreeze::SCHEMA_VERSION.inspect}"
      end
      raise ValidationError, 'draft boundary freeze state must be "draft"' unless freeze["state"] == "draft"
      unless freeze["records"].is_a?(Array) && freeze["records"].empty?
        raise ValidationError, "draft boundary freeze records must be empty before decision import"
      end
      approval = freeze["approval"]
      BoundaryFreeze.mapping!(approval, "draft boundary freeze approval")
      BoundaryFreeze.exact_keys!(approval, %w[approved_by approved_at], "draft boundary freeze approval")
      unless blank_value?(approval["approved_by"]) && blank_value?(approval["approved_at"])
        raise ValidationError, "draft boundary freeze approval must be blank before decision import"
      end
      freeze
    end

    def validate_dossier_freeze_alignment!(dossier, freeze)
      dossier_source = dossier.fetch("source")
      freeze_source = freeze.fetch("source")
      source_keys = %w[canonical_source_id registry_filename registry_sha256 markdown_files]
      unless source_keys.to_h { |key| [key, dossier_source[key]] } == source_keys.to_h { |key| [key, freeze_source[key]] }
        raise ValidationError, "boundary dossier and draft boundary freeze source provenance do not match"
      end
      unless dossier.fetch("base_amc") == freeze.fetch("base_amc")
        raise ValidationError, "boundary dossier and draft boundary freeze base AMC provenance do not match"
      end
    end

    def verify_context_binding!(context, dossier_file, dossier)
      expected = context.fetch("dossier")
      unless expected.fetch("filename") == File.basename(dossier_file)
        raise ValidationError,
              "boundary dossier filename changed since editorial handoff initialization/rebind"
      end
      actual_sha = BoundaryFreeze.sha256(dossier_file)
      unless expected.fetch("sha256") == actual_sha
        raise ValidationError,
              "boundary dossier changed since editorial handoff initialization/rebind: expected #{expected.fetch('sha256')}, got #{actual_sha}"
      end
      unless expected.fetch("schema_version") == dossier.fetch("schema_version")
        raise ValidationError, "boundary dossier schema changed since editorial handoff initialization/rebind"
      end
      unless context.fetch("source") == dossier.fetch("source")
        raise ValidationError, "boundary dossier source provenance changed; rebind the editorial handoff"
      end
      unless context.fetch("base_amc") == dossier.fetch("base_amc")
        raise ValidationError, "boundary dossier base AMC changed; rebind the editorial handoff"
      end
    end

    def approval_binding!(bundle_dir:, dossier_path:, source_root:, amc_path:, registry_path: nil)
      validation = validate!(bundle_dir:, complete: true)
      if validation.decisions.fetch("candidates").empty?
        raise ValidationError,
              "cannot approve an unreviewed empty editorial ledger; record at least one explicit reviewed disposition"
      end
      validate_approval_readiness!(validation.decisions.fetch("candidates"))

      dossier_file, dossier = load_dossier!(dossier_path)
      verify_context_binding!(validation.context, dossier_file, dossier)
      root = BoundaryFreeze.expanded_source_root(source_root)
      amc = BoundaryFreeze.existing_file!(amc_path, "base AMC")
      registry = BoundaryFreeze.registry_context(root, registry_path)
      source = validation.context.fetch("source")
      source_for_validation = source.slice(
        "canonical_source_id", "registry_filename", "registry_sha256", "markdown_files"
      )
      normalized_source = BoundaryFreeze.validate_source!(source_for_validation, registry, root)
      actual_segments = normalized_source.fetch(:segments)&.map do |segment|
        {
          "start_page" => segment.fetch(:start_page),
          "end_page" => segment.fetch(:end_page),
          "file" => segment.fetch(:file)
        }
      end
      unless source["segments"] == actual_segments
        raise ValidationError,
              "editorial source segment provenance no longer matches the registered source"
      end
      BoundaryFreeze.validate_base_amc!(validation.context.fetch("base_amc"), amc)

      context_path = File.join(validation.bundle_dir, CONTEXT_FILENAME)
      decisions_path = File.join(validation.bundle_dir, DECISIONS_FILENAME)
      review_path = File.join(validation.bundle_dir, REVIEW_FILENAME)
      BoundaryFreeze.existing_file!(review_path, "editorial review instructions")
      rendered_review = render_workspace(bundle_dir: validation.bundle_dir)
      counts = validation.counts
      binding = {
        "editorial_context" => file_binding(
          context_path,
          schema_version: validation.context.fetch("schema_version")
        ),
        "editorial_decisions" => file_binding(
          decisions_path,
          schema_version: validation.decisions.fetch("schema_version")
        ),
        "editorial_instructions" => file_binding(review_path),
        "rendered_review" => {
          "derivation" => RENDER_DERIVATION,
          "sha256" => Digest::SHA256.hexdigest(rendered_review)
        },
        "review_summary" => {
          "candidate_count" => validation.decisions.fetch("candidates").length,
          "dispositions" => DISPOSITIONS.to_h { |disposition| [disposition, counts.fetch(disposition)] }
        },
        "dossier" => deep_copy(validation.context.fetch("dossier")),
        "source" => deep_copy(source),
        "base_amc" => deep_copy(validation.context.fetch("base_amc"))
      }
      input_paths = [
        context_path,
        decisions_path,
        review_path,
        dossier_file,
        registry.fetch("path"),
        amc,
        *source.fetch("markdown_files").map do |item|
          BoundaryFreeze.source_file!(root, item.fetch("filename"))
        end
      ]
      if (specifications = validation.context["public_specifications"])
        input_paths << File.join(specifications.fetch("root"), "documents.json")
        input_paths.concat(specifications.fetch("files").map { |document| document.fetch("path") })
      end
      [binding, input_paths.uniq.to_h { |path| [path, BoundaryFreeze.sha256(path)] }]
    end

    def validate_approval_readiness!(candidates)
      unresolved = candidates.filter_map do |candidate|
        reasons = []
        reasons << "open_questions" unless Array(candidate["open_questions"]).empty?
        ambiguities = candidate.dig("editorial_review", "evidence", "unresolved_ambiguities")
        reasons << "editorial_review.evidence.unresolved_ambiguities" unless Array(ambiguities).empty?
        "#{candidate.fetch('candidate_key')}: #{reasons.join(', ')}" unless reasons.empty?
      end
      return if unresolved.empty?

      raise ValidationError,
            "cannot approve materially unresolved editorial review: #{unresolved.join('; ')}"
    end

    def validate_approval_record!(approval)
      BoundaryFreeze.mapping!(approval, "boundary editorial approval")
      BoundaryFreeze.exact_keys!(
        approval,
        %w[schema_version approval_id status approval binding],
        "boundary editorial approval"
      )
      BoundaryFreeze.require_keys!(
        approval,
        %w[schema_version approval_id status approval binding],
        "boundary editorial approval"
      )
      unless approval["schema_version"] == APPROVAL_SCHEMA_VERSION
        raise ValidationError,
              "Unsupported boundary editorial approval schema #{approval['schema_version'].inspect}; " \
              "expected #{APPROVAL_SCHEMA_VERSION.inspect}"
      end
      unless approval["status"] == "approved"
        raise ValidationError, 'boundary editorial approval status must be "approved"'
      end
      unless /\Asha256:[0-9a-f]{64}\z/.match?(approval["approval_id"].to_s)
        raise ValidationError, "boundary editorial approval_id must be a sha256 identity"
      end

      human = approval.fetch("approval")
      BoundaryFreeze.mapping!(human, "boundary editorial approval approval")
      BoundaryFreeze.exact_keys!(human, %w[approved_by approved_at], "boundary editorial approval approval")
      BoundaryFreeze.require_keys!(human, %w[approved_by approved_at], "boundary editorial approval approval")
      BoundaryFreeze.nonblank_string!(human["approved_by"], "boundary editorial approval approved_by")
      timestamp = BoundaryFreeze.nonblank_string!(human["approved_at"], "boundary editorial approval approved_at")
      begin
        Time.iso8601(timestamp)
      rescue ArgumentError
        raise ValidationError, "boundary editorial approval approved_at must be an ISO-8601 timestamp"
      end

      binding = approval.fetch("binding")
      BoundaryFreeze.mapping!(binding, "boundary editorial approval binding")
      BoundaryFreeze.exact_keys!(
        binding,
        %w[editorial_context editorial_decisions editorial_instructions rendered_review review_summary dossier source base_amc],
        "boundary editorial approval binding"
      )
      BoundaryFreeze.require_keys!(
        binding,
        %w[editorial_context editorial_decisions editorial_instructions rendered_review review_summary dossier source base_amc],
        "boundary editorial approval binding"
      )
      validate_file_binding!(binding.fetch("editorial_context"), "approval editorial_context", schema: true)
      validate_file_binding!(binding.fetch("editorial_decisions"), "approval editorial_decisions", schema: true)
      validate_file_binding!(binding.fetch("editorial_instructions"), "approval editorial_instructions", schema: false)
      rendered = binding.fetch("rendered_review")
      BoundaryFreeze.mapping!(rendered, "approval rendered_review")
      BoundaryFreeze.exact_keys!(rendered, %w[derivation sha256], "approval rendered_review")
      BoundaryFreeze.require_keys!(rendered, %w[derivation sha256], "approval rendered_review")
      unless rendered["derivation"] == RENDER_DERIVATION
        raise ValidationError, "approval rendered_review has an unsupported derivation"
      end
      sha256_string!(rendered["sha256"], "approval rendered_review.sha256")
      validate_review_summary!(binding.fetch("review_summary"))
      validate_dossier_binding!(binding.fetch("dossier"))
      validate_source_snapshot!(binding.fetch("source"), "approval source")
      validate_base_amc_snapshot!(binding.fetch("base_amc"), "approval base_amc")
      approval
    end

    def validate_file_binding!(binding, label, schema:)
      BoundaryFreeze.mapping!(binding, label)
      keys = %w[filename sha256]
      keys << "schema_version" if schema
      BoundaryFreeze.exact_keys!(binding, keys, label)
      BoundaryFreeze.require_keys!(binding, keys, label)
      BoundaryFreeze.nonblank_string!(binding["filename"], "#{label}.filename")
      sha256_string!(binding["sha256"], "#{label}.sha256")
      BoundaryFreeze.nonblank_string!(binding["schema_version"], "#{label}.schema_version") if schema
    end

    def validate_review_summary!(summary)
      BoundaryFreeze.mapping!(summary, "approval review_summary")
      BoundaryFreeze.exact_keys!(summary, %w[candidate_count dispositions], "approval review_summary")
      BoundaryFreeze.require_keys!(summary, %w[candidate_count dispositions], "approval review_summary")
      unless summary["candidate_count"].is_a?(Integer) && summary["candidate_count"].positive?
        raise ValidationError, "approval review_summary.candidate_count must be a positive integer"
      end
      dispositions = summary.fetch("dispositions")
      BoundaryFreeze.mapping!(dispositions, "approval review_summary.dispositions")
      BoundaryFreeze.exact_keys!(dispositions, DISPOSITIONS, "approval review_summary.dispositions")
      BoundaryFreeze.require_keys!(dispositions, DISPOSITIONS, "approval review_summary.dispositions")
      unless dispositions.values.all? { |value| value.is_a?(Integer) && !value.negative? }
        raise ValidationError, "approval review_summary disposition counts must be nonnegative integers"
      end
      unless dispositions.values.sum == summary.fetch("candidate_count")
        raise ValidationError, "approval review_summary disposition counts do not reconcile"
      end
    end

    def validate_dossier_binding!(dossier)
      BoundaryFreeze.mapping!(dossier, "approval dossier")
      BoundaryFreeze.exact_keys!(dossier, %w[filename sha256 schema_version], "approval dossier")
      BoundaryFreeze.require_keys!(dossier, %w[filename sha256 schema_version], "approval dossier")
      BoundaryFreeze.nonblank_string!(dossier["filename"], "approval dossier.filename")
      sha256_string!(dossier["sha256"], "approval dossier.sha256")
      unless SUPPORTED_DOSSIER_SCHEMAS.include?(dossier["schema_version"])
        raise ValidationError, "approval dossier has an unsupported schema"
      end
    end

    def file_binding(path, schema_version: nil)
      binding = {
        "filename" => File.basename(path),
        "sha256" => BoundaryFreeze.sha256(path)
      }
      binding["schema_version"] = schema_version if schema_version
      binding
    end

    def approval_id(binding, approved_by, approved_at)
      payload = canonical_json(
        "approved_by" => approved_by,
        "approved_at" => approved_at,
        "binding" => binding
      )
      "sha256:#{Digest::SHA256.hexdigest(payload)}"
    end

    def canonical_json(value)
      JSON.generate(canonical_value(value))
    end

    def canonical_value(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonical_value(value.fetch(key))] }
      when Array
        value.map { |item| canonical_value(item) }
      else
        value
      end
    end

    def software_timestamp!(value)
      unless value.respond_to?(:utc) && value.respond_to?(:iso8601)
        raise ValidationError, "approval clock must return a time value"
      end
      value.utc.iso8601(6)
    end

    def approval_output_path(bundle_dir, output_path)
      output = output_path || File.join(expanded_bundle_dir!(bundle_dir), APPROVAL_FILENAME)
      expanded = File.expand_path(PrivateDataRoot.destination!(output).to_s)
      raise ValidationError, "approval output path is required" if output.to_s.strip.empty?
      expanded
    end

    def publish_approval!(output, approval)
      FileUtils.mkdir_p(File.dirname(output))
      bytes = JSON.pretty_generate(approval) + "\n"
      Tempfile.create([".af-boundary-editorial-approval-", ".json"], File.dirname(output)) do |temp|
        temp.binmode
        temp.write(bytes)
        temp.flush
        temp.fsync
        begin
          File.link(temp.path, output)
        rescue Errno::EEXIST
          raise ValidationError, "refusing to overwrite existing boundary editorial approval: #{output}"
        end
      end
    end

    def verify_input_hashes!(input_hashes, message)
      changed = input_hashes.filter_map do |path, expected|
        actual = File.file?(path) ? BoundaryFreeze.sha256(path) : "missing"
        path unless actual == expected
      end
      return if changed.empty?

      raise ValidationError, "#{message}: #{changed.join(', ')}"
    end

    def ensure_clean_draft!(freeze_path:, dossier:, source_root:, source_id:, amc_path:, registry_path: nil)
      if File.exist?(freeze_path)
        draft = BoundaryFreeze.load_yaml_mapping(freeze_path, "draft boundary freeze")
        validate_clean_draft_freeze!(draft)
        validate_dossier_freeze_alignment!(dossier, draft)
        return false
      end

      FileUtils.mkdir_p(File.dirname(freeze_path))
      temporary_path = nil
      Tempfile.create([".af-boundary-freeze-draft-", ".yml"], File.dirname(freeze_path)) do |temporary|
        temporary_path = temporary.path
        temporary.close
        File.unlink(temporary_path)
        BoundaryFreeze.init!(
          source_root:,
          source_id:,
          amc_path:,
          output_path: temporary_path,
          registry_path:
        )
        draft = BoundaryFreeze.load_yaml_mapping(temporary_path, "draft boundary freeze")
        validate_clean_draft_freeze!(draft)
        validate_dossier_freeze_alignment!(dossier, draft)
        begin
          File.link(temporary_path, freeze_path)
          return true
        rescue Errno::EEXIST
          existing = BoundaryFreeze.load_yaml_mapping(freeze_path, "draft boundary freeze")
          validate_clean_draft_freeze!(existing)
          validate_dossier_freeze_alignment!(dossier, existing)
          return false
        ensure
          FileUtils.rm_f(temporary_path)
        end
      end
    ensure
      FileUtils.rm_f(temporary_path) if temporary_path
    end

    def expected_frozen_artifact(validation, approval_record)
      source = validation.context.fetch("source")
      accepted = validation.decisions.fetch("candidates").select do |candidate|
        candidate.fetch("disposition") == "accept"
      end
      {
        "schema_version" => BoundaryFreeze::SCHEMA_VERSION,
        "state" => "frozen",
        "source" => deep_copy(source.slice(
          "canonical_source_id", "registry_filename", "registry_sha256", "markdown_files"
        )),
        "base_amc" => deep_copy(validation.context.fetch("base_amc")),
        "approval" => deep_copy(approval_record.fetch("approval")),
        "records" => accepted.map { |candidate| freeze_record(candidate) }
      }
    end

    def approved_freeze_result(validation, reused:, draft_path:, draft_initialized:)
      ApprovedFreezeResult.new(
        output_path: validation.path,
        record_count: validation.record_count,
        sha256: validation.sha256,
        counts: validation.counts,
        approval_id: validation.approval_id,
        approval_sha256: validation.approval_sha256,
        reused:,
        draft_path:,
        draft_initialized:
      )
    end

    def required_expanded_path(value, label)
      raise ValidationError, "#{label} path is required" if value.nil? || value.to_s.strip.empty?

      File.expand_path(value.to_s)
    end

    def freeze_record(candidate)
      decision = candidate.fetch("decision")
      record = {
        "local_key" => candidate.fetch("candidate_key"),
        "canonical_title" => decision.fetch("canonical_title"),
        "printed_pages" => deep_copy(decision.fetch("printed_pages")),
        "editorial_rationale" => decision.fetch("editorial_rationale"),
        "state" => "frozen"
      }
      record["pdf_pages"] = deep_copy(decision["pdf_pages"]) if decision["pdf_pages"]
      record["levels"] = deep_copy(decision["levels"]) if decision["levels"]
      record["parent_key"] = decision["parent_candidate_key"] if decision["parent_candidate_key"]
      record["parent_adventure_id"] = decision["parent_adventure_id"] if decision["parent_adventure_id"]
      record
    end

    def publish_bundle!(output_dir, context, decisions, decisions_source_path: nil)
      output = File.expand_path(PrivateDataRoot.destination!(output_dir).to_s)
      raise ValidationError, "output directory is required" if output_dir.nil? || output_dir.to_s.strip.empty?
      paths = {
        context: File.join(output, CONTEXT_FILENAME),
        decisions: File.join(output, DECISIONS_FILENAME),
        review: File.join(output, REVIEW_FILENAME)
      }
      paths.each_value do |path|
        raise ValidationError, "refusing to overwrite existing editorial handoff artifact: #{path}" if File.exist?(path)
      end

      validate_context!(context)
      validate_candidates!(
        decisions.fetch("candidates"),
        complete: false,
        schema_version: decisions.fetch("schema_version")
      )
      FileUtils.mkdir_p(output)
      begin
        File.write(paths.fetch(:context), JSON.pretty_generate(context) + "\n", encoding: "UTF-8")
        if decisions_source_path
          FileUtils.cp(decisions_source_path, paths.fetch(:decisions), preserve: true)
        else
          File.write(paths.fetch(:decisions), decisions_yaml(decisions), encoding: "UTF-8")
        end
        File.write(paths.fetch(:review), render_review(context), encoding: "UTF-8")
      rescue StandardError
        paths.each_value { |path| FileUtils.rm_f(path) }
        raise
      end

      BundleResult.new(
        output_dir: output,
        context_path: paths.fetch(:context),
        decisions_path: paths.fetch(:decisions),
        review_path: paths.fetch(:review),
        context:,
        decisions:
      )
    end

    def decisions_yaml(decisions)
      <<~HEADER + YAML.dump(decisions)
        # AdventureFinder editable editorial decision ledger.
        # Software owns editorial_context.json. Edit candidates here only.
        # Do not assign Adventure IDs. candidate_key is stable once introduced.
      HEADER
    end

    def frontier_prompt(context)
      source_id = context.dig("source", "canonical_source_id")
      selection = if context["public_specifications"]
        EditorialSpecifications.lines(context.fetch("public_specifications")).join("\n") + "\n\n"
      else
        ""
      end
      selection + <<~PROMPT.strip
        Perform AdventureFinder boundary editorial Phase 1, Phase 1b, and Phase 2 for #{source_id.inspect} using the attached canonical source Markdown, boundary dossier, editorial review instructions, and editable editorial decision ledger.

        Inspect the complete canonical source, not a summary. Treat the boundary dossier as evidence to inspect, not as an adventure classifier. Phase 1 should retain plausible playable units at high recall. Phase 1b / Phase 2 should resolve standalone or embedded status, parent/child relationships, canonical titles, printed-page boundaries, optional PDF-page boundaries, and Level Start / Level End only where the source establishes them.

        Update editorial_decisions.yml according to editorial_review.md. Preserve every retained candidate with an explicit disposition and review history; use split to keep the original candidate traceable when Phase 1b/Phase 2 produces explicit child candidates, and use hold when evidence remains unresolved. Record source-supported facts, editorial inference, and unresolved ambiguity distinctly. Do not assign Adventure IDs. Do not invent adventure content or silently fill missing evidence. Do not modify software-owned editorial_context.json.

        Return the completed editorial_decisions.yml for David's review.
      PROMPT
    end

    def render_review(context)
      source = context.fetch("source")
      base = context.fetch("base_amc")
      history = context.fetch("rebind_history")
      lines = []
      lines << "# AdventureFinder boundary editorial handoff"
      lines << ""
      lines << "> **Human/frontier editorial surface.** `editorial_context.json` is software-owned provenance. `editorial_decisions.yml` is the editable candidate ledger. No Adventure IDs are assigned here."
      lines << ""
      lines << "- Source: `#{source.fetch('canonical_source_id')}`"
      lines << "- Boundary dossier: `#{context.dig('dossier', 'filename')}` (`#{context.dig('dossier', 'schema_version')}`)"
      lines << "- Dossier SHA-256: `#{context.dig('dossier', 'sha256')}`"
      lines << "- Base AMC: `#{base.fetch('filename')}`"
      lines << "- Base-AMC SHA-256: `#{base.fetch('sha256')}`"
      lines << "- Prior controlled rebinds: #{history.length}"
      lines << ""
      lines << "## Editorial workflow"
      lines << ""
      lines << "1. Phase 1 adds every plausible candidate to `editorial_decisions.yml` with a stable `candidate_key`, provisional source coordinates, playability evidence, and a `review_history` entry. `candidate_key` is stable once introduced."
      lines << "2. Phase 1b applies the four-part Survivor Play-Spine Proof and records sibling calibration or pairwise identity/boundary evidence where relevant; Phase 2 adjudicates canonical identity, nesting, title, and exact boundaries. These are editorial prompts, never deterministic decision rules."
      lines << "3. Update the same candidate entry. Never replace a rejected, merged, or split candidate with silence: set an explicit disposition and preserve the review history. `split` names at least two explicit candidate keys while retaining the original candidate."
      lines << "4. Final dispositions are `accept`, `reject`, `merge`, or `split`. `pending` and `hold` deliberately block decision import. A complete, traceable zero-accepted-adventure result is valid."
      lines << "5. Accepted candidates supply the exact fields required for `af-boundary-freeze/v0.1`; their `candidate_key` becomes the freeze `local_key`."
      lines << "6. David reviews the complete rendered result and approves at the provenance-bound import stage, not inside frontier-authored provenance."
      lines << ""
      lines << "## Candidate shape"
      lines << ""
      lines << "```yaml"
      lines << "- candidate_key: source-stable-key"
      lines << "  provisional_title: Source-facing title"
      lines << "  provisional_printed_pages: {start: 10, end: 12}"
      lines << "  provisional_pdf_pages: {start: 14, end: 16}"
      lines << "  apparent_parent_context: Optional source-facing parent context"
      lines << "  playability_evidence: Why this was retained for editorial review."
      lines << "  open_questions:"
      lines << "    - What still needs pressure testing?"
      lines << "  review_history:"
      lines << "    - phase: phase1"
      lines << "      status: retained"
      lines << "      rationale: High-recall reason for keeping the candidate."
      lines << "    - phase: phase2"
      lines << "      status: accepted"
      lines << "      rationale: Final identity/boundary decision."
      lines << "  editorial_review:"
      lines << "    evidence:"
      lines << "      source_supported: [A source-supported fact.]"
      lines << "      editorial_inferences: [An explicitly labeled editorial inference.]"
      lines << "      unresolved_ambiguities: []"
      lines << "    survivor_play_spine:"
      lines << "      entry: How play begins."
      lines << "      authored_middle: What sustained authored play exists."
      lines << "      resolution_exit: How play resolves or exits."
      lines << "      reviewer_completion: Why this forms a coherent playable unit."
      lines << "  disposition: accept"
      lines << "  decision:"
      lines << "    canonical_title: Canonical adventure title"
      lines << "    printed_pages: {start: 10, end: 12}"
      lines << "    pdf_pages: {start: 14, end: 16}"
      lines << "    parent_candidate_key: optional-accepted-parent"
      lines << "    levels: {start: 3, end: 4}"
      lines << "    editorial_rationale: Concise rationale imported into the frozen boundary artifact."
      lines << "```"
      lines << ""
      lines << "For `reject`, omit `decision` and provide `decision_rationale`. For `merge`, provide `merge_into_candidate_key` pointing directly to an accepted candidate plus `decision_rationale`. For `split`, provide at least two `split_into_candidate_keys` plus `decision_rationale`; retain the original candidate and its history. For `hold`, provide the unresolved reason; the bundle remains intentionally incomplete. Optional `editorial_review` fields record sibling calibration, pairwise identity/boundary diagnostics, precedents, competing interpretations, and boundary disagreements."
      lines << ""
      lines << "## Frontier ChatGPT handoff"
      lines << ""
      lines << "Open a normal ChatGPT conversation and attach the complete canonical source Markdown file(s), the bound `boundary_dossier.json`, this `editorial_review.md`, and `editorial_decisions.yml`."
      if context["public_specifications"]
        lines.concat(EditorialSpecifications.lines(context.fetch("public_specifications")))
      end
      lines << ""
      lines << "Canonical source Markdown file(s):"
      source.fetch("markdown_files").each do |item|
        lines << "- `#{item.fetch('filename')}`"
      end
      lines << ""
      lines << "Use this prompt:"
      lines << ""
      lines << "```text"
      lines.concat(frontier_prompt(context).lines(chomp: true))
      lines << "```"
      lines << ""
      lines << "Review the returned `editorial_decisions.yml` before saving it over the editable ledger. Render the complete ambiguity-first workspace with `bin/af-boundary-editorial render BUNDLE_DIR`, then rerun `bin/af-ingest-next` against this editorial bundle directory."
      lines << ""
      lines << "## Rebind rule"
      lines << ""
      lines << "If source identity/provenance or the base AMC changes, generate a fresh boundary dossier and use the controlled `rebind` operation. Rebind preserves `editorial_decisions.yml` byte-for-byte only when the registered Markdown content hashes and segmented source ranges are unchanged. A source-ID change requires the explicit `--allow-source-id-change` flag. The new provenance must be reviewed again before import."
      lines << ""
      lines.join("\n")
    end

    def source_content_fingerprint(source)
      sha_by_filename = source.fetch("markdown_files").to_h do |item|
        [item.fetch("filename"), item.fetch("sha256")]
      end
      {
        "markdown_sha256s" => source.fetch("markdown_files").map { |item| item.fetch("sha256") },
        "segments" => source["segments"]&.map do |segment|
          {
            "start_page" => segment.fetch("start_page"),
            "end_page" => segment.fetch("end_page"),
            "sha256" => sha_by_filename.fetch(segment.fetch("file"))
          }
        end
      }
    end

    def binding_summary(context)
      {
        "dossier_sha256" => context.dig("dossier", "sha256"),
        "dossier_schema_version" => context.dig("dossier", "schema_version"),
        "canonical_source_id" => context.dig("source", "canonical_source_id"),
        "registry_sha256" => context.dig("source", "registry_sha256"),
        "base_amc" => deep_copy(context.fetch("base_amc"))
      }
    end

    def validate_rebind_history_entry!(entry, index)
      label = "editorial context rebind_history[#{index}]"
      BoundaryFreeze.mapping!(entry, label)
      BoundaryFreeze.exact_keys!(entry, %w[reason from to], label)
      BoundaryFreeze.require_keys!(entry, %w[reason from to], label)
      BoundaryFreeze.nonblank_string!(entry["reason"], "#{label}.reason")
      %w[from to].each do |edge|
        item = entry.fetch(edge)
        edge_label = "#{label}.#{edge}"
        BoundaryFreeze.mapping!(item, edge_label)
        BoundaryFreeze.exact_keys!(
          item,
          %w[dossier_sha256 dossier_schema_version canonical_source_id registry_sha256 base_amc],
          edge_label
        )
        BoundaryFreeze.require_keys!(
          item,
          %w[dossier_sha256 dossier_schema_version canonical_source_id registry_sha256 base_amc],
          edge_label
        )
        sha256_string!(item["dossier_sha256"], "#{edge_label}.dossier_sha256")
        BoundaryFreeze.nonblank_string!(item["dossier_schema_version"], "#{edge_label}.dossier_schema_version")
        BoundaryFreeze.nonblank_string!(item["canonical_source_id"], "#{edge_label}.canonical_source_id")
        sha256_string!(item["registry_sha256"], "#{edge_label}.registry_sha256")
        validate_base_amc_snapshot!(item["base_amc"], "#{edge_label}.base_amc")
      end
    end

    def candidate_key!(value, label)
      value = BoundaryFreeze.nonblank_string!(value, label)
      unless CANDIDATE_KEY_RE.match?(value)
        raise ValidationError, "#{label} must match #{CANDIDATE_KEY_RE.inspect}"
      end
      value
    end

    def optional_candidate_key!(value, label)
      return nil if value.nil?
      candidate_key!(value, label)
    end

    def optional_nonblank_string!(value, label)
      return nil if value.nil?
      BoundaryFreeze.nonblank_string!(value, label)
    end

    def optional_page_span!(value, label)
      return nil if value.nil?
      page_span!(value, label)
    end

    def optional_levels!(value, label)
      return nil if value.nil?
      BoundaryFreeze.mapping!(value, label)
      BoundaryFreeze.exact_keys!(value, %w[start end], label)
      BoundaryFreeze.require_keys!(value, %w[start end], label)
      start_level = BoundaryFreeze.positive_integer!(value["start"], "#{label}.start")
      end_level = BoundaryFreeze.positive_integer!(value["end"], "#{label}.end")
      raise ValidationError, "#{label}.start exceeds end" if start_level > end_level
      value
    end

    def page_span!(value, label)
      BoundaryFreeze.mapping!(value, label)
      BoundaryFreeze.exact_keys!(value, %w[start end], label)
      BoundaryFreeze.require_keys!(value, %w[start end], label)
      start_page = BoundaryFreeze.positive_integer!(value["start"], "#{label}.start")
      end_page = BoundaryFreeze.positive_integer!(value["end"], "#{label}.end")
      raise ValidationError, "#{label}.start exceeds end" if start_page > end_page
      value
    end

    def forbid_fields!(candidate, fields, label)
      present = fields.select { |field| candidate.key?(field) }
      return if present.empty?
      raise ValidationError, "#{label} has fields incompatible with #{candidate.fetch('disposition')}: #{present.join(', ')}"
    end

    def sha256_string!(value, label)
      unless value.is_a?(String) && BoundaryFreeze::SHA256_RE.match?(value)
        raise ValidationError, "#{label} must be 64 lowercase hexadecimal characters"
      end
      value
    end

    def blank_value?(value)
      value.nil? || (value.is_a?(String) && value.strip.empty?)
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr)
        command = argv.shift
        case command
        when "init"
          init_command(argv, out:)
        when "validate"
          validate_command(argv, out:)
        when "render"
          render_command(argv, out:)
        when "approve"
          approve_command(argv, out:)
        when "validate-approval"
          validate_approval_command(argv, out:)
        when "freeze-approved"
          freeze_approved_command(argv, out:)
        when "validate-approved-freeze"
          validate_approved_freeze_command(argv, out:)
        when "import"
          import_command(argv, out:)
        when "rebind"
          rebind_command(argv, out:)
        when nil, "help", "--help", "-h"
          out.puts(help)
          0
        else
          err.puts("ERROR: unknown command #{command.inspect}\n\n#{help}")
          2
        end
      rescue OptionParser::ParseError, AfDataPipeline::Error => e
        err.puts("ERROR: #{e.message}")
        2
      end

      def self.init_command(argv, out:)
        options = { dossier: nil, source_root: nil, output: nil, spec_root: nil }
        OptionParser.new do |parser|
          parser.on("--dossier PATH", "boundary_dossier.json or its directory") { |value| options[:dossier] = value }
          parser.on("--source-root DIR", "Canonical Markdown corpus root for frontier attachment paths") { |value| options[:source_root] = value }
          parser.on("--spec-root DIR", "Explicit pinned public definitions for a new editorial bundle") { |value| options[:spec_root] = value }
          parser.on("--output DIR", "New editorial handoff bundle directory") { |value| options[:output] = value }
        end.parse!(argv)
        raise OptionParser::MissingArgument, "--dossier PATH" unless options[:dossier]
        raise OptionParser::MissingArgument, "--output DIR" unless options[:output]
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        result = BoundaryEditorial.init!(dossier_path: options[:dossier], output_dir: options[:output], spec_root: options[:spec_root])
        dossier_path = File.expand_path(options[:dossier])
        dossier_path = File.join(dossier_path, "boundary_dossier.json") if File.directory?(dossier_path)
        source_root = options[:source_root] && File.expand_path(options[:source_root])
        source_paths = result.context.dig("source", "markdown_files").map do |item|
          filename = item.fetch("filename")
          source_root ? File.expand_path(filename, source_root) : filename
        end

        lines = [
          "Boundary editorial handoff: PASS",
          "Source: #{result.context.dig('source', 'canonical_source_id')}",
          "Base AMC: #{result.context.dig('base_amc', 'filename')}",
          "Candidates initialized: 0",
          "Wrote #{result.context_path}",
          "Wrote #{result.decisions_path}",
          "Wrote #{result.review_path}",
          "",
          "Frontier editorial handoff required:",
          "  1. Open ChatGPT in normal Chat.",
          "  2. Attach these exact files:"
        ]
        source_paths.each { |path| lines << "     - #{path}" }
        lines.concat(
          [
            "     - #{dossier_path}",
            "     - #{result.review_path}",
            "     - #{result.decisions_path}",
            "  3. Send this prompt:"
          ]
        )
        BoundaryEditorial.frontier_prompt(result.context).each_line do |line|
          lines << "     #{line.rstrip}"
        end
        lines.concat(
          [
            "  4. Review ChatGPT's proposed editorial_decisions.yml before replacing:",
            "     #{result.decisions_path}",
            "  5. Resume only after the reviewed ledger is saved:",
            "     cd #{File.expand_path('../..', __dir__)}",
            "     #{File.expand_path('../../bin/af-ingest-next', __dir__)} #{result.output_dir}"
          ]
        )
        out.puts(lines.join("\n"))
        0
      end

      def self.validate_command(argv, out:)
        complete = false
        OptionParser.new do |parser|
          parser.on("--complete", "Require every candidate to be importable (no pending/hold)") { complete = true }
        end.parse!(argv)
        bundle = argv.shift
        raise OptionParser::MissingArgument, "BUNDLE_DIR" unless bundle
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        result = BoundaryEditorial.validate!(bundle_dir: bundle, complete:)
        repo_root = File.expand_path("../..", __dir__)
        executable = File.join(repo_root, "bin", "af-ingest-next")
        resume = [
          Shellwords.escape(executable),
          Shellwords.escape(File.expand_path(bundle))
        ].join(" ")
        continuation = if result.complete
          "Next command:"
        else
          "After resolving pending/held ledger rows, resume with:"
        end
        out.puts(
          "Boundary editorial decisions: PASS\n" \
          "Accepted: #{result.counts.fetch('accept')}\n" \
          "Rejected: #{result.counts.fetch('reject')}\n" \
          "Merged: #{result.counts.fetch('merge')}\n" \
          "Split: #{result.counts.fetch('split', 0)}\n" \
          "Held: #{result.counts.fetch('hold')}\n" \
          "Pending: #{result.counts.fetch('pending')}\n" \
          "Complete: #{result.complete}\n\n" \
          "#{continuation}\n" \
          "  1. cd #{Shellwords.escape(repo_root)}\n" \
          "     #{resume}"
        )
        0
      end

      def self.render_command(argv, out:)
        bundle = argv.shift
        raise OptionParser::MissingArgument, "BUNDLE_DIR" unless bundle
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        out.write(BoundaryEditorial.render_workspace(bundle_dir: bundle))
        0
      end

      def self.approve_command(argv, out:)
        options = approval_options(argv, include_approver: true, include_output: true)
        result = BoundaryEditorial.approve!(
          bundle_dir: options.fetch(:bundle),
          dossier_path: options.fetch(:dossier),
          source_root: options.fetch(:source_root),
          amc_path: options.fetch(:amc),
          approved_by: options.fetch(:approved_by),
          output_path: options.fetch(:output),
          registry_path: options[:registry]
        )
        out.puts(
          "Boundary editorial approval: PASS\n" \
          "Approval ID: #{result.approval.fetch('approval_id')}\n" \
          "Approved by: #{result.approval.dig('approval', 'approved_by')}\n" \
          "Approved at: #{result.approval.dig('approval', 'approved_at')}\n" \
          "Approval SHA-256: #{result.sha256}\n" \
          "Replay: #{result.reused ? 'reused identical approval bytes' : 'issued new approval'}\n" \
          "Wrote #{result.output_path}"
        )
        0
      end

      def self.validate_approval_command(argv, out:)
        options = approval_options(argv, include_approver: false, include_output: false)
        approval_path = options.fetch(:approval)
        result = BoundaryEditorial.validate_approval!(
          approval_path:,
          bundle_dir: options.fetch(:bundle),
          dossier_path: options.fetch(:dossier),
          source_root: options.fetch(:source_root),
          amc_path: options.fetch(:amc),
          registry_path: options[:registry]
        )
        out.puts(
          "Boundary editorial approval validation: PASS\n" \
          "Approval ID: #{result.approval.fetch('approval_id')}\n" \
          "Approval SHA-256: #{result.sha256}\n" \
          "Approved by: #{result.approval.dig('approval', 'approved_by')}\n" \
          "Approved at: #{result.approval.dig('approval', 'approved_at')}"
        )
        0
      end

      def self.approval_options(argv, include_approver:, include_output:)
        options = {
          bundle: nil, dossier: nil, source_root: nil, amc: nil, registry: nil,
          approved_by: nil, output: nil, approval: nil
        }
        OptionParser.new do |parser|
          parser.on("--dossier PATH", "Current boundary dossier bound by the bundle") { |value| options[:dossier] = value }
          parser.on("--source-root DIR", "Canonical Markdown corpus root") { |value| options[:source_root] = value }
          parser.on("--amc PATH", "Exact base AMC bound by the dossier") { |value| options[:amc] = value }
          parser.on("--registry PATH", "Source registry override") { |value| options[:registry] = value }
          if include_approver
            parser.on("--approved-by NAME", "Explicit human approver attesting the completed review") do |value|
              options[:approved_by] = value
            end
          end
          parser.on("--output PATH", "Immutable approval record path") { |value| options[:output] = value } if include_output
          parser.on("--approval PATH", "Boundary editorial approval record") { |value| options[:approval] = value } unless include_output
        end.parse!(argv)
        options[:bundle] = argv.shift
        raise OptionParser::MissingArgument, "BUNDLE_DIR" unless options[:bundle]
        required = %i[dossier source_root amc]
        required << :approved_by if include_approver
        required << :approval unless include_output
        required.each do |key|
          raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')} VALUE" unless options[key]
        end
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
        options
      end

      def self.import_command(argv, out:)
        options = {
          dossier: nil, freeze: nil, source_root: nil, amc: nil,
          approval: nil, output: nil, registry: nil
        }
        OptionParser.new do |parser|
          parser.on("--dossier PATH", "Current boundary dossier bound by the bundle") { |value| options[:dossier] = value }
          parser.on("--freeze PATH", "Fresh draft af-boundary-freeze/v0.1 YAML") { |value| options[:freeze] = value }
          parser.on("--source-root DIR", "Canonical Markdown corpus root") { |value| options[:source_root] = value }
          parser.on("--amc PATH", "Exact base AMC bound by the dossier/freeze") { |value| options[:amc] = value }
          parser.on("--approval PATH", "Validated boundary editorial approval record") { |value| options[:approval] = value }
          parser.on("--output PATH", "New frozen boundary-freeze YAML") { |value| options[:output] = value }
          parser.on("--registry PATH", "Registry override passed to boundary-freeze validation") { |value| options[:registry] = value }
        end.parse!(argv)
        bundle = argv.shift
        raise OptionParser::MissingArgument, "BUNDLE_DIR" unless bundle
        %i[dossier freeze source_root amc approval output].each do |key|
          raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')} VALUE" unless options[key]
        end
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        result = BoundaryEditorial.import!(
          bundle_dir: bundle,
          dossier_path: options[:dossier],
          freeze_path: options[:freeze],
          source_root: options[:source_root],
          amc_path: options[:amc],
          approval_path: options[:approval],
          output_path: options[:output],
          registry_path: options[:registry]
        )
        repo_root = File.expand_path("../..", __dir__)
        executable = File.join(repo_root, "bin", "af-data")
        next_args = [
          executable,
          "boundary-freeze-validate",
          result.output_path,
          "--source-root",
          options.fetch(:source_root),
          "--amc",
          options.fetch(:amc)
        ]
        next_args.concat(["--registry", options.fetch(:registry)]) if options[:registry]
        next_command = next_args.map { |value| Shellwords.escape(value.to_s) }.join(" ")
        out.puts(
          "Boundary editorial import: PASS\n" \
          "Accepted records imported: #{result.record_count}\n" \
          "Rejected candidates preserved in ledger: #{result.counts.fetch('reject')}\n" \
          "Merged candidates preserved in ledger: #{result.counts.fetch('merge')}\n" \
          "Split candidates preserved in ledger: #{result.counts.fetch('split', 0)}\n" \
          "Boundary freeze SHA-256: #{result.sha256}\n" \
          "Wrote #{result.output_path}\n\n" \
          "Next command:\n" \
          "  1. cd #{Shellwords.escape(repo_root)}\n" \
          "     #{next_command}"
        )
        0
      end

      def self.freeze_approved_command(argv, out:)
        options = approved_freeze_options(argv, require_draft: true)
        result = BoundaryEditorial.freeze_approved!(
          bundle_dir: options.fetch(:bundle),
          approval_path: options.fetch(:approval),
          dossier_path: options.fetch(:dossier),
          freeze_path: options.fetch(:freeze),
          source_root: options.fetch(:source_root),
          amc_path: options.fetch(:amc),
          output_path: options.fetch(:output),
          registry_path: options[:registry]
        )
        out.puts(
          "Approved boundary freeze composition: PASS\n" \
          "Terminal state: VALIDATED_FROZEN_BOUNDARIES\n" \
          "Accepted records frozen: #{result.record_count}\n" \
          "Rejected candidates preserved in ledger: #{result.counts.fetch('reject')}\n" \
          "Merged candidates preserved in ledger: #{result.counts.fetch('merge')}\n" \
          "Split candidates preserved in ledger: #{result.counts.fetch('split', 0)}\n" \
          "Approval ID: #{result.approval_id}\n" \
          "Approval SHA-256: #{result.approval_sha256}\n" \
          "Boundary freeze SHA-256: #{result.sha256}\n" \
          "Draft: #{result.draft_initialized ? 'initialized clean draft' : 'reused or not needed'} at #{result.draft_path}\n" \
          "Replay: #{result.reused ? 'reused exact validated frozen bytes' : 'published new validated frozen bytes'}\n" \
          "Wrote #{result.output_path}\n" \
          "No AMC application, catalog promotion, scoring, or inference was performed."
        )
        0
      end

      def self.validate_approved_freeze_command(argv, out:)
        options = approved_freeze_options(argv, require_draft: false)
        result = BoundaryEditorial.validate_approved_freeze!(
          freeze_path: options.fetch(:output),
          approval_path: options.fetch(:approval),
          bundle_dir: options.fetch(:bundle),
          dossier_path: options.fetch(:dossier),
          source_root: options.fetch(:source_root),
          amc_path: options.fetch(:amc),
          registry_path: options[:registry]
        )
        out.puts(
          "Approved boundary freeze validation: PASS\n" \
          "Terminal state: VALIDATED_FROZEN_BOUNDARIES\n" \
          "Accepted records frozen: #{result.record_count}\n" \
          "Approval ID: #{result.approval_id}\n" \
          "Approval SHA-256: #{result.approval_sha256}\n" \
          "Boundary freeze SHA-256: #{result.sha256}"
        )
        0
      end

      def self.approved_freeze_options(argv, require_draft:)
        options = {
          bundle: nil, approval: nil, dossier: nil, freeze: nil,
          source_root: nil, amc: nil, output: nil, registry: nil
        }
        OptionParser.new do |parser|
          parser.on("--approval PATH", "Exact IG-09A boundary editorial approval") { |value| options[:approval] = value }
          parser.on("--dossier PATH", "Current boundary dossier bound by the bundle") { |value| options[:dossier] = value }
          if require_draft
            parser.on("--freeze PATH", "Clean draft path to validate or initialize") { |value| options[:freeze] = value }
          end
          parser.on("--source-root DIR", "Canonical Markdown corpus root") { |value| options[:source_root] = value }
          parser.on("--amc PATH", "Exact frozen base AMC") { |value| options[:amc] = value }
          parser.on("--output PATH", "Frozen boundary artifact to publish or validate") { |value| options[:output] = value }
          parser.on("--registry PATH", "Source registry override") { |value| options[:registry] = value }
        end.parse!(argv)
        options[:bundle] = argv.shift
        raise OptionParser::MissingArgument, "BUNDLE_DIR" unless options[:bundle]
        required = %i[approval dossier source_root amc output]
        required << :freeze if require_draft
        required.each do |key|
          raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')} VALUE" unless options[key]
        end
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
        options
      end

      def self.rebind_command(argv, out:)
        options = { dossier: nil, output: nil, reason: nil, allow_source_id_change: false }
        OptionParser.new do |parser|
          parser.on("--dossier PATH", "Fresh boundary dossier to bind") { |value| options[:dossier] = value }
          parser.on("--output DIR", "New rebound editorial handoff directory") { |value| options[:output] = value }
          parser.on("--reason TEXT", "Required audit reason for the rebind") { |value| options[:reason] = value }
          parser.on("--allow-source-id-change", "Explicitly allow canonical source identity correction when source bytes/ranges match") do
            options[:allow_source_id_change] = true
          end
        end.parse!(argv)
        bundle = argv.shift
        raise OptionParser::MissingArgument, "BUNDLE_DIR" unless bundle
        raise OptionParser::MissingArgument, "--dossier PATH" unless options[:dossier]
        raise OptionParser::MissingArgument, "--output DIR" unless options[:output]
        raise OptionParser::MissingArgument, "--reason TEXT" unless options[:reason]
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        result = BoundaryEditorial.rebind!(
          bundle_dir: bundle,
          dossier_path: options[:dossier],
          output_dir: options[:output],
          reason: options[:reason],
          allow_source_id_change: options[:allow_source_id_change]
        )
        old = result.context.fetch("rebind_history").last.fetch("from")
        current = result.context.fetch("rebind_history").last.fetch("to")
        out.puts(
          "Boundary editorial rebind: PASS\n" \
          "Source: #{old.fetch('canonical_source_id')} -> #{current.fetch('canonical_source_id')}\n" \
          "Base AMC: #{old.dig('base_amc', 'filename')} -> #{current.dig('base_amc', 'filename')}\n" \
          "Candidate decisions preserved byte-for-byte\n" \
          "Human re-review and approval are required before import\n" \
          "Wrote #{result.output_dir}"
        )
        0
      end

      def self.help
        <<~TEXT
          Usage:
            bin/af-boundary-editorial init --dossier PATH --output DIR [--spec-root ABSOLUTE_PUBLIC_DIR]
            bin/af-boundary-editorial validate BUNDLE_DIR [--complete]
            bin/af-boundary-editorial render BUNDLE_DIR
            bin/af-boundary-editorial approve BUNDLE_DIR --dossier PATH --source-root DIR --amc BASE.xlsx --approved-by NAME [--output APPROVAL.json] [--registry PATH]
            bin/af-boundary-editorial validate-approval BUNDLE_DIR --approval APPROVAL.json --dossier PATH --source-root DIR --amc BASE.xlsx [--registry PATH]
            bin/af-boundary-editorial freeze-approved BUNDLE_DIR --approval APPROVAL.json --dossier PATH --freeze DRAFT.yml --source-root DIR --amc BASE.xlsx --output FROZEN.yml [--registry PATH]
            bin/af-boundary-editorial validate-approved-freeze BUNDLE_DIR --approval APPROVAL.json --dossier PATH --source-root DIR --amc BASE.xlsx --output FROZEN.yml [--registry PATH]
            bin/af-boundary-editorial import BUNDLE_DIR --approval APPROVAL.json --dossier PATH --freeze DRAFT.yml --source-root DIR --amc BASE.xlsx --output FROZEN.yml [--registry PATH]
            bin/af-boundary-editorial rebind BUNDLE_DIR --dossier PATH --output DIR --reason TEXT [--allow-source-id-change]
        TEXT
      end
    end
  end
end
