# frozen_string_literal: true

module AfDataPipeline
  module Adapters
    # Package-level adapter for the LME production handoff produced by the
    # Horizontal Discovery collector. One scoped manifest is one logical result;
    # a logical result may contain multiple long-form assessment rows (Levels).
    class HorizontalDiscoveryV1
      ADAPTER_NAME = "HorizontalDiscoveryV1"
      SCOPE_FILE = "INGEST_SCOPE.txt"
      MANIFEST_PATTERN = %r{\Aexperiments/.+\.ya?ml\z}

      Scope = Data.define(:manifest_paths, :inclusive_cutoff, :first_excluded, :declared_count) do
        def to_h
          {
            "manifest_paths" => manifest_paths,
            "inclusive_cutoff" => inclusive_cutoff,
            "first_excluded" => first_excluded,
            "declared_count" => declared_count
          }
        end
      end

      Extraction = Data.define(
        :records,
        :all_records,
        :excluded_records,
        :scope,
        :errors,
        :duplicates,
        :conflicts,
        :consumed_paths
      )

      def initialize(root:, entries:)
        @root = File.expand_path(root)
        @entries_by_path = entries.to_h { |entry| [entry.relative_path, entry] }
        @entries_by_experiment = Hash.new { |hash, key| hash[key] = [] }

        entries.each do |entry|
          parts = entry.relative_path.split("/", 3)
          next unless parts.length == 3 && parts.first == "output"

          @entries_by_experiment[parts.fetch(1)] << entry
        end
      end

      def extract(through:, dimension:, expected_count: nil)
        scope = parse_scope
        errors = validate_scope(scope)
        all_records = scope.manifest_paths.each_with_index.map do |manifest_path, index|
          build_record(manifest_path, index + 1)
        end

        # The handoff package itself declares the exact inclusive scope. Treat the
        # caller's Adventure ID/dimension as assertions about that declared cutoff,
        # not as a heuristic search through the archive. This preserves malformed
        # scoped records in the review packet instead of silently dropping them.
        records = all_records
        excluded_records = []
        boundary = records.last
        if boundary
          if boundary["adventure_id"] != through || boundary["dimension"] != dimension
            errors << "declared cutoff record resolves to #{boundary['adventure_id'].inspect} / #{boundary['dimension'].inspect}; expected #{through} / #{dimension}"
          end
        else
          errors << "requested boundary #{through} / #{dimension} cannot be validated because the scope is empty"
        end

        if expected_count && records.length != expected_count
          errors << "selected #{records.length} logical results; expected #{expected_count}"
        end

        record_errors = records.flat_map do |record|
          record.fetch("audit_errors").map { |message| "##{record['ordinal']} #{record['manifest']}: #{message}" }
        end
        errors.concat(record_errors)

        duplicates, conflicts = duplicate_findings(records)
        errors << "duplicate logical result keys detected: #{duplicates.join(', ')}" unless duplicates.empty?
        errors << "conflicting duplicate logical result keys detected: #{conflicts.join(', ')}" unless conflicts.empty?

        Extraction.new(
          records:,
          all_records:,
          excluded_records:,
          scope:,
          errors: errors.uniq,
          duplicates:,
          conflicts:,
          consumed_paths: consumed_paths(all_records)
        )
      end

      private

      def parse_scope
        entry = @entries_by_path[SCOPE_FILE]
        raise ValidationError, "Horizontal Discovery package is missing #{SCOPE_FILE}" unless entry

        text = File.read(entry.absolute_path, encoding: "UTF-8")
        lines = text.lines.map(&:strip)
        declared_index = lines.index { |line| line.match?(/\ASCOPED RUN-ORDER ENTRIES:/) }
        manifests = if declared_index
                      lines[(declared_index + 1)..].select { |line| line.match?(MANIFEST_PATTERN) }
                    else
                      []
                    end
        declared_count = text[/SCOPED RUN-ORDER ENTRIES:\s*(\d+)/, 1]&.to_i

        Scope.new(
          manifest_paths: manifests,
          inclusive_cutoff: value_after_label(lines, "INCLUSIVE CUTOFF:"),
          first_excluded: value_after_label(lines, "FIRST EXCLUDED:"),
          declared_count:
        )
      end

      def validate_scope(scope)
        errors = []
        errors << "#{SCOPE_FILE} contains no scoped manifests" if scope.manifest_paths.empty?
        if scope.declared_count && scope.declared_count != scope.manifest_paths.length
          errors << "scope declares #{scope.declared_count} entries but lists #{scope.manifest_paths.length} manifests"
        end
        if scope.inclusive_cutoff && scope.manifest_paths.last != scope.inclusive_cutoff
          errors << "scope inclusive cutoff is not the last scoped manifest"
        end
        if scope.first_excluded && scope.manifest_paths.include?(scope.first_excluded)
          errors << "scope first-excluded manifest is incorrectly included"
        end
        errors
      end

      def value_after_label(lines, label)
        index = lines.index(label)
        return nil unless index

        lines[(index + 1)..].find { |line| !line.empty? }
      end

      def build_record(manifest_path, ordinal)
        audit_errors = []
        manifest_entry = @entries_by_path[manifest_path]
        unless manifest_entry
          return base_error_record(ordinal, manifest_path, "missing scoped manifest")
        end

        manifest_body = File.read(manifest_entry.absolute_path, encoding: "UTF-8")
        experiment = manifest_name(manifest_body, manifest_path)
        output_entries = @entries_by_experiment.fetch(experiment, [])

        assessment_entries = output_entries.select do |entry|
          entry.relative_path.include?("/native/assessments/") &&
            entry.extension == ".csv"
        end
        raw_entries = output_entries.select do |entry|
          entry.relative_path.include?("/native/raw/") &&
            File.basename(entry.relative_path).start_with?("dimension_") &&
            entry.extension == ".json" &&
            !entry.relative_path.end_with?("_request.json")
        end

        audit_errors << "expected exactly 1 assessment CSV, found #{assessment_entries.length}" unless assessment_entries.length == 1
        audit_errors << "expected exactly 1 dimension raw JSON, found #{raw_entries.length}" unless raw_entries.length == 1

        assessment_rows = assessment_entries.length == 1 ? parse_assessment_rows(assessment_entries.first, audit_errors) : []
        raw_summary = raw_entries.length == 1 ? parse_raw(raw_entries.first, audit_errors) : empty_raw_summary

        adventure_id = single_value(assessment_rows, "adventure_id", audit_errors, "adventure_id")
        dimension = logical_dimension(assessment_rows, audit_errors)
        values = assessment_rows.map { |row| { "metric" => row["metric"], "value" => coerce_value(row["value"]) } }
        rationales = assessment_rows.map do |row|
          {
            "metric" => row["metric"],
            "rationale" => row["rationale"],
            "adjacent_lower_reason" => row["adjacent_lower_reason"],
            "adjacent_higher_reason" => row["adjacent_higher_reason"]
          }
        end

        consistency = compare_raw_to_assessment(raw_summary["structured_content"], assessment_rows)
        consistency.fetch("errors").each { |message| audit_errors << message }

        {
          "schema_version" => "af-horizontal-ingest-record/v0.1",
          "adapter" => ADAPTER_NAME,
          "ordinal" => ordinal,
          "manifest" => manifest_path,
          "experiment" => experiment,
          "adventure_id" => adventure_id,
          "dimension" => dimension,
          "score" => single_interpretive_score(assessment_rows),
          "values" => values,
          "rationales" => rationales,
          "assessment_rows" => assessment_rows,
          "raw" => raw_summary,
          "raw_assessment_consistency" => consistency,
          "provenance" => provenance(manifest_entry, assessment_entries.first, raw_entries.first),
          "mechanical_status" => audit_errors.empty? ? "valid" : "error",
          "audit_errors" => audit_errors.uniq
        }
      rescue CSV::MalformedCSVError, JSON::ParserError => e
        base_error_record(ordinal, manifest_path, "parse failure: #{e.message}")
      end

      def base_error_record(ordinal, manifest_path, message)
        {
          "schema_version" => "af-horizontal-ingest-record/v0.1",
          "adapter" => ADAPTER_NAME,
          "ordinal" => ordinal,
          "manifest" => manifest_path,
          "experiment" => nil,
          "adventure_id" => nil,
          "dimension" => nil,
          "score" => nil,
          "values" => [],
          "rationales" => [],
          "assessment_rows" => [],
          "raw" => empty_raw_summary,
          "raw_assessment_consistency" => { "checked" => false, "matches" => [], "errors" => [] },
          "provenance" => [],
          "mechanical_status" => "error",
          "audit_errors" => [message]
        }
      end

      def manifest_name(body, fallback)
        line = body.lines.find { |candidate| candidate.match?(/^\s*name\s*:/) }
        return File.basename(fallback, File.extname(fallback)) unless line

        line.split(":", 2).last.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
      end

      def parse_assessment_rows(entry, audit_errors)
        rows = CSV.read(entry.absolute_path, headers: true).map(&:to_h)
        audit_errors << "assessment CSV contains no data rows" if rows.empty?
        rows
      end

      def parse_raw(entry, audit_errors)
        payload = JSON.parse(File.read(entry.absolute_path, encoding: "UTF-8"))
        choices = Array(payload["choices"])
        choice = choices.first || {}
        message = choice["message"] || {}
        content = message["content"]
        structured_content = nil
        structured_present = content.is_a?(String) && !content.strip.empty?

        if structured_present
          begin
            structured_content = JSON.parse(content)
          rescue JSON::ParserError => e
            audit_errors << "raw structured content is not valid JSON: #{e.message}"
            structured_content = content
          end
        else
          audit_errors << "raw response contains no structured message content"
        end

        {
          "provider_model" => payload["model"],
          "finish_reason" => choice["finish_reason"],
          "structured_content_present" => structured_present,
          "structured_content" => structured_content,
          "reasoning" => message["reasoning"],
          "usage" => payload["usage"]
        }
      end

      def empty_raw_summary
        {
          "provider_model" => nil,
          "finish_reason" => nil,
          "structured_content_present" => false,
          "structured_content" => nil,
          "reasoning" => nil,
          "usage" => nil
        }
      end

      def single_value(rows, key, audit_errors, label)
        values = rows.map { |row| row[key].to_s.strip }.reject(&:empty?).uniq
        audit_errors << "assessment rows contain #{values.length} distinct #{label} values" unless values.length == 1
        values.one? ? values.first : nil
      end

      def logical_dimension(rows, audit_errors)
        metrics = rows.map { |row| row["metric"].to_s.strip }.reject(&:empty?).uniq
        return "Levels" if metrics.sort == ["Level End", "Level Start"]
        return metrics.first if metrics.length == 1

        audit_errors << "cannot resolve one logical dimension from metrics #{metrics.inspect}"
        nil
      end

      def single_interpretive_score(rows)
        return nil unless rows.length == 1 && rows.first["metric_kind"] == "interpretive"

        value = rows.first["value"].to_s
        value.match?(/\A-?\d+\z/) ? value.to_i : nil
      end

      def coerce_value(value)
        text = value.to_s
        text.match?(/\A-?\d+\z/) ? text.to_i : value
      end

      def compare_raw_to_assessment(structured, rows)
        return { "checked" => false, "matches" => [], "errors" => ["cannot compare assessment to missing/unparsed structured content"] } unless structured.is_a?(Hash)

        raw_assessments = raw_assessments_by_metric(structured)
        matches = []
        errors = []
        rows.each do |row|
          metric = row["metric"]
          unless raw_assessments.key?(metric)
            errors << "raw structured content does not contain metric #{metric.inspect}"
            next
          end

          raw = raw_assessments[metric]
          csv_value = coerce_value(row["value"])
          metric_errors = []
          if raw["value"].to_s != csv_value.to_s
            metric_errors << "raw/assessment value mismatch for #{metric}: raw=#{raw['value'].inspect}, csv=#{csv_value.inspect}"
          end

          raw_rationale = raw["rationale"].to_s
          csv_rationale = row["rationale"].to_s
          if raw_rationale.empty?
            metric_errors << "raw structured content has no rationale for #{metric}"
          elsif raw_rationale != csv_rationale
            metric_errors << "raw/assessment rationale mismatch for #{metric}"
          end

          if metric_errors.empty?
            matches << metric
          else
            errors.concat(metric_errors)
          end
        end
        { "checked" => true, "matches" => matches, "errors" => errors }
      end

      def raw_assessments_by_metric(structured)
        values = {}
        Array(structured["dimensions"]).each do |item|
          next unless item.is_a?(Hash) && item["dimension"]
          values[item["dimension"]] = { "value" => item["score"], "rationale" => item["rationale"] }
        end
        if structured["sessions"].is_a?(Hash)
          item = structured["sessions"]
          values["# of Sessions"] = { "value" => item["normalized_sessions"], "rationale" => item["rationale"] }
        end
        if structured["level_start"].is_a?(Hash)
          item = structured["level_start"]
          values["Level Start"] = { "value" => item["value"], "rationale" => item["rationale"] }
        end
        if structured["level_end"].is_a?(Hash)
          item = structured["level_end"]
          values["Level End"] = { "value" => item["value"], "rationale" => item["rationale"] }
        end
        values
      end

      def provenance(*entries)
        entries.compact.map do |entry|
          {
            "source_path" => entry.relative_path,
            "source_sha256" => entry.sha256,
            "bytes" => entry.bytes
          }
        end
      end

      def duplicate_findings(records)
        groups = records.select { |record| record["adventure_id"] && record["dimension"] }
                        .group_by { |record| [record["adventure_id"], record["dimension"]] }
        duplicate_groups = groups.select { |_key, matches| matches.length > 1 }
        duplicates = duplicate_groups.keys.map { |key| key.join(" / ") }.sort
        conflicts = duplicate_groups.select do |_key, matches|
          matches.map { |record| record["values"] }.uniq.length > 1
        end.keys.map { |key| key.join(" / ") }.sort
        [duplicates, conflicts]
      end

      def consumed_paths(records)
        paths = [SCOPE_FILE]
        records.each do |record|
          paths << record["manifest"]
          record.fetch("provenance", []).each { |item| paths << item["source_path"] }
        end
        paths.compact.uniq
      end
    end
  end
end
