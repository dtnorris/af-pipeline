# frozen_string_literal: true

require "optparse"

module AfDataPipeline
  # Builds deterministic, read-only evidence for Phase 1 boundary review.
  # It deliberately does not decide, rank, accept, reject, or assign IDs.
  class BoundaryDossier
    SCHEMA_VERSION = "af-boundary-dossier/v0.2"
    JSON_FILENAME = "boundary_dossier.json"
    MARKDOWN_FILENAME = "boundary_dossier.md"
    MAX_SIGNAL_TEXT = 240

    SIGNAL_PATTERNS = {
      "adventure_terms" => /\b(?:adventure|scenario|mission|quest)\b/i,
      "dungeon_terms" => /\bdungeon\b/i,
      "hook_terms" => /\b(?:hook|getting the mission|adventure start|starting the adventure)\b/i,
      "encounter_terms" => /\bencounters?\b/i,
      "resolution_terms" => /\b(?:conclusion|resolution|aftermath|success|failure|developments?)\b/i,
      "level_terms" => /\blevels?\b/i
    }.freeze

    LEVEL_PATTERNS = [
      /\b(?:levels?|level)\s+(\d{1,2})\s*(?:-|–|—|to)\s*(\d{1,2})\b/i,
      /\b(?:for\s+)?level\s+(\d{1,2})\s+(?:characters?|adventurers?|party)\b/i,
      /\b(\d{1,2})(?:st|nd|rd|th)[- ]level\s+(?:characters?|adventurers?|party)\b/i
    ].freeze

    CONTENTS_HEADING_PATTERN = /\A(?:table of )?contents?\z/i
    STRUCTURAL_LABEL_PATTERN = /\A(?:(?:chapter|act|scene|part|appendix)\s+\S+|(?:mission|quest|adventure)\s*:\s*\S)/i
    SIMPLE_PAGE_PATTERN = /\A(\d{1,4})(?:\s*(?:-|–|—|to)\s*(\d{1,4}))?\z/i

    Result = Data.define(:output_dir, :json_path, :markdown_path, :report)

    def self.generate!(source_root:, source_id:, amc_path:, output_dir:, registry_path: nil,
                       workbook_class: BoundaryFreezeApply::Workbook)
      new(
        source_root:, source_id:, amc_path:, output_dir:, registry_path:, workbook_class:
      ).generate!
    end

    def initialize(source_root:, source_id:, amc_path:, output_dir:, registry_path:, workbook_class:)
      @source_root = source_root
      @source_id = source_id
      @amc_path = amc_path
      @output_dir = output_dir
      @registry_path = registry_path
      @workbook_class = workbook_class
    end

    def generate!
      root = BoundaryFreeze.expanded_source_root(@source_root)
      source_id = BoundaryFreeze.nonblank_string!(@source_id, "source_id")
      amc = BoundaryFreeze.existing_file!(@amc_path, "base AMC")
      registry = BoundaryFreeze.registry_context(root, @registry_path)
      entry = registry.fetch("sources")[source_id]
      raise ValidationError, "Source registry has no entry for #{source_id.inspect}" unless entry

      normalized_entry = BoundaryFreeze.normalize_registry_entry(source_id, entry)
      registry_sha = BoundaryFreeze.sha256(registry.fetch("path"))
      amc_sha = BoundaryFreeze.sha256(amc)
      source_files = normalized_entry.fetch(:files).map do |filename|
        path = BoundaryFreeze.source_file!(root, filename)
        analyze_markdown(path, filename)
      end

      workbook = @workbook_class.new(amc)
      ordinary = workbook.sheet_by_name!(BoundaryFreezeApply::ORDINARY_SHEET)
      large = workbook.sheet_by_name!(BoundaryFreezeApply::LARGE_SHEET)
      ordinary.validate_catalog_schema!
      large.validate_catalog_schema!
      catalog = catalog_evidence(ordinary, large)

      input_hashes = { registry.fetch("path") => registry_sha, amc => amc_sha }
      source_files.each do |item|
        source_path = BoundaryFreeze.source_file!(root, item.fetch("filename"))
        input_hashes[source_path] = item.fetch("sha256")
      end
      verify_inputs_stable!(input_hashes)

      report = {
        "schema_version" => SCHEMA_VERSION,
        "purpose" => "Deterministic evidence preparation for human/frontier Phase 1 review; not a boundary classifier.",
        "source" => {
          "canonical_source_id" => source_id,
          "registry_filename" => registry.fetch("relative_path"),
          "registry_sha256" => registry_sha,
          "markdown_files" => source_files.map do |item|
            { "filename" => item.fetch("filename"), "sha256" => item.fetch("sha256") }
          end,
          "segments" => normalized_entry[:segments]&.map do |segment|
            {
              "start_page" => segment.fetch(:start_page),
              "end_page" => segment.fetch(:end_page),
              "file" => segment.fetch(:file)
            }
          end
        }.compact,
        "base_amc" => {
          "filename" => File.basename(amc),
          "sha256" => amc_sha
        },
        "amc_evidence" => amc_evidence(catalog, source_id, source_files),
        "source_files" => source_files.map { |item| item.reject { |key, _| key == "sha256" } },
        "review_contract" => {
          "phase_1_standard" => "Treat every structural anchor and signal as evidence to inspect, not as an accepted candidate.",
          "no_decisions_made" => true,
          "no_adventure_ids_assigned" => true,
          "no_inferred_headings_or_page_mappings" => true,
          "no_adventure_classification" => true,
          "inputs_mutated" => false
        }
      }

      publish!(report)
    rescue Zip::Error, REXML::ParseException => e
      raise ValidationError, "boundary dossier parse failure: #{e.message}"
    end

    private

    def analyze_markdown(path, filename)
      lines = File.readlines(path, chomp: true, encoding: "UTF-8")
      contexts = []
      headings = []
      signal_hits = []
      level_mentions = []
      quality_flags = []
      pdf_markers = []
      printed_markers = []
      page_mappings = []
      current_pdf = nil
      current_printed = nil
      current_page_mapping = nil
      heading_stack = []

      lines.each_with_index do |line, index|
        line_number = index + 1
        if (match = line.match(/<!--\s*PDF Page\s+(\d+)\s*-->/i))
          current_pdf = Integer(match[1], 10)
          current_printed = nil
          current_page_mapping = {
            "pdf_page" => current_pdf,
            "pdf_marker_line" => line_number,
            "printed_markers" => []
          }
          page_mappings << current_page_mapping
          pdf_markers << { "line" => line_number, "page" => current_pdf }
        end
        if (match = line.match(/<!--\s*Printed Page\s+(\d+)\s*-->/i))
          current_printed = Integer(match[1], 10)
          printed_marker = { "line" => line_number, "page" => current_printed }
          printed_markers << printed_marker
          current_page_mapping&.fetch("printed_markers")&.push(printed_marker)
        end
        contexts << { "pdf_page" => current_pdf, "printed_page" => current_printed }

        if (match = line.match(/\A(#+)\s+(.+?)\s*\z/)) && match[1].length <= 6
          level = match[1].length
          title = match[2].strip
          heading_stack.pop while heading_stack.any? && heading_stack.last.fetch("level") >= level
          id = format("H%04d", headings.length + 1)
          parent_id = heading_stack.last && heading_stack.last.fetch("id")
          heading = {
            "id" => id,
            "line" => line_number,
            "level" => level,
            "title" => title,
            "parent_heading_id" => parent_id,
            "start_pdf_page" => current_pdf,
            "start_printed_page" => current_printed
          }.compact
          headings << heading
          heading_stack << heading
        end

        categories = SIGNAL_PATTERNS.filter_map { |name, pattern| name if pattern.match?(line) }
        unless categories.empty? || page_marker_line?(line)
          signal_hits << source_line_record(line_number, current_printed, current_pdf, line).merge(
            "categories" => categories
          )
        end

        extract_levels(line).each do |range|
          level_mentions << source_line_record(line_number, current_printed, current_pdf, line).merge(
            "start" => range.fetch(:start),
            "end" => range.fetch(:end)
          )
        end

        if line.include?("�") || /\bERROR\b/.match?(line)
          quality_flags << source_line_record(line_number, current_printed, current_pdf, line)
        end
      end

      headings.each_with_index do |heading, index|
        following = headings[(index + 1)..]&.find { |candidate| candidate.fetch("level") <= heading.fetch("level") }
        end_line = following ? following.fetch("line") - 1 : lines.length
        end_context = contexts[[end_line - 1, 0].max] || {}
        heading["end_line"] = end_line
        heading["end_pdf_page"] = end_context["pdf_page"] if end_context["pdf_page"]
        heading["end_printed_page"] = end_context["printed_page"] if end_context["printed_page"]
        heading["signal_categories"] = SIGNAL_PATTERNS.filter_map do |name, pattern|
          name if pattern.match?(heading.fetch("title"))
        end
      end

      signal_tables = extract_signal_tables(lines, contexts, headings)

      {
        "filename" => filename,
        "sha256" => BoundaryFreeze.sha256(path),
        "line_count" => lines.length,
        "page_markers" => {
          "pdf" => marker_summary(pdf_markers),
          "printed" => marker_summary(printed_markers)
        },
        "navigation_evidence" => {
          "contract" => {
            "headings" => "literal_markdown_only",
            "printed_page_mappings" => "explicit_same_pdf_page_marker_only",
            "adventure_classification" => "none"
          },
          "page_mappings" => finalize_page_mappings(page_mappings),
          "anchors" => navigation_anchors(lines, contexts, headings, signal_tables)
        },
        "quality_flags" => quality_flags,
        "headings" => headings,
        "signal_tables" => signal_tables,
        "signal_hits" => signal_hits,
        "level_mentions" => level_mentions
      }
    end

    def source_line_record(line_number, printed_page, pdf_page, line)
      {
        "line" => line_number,
        "printed_page" => printed_page,
        "pdf_page" => pdf_page,
        "text" => clipped_text(line)
      }.compact
    end

    def extract_signal_tables(lines, contexts, headings)
      tables = []
      index = 0
      while index < lines.length - 1
        header = lines[index]
        divider = lines[index + 1]
        unless table_row?(header) && table_divider?(divider)
          index += 1
          next
        end

        columns = split_table_row(header)
        categories = SIGNAL_PATTERNS.filter_map do |name, pattern|
          name if columns.any? { |column| pattern.match?(column) }
        end
        if table_looks_like_overview?(columns) || table_under_contents_heading?(index + 1, headings)
          categories << "toc_or_overview_table"
        end
        row_index = index + 2
        rows = []
        while row_index < lines.length && table_row?(lines[row_index])
          rows << split_table_row(lines[row_index])
          row_index += 1
        end

        unless categories.empty?
          start_context = contexts[index] || {}
          end_context = contexts[[row_index - 1, index].max] || {}
          tables << {
            "line_start" => index + 1,
            "line_end" => row_index,
            "start_pdf_page" => start_context["pdf_page"],
            "end_pdf_page" => end_context["pdf_page"],
            "start_printed_page" => start_context["printed_page"],
            "end_printed_page" => end_context["printed_page"],
            "signal_categories" => categories.uniq,
            "columns" => columns,
            "rows" => rows
          }.compact
        end
        index = row_index
      end
      tables
    end

    def table_looks_like_overview?(columns)
      normalized = columns.map { |column| column.downcase.gsub(/[^a-z0-9]+/, " ").strip }
      has_page = normalized.any? { |column| column == "page" || column == "pages" }
      has_identity = normalized.any? do |column|
        %w[name title adventure dungeon quest mission scenario].include?(column)
      end
      has_page && has_identity
    end

    def table_under_contents_heading?(line_number, headings)
      heading = headings.reverse.find { |item| item.fetch("line") < line_number }
      heading && CONTENTS_HEADING_PATTERN.match?(heading.fetch("title").strip)
    end

    def finalize_page_mappings(page_mappings)
      page_mappings.map do |mapping|
        printed_pages = mapping.fetch("printed_markers").map { |marker| marker.fetch("page") }.uniq
        status = if printed_pages.empty?
                   "unknown"
                 elsif printed_pages.length == 1
                   "observed"
                 else
                   "ambiguous"
                 end
        mapping.merge(
          "mapping_status" => status,
          "printed_page" => (printed_pages.first if status == "observed")
        ).compact
      end
    end

    def navigation_anchors(lines, contexts, headings, signal_tables)
      anchors = headings.map do |heading|
        {
          "kind" => "markdown_heading",
          "evidence_status" => "observed",
          "line" => heading.fetch("line"),
          "pdf_page" => heading["start_pdf_page"],
          "printed_page" => heading["start_printed_page"],
          "text" => heading.fetch("title")
        }.compact
      end

      signal_tables.each do |table|
        next unless table.fetch("signal_categories").include?("toc_or_overview_table")

        page_index = table.fetch("columns").index { |column| %w[page pages].include?(normalize_header(column)) }
        label_index = table.fetch("columns").each_index.find do |index|
          %w[name title section adventure quest mission scenario].include?(normalize_header(table.fetch("columns")[index]))
        end
        next unless page_index && label_index

        table.fetch("rows").each_with_index do |row, row_offset|
          page_range = parse_simple_page_range(row[page_index])
          label = row[label_index].to_s.strip
          next unless page_range && !label.empty?

          line_number = table.fetch("line_start") + 2 + row_offset
          context = contexts[line_number - 1] || {}
          anchors << {
            "kind" => "contents_entry",
            "evidence_status" => "observed_source_contents",
            "line" => line_number,
            "pdf_page" => context["pdf_page"],
            "printed_page" => context["printed_page"],
            "text" => clipped_text(label),
            "source_target_page_start" => page_range.fetch(:start),
            "source_target_page_end" => page_range.fetch(:end)
          }.compact
        end
      end

      heading_lines = headings.to_h { |heading| [heading.fetch("line"), true] }
      lines.each_with_index do |line, index|
        line_number = index + 1
        next if heading_lines[line_number] || page_marker_line?(line) || table_row?(line)

        text = line.to_s.gsub(/\s+/, " ").strip
        next if text.empty? || text.length > MAX_SIGNAL_TEXT || !STRUCTURAL_LABEL_PATTERN.match?(text)

        context = contexts[index] || {}
        anchors << {
          "kind" => "structural_label_signal",
          "evidence_status" => "observed_source_text",
          "line" => line_number,
          "pdf_page" => context["pdf_page"],
          "printed_page" => context["printed_page"],
          "text" => text
        }.compact
      end

      anchors.sort_by! { |anchor| [anchor.fetch("line"), anchor.fetch("kind"), anchor.fetch("text")] }
      anchors.each_with_index { |anchor, index| anchor["id"] = format("N%04d", index + 1) }
      anchors
    end

    def parse_simple_page_range(value)
      match = SIMPLE_PAGE_PATTERN.match(value.to_s.strip)
      return nil unless match

      start_page = Integer(match[1], 10)
      end_page = match[2] ? Integer(match[2], 10) : start_page
      return nil if start_page <= 0 || end_page < start_page

      { start: start_page, end: end_page }
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_header(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
    end

    def catalog_evidence(ordinary, large)
      [ordinary, large].flat_map do |sheet|
        page_count_column = sheet.column_for_header("Page Count")
        start_column = sheet.column_for_header("Start Page")
        end_column = sheet.column_for_header("End Page")
        level_start_column = sheet.column_for_header("Level Start")
        level_end_column = sheet.column_for_header("Level End")

        sheet.catalog_records.map do |record|
          row = record.fetch("row")
          start_page = integer_value(sheet.cell_value("#{start_column}#{row}"))
          end_page = integer_value(sheet.cell_value("#{end_column}#{row}"))
          page_count = if start_page && end_page
                         end_page - start_page + 1
                       else
                         integer_value(sheet.cell_value("#{page_count_column}#{row}"))
                       end
          level_start = level_start_column && integer_value(sheet.cell_value("#{level_start_column}#{row}"))
          level_end = level_end_column && integer_value(sheet.cell_value("#{level_end_column}#{row}"))
          record.merge(
            "sheet" => sheet.name,
            "start_page" => start_page,
            "end_page" => end_page,
            "page_count" => page_count,
            "level_start" => level_start,
            "level_end" => level_end
          ).compact
        end
      end
    end

    def amc_evidence(catalog, source_id, source_files)
      headings = source_files.flat_map { |item| item.fetch("headings") }
      matches = headings.filter_map do |heading|
        title = heading.fetch("title").strip
        exact = catalog.select { |record| record["title"].to_s.strip == title }
        normalized = catalog.select do |record|
          record_title = record["title"].to_s.strip
          record_title != title && normalize_title(record_title) == normalize_title(title)
        end
        next if exact.empty? && normalized.empty?

        {
          "heading_id" => heading.fetch("id"),
          "heading_title" => title,
          "exact_title_matches" => compact_catalog_records(exact),
          "normalized_title_matches" => compact_catalog_records(normalized)
        }
      end

      short_counts = [1, 2, 3, 5].to_h do |limit|
        ["lte_#{limit}_pages", catalog.count { |record| record["page_count"] && record["page_count"] <= limit }]
      end
      shortest = catalog.select { |record| record["page_count"] }
                        .sort_by { |record| [record.fetch("page_count"), record.fetch("adventure_id")] }
                        .first(12)

      {
        "catalog_record_count" => catalog.length,
        "short_record_counts" => short_counts,
        "same_source_records" => compact_catalog_records(catalog.select { |record| record["source_book"] == source_id }),
        "heading_title_matches" => matches,
        "shortest_record_examples" => compact_catalog_records(shortest)
      }
    end

    def compact_catalog_records(records)
      records.map do |record|
        record.slice(
          "adventure_id", "title", "source_book", "publisher", "sheet", "row",
          "start_page", "end_page", "page_count", "level_start", "level_end"
        )
      end
    end

    def publish!(report)
      raise ValidationError, "output directory is required" if @output_dir.nil? || @output_dir.to_s.strip.empty?
      output = File.expand_path(PrivateDataRoot.destination!(@output_dir).to_s)
      json_path = File.join(output, JSON_FILENAME)
      markdown_path = File.join(output, MARKDOWN_FILENAME)
      [json_path, markdown_path].each do |path|
        raise ValidationError, "refusing to overwrite existing dossier artifact: #{path}" if File.exist?(path)
      end

      FileUtils.mkdir_p(output)
      begin
        File.write(json_path, JSON.pretty_generate(report) + "\n", encoding: "UTF-8")
        File.write(markdown_path, render_markdown(report), encoding: "UTF-8")
      rescue StandardError
        FileUtils.rm_f(json_path)
        FileUtils.rm_f(markdown_path)
        raise
      end
      Result.new(output_dir: output, json_path:, markdown_path:, report:)
    end

    def render_markdown(report)
      lines = []
      lines << "# AdventureFinder pre-Phase-1 boundary dossier"
      lines << ""
      lines << "> **Evidence only.** No boundary decisions made. This dossier does not identify candidates, decide boundaries, assign Adventure IDs, or mutate the AMC. David + frontier review still own Phase 1 / Phase 1b / Phase 2 judgment."
      lines << ""
      lines << "- Source: `#{report.dig('source', 'canonical_source_id')}`"
      lines << "- Base AMC: `#{report.dig('base_amc', 'filename')}`"
      lines << "- Source-registry SHA-256: `#{report.dig('source', 'registry_sha256')}`"
      lines << "- Base-AMC SHA-256: `#{report.dig('base_amc', 'sha256')}`"
      lines << ""

      amc = report.fetch("amc_evidence")
      lines << "## AMC context"
      lines << ""
      lines << "- Canonical catalog records: #{amc.fetch('catalog_record_count')}"
      lines << "- Records ≤1 page: #{amc.dig('short_record_counts', 'lte_1_pages')}"
      lines << "- Records ≤2 pages: #{amc.dig('short_record_counts', 'lte_2_pages')}"
      lines << "- Records ≤3 pages: #{amc.dig('short_record_counts', 'lte_3_pages')}"
      lines << "- Records ≤5 pages: #{amc.dig('short_record_counts', 'lte_5_pages')}"
      lines << "- Existing records from this exact source identity: #{amc.fetch('same_source_records').length}"
      lines << ""
      append_catalog_table(lines, "Shortest existing AMC examples", amc.fetch("shortest_record_examples"))
      append_title_matches(lines, amc.fetch("heading_title_matches"))

      report.fetch("source_files").each do |file|
        lines << "## Source file: `#{file.fetch('filename')}`"
        lines << ""
        pdf = file.dig("page_markers", "pdf")
        printed = file.dig("page_markers", "printed")
        lines << "- Lines: #{file.fetch('line_count')}"
        lines << "- PDF markers: #{marker_markdown(pdf)}"
        lines << "- Printed-page markers: #{marker_markdown(printed)}"
        navigation = file.fetch("navigation_evidence")
        unknown_mappings = navigation.fetch("page_mappings").count { |mapping| mapping.fetch("mapping_status") == "unknown" }
        ambiguous_mappings = navigation.fetch("page_mappings").count { |mapping| mapping.fetch("mapping_status") == "ambiguous" }
        lines << "- PDF pages without an explicit printed-page mapping: #{unknown_mappings}"
        lines << "- Ambiguous PDF/printed-page mappings: #{ambiguous_mappings}"
        lines << "- Conversion-quality flags (`�` or standalone `ERROR`): #{file.fetch('quality_flags').length}"
        lines << ""

        unless file.fetch("quality_flags").empty?
          lines << "### Conversion-quality flags"
          lines << ""
          lines << "| Line | Printed | PDF | Source line |"
          lines << "| ---: | ---: | ---: | --- |"
          file.fetch("quality_flags").each do |flag|
            lines << "| #{flag.fetch('line')} | #{flag['printed_page'] || ''} | #{flag['pdf_page'] || ''} | #{escape_table(flag.fetch('text'))} |"
          end
          lines << ""
        end

        lines << "### Deterministic navigation evidence"
        lines << ""
        lines << "> Literal Markdown headings remain headings. Contents rows and plain-text structural labels are navigation signals only. A printed-page mapping exists only when that PDF page contains an explicit `Printed Page` marker; otherwise it remains unknown."
        lines << ""
        lines << "| ID | Kind | Line | Printed | PDF | Source TOC target | Source text |"
        lines << "| --- | --- | ---: | ---: | ---: | --- | --- |"
        navigation.fetch("anchors").each do |anchor|
          target = span_text(anchor["source_target_page_start"], anchor["source_target_page_end"])
          lines << "| #{anchor.fetch('id')} | #{anchor.fetch('kind')} | #{anchor.fetch('line')} | #{anchor['printed_page'] || ''} | #{anchor['pdf_page'] || ''} | #{target} | #{escape_table(anchor.fetch('text'))} |"
        end
        lines << ""

        lines << "#### Explicit PDF/printed-page mappings"
        lines << ""
        lines << "| PDF | PDF marker line | Printed marker(s) | Mapping |"
        lines << "| ---: | ---: | --- | --- |"
        navigation.fetch("page_mappings").each do |mapping|
          marker_text = mapping.fetch("printed_markers").map { |marker| "#{marker.fetch('page')}@L#{marker.fetch('line')}" }.join(", ")
          lines << "| #{mapping.fetch('pdf_page')} | #{mapping.fetch('pdf_marker_line')} | #{marker_text} | #{mapping.fetch('mapping_status')} |"
        end
        lines << ""

        lines << "### Heading hierarchy and mechanical section spans"
        lines << ""
        lines << "| ID | Depth | Parent | Printed pages | PDF pages | Lines | Heading | Heading signals |"
        lines << "| --- | ---: | --- | --- | --- | --- | --- | --- |"
        file.fetch("headings").each do |heading|
          lines << "| #{heading.fetch('id')} | #{heading.fetch('level')} | #{heading['parent_heading_id'] || ''} | #{span_text(heading['start_printed_page'], heading['end_printed_page'])} | #{span_text(heading['start_pdf_page'], heading['end_pdf_page'])} | #{heading.fetch('line')}–#{heading.fetch('end_line')} | #{escape_table(heading.fetch('title'))} | #{heading.fetch('signal_categories').join(', ')} |"
        end
        lines << ""

        unless file.fetch("signal_tables").empty?
          lines << "### Signal-bearing Markdown tables"
          lines << ""
          file.fetch("signal_tables").each_with_index do |table, index|
            lines << "#### Table #{index + 1} — lines #{table.fetch('line_start')}–#{table.fetch('line_end')}"
            lines << ""
            lines << "Signals: #{table.fetch('signal_categories').join(', ')}; printed pages #{span_text(table['start_printed_page'], table['end_printed_page'])}; PDF pages #{span_text(table['start_pdf_page'], table['end_pdf_page'])}."
            lines << ""
            columns = table.fetch("columns")
            lines << "| #{columns.map { |cell| escape_table(cell) }.join(' | ')} |"
            lines << "| #{columns.map { '---' }.join(' | ')} |"
            table.fetch("rows").each do |row|
              padded = row + Array.new([columns.length - row.length, 0].max, "")
              lines << "| #{padded.first(columns.length).map { |cell| escape_table(cell) }.join(' | ')} |"
            end
            lines << ""
          end
        end

        lines << "### Source-language signal hits"
        lines << ""
        lines << "| Line | Printed | PDF | Signals | Source line |"
        lines << "| ---: | ---: | ---: | --- | --- |"
        file.fetch("signal_hits").each do |hit|
          lines << "| #{hit.fetch('line')} | #{hit['printed_page'] || ''} | #{hit['pdf_page'] || ''} | #{hit.fetch('categories').join(', ')} | #{escape_table(hit.fetch('text'))} |"
        end
        lines << ""

        lines << "### Mechanical level mentions"
        lines << ""
        lines << "| Line | Printed | PDF | Parsed range | Source line |"
        lines << "| ---: | ---: | ---: | --- | --- |"
        file.fetch("level_mentions").each do |mention|
          lines << "| #{mention.fetch('line')} | #{mention['printed_page'] || ''} | #{mention['pdf_page'] || ''} | #{mention.fetch('start')}–#{mention.fetch('end')} | #{escape_table(mention.fetch('text'))} |"
        end
        lines << ""
      end

      lines << "## Frontier review instructions"
      lines << ""
      lines << "Use this packet to reduce clerical source navigation, not to replace editorial review. Inspect every plausible playable unit in the canonical source, preserve borderline cases into Phase 1b, and treat shortness or embedding as evidence rather than an automatic exclusion. The dossier's headings, signal hits, parsed levels, table rows, AMC examples, and title matches are mechanical observations only."
      lines << ""
      lines.join("\n")
    end

    def append_catalog_table(lines, title, records)
      lines << "### #{title}"
      lines << ""
      lines << "| Adventure ID | Title | Source | Pages | Span |"
      lines << "| --- | --- | --- | ---: | --- |"
      records.each do |record|
        lines << "| #{record['adventure_id']} | #{escape_table(record['title'])} | #{escape_table(record['source_book'])} | #{record['page_count'] || ''} | #{span_text(record['start_page'], record['end_page'])} |"
      end
      lines << ""
    end

    def append_title_matches(lines, matches)
      lines << "### Heading-title matches already present in AMC"
      lines << ""
      if matches.empty?
        lines << "No exact or punctuation/whitespace-normalized heading-title matches were found."
        lines << ""
        return
      end
      matches.each do |match|
        lines << "- `#{match.fetch('heading_id')}` **#{match.fetch('heading_title')}**"
        match.fetch("exact_title_matches").each do |record|
          lines << "  - exact: #{record['adventure_id']} — #{record['title']} — #{record['source_book']}"
        end
        match.fetch("normalized_title_matches").each do |record|
          lines << "  - normalized: #{record['adventure_id']} — #{record['title']} — #{record['source_book']}"
        end
      end
      lines << ""
    end

    def marker_summary(markers)
      pages = markers.map { |item| item.fetch("page") }
      duplicates = pages.tally.select { |_page, count| count > 1 }.keys.sort
      gaps = pages.each_cons(2).filter_map do |left, right|
        { "after" => left, "before" => right } if right > left + 1
      end
      non_increasing = pages.each_cons(2).filter_map do |left, right|
        { "from" => left, "to" => right } if right <= left
      end
      {
        "count" => pages.length,
        "first" => pages.first,
        "last" => pages.last,
        "duplicates" => duplicates,
        "gaps" => gaps,
        "non_increasing" => non_increasing
      }.compact
    end

    def extract_levels(line)
      LEVEL_PATTERNS.filter_map do |pattern|
        match = pattern.match(line)
        next unless match
        start_level = Integer(match[1], 10)
        end_level = match[2] ? Integer(match[2], 10) : start_level
        next if start_level <= 0 || end_level <= 0 || start_level > end_level
        { start: start_level, end: end_level }
      end.uniq
    rescue ArgumentError
      []
    end

    def table_row?(line)
      stripped = line.strip
      stripped.include?("|") && (stripped.start_with?("|") || stripped.end_with?("|"))
    end

    def table_divider?(line)
      cells = split_table_row(line)
      !cells.empty? && cells.all? { |cell| /\A:?-{3,}:?\z/.match?(cell.delete(" ")) }
    end

    def split_table_row(line)
      stripped = line.strip
      stripped = stripped[1..] if stripped.start_with?("|")
      stripped = stripped[...-1] if stripped.end_with?("|")
      stripped.split("|", -1).map { |cell| cell.strip }
    end

    def page_marker_line?(line)
      /<!--\s*(?:PDF|Printed) Page\s+\d+\s*-->/i.match?(line)
    end

    def clipped_text(line)
      text = line.to_s.gsub(/\s+/, " ").strip
      return text if text.length <= MAX_SIGNAL_TEXT
      text[0, MAX_SIGNAL_TEXT - 1] + "…"
    end

    def normalize_title(value)
      value.to_s.downcase.gsub(/[^\p{Alnum}]+/u, " ").strip.gsub(/\s+/, " ")
    end

    def integer_value(value)
      return value if value.is_a?(Integer)
      return value.to_i if value.is_a?(Numeric) && value.to_i == value
      Integer(value, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def marker_markdown(summary)
      return "0" if summary.fetch("count").zero?
      text = "#{summary.fetch('count')} (#{summary['first']}–#{summary['last']})"
      text += "; #{summary.fetch('gaps').length} gap(s)" unless summary.fetch("gaps").empty?
      text += "; duplicates: #{summary.fetch('duplicates').join(', ')}" unless summary.fetch("duplicates").empty?
      text += "; non-increasing transitions: #{summary.fetch('non_increasing').length}" unless summary.fetch("non_increasing").empty?
      text
    end

    def span_text(start_value, end_value)
      return "" unless start_value || end_value
      return start_value.to_s unless start_value && end_value
      start_value == end_value ? start_value.to_s : "#{start_value}–#{end_value}"
    end

    def escape_table(value)
      value.to_s.gsub("|", "\\|").gsub("\n", " ")
    end

    def verify_inputs_stable!(files)
      files.each do |path, expected_sha|
        actual = BoundaryFreeze.sha256(path)
        next if actual == expected_sha
        raise ValidationError, "input changed during boundary dossier generation: #{path}"
      end
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr, generator: BoundaryDossier)
        options = { source_root: nil, source_id: nil, amc: nil, output: nil, registry: nil }
        OptionParser.new do |parser|
          parser.banner = "Usage: bin/af-boundary-dossier --source-root DIR --source-id ID --amc BASE.xlsx --output DIR [--registry PATH]"
          parser.on("--source-root DIR", "Canonical Markdown corpus root") { |value| options[:source_root] = value }
          parser.on("--source-id ID", "Exact canonical source identity from source_registry.yml") { |value| options[:source_id] = value }
          parser.on("--amc PATH", "Explicit base Adventure Master Catalog workbook") { |value| options[:amc] = value }
          parser.on("--output DIR", "New dossier output directory") { |value| options[:output] = value }
          parser.on("--registry PATH", "Registry path (default: source_registry.yml beneath source root)") { |value| options[:registry] = value }
        end.parse!(argv)
        raise OptionParser::MissingArgument, "--source-root DIR" unless options[:source_root]
        raise OptionParser::MissingArgument, "--source-id ID" unless options[:source_id]
        raise OptionParser::MissingArgument, "--amc PATH" unless options[:amc]
        raise OptionParser::MissingArgument, "--output DIR" unless options[:output]
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        result = generator.generate!(
          source_root: options[:source_root],
          source_id: options[:source_id],
          amc_path: options[:amc],
          output_dir: options[:output],
          registry_path: options[:registry]
        )
        report = result.report
        heading_count = report.fetch("source_files").sum { |file| file.fetch("headings").length }
        signal_count = report.fetch("source_files").sum { |file| file.fetch("signal_hits").length }
        navigation_count = report.fetch("source_files").sum do |file|
          file.dig("navigation_evidence", "anchors").length
        end
        unknown_mapping_count = report.fetch("source_files").sum do |file|
          file.dig("navigation_evidence", "page_mappings").count do |mapping|
            mapping.fetch("mapping_status") == "unknown"
          end
        end
        out.puts(
          "Boundary dossier: PASS\n" \
          "Source: #{report.dig('source', 'canonical_source_id')}\n" \
          "Markdown files: #{report.fetch('source_files').length}\n" \
          "Headings indexed: #{heading_count}\n" \
          "Navigation anchors: #{navigation_count}\n" \
          "PDF pages without explicit printed-page mapping: #{unknown_mapping_count}\n" \
          "Signal lines: #{signal_count}\n" \
          "AMC records measured: #{report.dig('amc_evidence', 'catalog_record_count')}\n" \
          "No boundary decisions made; AMC unchanged\n" \
          "Wrote #{result.json_path}\n" \
          "Wrote #{result.markdown_path}\n" \
          "\n" \
          "Next command:\n" \
          "  1. cd #{File.expand_path('../..', __dir__)}\n" \
          "     #{File.expand_path('../../bin/af-ingest-next', __dir__)} " \
          "#{result.output_dir}"
        )
        0
      rescue OptionParser::ParseError, AfDataPipeline::Error => e
        err.puts("ERROR: #{e.message}")
        2
      end
    end
  end
end
