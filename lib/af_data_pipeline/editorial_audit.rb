# frozen_string_literal: true

module AfDataPipeline
  # Creates and validates the human editorial decision ledger that sits between
  # a mechanically clean production-review packet and any future AMC mutation.
  #
  # This layer never changes proposed values and never calls an LLM. ACCEPT
  # means the reviewer has inspected the proposed numeric value against its
  # supplied rationale/evidence and accepts that exact candidate. HOLD and
  # REJECT leave AMC untouched.
  class EditorialAudit
    MANIFEST_SCHEMA = "af-editorial-audit-manifest/v0.1"
    DECISION_SCHEMA = "af-editorial-decision/v0.1"
    REPORT_SCHEMA = "af-editorial-audit-report/v0.1"
    CANDIDATE_DECISIONS = %w[ACCEPT HOLD REJECT].freeze
    LOCKED_SOURCE_HOLD_DECISION = "HOLD"

    LEDGER_HEADERS = %w[
      record_type
      record_key
      record_sha256
      adventure_id
      adventure_title
      dimension
      proposed_value
      assessment_state
      source_review_disposition
      source_hold_reason
      metric_review_flags
      package_review_flags
      provider
      model
      experiment_name
      lme_run_id
      rationale
      adjacent_lower_reason
      adjacent_higher_reason
      evidence_json
      source_assessment_path
      source_assessment_sha256
      raw_response_path
      raw_response_sha256
      editorial_decision
      editorial_note
    ].freeze

    Validation = Data.define(
      :rows,
      :accepted,
      :held,
      :rejected,
      :source_holds,
      :pending,
      :errors,
      :complete
    )

    def self.initialize!(review_dir:, audit_dir:)
      new(review_dir:).initialize!(audit_dir:)
    end

    def self.validate!(audit_dir:, output_dir:)
      manifest_path = File.join(File.expand_path(audit_dir), "audit_manifest.json")
      raise ValidationError, "missing audit manifest: #{manifest_path}" unless File.file?(manifest_path)

      manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
      source_review = resolve_review_dir(File.expand_path(audit_dir), manifest)
      new(review_dir: source_review).validate!(audit_dir:, output_dir:, manifest:)
    rescue JSON::ParserError => e
      raise ValidationError, "audit manifest parse failure: #{e.message}"
    end

    def self.resolve_review_dir(audit_dir, manifest)
      relative = manifest["source_review_relative_path"].to_s
      raise ValidationError, "audit manifest source_review_relative_path is blank" if relative.strip.empty?

      File.expand_path(relative, audit_dir)
    end

    def initialize(review_dir:)
      @review_dir = File.expand_path(review_dir)
    end

    def initialize!(audit_dir:)
      audit_dir = File.expand_path(PrivateDataRoot.destination!(audit_dir))
      validate_review_packet!
      refuse_existing_ledger!(audit_dir)

      candidates = read_jsonl(review_file("candidates.jsonl"))
      holds = read_jsonl(review_file("holds.jsonl"))
      validate_source_records!(candidates, holds)
      manifest = build_manifest(audit_dir, candidates, holds)

      FileUtils.mkdir_p(audit_dir)
      write_ledger(File.join(audit_dir, "editorial_decisions.csv"), candidates, holds)
      File.write(File.join(audit_dir, "audit_manifest.json"), JSON.pretty_generate(manifest) + "\n")
      write_instructions(File.join(audit_dir, "README.md"), manifest)

      manifest
    end

    def validate!(audit_dir:, output_dir:, manifest: nil)
      audit_dir = File.expand_path(audit_dir)
      output_dir = File.expand_path(PrivateDataRoot.destination!(output_dir))
      manifest ||= JSON.parse(File.read(File.join(audit_dir, "audit_manifest.json"), encoding: "UTF-8"))

      errors = []
      validate_manifest(manifest, errors)
      validate_review_hashes(manifest, errors)

      candidates = safe_read_jsonl(review_file("candidates.jsonl"), errors)
      source_holds = safe_read_jsonl(review_file("holds.jsonl"), errors)
      expected_rows = expected_ledger_rows(candidates, source_holds)
      ledger_path = File.join(audit_dir, "editorial_decisions.csv")
      ledger_rows = read_ledger(ledger_path, errors)
      validate_ledger_shape(expected_rows, ledger_rows, errors)

      decisions = normalize_decisions(expected_rows, ledger_rows, errors)
      accepted = decisions.select { |row| row["record_type"] == "candidate" && row["editorial_decision"] == "ACCEPT" }
      held = decisions.select { |row| row["record_type"] == "candidate" && row["editorial_decision"] == "HOLD" }
      rejected = decisions.select { |row| row["record_type"] == "candidate" && row["editorial_decision"] == "REJECT" }
      locked_holds = decisions.select { |row| row["record_type"] == "source_hold" }
      pending = decisions.select { |row| row["record_type"] == "candidate" && blank?(row["editorial_decision"]) }
      complete = errors.empty? && pending.empty?

      validation = Validation.new(
        rows: decisions,
        accepted:,
        held:,
        rejected:,
        source_holds: locked_holds,
        pending:,
        errors: errors.uniq,
        complete:
      )

      write_validation_output(output_dir, validation, candidates, source_holds, manifest)
      validation
    rescue JSON::ParserError => e
      raise ValidationError, "audit source parse failure: #{e.message}"
    end

    private

    def validate_review_packet!
      required = %w[integrity_report.json candidates.jsonl holds.jsonl]
      missing = required.reject { |name| File.file?(review_file(name)) }
      raise ValidationError, "production review packet missing: #{missing.join(', ')}" unless missing.empty?

      report = JSON.parse(File.read(review_file("integrity_report.json"), encoding: "UTF-8"))
      errors = Array(report["errors"])
      raise ValidationError, "production review has mechanical errors: #{errors.length}" unless errors.empty?
      if report.key?("expectation_match") && report["expectation_match"] != true
        raise ValidationError, "production review candidate expectation does not match"
      end
      if report.fetch("mechanically_invalid_runs", 0).to_i.positive?
        raise ValidationError, "production review contains mechanically invalid runs"
      end

      candidates = read_jsonl(review_file("candidates.jsonl"))
      holds = read_jsonl(review_file("holds.jsonl"))
      expected_candidates = report["candidates"]
      expected_holds = report["holds"]
      if !expected_candidates.nil? && candidates.length != expected_candidates.to_i
        raise ValidationError, "candidates.jsonl contains #{candidates.length} rows; integrity report says #{expected_candidates}"
      end
      if !expected_holds.nil? && holds.length != expected_holds.to_i
        raise ValidationError, "holds.jsonl contains #{holds.length} rows; integrity report says #{expected_holds}"
      end
    rescue JSON::ParserError => e
      raise ValidationError, "production review integrity report parse failure: #{e.message}"
    end

    def validate_source_records!(candidates, holds)
      candidate_keys = candidates.map { |candidate| candidate["candidate_key"] }
      hold_keys = holds.map { |hold| hold["hold_key"] }
      duplicate_candidate_keys = candidate_keys.tally.select { |_key, count| count > 1 }.keys
      duplicate_hold_keys = hold_keys.tally.select { |_key, count| count > 1 }.keys
      overlaps = candidate_keys & hold_keys

      raise ValidationError, "duplicate candidate keys in production review: #{duplicate_candidate_keys.join(', ')}" unless duplicate_candidate_keys.empty?
      raise ValidationError, "duplicate hold keys in production review: #{duplicate_hold_keys.join(', ')}" unless duplicate_hold_keys.empty?
      raise ValidationError, "keys appear as both candidate and source hold: #{overlaps.join(', ')}" unless overlaps.empty?
    end

    def refuse_existing_ledger!(audit_dir)
      existing = %w[editorial_decisions.csv audit_manifest.json].select { |name| File.exist?(File.join(audit_dir, name)) }
      return if existing.empty?

      raise ValidationError, "refusing to overwrite existing editorial audit files: #{existing.join(', ')}"
    end

    def build_manifest(audit_dir, candidates, holds)
      {
        "schema_version" => MANIFEST_SCHEMA,
        "source_review_relative_path" => Pathname.new(@review_dir).relative_path_from(Pathname.new(audit_dir)).to_s,
        "source_files" => {
          "integrity_report.json" => file_manifest("integrity_report.json"),
          "candidates.jsonl" => file_manifest("candidates.jsonl", rows: candidates.length),
          "holds.jsonl" => file_manifest("holds.jsonl", rows: holds.length)
        },
        "candidate_count" => candidates.length,
        "source_hold_count" => holds.length,
        "audit_row_count" => candidates.length + holds.length,
        "candidate_decisions" => CANDIDATE_DECISIONS,
        "source_hold_decision" => LOCKED_SOURCE_HOLD_DECISION
      }
    end

    def file_manifest(name, rows: nil)
      path = review_file(name)
      item = {
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "bytes" => File.size(path)
      }
      item["rows"] = rows unless rows.nil?
      item
    end

    def write_ledger(path, candidates, holds)
      CSV.open(path, "w", encoding: "UTF-8", write_headers: true, headers: LEDGER_HEADERS) do |csv|
        candidates.each { |candidate| csv << ledger_row("candidate", candidate, decision: nil) }
        holds.each { |hold| csv << ledger_row("source_hold", hold, decision: LOCKED_SOURCE_HOLD_DECISION) }
      end
    end

    def expected_ledger_rows(candidates, holds)
      rows = {}
      candidates.each do |candidate|
        row = ledger_row("candidate", candidate, decision: nil)
        rows[row.fetch("record_key")] = row
      end
      holds.each do |hold|
        row = ledger_row("source_hold", hold, decision: LOCKED_SOURCE_HOLD_DECISION)
        rows[row.fetch("record_key")] = row
      end
      rows
    end

    def ledger_row(record_type, record, decision:)
      provenance = record["provenance"].to_h
      assessment = provenance["assessment"].to_h
      raw_response = provenance["raw_response"].to_h
      key = record_type == "candidate" ? record["candidate_key"] : record["hold_key"]
      immutable = {
        "record_type" => record_type,
        "record_key" => key,
        "record_sha256" => record_sha(record),
        "adventure_id" => record["adventure_id"],
        "adventure_title" => record["adventure_title"],
        "dimension" => record["dimension"],
        "proposed_value" => format_cell(record["value"]),
        "assessment_state" => record["assessment_state"],
        "source_review_disposition" => record["review_disposition"],
        "source_hold_reason" => record["hold_reason"],
        "metric_review_flags" => record["metric_review_flags"],
        "package_review_flags" => record["package_review_flags"],
        "provider" => record["provider"],
        "model" => record["model"],
        "experiment_name" => record["experiment_name"],
        "lme_run_id" => record["lme_run_id"],
        "rationale" => record["rationale"],
        "adjacent_lower_reason" => record["adjacent_lower_reason"],
        "adjacent_higher_reason" => record["adjacent_higher_reason"],
        "evidence_json" => JSON.generate(Array(record["evidence"])),
        "source_assessment_path" => assessment["source_path"],
        "source_assessment_sha256" => assessment["source_sha256"],
        "raw_response_path" => raw_response["source_path"],
        "raw_response_sha256" => raw_response["source_sha256"],
        "editorial_decision" => decision,
        "editorial_note" => nil
      }
      LEDGER_HEADERS.to_h { |header| [header, immutable[header]] }
    end

    def record_sha(record)
      Digest::SHA256.hexdigest(JSON.generate(record))
    end

    def format_cell(value)
      value.nil? ? nil : value.to_s
    end

    def write_instructions(path, manifest)
      File.write(path, <<~MD)
        # AdventureFinder Editorial Audit

        This directory is durable editorial state. It is intentionally separate from generated `output/` review packets.

        Source production review: `#{manifest['source_review_relative_path']}`

        ## Decision contract

        Edit only `editorial_decision` and `editorial_note` in `editorial_decisions.csv`.

        - `ACCEPT` — the mechanically valid result is coherent enough to support the proposed value and the stored result contains no concrete reason to think that numeric value itself is unreliable.
        - `HOLD` — do not mutate AMC; the stored result itself gives a concrete reason the numeric value may be unreliable and targeted re-review is required. `editorial_note` is required.
        - `REJECT` — do not mutate AMC; the proposed value is affirmatively unsupported. `editorial_note` is required.
        - Blank — candidate has not yet been audited.
        - `source_hold` rows are already mechanically valid source-verification holds and are locked to `HOLD`.

        Editorial audit is a **production sanity gate, not a second scoring pass**. Mechanically valid numeric results should normally be accepted. The reviewer is checking for a concrete reason not to trust the proposed number, not deciding whether they personally prefer an adjacent score or whether the explanation is maximally rigorous.

        Do **not** HOLD merely because adjacent-anchor discussion is imperfect, another nearby score also seems plausible, a weak proxy appears as secondary support, the reviewer would phrase the reasoning differently, or an upstream `REVIEW_REQUIRED` flag is present. Those observations may be useful model-QA signals without blocking production ingest.

        Use `HOLD` only when the stored result itself gives a concrete reason the numeric value may be unreliable: explicit unresolved/source insufficiency; a rationale that materially contradicts the chosen value; construct/rubric misuse that materially drives the numeric selection; severe internal inconsistency that prevents understanding why the number was chosen; or a known severe model failure visibly affecting the result. Deep source adjudication is a separate follow-up for those exceptional cases, not part of routine ingest.

        Do not edit proposed values or evidence fields in place. If a score is wrong, HOLD or REJECT it and correct/rescore upstream so provenance remains intact.

        Validate the ledger with `bin/af-data editorial-audit-validate AUDIT_DIR --output OUTPUT_DIR`.
        Promotion-ready `accepted_candidates.jsonl` is emitted only when every candidate has a decision and the ledger validates without errors.
      MD
    end

    def validate_manifest(manifest, errors)
      errors << "unsupported audit manifest schema #{manifest['schema_version'].inspect}" unless manifest["schema_version"] == MANIFEST_SCHEMA
      source_files = manifest["source_files"]
      errors << "audit manifest source_files is missing" unless source_files.is_a?(Hash)
    end

    def validate_review_hashes(manifest, errors)
      source_files = manifest["source_files"].to_h
      source_files.each do |name, expected|
        path = review_file(name)
        unless File.file?(path)
          errors << "source review file missing: #{name}"
          next
        end
        actual_sha = Digest::SHA256.file(path).hexdigest
        errors << "source review file changed: #{name}" unless actual_sha == expected["sha256"]
      end
    end

    def safe_read_jsonl(path, errors)
      return [] unless File.file?(path)

      read_jsonl(path)
    rescue JSON::ParserError => e
      errors << "JSONL parse failure #{File.basename(path)}: #{e.message}"
      []
    end

    def read_jsonl(path)
      File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
    end

    def read_ledger(path, errors)
      unless File.file?(path)
        errors << "editorial ledger missing: #{path}"
        return []
      end

      table = CSV.read(path, headers: true, encoding: "UTF-8")
      actual_headers = table.headers
      errors << "editorial ledger headers changed" unless actual_headers == LEDGER_HEADERS
      table.map(&:to_h)
    rescue CSV::MalformedCSVError => e
      errors << "editorial ledger CSV parse failure: #{e.message}"
      []
    end

    def validate_ledger_shape(expected_rows, ledger_rows, errors)
      keys = ledger_rows.map { |row| row["record_key"] }
      duplicates = keys.tally.select { |_key, count| count > 1 }.keys
      errors << "duplicate editorial ledger keys: #{duplicates.join(', ')}" unless duplicates.empty?

      expected_keys = expected_rows.keys
      missing = expected_keys - keys
      extra = keys - expected_keys
      errors << "editorial ledger missing keys: #{missing.join(', ')}" unless missing.empty?
      errors << "editorial ledger contains unknown keys: #{extra.join(', ')}" unless extra.empty?
    end

    def normalize_decisions(expected_rows, ledger_rows, errors)
      ledger_by_key = ledger_rows.each_with_object({}) { |row, memo| memo[row["record_key"]] ||= row }
      expected_rows.keys.sort.filter_map do |key|
        expected = expected_rows.fetch(key)
        actual = ledger_by_key[key]
        next unless actual

        immutable_headers = LEDGER_HEADERS - %w[editorial_decision editorial_note]
        immutable_headers.each do |header|
          expected_value = expected[header].to_s
          actual_value = actual[header].to_s
          next if expected_value == actual_value

          errors << "#{key}: immutable ledger field #{header} changed"
        end

        decision = actual["editorial_decision"].to_s.strip.upcase
        note = actual["editorial_note"].to_s.strip
        if expected["record_type"] == "source_hold"
          unless decision == LOCKED_SOURCE_HOLD_DECISION
            errors << "#{key}: source_hold decision is locked to #{LOCKED_SOURCE_HOLD_DECISION}"
          end
        elsif !decision.empty? && !CANDIDATE_DECISIONS.include?(decision)
          errors << "#{key}: invalid editorial decision #{actual['editorial_decision'].inspect}"
        elsif %w[HOLD REJECT].include?(decision) && note.empty?
          errors << "#{key}: #{decision} requires editorial_note"
        end

        {
          "schema_version" => DECISION_SCHEMA,
          "record_type" => expected["record_type"],
          "record_key" => key,
          "record_sha256" => expected["record_sha256"],
          "adventure_id" => expected["adventure_id"],
          "dimension" => expected["dimension"],
          "proposed_value" => expected["proposed_value"].nil? ? nil : coerce_cell(expected["proposed_value"]),
          "editorial_decision" => decision.empty? ? nil : decision,
          "editorial_note" => note.empty? ? nil : note
        }
      end
    end

    def write_validation_output(output_dir, validation, candidates, source_holds, manifest)
      FileUtils.mkdir_p(output_dir)
      write_jsonl(File.join(output_dir, "editorial_decisions.jsonl"), validation.rows)

      report = {
        "schema_version" => REPORT_SCHEMA,
        "complete" => validation.complete,
        "source_candidate_count" => candidates.length,
        "source_hold_count" => source_holds.length,
        "audit_row_count" => validation.rows.length,
        "accepted" => validation.accepted.length,
        "held" => validation.held.length,
        "rejected" => validation.rejected.length,
        "source_holds" => validation.source_holds.length,
        "pending" => validation.pending.length,
        "errors" => validation.errors,
        "source_files" => manifest["source_files"]
      }
      File.write(File.join(output_dir, "editorial_audit_report.json"), JSON.pretty_generate(report) + "\n")

      return unless validation.complete

      candidates_by_key = candidates.to_h { |candidate| [candidate.fetch("candidate_key"), candidate] }
      source_holds_by_key = source_holds.to_h { |hold| [hold.fetch("hold_key"), hold] }
      write_jsonl(
        File.join(output_dir, "accepted_candidates.jsonl"),
        validation.accepted.map { |decision| candidates_by_key.fetch(decision.fetch("record_key")) }
      )
      write_jsonl(
        File.join(output_dir, "held_candidates.jsonl"),
        validation.held.map { |decision| candidates_by_key.fetch(decision.fetch("record_key")) }
      )
      write_jsonl(
        File.join(output_dir, "rejected_candidates.jsonl"),
        validation.rejected.map { |decision| candidates_by_key.fetch(decision.fetch("record_key")) }
      )
      write_jsonl(
        File.join(output_dir, "source_holds.jsonl"),
        validation.source_holds.map { |decision| source_holds_by_key.fetch(decision.fetch("record_key")) }
      )
    end

    def write_jsonl(path, rows)
      File.open(path, "w", encoding: "UTF-8") do |file|
        rows.each { |row| file.puts(JSON.generate(row)) }
      end
    end

    def review_file(name)
      File.join(@review_dir, name)
    end

    def coerce_cell(value)
      return Integer(value) if value.to_s.match?(/\A-?\d+\z/)
      return Float(value) if value.to_s.match?(/\A-?\d+(?:\.\d+)?\z/)

      value
    rescue ArgumentError
      value
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
