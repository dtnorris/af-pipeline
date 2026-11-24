# frozen_string_literal: true

require_relative "private_data_root"

require_relative "error"

module AfDataPipeline
  # Applies only validated editorial ACCEPT decisions to a new AMC workbook.
  # XLSX mutation is deliberately limited to the resolved catalog worksheet
  # and, only when necessary, an append-only cellXfs style addition.
  class AmcApply < AfXlsxFiles::AmcApply
    prepend XlsxFilesErrors.wrap(:apply!)
    singleton_class.prepend XlsxFilesErrors.wrap(:verify!, :reference_parts)

    # Keep helper failures inside the pipeline rescue contract, including
    # worksheets/styles returned by the owner's workbook implementation.
    class Worksheet < AfXlsxFiles::AmcApply::Worksheet
      PIPELINE_ERRORS = XlsxFilesErrors.wrap(*superclass.public_instance_methods(false))
      prepend PIPELINE_ERRORS
      prepend XlsxFilesErrors.wrap(:initialize)
    end

    class StyleTable < AfXlsxFiles::AmcApply::StyleTable
      PIPELINE_ERRORS = XlsxFilesErrors.wrap(*superclass.public_instance_methods(false))
      prepend PIPELINE_ERRORS
      prepend XlsxFilesErrors.wrap(:initialize)
    end

    class Workbook < AfXlsxFiles::AmcApply::Workbook
      prepend XlsxFilesErrors.wrap(*superclass.public_instance_methods(false), :initialize)

      # Return the owner's parsed sheet with pipeline exception translation.
      def sheet(part)
        super&.extend(Worksheet::PIPELINE_ERRORS)
      end

      # Return the owner's style table with pipeline exception translation.
      def styles
        super.extend(StyleTable::PIPELINE_ERRORS)
      end
    end

    COMMAND_SCHEMA = "af-data-amc-apply/v0.1"
    REPORT_SCHEMA = "af-amc-apply-report/v0.1"
    Result = Data.define(:output_path, :report_path, :report)
    AuthorizationValidation = Data.define(:source_holds, :held, :rejected, :pending)

    def self.apply!(audit_dir:, amc_path:, output_path:, report_path: nil, progress: nil)
      new(audit_dir:, amc_path:, output_path:, report_path:, progress:).apply!
    end

    # Alternate writer entry for a separately validated, immutable candidate
    # authorization set. It deliberately does not manufacture editorial ACCEPT
    # rows or weaken the existing human-ledger entry above.
    def self.apply_authorized!(authorized_candidates:, authorization:, accounting:, amc_path:, output_path:,
                               report_path: nil, progress: nil)
      new(
        audit_dir: nil,
        amc_path:,
        output_path:,
        report_path:,
        progress:,
        authorized_candidates:,
        authorization:,
        accounting:
      ).apply!
    end

    def self.default_report_path(output_path)
      expanded = File.expand_path(output_path)
      expanded.sub(/\.xlsx\z/i, "") + ".amc-apply-report.json"
    end

    # Public so a saved ledger can independently re-verify a promoted workbook.
    def self.verify!(source_amc:, output_amc:, records:, styles_appended: 0)
      source = Workbook.new(source_amc)
      output = Workbook.new(output_amc)
      errors = []

      errors << "XLSX package member order or membership changed" unless source.entry_names == output.entry_names
      written = records.select { |record| record.fetch("action") == "written" }
      already_present = records.select { |record| record.fetch("action") == "already_present" }
      authorized_cells = written.to_h { |record| [[record.fetch("sheet_part"), record.fetch("cell")], record] }
      allowed_parts = authorized_cells.keys.map(&:first).uniq
      allowed_parts << "xl/styles.xml" if styles_appended.positive?
      changed_parts = (source.member_hashes.keys | output.member_hashes.keys).select do |name|
        source.member_hashes[name] != output.member_hashes[name]
      end
      unexpected_parts = changed_parts - allowed_parts
      errors << "unexpected XLSX package members changed: #{unexpected_parts.join(', ')}" unless unexpected_parts.empty?

      errors << "workbook sheet names/order changed" unless source.sheet_identity == output.sheet_identity
      source.sheet_parts.each do |part|
        source_sheet = source.sheet(part)
        output_sheet = output.sheet(part)
        unless output_sheet
          errors << "worksheet missing after apply: #{part}"
          next
        end
        unless source_sheet.structure_signature == output_sheet.structure_signature
          errors << "worksheet structure changed outside cells: #{part}"
        end

        source_cells = source_sheet.cell_snapshots
        output_cells = output_sheet.cell_snapshots
        (source_cells.keys | output_cells.keys).each do |reference|
          next if authorized_cells.key?([part, reference])
          next if source_cells[reference] == output_cells[reference]

          errors << "unauthorized worksheet cell change: #{part}!#{reference}"
        end
      end

      written.each do |record|
        source_sheet = source.sheet(record.fetch("sheet_part"))
        sheet = output.sheet(record.fetch("sheet_part"))
        source_cell = source_sheet&.cell(record.fetch("cell"))
        cell = sheet&.cell(record.fetch("cell"))
        if !cell || !numeric_equal?(sheet.cell_numeric_value(cell), record.fetch("proposed_value"))
          errors << "written value verification failed: #{record.fetch('sheet')}!#{record.fetch('cell')}"
        end
        if cell && cell.attributes["s"].to_s != record.fetch("expected_style_index").to_s
          errors << "written style verification failed: #{record.fetch('sheet')}!#{record.fetch('cell')}"
        end
        if cell && sheet.cell_formula(cell)
          errors << "written target unexpectedly contains a formula: #{record.fetch('sheet')}!#{record.fetch('cell')}"
        end
        if cell && !sheet.written_cell_structure_preserved?(source_cell, cell)
          errors << "written target changed unauthorized cell structure: #{record.fetch('sheet')}!#{record.fetch('cell')}"
        end
        fill = cell && output.styles.fill_rgb(cell.attributes["s"] || "0")
        unless fill == REQUIRED_FILL
          errors << "written fill verification failed: #{record.fetch('sheet')}!#{record.fetch('cell')} (#{fill.inspect})"
        end
      end

      already_present.each do |record|
        source_sheet = source.sheet(record.fetch("sheet_part"))
        output_sheet = output.sheet(record.fetch("sheet_part"))
        source_cell = source_sheet&.cell(record.fetch("cell"))
        output_cell = output_sheet&.cell(record.fetch("cell"))
        unless source_cell && output_cell && source_sheet.snapshot(source_cell) == output_sheet.snapshot(output_cell)
          errors << "already-present cell changed: #{record.fetch('sheet')}!#{record.fetch('cell')}"
        end
      end

      if styles_appended.positive? && !source.styles.append_only_match?(output.styles, styles_appended)
        errors << "styles.xml change was not the expected append-only cellXfs mutation"
      end

      raise ValidationError, "AMC post-write verification failed:\n- #{errors.join("\n- ")}" unless errors.empty?

      {
        "passed" => true,
        "written_values_verified" => written.length,
        "written_fills_verified" => written.length,
        "already_present_unchanged" => already_present.length,
        "nonaccepted_writes" => 0,
        "formula_cells_checked" => source.formula_count,
        "unauthorized_cell_changes" => 0,
        "package_members_changed" => changed_parts,
        "unexpected_package_member_changes" => []
      }
    rescue Zip::Error, REXML::ParseException => e
      raise ValidationError, "AMC post-write verification could not read XLSX: #{e.message}"
    end

    def self.numeric_equal?(left, right)
      left.is_a?(Numeric) && right.is_a?(Numeric) && left == right
    end

    def initialize(audit_dir:, amc_path:, output_path:, report_path: nil, progress: nil,
                   authorized_candidates: nil, authorization: nil, accounting: nil)
      @audit_dir = File.expand_path(audit_dir) if audit_dir
      @amc_path = File.expand_path(amc_path)
      @output_path = File.expand_path(output_path)
      @report_path = File.expand_path(report_path || self.class.default_report_path(@output_path))
      @progress = progress
      @authorized_candidates = authorized_candidates && deep_copy(authorized_candidates)
      @authorization = authorization && deep_copy(authorization)
      @accounting = accounting && deep_copy(accounting)
    end

    def apply!
      PrivateDataRoot.destination!(@output_path)
      PrivateDataRoot.destination!(@report_path)
      validate_paths!
      source_sha = Digest::SHA256.file(@amc_path).hexdigest
      validation, accepted, audit_identity, authorization_identity = resolve_authorized_candidates!
      progress("[preflight] resolving #{accepted.length} accepted candidate(s) against AMC")
      workbook = Workbook.new(@amc_path)
      catalog = workbook.catalog_sheet!
      catalog.resolve_headers!(accepted.map { |candidate| candidate.fetch("dimension") })
      catalog.validate_unique_adventure_ids!
      records, conflicts, errors = build_plan(accepted, catalog, workbook.styles)
      unless conflicts.empty? && errors.empty?
        raise ValidationError, "AMC apply preflight failed:\n- #{(conflicts + errors).join("\n- ")}"
      end

      styles_appended = workbook.styles.appended_count
      written = records.select { |record| record.fetch("action") == "written" }
      already_present = records.count { |record| record.fetch("action") == "already_present" }
      progress("[preflight] #{written.length} write(s), #{already_present} already present")
      temp_output = temporary_path(File.dirname(@output_path), ".amc-apply-", ".xlsx")
      temp_report = temporary_path(File.dirname(@report_path), ".amc-apply-report-", ".json")
      begin
        progress("[write] preparing temporary workbook")
        FileUtils.cp(@amc_path, temp_output)
        FileUtils.chmod(File.stat(@amc_path).mode & 0o777, temp_output)
        unless written.empty?
          written.each { |record| catalog.write!(record) }
          replacements = { catalog.part => catalog.to_xml }
          replacements["xl/styles.xml"] = workbook.styles.to_xml if styles_appended.positive?
          replace_zip_members!(temp_output, replacements)
        end
        progress(written.empty? ? "[write] no new cells to write" : "[write] wrote #{written.length} cell(s)")

        progress("[verify] verifying workbook integrity")
        verification = self.class.verify!(
          source_amc: @amc_path,
          output_amc: temp_output,
          records:,
          styles_appended:
        )
        progress("[verify] passed")
        unless Digest::SHA256.file(@amc_path).hexdigest == source_sha
          raise ValidationError, "source AMC changed during apply"
        end
        if audit_identity && capture_audit_identity! != audit_identity
          raise ValidationError, "editorial audit changed during apply"
        end
        if authorization_identity && capture_authorization_identity != authorization_identity
          raise ValidationError, "authorized candidate set changed during apply"
        end

        output_sha = Digest::SHA256.file(temp_output).hexdigest
        report = build_report(
          validation:,
          records:,
          source_sha:,
          output_sha:,
          audit_identity:,
          authorization_identity:,
          styles_appended:,
          verification:
        )
        File.write(temp_report, JSON.pretty_generate(report) + "\n", encoding: "UTF-8")
        progress("[publish] writing output workbook and report")
        publish_new_file!(temp_output, @output_path)
        begin
          publish_new_file!(temp_report, @report_path)
        rescue StandardError
          FileUtils.rm_f(@output_path)
          raise
        end
        progress("[publish] complete")
        Result.new(output_path: @output_path, report_path: @report_path, report:)
      ensure
        FileUtils.rm_f(temp_output)
        FileUtils.rm_f(temp_report)
      end
    rescue JSON::ParserError => e
      raise ValidationError, "audit manifest parse failure: #{e.message}"
    rescue Zip::Error, REXML::ParseException => e
      raise ValidationError, "AMC XLSX parse failure: #{e.message}"
    rescue SystemCallError => e
      raise ValidationError, "AMC apply file operation failed: #{e.message}"
    end

    private

    def progress(message)
      @progress&.call(message)
    end

    def validate_paths!
      raise ValidationError, "source AMC does not exist: #{@amc_path}" unless File.file?(@amc_path)
      if @audit_dir && !File.directory?(@audit_dir)
        raise ValidationError, "editorial audit directory does not exist: #{@audit_dir}"
      end
      if !@audit_dir && !@authorized_candidates
        raise ValidationError, "an editorial audit or authorized candidate set is required"
      end
      unless File.directory?(File.dirname(@output_path))
        raise ValidationError, "output directory does not exist: #{File.dirname(@output_path)}"
      end
      unless File.directory?(File.dirname(@report_path))
        raise ValidationError, "report directory does not exist: #{File.dirname(@report_path)}"
      end

      source_identity = File.realpath(@amc_path)
      output_identity = File.join(File.realpath(File.dirname(@output_path)), File.basename(@output_path))
      raise ValidationError, "--output must be a different file from --amc" if source_identity == output_identity
      raise ValidationError, "--report must be a different file from --output" if @report_path == @output_path
      raise ValidationError, "refusing to overwrite existing output workbook: #{@output_path}" if File.exist?(@output_path)
      raise ValidationError, "refusing to overwrite existing apply report: #{@report_path}" if File.exist?(@report_path)
    end

    def capture_audit_identity!
      manifest_path = File.join(@audit_dir, "audit_manifest.json")
      ledger_path = File.join(@audit_dir, "editorial_decisions.csv")
      raise ValidationError, "missing audit manifest: #{manifest_path}" unless File.file?(manifest_path)
      raise ValidationError, "missing editorial ledger: #{ledger_path}" unless File.file?(ledger_path)

      manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
      source_files = manifest["source_files"]
      raise ValidationError, "audit manifest source_files is missing" unless source_files.is_a?(Hash)

      source_review = EditorialAudit.resolve_review_dir(@audit_dir, manifest)
      actual_source_hashes = source_files.keys.sort.to_h do |name|
        path = File.join(source_review, name)
        raise ValidationError, "source review file missing: #{name}" unless File.file?(path)

        [name, Digest::SHA256.file(path).hexdigest]
      end
      {
        "audit_manifest_sha256" => Digest::SHA256.file(manifest_path).hexdigest,
        "editorial_decisions_sha256" => Digest::SHA256.file(ledger_path).hexdigest,
        "source_review_path" => File.expand_path(source_review),
        "source_files" => source_files,
        "decision_authority" => manifest.fetch("decision_authority", "human_editorial"),
        "human_reviewed" => manifest.fetch("human_reviewed", true),
        "actual_source_file_sha256" => actual_source_hashes
      }
    end

    def resolve_authorized_candidates!
      unless @authorized_candidates
        progress("[audit] validating editorial audit")
        audit_identity = capture_audit_identity!
        validation = nil
        Dir.mktmpdir("af-data-amc-audit-", PrivateDataRoot.selected) do |validation_dir|
          validation = EditorialAudit.validate!(audit_dir: @audit_dir, output_dir: validation_dir)
        end
        unless capture_audit_identity! == audit_identity
          raise ValidationError, "editorial audit changed during validation"
        end
        unless validation.complete
          details = validation.errors.dup
          details << "#{validation.pending.length} editorial candidate(s) remain pending" if validation.pending.any?
          raise ValidationError, "editorial audit is not complete and clean:\n- #{details.join("\n- ")}"
        end
        progress(
          "[audit] complete: #{validation.accepted.length} accepted, " \
          "#{validation.held.length} held, #{validation.rejected.length} rejected"
        )
        return [validation, validate_accepted!(validation.accepted), audit_identity, nil]
      end

      progress("[authorization] validating authorized candidate set")
      identity = capture_authorization_identity
      counts = @accounting
      unless counts.is_a?(Hash) && %w[source_holds held_candidates rejected_candidates pending_candidates].all? do |key|
        counts[key].is_a?(Integer) && counts[key] >= 0
      end
        raise ValidationError, "authorized candidate accounting is malformed"
      end
      validation = AuthorizationValidation.new(
        source_holds: Array.new(counts.fetch("source_holds")),
        held: Array.new(counts.fetch("held_candidates")),
        rejected: Array.new(counts.fetch("rejected_candidates")),
        pending: Array.new(counts.fetch("pending_candidates"))
      )
      progress("[authorization] complete: #{@authorized_candidates.length} candidate(s)")
      [validation, validate_authorized_candidates!(@authorized_candidates), nil, identity]
    end

    def validate_authorized_candidates!(candidates)
      unless candidates.is_a?(Array) && candidates.all? { |candidate| candidate.is_a?(Hash) }
        raise ValidationError, "authorized candidates must be an array of objects"
      end
      rows = candidates.map do |candidate|
        {
          "record_key" => candidate["candidate_key"],
          "adventure_id" => candidate["adventure_id"],
          "dimension" => candidate["dimension"],
          "proposed_value" => candidate["proposed_value"]
        }
      end
      validate_accepted!(rows)
    end

    def capture_authorization_identity
      unless @authorization.is_a?(Hash) && !@authorization.empty?
        raise ValidationError, "authorized candidate set requires a non-empty authorization record"
      end
      Digest::SHA256.hexdigest(canonical_json(
        "authorization" => @authorization,
        "candidates" => @authorized_candidates,
        "accounting" => @accounting
      ))
    end

    def validate_accepted!(accepted)
      duplicate_keys = accepted.map { |row| row["record_key"] }.tally.select { |_key, count| count > 1 }.keys
      raise ValidationError, "duplicate accepted candidate keys: #{duplicate_keys.join(', ')}" unless duplicate_keys.empty?

      accepted.map do |row|
        adventure_id = row["adventure_id"].to_s
        dimension = row["dimension"].to_s
        value = row["proposed_value"]
        key = row["record_key"].to_s
        raise ValidationError, "#{key}: invalid Adventure ID #{adventure_id.inspect}" unless adventure_id.match?(ADV_ID)
        unless DIMENSION_HEADERS.key?(dimension)
          raise ValidationError, "#{key}: unsupported candidate dimension #{dimension.inspect}"
        end
        unless key == "#{adventure_id}::#{dimension}"
          raise ValidationError, "#{key}: candidate key does not match Adventure ID and dimension"
        end
        unless value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
          raise ValidationError, "#{key}: accepted value must be numeric"
        end

        {
          "candidate_key" => key,
          "adventure_id" => adventure_id,
          "dimension" => dimension,
          "proposed_value" => value
        }
      end
    end

    def build_plan(accepted, catalog, styles)
      records = []
      conflicts = []
      errors = []
      accepted.each do |candidate|
        begin
          row_number = catalog.row_for_adventure(candidate.fetch("adventure_id"))
          unless row_number
            errors << "#{candidate.fetch('candidate_key')}: unknown Adventure ID #{candidate.fetch('adventure_id')}"
            next
          end
          column = catalog.column_for_dimension(candidate.fetch("dimension"))
          reference = "#{column}#{row_number}"
          cell = catalog.cell(reference)
          previous = catalog.display_value(cell)
          base = candidate.merge(
            "previous_value" => previous,
            "cell" => reference,
            "sheet" => catalog.name,
            "sheet_part" => catalog.part
          )
          if catalog.blank_cell?(cell)
            base_style = catalog.base_style_for(reference, styles)
            red_style = styles.red_style_for(base_style)
            records << base.merge(
              "action" => "written",
              "expected_fill" => REQUIRED_FILL,
              "expected_style_index" => red_style
            )
          elsif self.class.numeric_equal?(catalog.cell_numeric_value(cell), candidate.fetch("proposed_value"))
            records << base.merge("action" => "already_present")
          else
            conflicts << "#{candidate.fetch('candidate_key')}: conflict at #{catalog.name}!#{reference}; existing=#{previous.inspect}, proposed=#{candidate.fetch('proposed_value').inspect}"
          end
        rescue ValidationError => e
          errors << "#{candidate.fetch('candidate_key')}: #{e.message}"
        end
      end
      [records, conflicts, errors]
    end

    def build_report(validation:, records:, source_sha:, output_sha:, audit_identity:, authorization_identity:,
                     styles_appended:, verification:)
      report = {
        "schema_version" => REPORT_SCHEMA,
        "command_schema_version" => COMMAND_SCHEMA,
        "status" => "complete",
        "generated_at" => Time.now.utc.iso8601,
        "source_amc" => { "path" => File.realpath(@amc_path), "sha256" => source_sha },
        "output_amc" => { "path" => @output_path, "sha256" => output_sha },
        "counts" => {
          "accepted_candidates_considered" => records.length,
          "new_cells_written" => records.count { |record| record["action"] == "written" },
          "already_present_exact_matches" => records.count { |record| record["action"] == "already_present" },
          "source_holds" => validation.source_holds.length,
          "held_candidates" => validation.held.length,
          "rejected_candidates" => validation.rejected.length,
          "pending_candidates" => validation.pending.length,
          "conflicts" => 0,
          "errors" => 0
        },
        "style_mutation" => {
          "required_fill" => REQUIRED_FILL,
          "cell_xfs_appended" => styles_appended
        },
        "records" => records,
        "verification" => verification
      }
      if audit_identity
        report["editorial_audit"] = {
          "path" => File.realpath(@audit_dir),
          "audit_manifest_sha256" => audit_identity.fetch("audit_manifest_sha256"),
          "editorial_decisions_sha256" => audit_identity.fetch("editorial_decisions_sha256"),
          "source_review_path" => audit_identity.fetch("source_review_path"),
          "source_files" => audit_identity.fetch("source_files"),
          "decision_authority" => audit_identity.fetch("decision_authority"),
          "human_reviewed" => audit_identity.fetch("human_reviewed")
        }
      else
        report["candidate_authorization"] = {
          "kind" => "validated_authorized_candidate_set",
          "sha256" => authorization_identity,
          "authority" => @authorization
        }
      end
      report
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def temporary_path(directory, prefix, suffix)
      tempfile = Tempfile.create([prefix, suffix], directory)
      path = tempfile.path
      tempfile.close
      path
    end

    def publish_new_file!(temporary, destination)
      File.link(temporary, destination)
      File.unlink(temporary)
    rescue Errno::EEXIST
      raise ValidationError, "refusing to overwrite file created during apply: #{destination}"
    end

    def replace_zip_members!(path, replacements)
      Zip::File.open(path) do |zip|
        replacements.each do |name, content|
          entry = zip.find_entry(name)
          raise ValidationError, "required XLSX package member missing: #{name}" unless entry

          zip.get_output_stream(entry) { |stream| stream.write(content) }
        end
      end
    end

  end
end
