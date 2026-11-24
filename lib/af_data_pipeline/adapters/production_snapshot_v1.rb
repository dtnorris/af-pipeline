# frozen_string_literal: true

module AfDataPipeline
  module Adapters
    # Discovers completed LME scoring runs in an immutable evidence snapshot and
    # emits one production candidate per complete AFCSU assessment value.
    class ProductionSnapshotV1
      ADAPTER_NAME = "ProductionSnapshotV1"
      RUN_SCHEMA = "af-production-run/v0.1"
      CANDIDATE_SCHEMA = "af-production-candidate/v0.1"
      HOLD_SCHEMA = "af-production-hold/v0.1"
      HOLD_ASSESSMENT_REASONS = {
        "uncertain / requires source verification" => "source_verification_required",
        "insufficient evidence" => "insufficient_evidence"
      }.freeze
      ADV_ID = /\AADV-\d{4}\z/

      Extraction = Data.define(
        :runs,
        :candidates,
        :holds,
        :duplicates,
        :conflicts,
        :unclaimed_assessments,
        :errors,
        :expected_candidates,
        :expectation_match,
        :consumed_paths
      )

      def initialize(root:, entries:, progress: nil, progress_every: 25)
        @root = File.expand_path(root)
        @entries = entries
        @entries_by_path = entries.to_h { |entry| [entry.relative_path, entry] }
        @progress = progress
        @progress_every = progress_every
      end

      def extract(expected_candidates: nil)
        run_metadata_entries = discover_run_metadata
        flat_assessment_entries = discover_flat_assessment_entries
        run_entries = if run_metadata_entries.empty?
                        flat_assessment_entries.map { |entry| [:flat, entry] }
                      else
                        run_metadata_entries.map { |entry| [:lme, entry] }
                      end
        @progress&.call(phase: :discover, current: run_entries.length, total: run_entries.length)
        runs = run_entries.each_with_index.map do |item, index|
          kind, entry = item
          run = kind == :flat ? build_flat_run(entry) : build_run(entry)
          current = index + 1
          if current == run_entries.length || (@progress_every.positive? && (current % @progress_every).zero?)
            @progress&.call(phase: :extract, current:, total: run_entries.length)
          end
          run
        end
        candidates = runs.flat_map { |run| run.fetch("candidates") }
        holds = runs.flat_map { |run| run.fetch("holds") }
        runs.each do |run|
          run.delete("candidates")
          run.delete("holds")
        end

        duplicates, conflicts = duplicate_findings(candidates)
        claimed_assessments = runs.flat_map { |run| Array(run.dig("provenance", "assessments")).map { |item| item["source_path"] } }
        all_assessments = @entries.select { |entry| assessment_entry?(entry) }.map(&:relative_path)
        unclaimed_assessments = (all_assessments - claimed_assessments).sort

        errors = runs.flat_map do |run|
          Array(run["issues"]).map { |message| "#{run['run_path']}: #{message}" }
        end
        errors << "duplicate candidate keys detected: #{duplicates.map { |item| item['candidate_key'] }.join(', ')}" unless duplicates.empty?
        errors << "conflicting candidate keys detected: #{conflicts.map { |item| item['candidate_key'] }.join(', ')}" unless conflicts.empty?
        errors << "unclaimed assessment CSVs detected: #{unclaimed_assessments.join(', ')}" unless unclaimed_assessments.empty?

        expectation_match = expected_candidates.nil? || candidates.length == expected_candidates
        if expected_candidates && !expectation_match
          errors << "normalized #{candidates.length} production candidates; expected #{expected_candidates}"
        end

        Extraction.new(
          runs: runs.sort_by { |run| run["run_path"] },
          candidates: candidates.sort_by { |candidate| outcome_sort_key(candidate) },
          holds: holds.sort_by { |hold| outcome_sort_key(hold) },
          duplicates:,
          conflicts:,
          unclaimed_assessments:,
          errors: errors.uniq,
          expected_candidates:,
          expectation_match:,
          consumed_paths: consumed_paths(runs, candidates, holds)
        )
      end

      private

      def discover_run_metadata
        @entries.select do |entry|
          File.basename(entry.relative_path) == "metadata.json" &&
            entry.relative_path.include?("/runs/") &&
            File.directory?(File.join(File.dirname(entry.absolute_path), "native"))
        end.sort_by(&:relative_path)
      end


      def discover_flat_assessment_entries
        @entries.select { |entry| flat_assessment_entry?(entry) }.sort_by(&:relative_path)
      end

      def flat_assessment_entry?(entry)
        return false unless entry.extension == ".csv"

        parts = entry.relative_path.split("/")
        return false unless parts.length >= 2 && parts[-2] == "assessments"

        !entry.relative_path.include?("/native/assessments/") &&
          !entry.relative_path.start_with?("native/assessments/")
      end

      def build_flat_run(assessment_entry)
        issues = []
        rows = parse_rows(assessment_entry, issues)
        adventures = rows.map { |row| row["adventure_id"] }.reject { |value| blank?(value) }.uniq
        run_ids = rows.map { |row| row["run_id"] }.reject { |value| blank?(value) }.uniq
        statuses = rows.map { |row| row["status"] }.reject { |value| blank?(value) }.uniq
        adventure_id = adventures.one? ? adventures.first : nil
        scoring_run_id = run_ids.one? ? run_ids.first : nil
        dimensions = flat_dimensions(rows.map { |row| row["metric"] })

        unless adventures.one? && adventure_id.match?(ADV_ID)
          issues << "flat AFCSU assessment must identify exactly one canonical adventure; found #{adventures.inspect}"
        end
        unless run_ids.one?
          issues << "flat AFCSU assessment must identify exactly one scoring run_id; found #{run_ids.inspect}"
        end
        unless statuses == ["PROPOSED"]
          issues << "flat AFCSU assessment rows must all have status PROPOSED; found #{statuses.inspect}"
        end

        identity = {
          "metadata_schema" => "afcsu-flat-v1",
          "experiment_name" => nil,
          "lme_run_id" => nil,
          "adventure_id" => adventure_id,
          "dimensions" => dimensions,
          "replicate" => nil,
          "model" => single_field(rows, "model"),
          "repo_commit" => nil,
          "scorer_commit" => nil,
          "started_at" => nil,
          "ended_at" => nil,
          "complete" => true
        }

        validate_rows(rows, identity, issues) unless rows.empty?
        raw_entries = flat_raw_response_entries(assessment_entry, adventure_id, scoring_run_id)
        raw_documents = raw_entries.filter_map { |entry| parse_raw_document(entry, issues) }
        assessment_rows = expected_candidate_rows(rows, identity, issues)
        candidate_records = []
        hold_records = []

        if issues.empty?
          assessment_rows.each do |row|
            if hold_assessment_state?(row["assessment_state"])
              hold = build_hold(row, identity, nil, assessment_entry, raw_documents, issues)
              hold_records << hold if hold
            else
              candidate = build_candidate(row, identity, nil, assessment_entry, raw_documents, issues)
              candidate_records << candidate if candidate
            end
          end
        end

        expected_outcome_count = expected_metrics(identity.fetch("dimensions")).length
        actual_outcome_count = candidate_records.length + hold_records.length
        if actual_outcome_count != expected_outcome_count
          issues << "produced #{actual_outcome_count} complete assessment outcomes; expected #{expected_outcome_count} from #{identity['dimensions'].inspect}"
        end

        candidates = issues.empty? ? candidate_records : []
        holds = issues.empty? ? hold_records : []

        {
          "schema_version" => RUN_SCHEMA,
          "adapter" => ADAPTER_NAME,
          "metadata_schema" => identity["metadata_schema"],
          "run_path" => assessment_entry.relative_path,
          "experiment_name" => nil,
          "lme_run_id" => nil,
          "adventure_id" => adventure_id,
          "dimensions" => dimensions,
          "replicate" => nil,
          "provider" => rows.empty? ? nil : single_field(rows, "provider"),
          "model" => identity["model"],
          "repo_commit" => nil,
          "scorer_commit" => nil,
          "started_at" => nil,
          "ended_at" => nil,
          "source_complete" => issues.empty?,
          "mechanical_status" => issues.empty? ? "valid" : "error",
          "candidate_count" => candidates.length,
          "hold_count" => holds.length,
          "issues" => issues.uniq,
          "provenance" => {
            "metadata" => nil,
            "assessments" => [provenance_item(assessment_entry)],
            "raw_responses" => raw_entries.map { |entry| provenance_item(entry) }
          },
          "candidates" => candidates,
          "holds" => holds
        }
      end

      def flat_dimensions(metrics)
        metrics = metrics.reject { |metric| blank?(metric) }
        dimensions = []
        if metrics.any? { |metric| ["Level Start", "Level End"].include?(metric) }
          dimensions << "Levels"
          metrics = metrics.reject { |metric| ["Level Start", "Level End"].include?(metric) }
        end
        dimensions.concat(metrics.uniq)
      end

      def flat_raw_response_entries(assessment_entry, adventure_id, scoring_run_id)
        return [] if blank?(adventure_id) || blank?(scoring_run_id)

        batch_root = File.dirname(File.dirname(assessment_entry.relative_path))
        prefix = batch_root == "." ? "" : "#{batch_root}/"
        raw_root = "#{prefix}raw/#{adventure_id}/#{scoring_run_id}/"
        @entries.select do |entry|
          next false unless entry.relative_path.start_with?(raw_root) && entry.extension == ".json"

          basename = File.basename(entry.relative_path)
          basename != "run_metadata.json" && !basename.end_with?("_request.json")
        end.sort_by(&:relative_path)
      end

      def build_run(metadata_entry)
        issues = []
        metadata = JSON.parse(File.read(metadata_entry.absolute_path, encoding: "UTF-8"))
        identity = normalize_metadata(metadata, metadata_entry.relative_path, issues)
        run_root = File.dirname(metadata_entry.relative_path)
        assessment_entries = @entries.select do |entry|
          entry.relative_path.start_with?("#{run_root}/native/assessments/") && entry.extension == ".csv"
        end.sort_by(&:relative_path)

        # A recognized LME run that explicitly did not complete is preserved as
        # an incomplete execution, not treated as malformed scoring evidence.
        # Do not parse or validate derivative assessment artifacts from an
        # incomplete run: their absence (or partial presence) follows from the
        # execution state and must not create cascading integrity errors.
        if !identity["complete"] && issues.empty?
          raw_entries = raw_response_entries(run_root)
          return {
            "schema_version" => RUN_SCHEMA,
            "adapter" => ADAPTER_NAME,
            "metadata_schema" => identity["metadata_schema"],
            "run_path" => run_root,
            "experiment_name" => identity["experiment_name"],
            "lme_run_id" => identity["lme_run_id"],
            "adventure_id" => identity["adventure_id"],
            "dimensions" => identity["dimensions"],
            "replicate" => identity["replicate"],
            "provider" => nil,
            "model" => identity["model"],
            "repo_commit" => identity["repo_commit"],
            "scorer_commit" => identity["scorer_commit"],
            "started_at" => identity["started_at"],
            "ended_at" => identity["ended_at"],
            "source_complete" => false,
            "mechanical_status" => "incomplete",
            "candidate_count" => 0,
            "hold_count" => 0,
            "issues" => [],
            "provenance" => {
              "metadata" => provenance_item(metadata_entry),
              "assessments" => assessment_entries.map { |entry| provenance_item(entry) },
              "raw_responses" => raw_entries.map { |entry| provenance_item(entry) }
            },
            "candidates" => [],
            "holds" => []
          }
        end

        issues << "run metadata does not report successful completion" unless identity["complete"]
        issues << "expected exactly 1 assessment CSV, found #{assessment_entries.length}" unless assessment_entries.length == 1

        rows = assessment_entries.length == 1 ? parse_rows(assessment_entries.first, issues) : []
        validate_rows(rows, identity, issues)
        raw_entries = raw_response_entries(run_root)
        raw_documents = raw_entries.filter_map { |entry| parse_raw_document(entry, issues) }

        assessment_rows = expected_candidate_rows(rows, identity, issues)
        candidate_records = []
        hold_records = []
        if identity["complete"] && issues.empty?
          assessment_rows.each do |row|
            if hold_assessment_state?(row["assessment_state"])
              hold = build_hold(row, identity, metadata_entry, assessment_entries.first, raw_documents, issues)
              hold_records << hold if hold
            else
              candidate = build_candidate(row, identity, metadata_entry, assessment_entries.first, raw_documents, issues)
              candidate_records << candidate if candidate
            end
          end
        end

        expected_outcome_count = expected_metrics(identity.fetch("dimensions")).length
        actual_outcome_count = candidate_records.length + hold_records.length
        if identity["complete"] && actual_outcome_count != expected_outcome_count
          issues << "produced #{actual_outcome_count} complete assessment outcomes; expected #{expected_outcome_count} from #{identity['dimensions'].inspect}"
        end
        candidates = issues.empty? ? candidate_records : []
        holds = issues.empty? ? hold_records : []

        {
          "schema_version" => RUN_SCHEMA,
          "adapter" => ADAPTER_NAME,
          "metadata_schema" => identity["metadata_schema"],
          "run_path" => run_root,
          "experiment_name" => identity["experiment_name"],
          "lme_run_id" => identity["lme_run_id"],
          "adventure_id" => identity["adventure_id"],
          "dimensions" => identity["dimensions"],
          "replicate" => identity["replicate"],
          "provider" => rows.empty? ? nil : single_field(rows, "provider"),
          "model" => identity["model"],
          "repo_commit" => identity["repo_commit"],
          "scorer_commit" => identity["scorer_commit"],
          "started_at" => identity["started_at"],
          "ended_at" => identity["ended_at"],
          "source_complete" => identity["complete"],
          "mechanical_status" => issues.empty? ? "valid" : "error",
          "candidate_count" => candidates.length,
          "hold_count" => holds.length,
          "issues" => issues.uniq,
          "provenance" => {
            "metadata" => provenance_item(metadata_entry),
            "assessments" => assessment_entries.map { |entry| provenance_item(entry) },
            "raw_responses" => raw_entries.map { |entry| provenance_item(entry) }
          },
          "candidates" => candidates,
          "holds" => holds
        }
      rescue JSON::ParserError => e
        run_path = File.dirname(metadata_entry.relative_path)
        {
          "schema_version" => RUN_SCHEMA,
          "adapter" => ADAPTER_NAME,
          "metadata_schema" => nil,
          "run_path" => run_path,
          "experiment_name" => experiment_from_path(run_path),
          "lme_run_id" => nil,
          "adventure_id" => nil,
          "dimensions" => [],
          "replicate" => nil,
          "provider" => nil,
          "model" => nil,
          "repo_commit" => nil,
          "scorer_commit" => nil,
          "started_at" => nil,
          "ended_at" => nil,
          "source_complete" => false,
          "mechanical_status" => "error",
          "candidate_count" => 0,
          "hold_count" => 0,
          "issues" => ["metadata parse failure: #{e.message}"],
          "provenance" => { "metadata" => provenance_item(metadata_entry), "assessments" => [], "raw_responses" => [] },
          "candidates" => [],
          "holds" => []
        }
      end

      def normalize_metadata(metadata, path, issues)
        if metadata.key?("job_id") && metadata.key?("adventure") && metadata.key?("dimension")
          normalize_legacy_metadata(metadata, path, issues)
        elsif metadata.key?("run_id") && metadata["job"].is_a?(Hash)
          normalize_current_metadata(metadata, path, issues)
        else
          issues << "unsupported LME run metadata schema"
          {
            "metadata_schema" => "unsupported",
            "experiment_name" => experiment_from_path(File.dirname(path)),
            "lme_run_id" => metadata["run_id"] || metadata["job_id"],
            "adventure_id" => nil,
            "dimensions" => [],
            "replicate" => nil,
            "model" => nil,
            "repo_commit" => nil,
            "scorer_commit" => nil,
            "started_at" => nil,
            "ended_at" => nil,
            "complete" => false
          }
        end
      end

      def normalize_legacy_metadata(metadata, path, issues)
        adventure = metadata["adventure"].to_s
        dimension = metadata["dimension"].to_s
        issues << "invalid metadata adventure_id #{adventure.inspect}" unless adventure.match?(ADV_ID)
        issues << "metadata dimension is blank" if dimension.strip.empty?
        {
          "metadata_schema" => "lme-legacy-v1",
          "experiment_name" => experiment_from_path(File.dirname(path)),
          "lme_run_id" => metadata["job_id"],
          "adventure_id" => adventure,
          "dimensions" => dimension.empty? ? [] : [dimension],
          "replicate" => metadata["replicate"],
          "model" => metadata["ollama_model"],
          "repo_commit" => nil,
          "scorer_commit" => nil,
          "started_at" => metadata["started_at"],
          "ended_at" => metadata["completed_at"],
          "complete" => metadata["status"] == "complete" && metadata["exit_status"] == 0
        }
      end

      def normalize_current_metadata(metadata, path, issues)
        job = metadata.fetch("job")
        model = metadata["model"].is_a?(Hash) ? metadata["model"] : {}
        adventure = job["adventure_id"].to_s
        dimensions = Array(job["dimensions"]).map(&:to_s)
        issues << "invalid metadata adventure_id #{adventure.inspect}" unless adventure.match?(ADV_ID)
        issues << "metadata dimensions are empty" if dimensions.empty?
        {
          "metadata_schema" => "lme-current-v1",
          "experiment_name" => metadata["experiment_name"] || experiment_from_path(File.dirname(path)),
          "lme_run_id" => metadata["run_id"],
          "adventure_id" => adventure,
          "dimensions" => dimensions,
          "replicate" => job["replicate"],
          "model" => model["scorer_model"] || model["ollama_model"],
          "repo_commit" => metadata["repo_commit"],
          "scorer_commit" => metadata["scorer_commit"],
          "started_at" => metadata["started_at"],
          "ended_at" => metadata["ended_at"],
          "complete" => metadata["success"] == true
        }
      end

      def experiment_from_path(run_path)
        parts = run_path.split("/")
        runs_index = parts.rindex("runs")
        runs_index && runs_index.positive? ? parts[runs_index - 1] : nil
      end

      def parse_rows(entry, issues)
        rows = CSV.read(entry.absolute_path, headers: true).map(&:to_h)
        issues << "assessment CSV contains no data rows" if rows.empty?
        rows
      rescue CSV::MalformedCSVError => e
        issues << "assessment CSV parse failure: #{e.message}"
        []
      end

      def validate_rows(rows, identity, issues)
        return if rows.empty?

        adventures = rows.map { |row| row["adventure_id"] }.uniq
        issues << "assessment adventure_id values #{adventures.inspect} do not match metadata #{identity['adventure_id'].inspect}" unless adventures == [identity["adventure_id"]]

        scoring_run_ids = rows.map { |row| row["run_id"] }.reject { |value| blank?(value) }.uniq
        issues << "assessment rows must share exactly one run_id; found #{scoring_run_ids.inspect}" unless scoring_run_ids.length == 1

        %w[provider model].each do |field|
          values = rows.map { |row| row[field] }.reject { |value| blank?(value) }.uniq
          issues << "assessment rows contain multiple #{field} values: #{values.inspect}" if values.length > 1
        end

        model = single_field(rows, "model")
        if !blank?(identity["model"]) && !blank?(model) && identity["model"] != model
          issues << "metadata model #{identity['model'].inspect} does not match assessment model #{model.inspect}"
        end
      end

      def expected_candidate_rows(rows, identity, issues)
        expected = expected_metrics(identity.fetch("dimensions"))
        actual = rows.map { |row| row["metric"] }
        missing = expected - actual
        extra = actual - expected
        duplicates = actual.tally.select { |_metric, count| count > 1 }.keys
        issues << "missing expected assessment metrics: #{missing.join(', ')}" unless missing.empty?
        issues << "unexpected assessment metrics: #{extra.join(', ')}" unless extra.empty?
        issues << "duplicate assessment metrics within run: #{duplicates.join(', ')}" unless duplicates.empty?

        expected.filter_map do |metric|
          matching = rows.select { |row| row["metric"] == metric }
          matching.one? ? matching.first : nil
        end
      end

      def expected_metrics(dimensions)
        dimensions.flat_map do |dimension|
          case dimension
          when "Levels" then ["Level Start", "Level End"]
          else [dimension]
          end
        end
      end

      def raw_response_entries(run_root)
        @entries.select do |entry|
          next false unless entry.relative_path.start_with?("#{run_root}/native/raw/") && entry.extension == ".json"

          basename = File.basename(entry.relative_path)
          basename != "run_metadata.json" && !basename.end_with?("_request.json")
        end.sort_by(&:relative_path)
      end

      def parse_raw_document(entry, issues)
        payload = JSON.parse(File.read(entry.absolute_path, encoding: "UTF-8"))
        structured, reasoning, raw_text, provider, model = raw_components(payload)
        return nil unless structured.is_a?(Hash)

        {
          "entry" => entry,
          "structured" => structured,
          "reasoning" => reasoning,
          "raw_text" => raw_text,
          "provider" => provider,
          "model" => model
        }
      rescue JSON::ParserError => e
        issues << "raw response parse failure #{entry.relative_path}: #{e.message}"
        nil
      end

      def raw_components(payload)
        structured = payload.dig("assistant", "structured")
        if structured.is_a?(Hash)
          return [structured, payload.dig("assistant", "reasoning"), payload.dig("assistant", "raw_text"), payload["provider"], payload["model"]]
        end

        message = Array(payload["choices"]).first.to_h["message"].to_h
        content = message["content"]
        structured = content.is_a?(Hash) ? content : JSON.parse(content.to_s)
        [structured, message["reasoning"], content, payload["provider"], payload["model"]]
      rescue JSON::ParserError
        [nil, nil, nil, payload["provider"], payload["model"]]
      end

      def build_hold(row, identity, metadata_entry, assessment_entry, raw_documents, issues)
        metric = row["metric"].to_s
        hold_issues = []
        hold_issues << "value must be blank for unresolved assessment" unless blank?(row["value"])
        hold_issues << "rationale is blank" if blank?(row["rationale"])
        hold_issues << "review_disposition must be REVIEW_REQUIRED for unresolved assessment" unless row["review_disposition"] == "REVIEW_REQUIRED"

        matches = raw_documents.select { |document| raw_metric_data(document["structured"], metric) }
        if matches.length != 1
          hold_issues << "expected exactly 1 raw response matching #{metric.inspect}, found #{matches.length}"
        end
        raw_document = matches.one? ? matches.first : nil
        raw_metric = raw_document && raw_metric_data(raw_document["structured"], metric)
        compare_candidate_to_raw(row, raw_metric, hold_issues) if raw_metric
        compare_raw_identity(row, raw_document, hold_issues) if raw_document

        unless hold_issues.empty?
          hold_issues.each { |message| issues << "#{metric}: #{message}" }
          return nil
        end

        {
          "schema_version" => HOLD_SCHEMA,
          "adapter" => ADAPTER_NAME,
          "hold_key" => "#{identity['adventure_id']}::#{metric}",
          "adventure_id" => identity["adventure_id"],
          "adventure_title" => row["adventure_title"],
          "source_book" => row["source_book"],
          "dimension" => metric,
          "metric_kind" => row["metric_kind"],
          "assessment_state" => row["assessment_state"],
          "value" => nil,
          "range_low" => coerce_value(row["range_low"]),
          "range_high" => coerce_value(row["range_high"]),
          "rationale" => row["rationale"],
          "evidence" => parse_evidence(row["evidence"]),
          "review_disposition" => row["review_disposition"],
          "metric_review_flags" => row["metric_review_flags"],
          "package_review_flags" => row["package_review_flags"],
          "afao_version" => row["afao_version"],
          "assessment_spec_version" => row["assessment_spec_version"],
          "provider" => row["provider"],
          "model" => row["model"],
          "scoring_run_id" => row["run_id"],
          "lme_run_id" => identity["lme_run_id"],
          "experiment_name" => identity["experiment_name"],
          "replicate" => identity["replicate"],
          "repo_commit" => identity["repo_commit"],
          "scorer_commit" => identity["scorer_commit"],
          "hold_reason" => hold_reason_for(row["assessment_state"]),
          "raw" => {
            "structured_content" => raw_document["structured"],
            "reasoning" => raw_document["reasoning"],
            "raw_text" => raw_document["raw_text"],
            "provider" => raw_document["provider"],
            "model" => raw_document["model"]
          },
          "provenance" => {
            "metadata" => provenance_item(metadata_entry),
            "assessment" => provenance_item(assessment_entry),
            "raw_response" => provenance_item(raw_document["entry"])
          },
          "mechanical_status" => "valid",
          "production_disposition" => "hold"
        }
      end

      def hold_assessment_state?(value)
        HOLD_ASSESSMENT_REASONS.key?(value.to_s.strip.downcase)
      end

      def hold_reason_for(value)
        HOLD_ASSESSMENT_REASONS.fetch(value.to_s.strip.downcase)
      end

      def build_candidate(row, identity, metadata_entry, assessment_entry, raw_documents, issues)
        metric = row["metric"].to_s
        candidate_issues = []
        candidate_issues << "assessment_state is blank" if blank?(row["assessment_state"])
        candidate_issues << "value is blank" if blank?(row["value"])
        candidate_issues << "rationale is blank" if blank?(row["rationale"])

        matches = raw_documents.select { |document| raw_metric_data(document["structured"], metric) }
        if matches.length != 1
          candidate_issues << "expected exactly 1 raw response matching #{metric.inspect}, found #{matches.length}"
        end
        raw_document = matches.one? ? matches.first : nil
        raw_metric = raw_document && raw_metric_data(raw_document["structured"], metric)
        compare_candidate_to_raw(row, raw_metric, candidate_issues) if raw_metric
        compare_raw_identity(row, raw_document, candidate_issues) if raw_document

        unless candidate_issues.empty?
          candidate_issues.each { |message| issues << "#{metric}: #{message}" }
          return nil
        end

        {
          "schema_version" => CANDIDATE_SCHEMA,
          "adapter" => ADAPTER_NAME,
          "candidate_key" => "#{identity['adventure_id']}::#{metric}",
          "adventure_id" => identity["adventure_id"],
          "adventure_title" => row["adventure_title"],
          "source_book" => row["source_book"],
          "dimension" => metric,
          "metric_kind" => row["metric_kind"],
          "assessment_state" => row["assessment_state"],
          "value" => coerce_value(row["value"]),
          "range_low" => coerce_value(row["range_low"]),
          "range_high" => coerce_value(row["range_high"]),
          "confidence" => coerce_value(row["confidence"]),
          "path_sensitive" => coerce_bool(row["path_sensitive"]),
          "path_variation_affects_anchor" => coerce_bool(row["path_variation_affects_anchor"]),
          "rationale" => row["rationale"],
          "adjacent_lower_reason" => row["adjacent_lower_reason"],
          "adjacent_higher_reason" => row["adjacent_higher_reason"],
          "evidence" => parse_evidence(row["evidence"]),
          "review_disposition" => row["review_disposition"],
          "metric_review_flags" => row["metric_review_flags"],
          "package_review_flags" => row["package_review_flags"],
          "afao_version" => row["afao_version"],
          "assessment_spec_version" => row["assessment_spec_version"],
          "provider" => row["provider"],
          "model" => row["model"],
          "scoring_run_id" => row["run_id"],
          "lme_run_id" => identity["lme_run_id"],
          "experiment_name" => identity["experiment_name"],
          "replicate" => identity["replicate"],
          "repo_commit" => identity["repo_commit"],
          "scorer_commit" => identity["scorer_commit"],
          "raw" => {
            "structured_content" => raw_document["structured"],
            "reasoning" => raw_document["reasoning"],
            "raw_text" => raw_document["raw_text"],
            "provider" => raw_document["provider"],
            "model" => raw_document["model"]
          },
          "provenance" => {
            "metadata" => provenance_item(metadata_entry),
            "assessment" => provenance_item(assessment_entry),
            "raw_response" => provenance_item(raw_document["entry"])
          },
          "mechanical_status" => "valid"
        }
      end

      def raw_metric_data(structured, metric)
        case metric
        when "Level Start" then structured["level_start"]
        when "Level End" then structured["level_end"]
        when "# of Sessions" then structured["sessions"]
        else
          Array(structured["dimensions"]).find { |item| item["dimension"] == metric }
        end
      end

      def compare_candidate_to_raw(row, raw, candidate_issues)
        expected_value = case row["metric"]
                         when "# of Sessions" then raw["normalized_sessions"]
                         else raw["score"] || raw["value"]
                         end
        compare_field(candidate_issues, "value", coerce_value(row["value"]), expected_value)
        compare_field(candidate_issues, "rationale", row["rationale"], raw["rationale"])
        compare_state(candidate_issues, row["assessment_state"], raw["assessment_state"])

        if row["metric"] == "# of Sessions"
          compare_field(candidate_issues, "range_low", coerce_value(row["range_low"]), raw["practical_range_low"])
          compare_field(candidate_issues, "range_high", coerce_value(row["range_high"]), raw["practical_range_high"])
        else
          compare_optional_field(candidate_issues, "adjacent_lower_reason", row["adjacent_lower_reason"], raw["adjacent_lower_reason"])
          compare_optional_field(candidate_issues, "adjacent_higher_reason", row["adjacent_higher_reason"], raw["adjacent_higher_reason"])
        end

        csv_evidence = parse_evidence(row["evidence"])
        raw_evidence = Array(raw["evidence"])
        compare_field(candidate_issues, "evidence", csv_evidence, raw_evidence) unless csv_evidence.empty? && raw_evidence.empty?
      end

      def compare_raw_identity(row, raw_document, candidate_issues)
        raw_model = raw_document["model"]
        raw_provider = raw_document["provider"]
        if !blank?(raw_model) && !blank?(row["model"]) && raw_model != row["model"]
          candidate_issues << "raw model #{raw_model.inspect} does not match assessment model #{row['model'].inspect}"
        end
        if !blank?(raw_provider) && !blank?(row["provider"]) && raw_provider != row["provider"]
          candidate_issues << "raw provider #{raw_provider.inspect} does not match assessment provider #{row['provider'].inspect}"
        end
      end

      def compare_state(issues, csv_value, raw_value)
        return if csv_value.to_s.strip.downcase == raw_value.to_s.strip.downcase

        issues << "assessment_state mismatch: CSV=#{csv_value.inspect}, raw=#{raw_value.inspect}"
      end

      def compare_field(issues, name, csv_value, raw_value)
        return if csv_value == raw_value

        issues << "#{name} mismatch: CSV=#{csv_value.inspect}, raw=#{raw_value.inspect}"
      end

      def compare_optional_field(issues, name, csv_value, raw_value)
        return if blank?(csv_value) && blank?(raw_value)

        compare_field(issues, name, csv_value, raw_value)
      end

      def duplicate_findings(candidates)
        duplicates = []
        conflicts = []
        candidates.group_by { |candidate| candidate["candidate_key"] }.each do |key, items|
          next if items.length < 2

          finding = {
            "candidate_key" => key,
            "count" => items.length,
            "sources" => items.map { |item| item.dig("provenance", "assessment", "source_path") }
          }
          signatures = items.map { |item| candidate_signature(item) }.uniq
          (signatures.length == 1 ? duplicates : conflicts) << finding
        end
        [duplicates.sort_by { |item| item["candidate_key"] }, conflicts.sort_by { |item| item["candidate_key"] }]
      end

      def candidate_signature(candidate)
        JSON.generate(
          "assessment_state" => candidate["assessment_state"],
          "value" => candidate["value"],
          "range_low" => candidate["range_low"],
          "range_high" => candidate["range_high"],
          "rationale" => candidate["rationale"],
          "adjacent_lower_reason" => candidate["adjacent_lower_reason"],
          "adjacent_higher_reason" => candidate["adjacent_higher_reason"],
          "evidence" => candidate["evidence"]
        )
      end

      def outcome_sort_key(outcome)
        [outcome["adventure_id"].to_s, outcome["dimension"].to_s, outcome["experiment_name"].to_s, outcome["lme_run_id"].to_s]
      end

      def assessment_entry?(entry)
        return false unless entry.extension == ".csv"

        entry.relative_path.include?("/native/assessments/") ||
          entry.relative_path.start_with?("native/assessments/") ||
          flat_assessment_entry?(entry)
      end

      def consumed_paths(runs, candidates, holds)
        paths = runs.flat_map do |run|
          provenance = run.fetch("provenance")
          [provenance["metadata"], *Array(provenance["assessments"]), *Array(provenance["raw_responses"])].compact.map { |item| item["source_path"] }
        end
        paths.concat(candidates.flat_map { |candidate| candidate.fetch("provenance").values.compact.map { |item| item["source_path"] } })
        paths.concat(holds.flat_map { |hold| hold.fetch("provenance").values.compact.map { |item| item["source_path"] } })
        paths.compact.uniq.sort
      end

      def provenance_item(entry)
        return nil unless entry

        {
          "source_path" => entry.relative_path,
          "source_sha256" => entry.sha256,
          "bytes" => entry.bytes
        }
      end

      def parse_evidence(value)
        return [] if blank?(value)

        parsed = JSON.parse(value)
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        []
      end

      def single_field(rows, field)
        values = rows.map { |row| row[field] }.reject { |value| blank?(value) }.uniq
        values.one? ? values.first : nil
      end

      def coerce_value(value)
        return nil if blank?(value)
        text = value.to_s
        return Integer(text) if text.match?(/\A-?\d+\z/)
        return Float(text) if text.match?(/\A-?\d+(?:\.\d+)?\z/)

        value
      rescue ArgumentError
        value
      end

      def coerce_bool(value)
        return nil if blank?(value)
        return true if value.to_s.casecmp("true").zero?
        return false if value.to_s.casecmp("false").zero?

        value
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
