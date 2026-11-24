# frozen_string_literal: true

module AfDataPipeline
  class ProductionReviewWriter
    def initialize(output_dir)
      @output_dir = File.expand_path(PrivateDataRoot.destination!(output_dir))
    end

    def write!(entries:, extraction:, source:, source_type:)
      FileUtils.mkdir_p(@output_dir)
      write_jsonl("inventory.jsonl", entries.map(&:to_h))
      write_jsonl("runs.jsonl", extraction.runs)
      write_jsonl("candidates.jsonl", extraction.candidates)
      write_jsonl("holds.jsonl", extraction.holds)
      write_review(extraction)
      write_integrity(entries:, extraction:, source:, source_type:)
    end

    private

    def write_jsonl(name, rows)
      File.open(File.join(@output_dir, name), "w", encoding: "UTF-8") do |file|
        rows.each { |row| file.puts(JSON.generate(row)) }
      end
    end

    def write_review(extraction)
      File.open(File.join(@output_dir, "audit_review.md"), "w", encoding: "UTF-8") do |file|
        file.puts("# AdventureFinder Production Snapshot Review Packet")
        file.puts
        file.puts("Generated mechanically by af-data-pipeline. No candidate is editorially accepted by this artifact.")
        file.puts
        file.puts("- Run packages discovered: #{extraction.runs.length}")
        file.puts("- Mechanically valid runs: #{extraction.runs.count { |run| run['mechanical_status'] == 'valid' }}")
        file.puts("- Incomplete runs: #{extraction.runs.count { |run| run['mechanical_status'] == 'incomplete' }}")
        file.puts("- Mechanically invalid runs: #{extraction.runs.count { |run| run['mechanical_status'] == 'error' }}")
        file.puts("- Complete production candidates: #{extraction.candidates.length}")
        file.puts("- Holds requiring review: #{extraction.holds.length}")
        file.puts("- Complete assessment outcomes: #{extraction.candidates.length + extraction.holds.length}")
        file.puts("- Unique candidate keys: #{extraction.candidates.map { |candidate| candidate['candidate_key'] }.uniq.length}")
        file.puts("- Expected candidates: #{extraction.expected_candidates}") if extraction.expected_candidates
        file.puts("- Mechanical errors: #{extraction.errors.length}")
        file.puts

        unless extraction.errors.empty?
          file.puts("## Mechanical integrity findings")
          file.puts
          extraction.errors.each { |message| file.puts("- #{message}") }
          file.puts
        end

        incomplete_runs = extraction.runs.select { |run| run["mechanical_status"] == "incomplete" }
        unless incomplete_runs.empty?
          file.puts("## Incomplete executions")
          file.puts
          file.puts("These run packages did not report successful completion. They produce no candidate or HOLD and are not mechanical integrity errors.")
          file.puts
          incomplete_runs.each do |run|
            dimensions = Array(run["dimensions"]).join(", ")
            file.puts("- `#{run['adventure_id']}` — #{dimensions} — `#{run['experiment_name']}` / `#{run['lme_run_id']}`")
          end
          file.puts
        end

        unless extraction.holds.empty?
          file.puts("## Holds requiring review")
          file.puts
          extraction.holds.each_with_index do |hold, index|
            file.puts("### H#{index + 1} — #{hold['adventure_id']} — #{hold['dimension']}")
            file.puts
            file.puts("**Assessment state:** #{hold['assessment_state']}")
            file.puts("**Disposition:** HOLD — source verification required")
            file.puts("**Experiment:** `#{hold['experiment_name']}`")
            file.puts("**LME run:** `#{hold['lme_run_id']}`")
            file.puts("**Model:** `#{hold['provider']} / #{hold['model']}`")
            file.puts
            file.puts("### Reason")
            file.puts
            file.puts(hold["rationale"])
            file.puts
            file.puts("### Provenance")
            file.puts
            hold.fetch("provenance").values.compact.each do |item|
              file.puts("- `#{item['source_path']}` — `#{item['source_sha256']}`")
            end
            file.puts
          end
        end

        extraction.candidates.each_with_index do |candidate, index|
          file.puts("## #{index + 1} — #{candidate['adventure_id']} — #{candidate['dimension']}")
          file.puts
          file.puts("**Proposed value:** #{candidate['value']}")
          if candidate["range_low"] || candidate["range_high"]
            file.puts("**Practical range:** #{candidate['range_low']}–#{candidate['range_high']}")
          end
          file.puts("**Assessment state:** #{candidate['assessment_state']}")
          file.puts("**Experiment:** `#{candidate['experiment_name']}`")
          file.puts("**LME run:** `#{candidate['lme_run_id']}`")
          file.puts("**Model:** `#{candidate['provider']} / #{candidate['model']}`")
          file.puts
          file.puts("### Reason")
          file.puts
          file.puts(candidate["rationale"])
          file.puts
          unless candidate["adjacent_lower_reason"].to_s.strip.empty?
            file.puts("**Adjacent lower:** #{candidate['adjacent_lower_reason']}")
            file.puts
          end
          unless candidate["adjacent_higher_reason"].to_s.strip.empty?
            file.puts("**Adjacent higher:** #{candidate['adjacent_higher_reason']}")
            file.puts
          end
          file.puts("### Provenance")
          file.puts
          candidate.fetch("provenance").values.compact.each do |item|
            file.puts("- `#{item['source_path']}` — `#{item['source_sha256']}`")
          end
          file.puts
        end
      end
    end

    def write_integrity(entries:, extraction:, source:, source_type:)
      valid_runs = extraction.runs.select { |run| run["mechanical_status"] == "valid" }
      incomplete_runs = extraction.runs.select { |run| run["mechanical_status"] == "incomplete" }
      invalid_runs = extraction.runs.select { |run| run["mechanical_status"] == "error" }
      supporting = entries.map(&:relative_path) - extraction.consumed_paths
      top_level_folders = top_level_snapshot_folders(entries)
      run_top_level_folders = extraction.runs.filter_map do |run|
        run_path = run["run_path"].to_s
        run_path.empty? ? nil : run_path.split("/", 2).first
      end.uniq.sort
      non_run_top_level_folders = top_level_folders - run_top_level_folders
      report = {
        "schema_version" => "af-production-snapshot-integrity-report/v0.1",
        "adapter" => Adapters::ProductionSnapshotV1::ADAPTER_NAME,
        "read_only" => true,
        "source" => File.expand_path(source),
        "source_type" => source_type,
        "source_sha256" => source_hash(source),
        "files_scanned" => entries.length,
        "top_level_snapshot_folders" => top_level_folders.length,
        "top_level_folders_with_run_packages" => run_top_level_folders.length,
        "top_level_folders_without_run_packages" => non_run_top_level_folders.length,
        "top_level_non_run_folders" => non_run_top_level_folders,
        "run_packages_discovered" => extraction.runs.length,
        "mechanically_valid_runs" => valid_runs.length,
        "incomplete_runs" => incomplete_runs.length,
        "mechanically_invalid_runs" => invalid_runs.length,
        "incomplete_run_details" => incomplete_runs.map do |run|
          {
            "adventure_id" => run["adventure_id"],
            "dimensions" => run["dimensions"],
            "experiment_name" => run["experiment_name"],
            "lme_run_id" => run["lme_run_id"],
            "run_path" => run["run_path"],
            "model" => run["model"]
          }
        end,
        "candidates" => extraction.candidates.length,
        "holds" => extraction.holds.length,
        "assessment_outcomes" => extraction.candidates.length + extraction.holds.length,
        "unique_candidate_keys" => extraction.candidates.map { |candidate| candidate["candidate_key"] }.uniq.length,
        "expected_candidates" => extraction.expected_candidates,
        "expectation_match" => extraction.expectation_match,
        "duplicates" => extraction.duplicates,
        "conflicts" => extraction.conflicts,
        "unclaimed_assessment_files" => extraction.unclaimed_assessments,
        "errors" => extraction.errors,
        "supporting_files_not_consumed" => supporting
      }
      File.write(File.join(@output_dir, "integrity_report.json"), JSON.pretty_generate(report) + "\n")
    end

    def top_level_snapshot_folders(entries)
      entries.filter_map do |entry|
        parts = entry.relative_path.split("/", 2)
        parts.length > 1 ? parts.first : nil
      end.uniq.sort
    end

    def source_hash(source)
      path = File.expand_path(source)
      File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
    end
  end
end
