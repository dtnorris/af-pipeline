# frozen_string_literal: true

require_relative "error"
require_relative "amc_apply"
require_relative "boundary_freeze_apply"

module AfDataPipeline
  # Composes XL structure with real PL scored-new-ID/release/frontier policy.
  # No caller-supplied authorization summary or callback is accepted.
  class AmcCompatibilityCheck < AfXlsxFiles::AmcCompatibilityCheck
    prepend XlsxFilesErrors.wrap(:check)

    attr_reader :frontier_evidence

    def self.check(candidate_path:, base_path: nil, release_manifest_path: nil, staged_path: nil, frontier_result_path: nil, release_base_path: nil, replay_observation: nil)
      new(candidate_path:, base_path:, release_manifest_path:, staged_path:, frontier_result_path:, release_base_path:, replay_observation:).check
    end

    def self.validate!(candidate_path:, base_path: nil, release_manifest_path: nil, staged_path: nil, frontier_result_path: nil, release_base_path: nil, replay_observation: nil)
      report = check(candidate_path:, base_path:, release_manifest_path:, staged_path:, frontier_result_path:, release_base_path:, replay_observation:)
      return report if report.fetch("status") == "PASS"

      detail = report.fetch("errors").map { |error| "- #{error}" }.join("\n")
      raise ValidationError, "AMC cross-consumer compatibility failed:\n#{detail}"
    end

    def initialize(candidate_path:, base_path: nil, release_manifest_path: nil, staged_path: nil, frontier_result_path: nil, release_base_path: nil, replay_observation: nil)
      @candidate_path = File.expand_path(candidate_path)
      @base_path = base_path && File.expand_path(base_path)
      @release_manifest_path = release_manifest_path && File.expand_path(release_manifest_path)
      @staged_path = staged_path && File.expand_path(staged_path)
      @frontier_result_path = frontier_result_path && File.expand_path(frontier_result_path)
      @release_base_path = release_base_path && File.expand_path(release_base_path)
      @replay_observation = replay_observation
    end

    def check
      errors = []
      unless File.file?(@candidate_path)
        return report(errors: ["candidate workbook does not exist: #{@candidate_path}"])
      end
      if @base_path && !File.file?(@base_path)
        return report(errors: ["comparison workbook does not exist: #{@base_path}"])
      end
      if @release_manifest_path.nil? != @staged_path.nil?
        return report(errors: ["release_manifest_path and staged_path must be supplied together"])
      end
      if @frontier_result_path && !@release_manifest_path
        return report(errors: ["frontier evidence requires the original release/base/staged tuple"])
      end
      if @release_manifest_path && !@base_path
        return report(errors: ["scored-new-ID authorization requires an exact comparison workbook"])
      end
      if @release_base_path && !@release_manifest_path
        return report(errors: ["release_base_path requires scored-release provenance"])
      end

      scored_authorization = validate_scored_authorization(errors)

      workbook = AfXlsxFiles::BoundaryFreezeApply::Workbook.new(@candidate_path)
      ordinary = fetch_sheet(workbook, BoundaryFreezeApply::ORDINARY_SHEET, errors)
      large = fetch_sheet(workbook, BoundaryFreezeApply::LARGE_SHEET, errors)
      books = fetch_sheet(workbook, BoundaryFreezeApply::BOOKS_SHEET, errors)
      return report(errors:) unless ordinary && large && books

      required_columns = {}
      [ordinary, large].each do |sheet|
        required = REQUIRED_IDENTITY_HEADERS + REQUIRED_SCORE_HEADERS
        required << ">99 pgs" if sheet.name == BoundaryFreezeApply::LARGE_SHEET
        required_columns[sheet.name] = resolve_columns(sheet, required, errors)
      end
      return report(errors:) if errors.any? { |error| error.include?("missing required header") || error.include?("ambiguous header") }

      ordinary_rows = catalog_rows(ordinary, required_columns.fetch(ordinary.name), errors)
      large_rows = catalog_rows(large, required_columns.fetch(large.name), errors)
      ordinary_by_id = unique_index(ordinary.name, ordinary_rows, errors)
      large_by_id = unique_index(large.name, large_rows, errors)

      mirror_mode = mirror_mode(ordinary, large, books, ordinary_by_id, large_by_id, errors)
      candidate_ids = (ordinary_by_id.keys | large_by_id.keys).sort
      base_ids = @base_path ? base_ids(errors) : []
      added_ids = candidate_ids - base_ids
      if scored_authorization && scored_authorization.boundary_created_ids != added_ids
        errors << "added Adventure IDs do not exactly match the authorized boundary-created IDs"
      end

      validate_catalog_rows(ordinary, ordinary_rows, required_columns.fetch(ordinary.name), added_ids, scored_authorization, errors)
      validate_catalog_rows(large, large_rows, required_columns.fetch(large.name), added_ids, scored_authorization, errors)
      validate_added_placement(ordinary, large, ordinary_by_id, large_by_id, added_ids, mirror_mode, errors)
      validate_large_summary(large, large_rows, errors)
      validate_current_books(books, ordinary, large, ordinary_rows, large_rows, mirror_mode, errors)

      report(
        errors:,
        mirror_mode:,
        canonical_count: candidate_ids.length,
        added_ids:,
        scored_authorization:
      )
    rescue Zip::Error, REXML::ParseException, KeyError, ArgumentError => e
      report(errors: ["candidate XLSX could not be validated: #{e.message}"])
    end

    private

    def validate_scored_authorization(errors)
      return unless @release_manifest_path

      if @frontier_result_path
        @frontier_evidence = FrontierReleaseEvidence.validate!(path: @frontier_result_path,
          release_manifest_path: @release_manifest_path, staged_path: @staged_path, base_path: @release_base_path || @base_path, replay_observation: @replay_observation)
        unless File.expand_path(@frontier_evidence.candidate_path) == @candidate_path
          raise ValidationError, "candidate differs from the exact optional frontier result"
        end
        return @frontier_evidence.proof
      end

      AmcScoredNewIdAuthorization.validate!(
        release_manifest_path: @release_manifest_path,
        candidate_path: @candidate_path,
        staged_path: @staged_path,
        base_path: @release_base_path || @base_path,
        frontier_result_path: @frontier_result_path
      )
    rescue ValidationError => e
      errors << "scored-new-ID authorization failed: #{e.message}"
      nil
    end

    def validate_catalog_rows(sheet, rows, columns, added_ids, scored_authorization, errors)
      rows.each do |record|
        id = record.fetch("adventure_id")
        row = record.fetch("row")

        ["Adventure Title", "Source Book", "Book Publisher"].each do |header|
          value = sheet.cell_value("#{columns.fetch(header)}#{row}").to_s.strip
          errors << "#{sheet.name} #{id}: #{header} must be nonblank" if value.empty?
        end

        start_page = integer_value(sheet.cell_value("#{columns.fetch('Start Page')}#{row}"))
        end_page = integer_value(sheet.cell_value("#{columns.fetch('End Page')}#{row}"))
        if !start_page&.positive? || !end_page&.positive? || end_page < start_page
          errors << "#{sheet.name} #{id}: invalid Start Page / End Page"
          next
        end

        expected_pages = end_page - start_page + 1
        page_count = integer_value(sheet.cell_value("#{columns.fetch('Page Count')}#{row}"))
        unless page_count == expected_pages
          errors << "#{sheet.name} #{id}: Page Count cache #{page_count.inspect} does not equal #{expected_pages} from Start/End Page"
        end
        if sheet.name == BoundaryFreezeApply::LARGE_SHEET && expected_pages < BoundaryFreezeApply::LARGE_THRESHOLD
          errors << "#{sheet.name} #{id}: #{expected_pages} pages is below the >=#{BoundaryFreezeApply::LARGE_THRESHOLD}-page threshold"
        end

        next unless added_ids.include?(id)

        validate_new_row_formulas(sheet, row, id, columns, expected_pages, scored_authorization, errors)
        validate_new_row_blank_fields(sheet, row, id, scored_authorization, errors)
      end
    end

    def validate_new_row_formulas(sheet, row, id, columns, expected_pages, scored_authorization, errors)
      start_column = columns.fetch("Start Page")
      end_column = columns.fetch("End Page")
      page_count_column = columns.fetch("Page Count")
      page_cell = sheet.cell("#{page_count_column}#{row}")
      expected_page_formula = "1+#{end_column}#{row}-#{start_column}#{row}"
      unless normalize_formula(sheet.cell_formula(page_cell)) == normalize_formula(expected_page_formula)
        errors << "#{sheet.name} #{id}: new Page Count must use formula #{expected_page_formula}"
      end

      first = sheet.column_for_header("Number of Sessions")
      last = sheet.column_for_header("Seriousness")
      scored_column = columns.fetch("Scored")
      scored_cell = sheet.cell("#{scored_column}#{row}")
      expected_scored_formula = "COUNT(#{first}#{row}:#{last}#{row})"
      unless normalize_formula(sheet.cell_formula(scored_cell)) == normalize_formula(expected_scored_formula)
        errors << "#{sheet.name} #{id}: new Scored must use formula #{expected_scored_formula}"
      end

      expected_scored = headers_between(sheet, row, "Number of Sessions", "Seriousness").count do |value|
        value.is_a?(Numeric)
      end
      actual_scored = integer_value(sheet.cell_value("#{scored_column}#{row}"))
      unless actual_scored == expected_scored || scored_authorization&.scored_id?(id)
        errors << "#{sheet.name} #{id}: Scored cache #{actual_scored.inspect} does not equal #{expected_scored}"
      end

      return unless sheet.name == BoundaryFreezeApply::LARGE_SHEET

      large_column = columns.fetch(">99 pgs")
      large_cell = sheet.cell("#{large_column}#{row}")
      expected_large_formula = "IF(#{page_count_column}#{row}>99,1,0)"
      unless normalize_formula(sheet.cell_formula(large_cell)) == normalize_formula(expected_large_formula)
        errors << "#{sheet.name} #{id}: >99 pgs must use formula #{expected_large_formula}"
      end
      actual_large = integer_value(sheet.cell_value("#{large_column}#{row}"))
      errors << "#{sheet.name} #{id}: >99 pgs cache must be 1" unless actual_large == 1 && expected_pages >= 100
    end

    def validate_new_row_blank_fields(sheet, row, id, scored_authorization, errors)
      (REQUIRED_SCORE_HEADERS + DEFERRED_SCORE_HEADERS.select { |header| safe_column(sheet, header) }).uniq.each do |header|
        column = safe_column(sheet, header)
        next unless column
        cell = sheet.cell("#{column}#{row}")
        next if sheet.blank_cell?(cell) && sheet.cell_formula(cell).nil?
        next if scored_authorization&.authorizes?(
          sheet: sheet.name,
          adventure_id: id,
          dimension: header,
          cell: "#{column}#{row}",
          value: sheet.cell_value("#{column}#{row}")
        )

        errors << "#{sheet.name} #{id}: unassessed production field #{header.inspect} must be blank"
      end

      left = safe_column(sheet, "Level Start")
      right = safe_column(sheet, "Level End")
      start_value = left && sheet.cell_value("#{left}#{row}")
      end_value = right && sheet.cell_value("#{right}#{row}")
      start_blank = blank?(start_value)
      end_blank = blank?(end_value)
      if start_blank != end_blank
        # V2 supplementation may responsibly leave one exact endpoint unknown.
        # The independent frontier proof binds both the explicit no-write and
        # the populated endpoint. Ordinary/staged workbooks retain pair rules.
        missing_dimension = start_blank ? "Level Start" : "Level End"
        dimension = start_blank ? "Level End" : "Level Start"
        column = start_blank ? right : left
        value = start_blank ? end_value : start_value
        level = integer_value(value)
        if @frontier_evidence&.no_write_keys&.include?("#{id}::#{missing_dimension}") &&
           level && (1..20).cover?(level) && scored_authorization&.authorizes?(
             sheet: sheet.name, adventure_id: id, dimension:, cell: "#{column}#{row}", value:
           )
          return
        end
        errors << "#{sheet.name} #{id}: Level Start and Level End must both be blank or both populated"
        return
      end
      return if start_blank

      start_level = integer_value(start_value)
      end_level = integer_value(end_value)
      unless start_level && end_level && (1..20).cover?(start_level) && (1..20).cover?(end_level) && end_level >= start_level
        errors << "#{sheet.name} #{id}: populated Levels must be whole numbers 1-20 with Level End >= Level Start"
      end
    end

  end
end
