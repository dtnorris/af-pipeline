# frozen_string_literal: true

module AfDataPipeline
  class HorizontalReviewWriter
    def initialize(output_dir)
      @output_dir = File.expand_path(PrivateDataRoot.destination!(output_dir))
    end

    def write!(entries:, extraction:, source:, source_type:)
      FileUtils.mkdir_p(@output_dir)
      write_jsonl("inventory.jsonl", entries.map(&:to_h))
      write_jsonl("results.jsonl", extraction.records)
      write_review(extraction)
      write_integrity(entries:, extraction:, source:, source_type:)
    end

    private

    def write_jsonl(name, rows)
      File.open(File.join(@output_dir, name), "w") do |file|
        rows.each { |row| file.puts(JSON.generate(row)) }
      end
    end

    def write_review(extraction)
      File.open(File.join(@output_dir, "audit_review.md"), "w") do |file|
        file.puts("# AdventureFinder Horizontal Discovery Review Packet")
        file.puts
        file.puts("Generated mechanically by af-data-pipeline. No score is editorially accepted by this artifact.")
        file.puts
        file.puts("- Selected logical results: #{extraction.records.length}")
        file.puts("- Declared inclusive cutoff: `#{extraction.scope.inclusive_cutoff}`") if extraction.scope.inclusive_cutoff
        file.puts("- Declared first excluded: `#{extraction.scope.first_excluded}`") if extraction.scope.first_excluded
        file.puts

        extraction.records.each do |record|
          file.puts("## #{record['ordinal']} — #{record['adventure_id'] || 'UNKNOWN'} — #{record['dimension'] || 'UNKNOWN'}")
          file.puts
          file.puts("**Mechanical status:** #{record['mechanical_status'].upcase}")
          file.puts
          file.puts("**Manifest:** `#{record['manifest']}`")
          file.puts

          unless record["audit_errors"].empty?
            file.puts("### Mechanical audit errors")
            file.puts
            record["audit_errors"].each { |message| file.puts("- #{message}") }
            file.puts
          end

          file.puts("### Proposed assessment")
          file.puts
          record["assessment_rows"].each do |row|
            file.puts("#### #{row['metric']} = #{row['value']}")
            file.puts
            file.puts(row["rationale"].to_s)
            file.puts
            unless row["adjacent_lower_reason"].to_s.empty?
              file.puts("**Adjacent lower:** #{row['adjacent_lower_reason']}")
              file.puts
            end
            unless row["adjacent_higher_reason"].to_s.empty?
              file.puts("**Adjacent higher:** #{row['adjacent_higher_reason']}")
              file.puts
            end
          end

          structured = record.dig("raw", "structured_content")
          if structured
            file.puts("### Raw structured response")
            file.puts
            file.puts("```json")
            file.puts(structured.is_a?(String) ? structured : JSON.pretty_generate(structured))
            file.puts("```")
            file.puts
          end

          reasoning = record.dig("raw", "reasoning")
          unless reasoning.to_s.strip.empty?
            file.puts("### Raw model reasoning")
            file.puts
            file.puts(reasoning)
            file.puts
          end

          file.puts("### Provenance")
          file.puts
          record["provenance"].each do |item|
            file.puts("- `#{item['source_path']}` — `#{item['source_sha256']}`")
          end
          file.puts
        end
      end
    end

    def write_integrity(entries:, extraction:, source:, source_type:)
      supporting = entries.map(&:relative_path) - extraction.consumed_paths
      report = {
        "schema_version" => "af-horizontal-integrity-report/v0.1",
        "adapter" => Adapters::HorizontalDiscoveryV1::ADAPTER_NAME,
        "source" => File.expand_path(source),
        "source_type" => source_type,
        "source_sha256" => source_hash(source),
        "files_scanned" => entries.length,
        "scope" => extraction.scope.to_h,
        "logical_results_discovered" => extraction.all_records.length,
        "records_selected" => extraction.records.length,
        "records_after_boundary" => extraction.excluded_records.length,
        "boundary" => extraction.records.last && {
          "ordinal" => extraction.records.last["ordinal"],
          "adventure_id" => extraction.records.last["adventure_id"],
          "dimension" => extraction.records.last["dimension"],
          "manifest" => extraction.records.last["manifest"]
        },
        "mechanically_valid_records" => extraction.records.count { |record| record["mechanical_status"] == "valid" },
        "mechanically_invalid_records" => extraction.records.count { |record| record["mechanical_status"] != "valid" },
        "duplicates" => extraction.duplicates,
        "conflicts" => extraction.conflicts,
        "errors" => extraction.errors,
        "supporting_files_not_consumed" => supporting
      }
      File.write(File.join(@output_dir, "integrity_report.json"), JSON.pretty_generate(report) + "\n")
    end

    def source_hash(source)
      path = File.expand_path(source)
      File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
    end
  end
end
