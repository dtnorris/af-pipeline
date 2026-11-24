# frozen_string_literal: true

require_relative "private_data_root"

module AfDataPipeline
  # Converts only the cells written by a verified amc-apply run from the
  # production-ingest red fill to the catalog's existing accepted light-blue
  # fill. The source workbook is never modified.
  class AmcFinalize
    prepend XlsxFilesErrors.wrap(:finalize!)
    singleton_class.prepend XlsxFilesErrors.wrap(:verify_existing!)

    REPORT_SCHEMA = "af-amc-finalize-report/v0.1"
    ACCEPTED_FILL = "#D0E0E3"

    Result = Data.define(:output_path, :report_path, :report)

    def self.finalize!(amc_path:, apply_report_path:, output_path:, report_path: nil, expected_cells: nil, progress: nil)
      new(
        amc_path:,
        apply_report_path:,
        output_path:,
        report_path:,
        expected_cells:,
        progress:
      ).finalize!
    end

    def self.default_report_path(output_path)
      expanded = File.expand_path(output_path)
      expanded.sub(/\.xlsx\z/i, "") + ".amc-finalize-report.json"
    end

    # Independently revalidates an already published apply/finalize pair
    # without rewriting either workbook.
    def self.verify_existing!(amc_path:, apply_report_path:, output_path:, report_path:)
      instance = new(
        amc_path:,
        apply_report_path:,
        output_path:,
        report_path:
      )
      instance.send(:verify_existing!)
    end

    def initialize(amc_path:, apply_report_path:, output_path:, report_path: nil, expected_cells: nil, progress: nil)
      @amc_path = File.expand_path(amc_path)
      @apply_report_path = File.expand_path(apply_report_path)
      @output_path = File.expand_path(output_path)
      @report_path = File.expand_path(report_path || self.class.default_report_path(@output_path))
      @expected_cells = expected_cells
      @progress = progress
    end

    def finalize!
      PrivateDataRoot.destination!(@output_path)
      PrivateDataRoot.destination!(@report_path)
      validate_paths!
      progress("[report] validating amc-apply report")
      source_sha = Digest::SHA256.file(@amc_path).hexdigest
      apply_report_sha = Digest::SHA256.file(@apply_report_path).hexdigest
      apply_report = load_apply_report!
      targets = validate_apply_report!(apply_report, source_sha:)
      progress("[report] #{targets.length} written cell(s) authorized for finalization")

      progress("[preflight] resolving accepted styles")
      source_workbook = AmcApply::Workbook.new(@amc_path)
      style_resolution = resolve_accepted_styles!(source_workbook, targets)
      style_map = style_resolution.fetch(:style_map)
      styles_appended = style_resolution.fetch(:appended_count)
      expected_formula_count = apply_report.dig("verification", "formula_cells_checked")
      if expected_formula_count && source_workbook.formula_count != expected_formula_count
        raise ValidationError,
          "applied AMC formula count #{source_workbook.formula_count} does not match apply verification #{expected_formula_count}"
      end

      replacements = build_replacements!(source_workbook, targets, style_map)
      if styles_appended.positive?
        replacements["xl/styles.xml"] = style_resolution.fetch(:styles_xml)
      end
      progress("[preflight] prepared #{replacements.length} worksheet replacement(s)")
      temp_output = temporary_path(File.dirname(@output_path), ".amc-finalize-", ".xlsx")
      temp_report = temporary_path(File.dirname(@report_path), ".amc-finalize-report-", ".json")
      begin
        progress("[write] preparing temporary workbook")
        FileUtils.cp(@amc_path, temp_output)
        FileUtils.chmod(File.stat(@amc_path).mode & 0o777, temp_output)
        replace_zip_members!(temp_output, replacements)
        progress("[write] recolored #{targets.length} cell(s)")

        progress("[verify] verifying workbook integrity")
        verification = verify!(
          source_amc: @amc_path,
          output_amc: temp_output,
          targets:,
          style_map:,
          styles_appended:
        )
        progress("[verify] passed")

        unless Digest::SHA256.file(@amc_path).hexdigest == source_sha
          raise ValidationError, "source applied AMC changed during finalization"
        end
        unless Digest::SHA256.file(@apply_report_path).hexdigest == apply_report_sha
          raise ValidationError, "amc-apply report changed during finalization"
        end

        output_sha = Digest::SHA256.file(temp_output).hexdigest
        report = build_report(
          source_sha:,
          output_sha:,
          apply_report_sha:,
          targets:,
          verification:,
          styles_appended:
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
      raise ValidationError, "amc-apply report parse failure: #{e.message}"
    rescue Zip::Error, REXML::ParseException => e
      raise ValidationError, "AMC finalization XLSX parse failure: #{e.message}"
    rescue SystemCallError => e
      raise ValidationError, "AMC finalization file operation failed: #{e.message}"
    end

    private

    def verify_existing!
      source_sha = Digest::SHA256.file(@amc_path).hexdigest
      apply_report_sha = Digest::SHA256.file(@apply_report_path).hexdigest
      apply_report = load_apply_report!
      targets = validate_apply_report!(apply_report, source_sha:)
      source = AmcApply::Workbook.new(@amc_path)
      style_resolution = resolve_accepted_styles!(source, targets)
      style_map = style_resolution.fetch(:style_map)
      styles_appended = style_resolution.fetch(:appended_count)
      verification = verify!(
        source_amc: @amc_path,
        output_amc: @output_path,
        targets:,
        style_map:,
        styles_appended:
      )
      report = JSON.parse(File.binread(@report_path))
      expected = {
        "schema_version" => REPORT_SCHEMA,
        "status" => "complete",
        "source_sha256" => source_sha,
        "apply_report_sha256" => apply_report_sha,
        "output_sha256" => Digest::SHA256.file(@output_path).hexdigest,
        "finalized_cells" => targets.length,
        "verification" => verification
      }
      actual = {
        "schema_version" => report["schema_version"],
        "status" => report["status"],
        "source_sha256" => report.dig("source_applied_amc", "sha256"),
        "apply_report_sha256" => report.dig("amc_apply_report", "sha256"),
        "output_sha256" => report.dig("output_amc", "sha256"),
        "finalized_cells" => report.dig("counts", "finalized_cells"),
        "verification" => report["verification"]
      }
      raise ValidationError, "existing AMC finalization report conflicts with verified output" unless actual == expected

      verification
    rescue Errno::ENOENT, JSON::ParserError => e
      raise ValidationError, "invalid existing AMC finalization: #{e.message}"
    end

    def progress(message)
      @progress&.call(message)
    end

    def validate_paths!
      raise ValidationError, "applied AMC does not exist: #{@amc_path}" unless File.file?(@amc_path)
      unless File.file?(@apply_report_path)
        raise ValidationError, "amc-apply report does not exist: #{@apply_report_path}"
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
      raise ValidationError, "refusing to overwrite existing finalize report: #{@report_path}" if File.exist?(@report_path)
    end

    def load_apply_report!
      JSON.parse(File.read(@apply_report_path, encoding: "UTF-8"))
    end

    def validate_apply_report!(report, source_sha:)
      unless report["schema_version"] == AmcApply::REPORT_SCHEMA
        raise ValidationError, "unsupported amc-apply report schema #{report['schema_version'].inspect}"
      end
      raise ValidationError, "amc-apply report is not complete" unless report["status"] == "complete"
      unless report.dig("verification", "passed") == true
        raise ValidationError, "amc-apply report verification did not pass"
      end

      counts = report["counts"]
      raise ValidationError, "amc-apply report counts are missing" unless counts.is_a?(Hash)
      %w[conflicts errors pending_candidates].each do |key|
        value = counts[key]
        raise ValidationError, "amc-apply report count #{key} is missing" unless value.is_a?(Integer)
        raise ValidationError, "amc-apply report contains #{key}=#{value}" unless value.zero?
      end

      reported_output_sha = report.dig("output_amc", "sha256")
      unless reported_output_sha == source_sha
        raise ValidationError,
          "applied AMC SHA-256 does not match amc-apply report output (actual=#{source_sha}, reported=#{reported_output_sha.inspect})"
      end
      unless report.dig("style_mutation", "required_fill") == AmcApply::REQUIRED_FILL
        raise ValidationError, "amc-apply report does not declare the required #{AmcApply::REQUIRED_FILL} fill"
      end

      records = report["records"]
      raise ValidationError, "amc-apply report records are missing" unless records.is_a?(Array)
      targets = records.select { |record| record["action"] == "written" }
      expected = counts["new_cells_written"]
      unless expected.is_a?(Integer) && targets.length == expected
        raise ValidationError,
          "amc-apply report write count mismatch (count=#{expected.inspect}, records=#{targets.length})"
      end

      if @expected_cells && targets.length != @expected_cells
        raise ValidationError,
          "finalization target count #{targets.length} does not match --expect-cells #{@expected_cells}"
      end

      duplicates = targets.map { |record| [record["sheet_part"], record["cell"]] }.tally
        .select { |_key, count| count > 1 }.keys
      unless duplicates.empty?
        raise ValidationError, "duplicate written cells in amc-apply report: #{duplicates.map { |part, cell| "#{part}!#{cell}" }.join(', ')}"
      end

      targets.each do |record|
        key = record["candidate_key"].to_s
        raise ValidationError, "written record has blank candidate_key" if key.empty?
        unless record["sheet_part"].to_s.start_with?("xl/worksheets/")
          raise ValidationError, "#{key}: invalid worksheet part #{record['sheet_part'].inspect}"
        end
        unless record["cell"].to_s.match?(/\A[A-Z]+[1-9]\d*\z/)
          raise ValidationError, "#{key}: invalid cell reference #{record['cell'].inspect}"
        end
        unless record["expected_fill"] == AmcApply::REQUIRED_FILL
          raise ValidationError, "#{key}: written record does not expect #{AmcApply::REQUIRED_FILL}"
        end
        begin
          Integer(record.fetch("expected_style_index").to_s, 10)
        rescue KeyError, ArgumentError, TypeError
          raise ValidationError, "#{key}: invalid expected_style_index"
        end
      end

      targets
    end

    def resolve_accepted_styles!(workbook, targets)
      style_table = read_style_table!
      style_map = {}
      appended_count = 0
      targets.map { |record| Integer(record.fetch("expected_style_index").to_s, 10) }.uniq.each do |red_style|
        unless workbook.styles.fill_rgb(red_style.to_s) == AmcApply::REQUIRED_FILL
          raise ValidationError,
            "expected style #{red_style} to use #{AmcApply::REQUIRED_FILL}; found #{workbook.styles.fill_rgb(red_style.to_s).inspect}"
        end

        signature = style_signature(style_table, red_style)
        matches = style_table.fetch(:xfs).each_index.select do |style_id|
          style_fill(style_table, style_id) == ACCEPTED_FILL &&
            style_signature(style_table, style_id) == signature
        end
        if matches.length > 1
          raise ValidationError,
            "expected exactly one #{ACCEPTED_FILL} style equivalent to red style #{red_style}; found #{matches.inspect}"
        end
        if matches.one?
          style_map[red_style] = matches.first
          next
        end

        accepted_fill_id = accepted_fill_id(style_table)
        unless accepted_fill_id
          raise ValidationError,
            "expected exactly one #{ACCEPTED_FILL} style equivalent to red style #{red_style}; found #{matches.inspect}"
        end

        red_xf = style_table.fetch(:xfs)[red_style]
        raise ValidationError, "style index #{red_style} does not exist" unless red_xf
        clone = red_xf.deep_clone
        clone.attributes["fillId"] = accepted_fill_id.to_s
        clone.attributes["applyFill"] = "1"
        style_table.fetch(:cell_xfs_element).add_element(clone)
        style_table.fetch(:xfs) << clone
        style_table.fetch(:cell_xfs_element).attributes["count"] = style_table.fetch(:xfs).length.to_s
        appended_count += 1
        style_map[red_style] = style_table.fetch(:xfs).length - 1
      end

      {
        style_map:,
        appended_count:,
        styles_xml: appended_count.positive? ? AmcApply.serialize_xml(style_table.fetch(:document)) : nil
      }
    end

    def read_style_table!
      xml = nil
      Zip::File.open(@amc_path) do |zip|
        entry = zip.find_entry("xl/styles.xml")
        raise ValidationError, "required XLSX package member missing: xl/styles.xml" unless entry
        xml = entry.get_input_stream.read
      end
      document = REXML::Document.new(xml)
      fills = REXML::XPath.match(document, "//s:styleSheet/s:fills/s:fill", AmcApply::NS)
      cell_xfs_element = REXML::XPath.first(document, "//s:styleSheet/s:cellXfs", AmcApply::NS)
      raise ValidationError, "styles.xml is missing cellXfs" unless cell_xfs_element
      xfs = REXML::XPath.match(cell_xfs_element, "./s:xf", AmcApply::NS)
      raise ValidationError, "styles.xml is missing cellXfs" if xfs.empty?
      { document:, fills:, cell_xfs_element:, xfs: }
    end

    def style_signature(style_table, style_id)
      style = style_table.fetch(:xfs)[style_id]
      raise ValidationError, "style index #{style_id} does not exist" unless style
      AmcApply.canonical_element(style, ignored_attributes: %w[fillId applyFill])
    end

    def style_fill(style_table, style_id)
      style = style_table.fetch(:xfs)[style_id]
      return nil unless style
      fill_id = Integer(style.attributes["fillId"] || "0", 10)
      fill_rgb(style_table.fetch(:fills)[fill_id])
    rescue ArgumentError, TypeError
      nil
    end

    def accepted_fill_id(style_table)
      matches = style_table.fetch(:fills).each_index.select do |fill_id|
        fill_rgb(style_table.fetch(:fills)[fill_id]) == ACCEPTED_FILL
      end
      matches.one? ? matches.first : nil
    end

    def fill_rgb(fill)
      return nil unless fill
      pattern = REXML::XPath.first(fill, "./s:patternFill", AmcApply::NS)
      return nil unless pattern && pattern.attributes["patternType"] == "solid"
      color = REXML::XPath.first(fill, "./s:patternFill/s:fgColor", AmcApply::NS)
      rgb = color && color.attributes["rgb"]&.upcase
      return nil unless rgb
      rgb = rgb[-6, 6] if rgb.length == 8
      "##{rgb}"
    end

    def build_replacements!(workbook, targets, style_map)
      targets.group_by { |record| record.fetch("sheet_part") }.to_h do |part, records|
        sheet = workbook.sheet(part)
        raise ValidationError, "worksheet package member missing: #{part}" unless sheet
        xml = read_zip_member(@amc_path, part)
        original = xml.dup

        records.each do |record|
          reference = record.fetch("cell")
          expected_style = Integer(record.fetch("expected_style_index").to_s, 10)
          accepted_style = style_map.fetch(expected_style)
          source_cell = sheet.cell(reference)
          unless source_cell && source_cell.attributes["s"].to_s == expected_style.to_s
            actual = source_cell && source_cell.attributes["s"]
            raise ValidationError,
              "#{record.fetch('candidate_key')}: expected red style #{expected_style} at #{part}!#{reference}; found #{actual.inspect}"
          end
          unless workbook.styles.fill_rgb(expected_style.to_s) == AmcApply::REQUIRED_FILL
            raise ValidationError, "#{record.fetch('candidate_key')}: target cell is not #{AmcApply::REQUIRED_FILL}"
          end

          # amc-apply serializes worksheet XML through REXML, which may emit
          # either single- or double-quoted attributes. Match both forms while
          # changing only the style attribute on the exact authorized cell.
          cell_pattern = Regexp.escape(reference)
          cell_tag = source_cell.prefix.to_s.empty? ? "c" : "#{source_cell.prefix}:c"
          tag_pattern = /<#{Regexp.escape(cell_tag)}\b(?=[^>]*\br=["']#{cell_pattern}["'])(?=[^>]*\bs=["']#{expected_style}["'])[^>]*>/
          matches = xml.scan(tag_pattern)
          unless matches.length == 1
            raise ValidationError,
              "#{record.fetch('candidate_key')}: expected exactly one red target cell at #{part}!#{reference}; found #{matches.length}"
          end
          tag = matches.first
          replaced = tag.sub(/\bs=(["'])#{expected_style}\1/) { |attribute| attribute.sub(expected_style.to_s, accepted_style.to_s) }
          if replaced == tag
            raise ValidationError, "#{record.fetch('candidate_key')}: could not replace target style at #{reference}"
          end
          xml = xml.sub(tag, replaced)
        end

        raise ValidationError, "no style changes produced for #{part}" if xml == original
        [part, xml]
      end
    end

    def verify!(source_amc:, output_amc:, targets:, style_map:, styles_appended:)
      source = AmcApply::Workbook.new(source_amc)
      output = AmcApply::Workbook.new(output_amc)
      errors = []

      errors << "XLSX package member order or membership changed" unless source.entry_names == output.entry_names
      expected_parts = targets.map { |record| record.fetch("sheet_part") }.uniq.sort
      expected_parts << "xl/styles.xml" if styles_appended.positive?
      expected_parts.sort!
      changed_parts = (source.member_hashes.keys | output.member_hashes.keys).select do |name|
        source.member_hashes[name] != output.member_hashes[name]
      end.sort
      errors << "unexpected XLSX package members changed: #{changed_parts.inspect}" unless changed_parts == expected_parts
      if styles_appended.positive? && !source.styles.append_only_match?(output.styles, styles_appended)
        errors << "styles.xml change was not the expected append-only cellXfs mutation"
      end
      errors << "workbook sheet names/order changed" unless source.sheet_identity == output.sheet_identity
      errors << "formula count changed: #{source.formula_count} -> #{output.formula_count}" unless source.formula_count == output.formula_count

      authorized = targets.to_h { |record| [[record.fetch("sheet_part"), record.fetch("cell")], record] }
      source.sheet_parts.each do |part|
        source_sheet = source.sheet(part)
        output_sheet = output.sheet(part)
        unless output_sheet
          errors << "worksheet missing after finalization: #{part}"
          next
        end
        unless source_sheet.structure_signature == output_sheet.structure_signature
          errors << "worksheet structure changed outside cells: #{part}"
        end

        source_cells = source_sheet.cell_snapshots
        output_cells = output_sheet.cell_snapshots
        (source_cells.keys | output_cells.keys).each do |reference|
          record = authorized[[part, reference]]
          if record
            source_cell = source_sheet.cell(reference)
            output_cell = output_sheet.cell(reference)
            unless source_cell && output_cell && canonical_cell_without_style(source_cell) == canonical_cell_without_style(output_cell)
              errors << "target cell changed beyond style: #{part}!#{reference}"
              next
            end

            red_style = Integer(record.fetch("expected_style_index").to_s, 10)
            accepted_style = style_map.fetch(red_style)
            errors << "target source style mismatch: #{part}!#{reference}" unless source_cell.attributes["s"].to_s == red_style.to_s
            errors << "target output style mismatch: #{part}!#{reference}" unless output_cell.attributes["s"].to_s == accepted_style.to_s
            errors << "target source fill mismatch: #{part}!#{reference}" unless source.styles.fill_rgb(red_style.to_s) == AmcApply::REQUIRED_FILL
            errors << "target accepted fill mismatch: #{part}!#{reference}" unless output.styles.fill_rgb(accepted_style.to_s) == ACCEPTED_FILL
            unless source.styles.base_signature(red_style) == output.styles.base_signature(accepted_style)
              errors << "target accepted style changed non-fill formatting: #{part}!#{reference}"
            end
          elsif source_cells[reference] != output_cells[reference]
            errors << "unauthorized worksheet cell change: #{part}!#{reference}"
          end
        end
      end

      raise ValidationError, "AMC finalization verification failed:\n- #{errors.join("\n- ")}" unless errors.empty?

      {
        "passed" => true,
        "finalized_cells_verified" => targets.length,
        "source_fill" => AmcApply::REQUIRED_FILL,
        "accepted_fill" => ACCEPTED_FILL,
        "formula_cells_checked" => source.formula_count,
        "unauthorized_cell_changes" => 0,
        "package_members_changed" => changed_parts,
        "unexpected_package_member_changes" => []
      }
    end

    def canonical_cell_without_style(cell)
      clone = cell.deep_clone
      clone.delete_attribute("s")
      AmcApply.canonical_element(clone)
    end

    def build_report(source_sha:, output_sha:, apply_report_sha:, targets:, verification:, styles_appended:)
      {
        "schema_version" => REPORT_SCHEMA,
        "status" => "complete",
        "generated_at" => Time.now.utc.iso8601,
        "source_applied_amc" => { "path" => File.realpath(@amc_path), "sha256" => source_sha },
        "amc_apply_report" => { "path" => File.realpath(@apply_report_path), "sha256" => apply_report_sha },
        "output_amc" => { "path" => @output_path, "sha256" => output_sha },
        "style_transition" => {
          "from" => AmcApply::REQUIRED_FILL,
          "to" => ACCEPTED_FILL,
          "cell_xfs_appended" => styles_appended
        },
        "counts" => { "finalized_cells" => targets.length, "errors" => 0 },
        "verification" => verification
      }
    end

    def read_zip_member(path, name)
      Zip::File.open(path) do |zip|
        entry = zip.find_entry(name)
        raise ValidationError, "required XLSX package member missing: #{name}" unless entry
        return entry.get_input_stream.read
      end
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
      raise ValidationError, "refusing to overwrite file created during finalization: #{destination}"
    end
  end
end
