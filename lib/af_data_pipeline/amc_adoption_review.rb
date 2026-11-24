# frozen_string_literal: true

require "pathname"
require "rexml/document"
require "rexml/xpath"
require "zip"
require_relative "error"
require_relative "amc_apply"
require_relative "boundary_freeze_apply"

module AfDataPipeline
  # Read-only comparison used by af-project-state adopt. This is intentionally
  # narrower than cross-consumer workbook compatibility validation: it gives the
  # operator an inspectable catalog delta without claiming that every AMC
  # consumer accepts the candidate workbook.
  class AmcAdoptionReview
    METADATA_HEADERS = [
      "Adventure Title",
      "Played",
      "Page Count",
      "Source Book",
      "Book Publisher",
      "Start Page",
      "End Page"
    ].freeze
    REVIEW_HEADERS = (
      METADATA_HEADERS + AmcApply::DIMENSION_HEADERS.values + ["Scored"]
    ).uniq.freeze

    def self.compare(current_path:, candidate_path:)
      new(current_path:, candidate_path:).compare
    end

    def initialize(current_path:, candidate_path:)
      @current_path = File.expand_path(current_path)
      @candidate_path = File.expand_path(candidate_path)
    end

    def compare
      current_sheet = catalog_sheet(@current_path)
      candidate_sheet = catalog_sheet(@candidate_path)
      current_records = index_records!(current_sheet)
      candidate_records = index_records!(candidate_sheet)

      current_ids = current_records.keys
      candidate_ids = candidate_records.keys
      added_ids = candidate_ids - current_ids
      removed_ids = current_ids - candidate_ids

      changed = (current_ids & candidate_ids).sort.filter_map do |adventure_id|
        before = row_signature(current_sheet, current_records.fetch(adventure_id))
        after = row_signature(candidate_sheet, candidate_records.fetch(adventure_id))
        field_changes = REVIEW_HEADERS.each_with_object({}) do |header, changes|
          next if before[header] == after[header]

          changes[header] = {
            "before" => before[header],
            "after" => after[header]
          }
        end
        next if field_changes.empty?

        {
          "adventure_id" => adventure_id,
          "title" => candidate_records.fetch(adventure_id).fetch("title"),
          "fields" => field_changes
        }
      end

      current_headers = present_review_headers(current_sheet)
      candidate_headers = present_review_headers(candidate_sheet)

      {
        "current_count" => current_records.length,
        "candidate_count" => candidate_records.length,
        "review_headers_added" => candidate_headers - current_headers,
        "review_headers_removed" => current_headers - candidate_headers,
        "added" => added_ids.sort.map { |id| record_summary(candidate_records.fetch(id)) },
        "removed" => removed_ids.sort.map { |id| record_summary(current_records.fetch(id)) },
        "changed" => changed
      }
    rescue Zip::Error, REXML::ParseException => e
      raise ValidationError, "AMC adoption review could not read XLSX: #{e.message}"
    end

    private

    def catalog_sheet(path)
      workbook = BoundaryFreezeApply::Workbook.new(path)
      sheet = workbook.sheet_by_name!(BoundaryFreezeApply::ORDINARY_SHEET)
      sheet.validate_catalog_schema!
      sheet
    end

    def index_records!(sheet)
      records = sheet.catalog_records
      duplicates = records.group_by { |record| record.fetch("adventure_id") }
        .select { |_id, matches| matches.length > 1 }
      unless duplicates.empty?
        details = duplicates.map { |id, matches| "#{id} (rows #{matches.map { |record| record.fetch('row') }.join(', ')})" }
        raise ValidationError, "duplicate Adventure IDs in #{sheet.name}: #{details.join('; ')}"
      end

      records.to_h { |record| [record.fetch("adventure_id"), record] }
    end

    def present_review_headers(sheet)
      REVIEW_HEADERS.select { |header| sheet.column_for_header(header) }
    end

    def row_signature(sheet, record)
      row = record.fetch("row")
      REVIEW_HEADERS.to_h do |header|
        column = sheet.column_for_header(header)
        value = if column
                  cell = sheet.cell("#{column}#{row}")
                  {
                    "value" => sheet.cell_value("#{column}#{row}"),
                    "formula" => sheet.cell_formula(cell)
                  }
                else
                  {"missing_header" => true}
                end
        [header, value]
      end
    end

    def record_summary(record)
      {
        "adventure_id" => record.fetch("adventure_id"),
        "title" => record.fetch("title")
      }
    end
  end
end
