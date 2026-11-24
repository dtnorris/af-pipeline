# frozen_string_literal: true

module AfDataPipeline
  # Deliberately narrow, content-based compatibility proof. This does not merge
  # catalogs, adopt a head, or decide whether an existing workload may execute.
  class StagedScoringConcurrency
    VERSION = "af-staged-scoring-concurrency/v0.1"
    CATALOGS = [BoundaryFreezeApply::ORDINARY_SHEET, BoundaryFreezeApply::LARGE_SHEET].freeze

    def self.compare(base_path:, head_path:, records:, source_id:)
      new.compare(base_path:, head_path:, records:, source_id:)
    end

    def compare(base_path:, head_path:, records:, source_id:)
      base, before = view(base_path)
      head, after = view(head_path)
      allocated = records.map { |r| r.fetch("adventure_id") }
      protected_ids = protected_closure(before, records, source_id)
      proof = {"schema_version" => VERSION, "protected_ids" => protected_ids,
               "allocated_ids" => allocated, "changed_cells" => []}
      collisions = allocated & after.values.map { |r| r.fetch("adventure_id") }
      return result(proof, "FRESH_DECISION", "ID_COLLISION", collisions) unless collisions.empty?
      unless base.entry_names == head.entry_names && base.sheet_identity == head.sheet_identity
        return result(proof, "UNPROVABLE", "WORKBOOK_STRUCTURE")
      end
      parts = CATALOGS.map { |name| base.sheet_by_name!(name).part }
      changed_parts = base.member_hashes.keys.select { |p| base.member_hashes[p] != head.member_hashes[p] }
      unless (changed_parts - parts).empty?
        return result(proof, "UNPROVABLE", "NON_CATALOG_MEMBER_CHANGE", changed_parts - parts)
      end
      unless before.keys.sort == after.keys.sort
        return result(proof, "FRESH_DECISION", "RECORD_SET_OR_PLACEMENT_CHANGED")
      end
      parts.each do |part|
        a = base.sheet(part)
        b = head.sheet(part)
        unless a.structure_signature == b.structure_signature
          return result(proof, "UNPROVABLE", "WORKSHEET_STRUCTURE", [part])
        end
        snapshots = [a.cell_snapshots, b.cell_snapshots]
        (snapshots[0].keys | snapshots[1].keys).sort.each do |ref|
          next if snapshots[0][ref] == snapshots[1][ref]
          proof["changed_cells"] << [part, ref]
          column, row = AmcApply.reference_parts(ref)
          record = before[[part, row]]
          return result(proof, "UNPROVABLE", "NON_RECORD_CELL", [part, ref]) unless record
          if protected_ids.include?(record.fetch("adventure_id"))
            return result(proof, "FRESH_DECISION", "PROTECTED_RECORD_CHANGED", [record.fetch("adventure_id"), ref])
          end
          allowed = BoundaryFreezeApply::ASSESSMENT_HEADERS.filter_map { |h| a.column_for_header(h) }
          unless allowed.include?(column) && a.cell_formula(a.cell(ref)).nil? && b.cell_formula(b.cell(ref)).nil?
            return result(proof, "FRESH_DECISION", "IDENTITY_OR_REFERENCE_CHANGE", [record.fetch("adventure_id"), ref])
          end
          unless numeric_or_blank?(a.cell_value(ref)) && numeric_or_blank?(b.cell_value(ref)) &&
                 scalar_cell?(a.cell(ref)) && scalar_cell?(b.cell(ref)) &&
                 cell_attributes(a.cell(ref)) == cell_attributes(b.cell(ref))
            return result(proof, "UNPROVABLE", "UNSUPPORTED_CELL_CHANGE", [part, ref])
          end
        end
      end
      result(proof, "SAFE_REUSE", proof["changed_cells"].empty? ? "UNCHANGED" : "UNRELATED_SCALAR_SCORES")
    rescue KeyError, Zip::Error, REXML::ParseException, ValidationError => e
      result({"schema_version" => VERSION}, "UNPROVABLE", "INVALID_COMPARISON_EVIDENCE", [e.message])
    end

    private

    def view(path)
      # Bounded process-local parsed views, keyed by actual bytes on every call.
      # No path, caller-supplied digest or retained PASS flag is a cache key.
      identity = [Digest::SHA256.file(path).hexdigest, File.size(path)]
      @views ||= {}
      return @views.fetch(identity) if @views.key?(identity)
      workbook = BoundaryFreezeApply::Workbook.new(path)
      rows = catalog_rows(workbook)
      @views.shift if @views.length >= 8
      @views[identity] = [workbook, rows]
    end

    def catalog_rows(workbook)
      CATALOGS.each_with_object({}) do |name, rows|
        sheet = workbook.sheet_by_name!(name)
        sheet.validate_catalog_schema!
        ids = []
        id_column = sheet.column_for_header("ADV - ID")
        sheet.cell_references.each do |ref|
          column, row = AmcApply.reference_parts(ref)
          next unless column == id_column && row > 1
          value = sheet.cell_value(ref)
          next if value.nil? || value.to_s.empty?
          raise ValidationError, "malformed Adventure ID" unless BoundaryFreezeApply::ADV_ID_RE.match?(value.to_s)
        end
        sheet.catalog_records.each do |record|
          id = record.fetch("adventure_id")
          raise ValidationError, "duplicate Adventure ID in #{name}" if ids.include?(id)
          ids << id
          refs = sheet.cell_references.select { |ref| AmcApply.reference_parts(ref)[1] == record.fetch("row") }
          rows[[sheet.part, record.fetch("row")]] = record.merge(
            "references" => refs.flat_map { |ref| sheet.cell_value(ref).to_s.scan(/ADV-\d{4,}/) }.uniq - [id],
            "has_formula" => refs.any? { |ref| sheet.cell_formula(sheet.cell(ref)) }
          )
        end
      end
    end

    def protected_closure(rows, records, source_id)
      ids = records.filter_map { |r| r["parent_adventure_id"] }
      sources = [source_id]
      loop do
        prior = [ids.sort, sources.sort]
        rows.each_value do |row|
          next unless ids.include?(row.fetch("adventure_id")) || sources.include?(row.fetch("source_book"))
          ids |= [row.fetch("adventure_id"), *row.fetch("references")]
          sources |= [row.fetch("source_book")]
          # Unparsed formula dependencies are conservatively closed over every
          # record, never assumed local or harmless.
          ids |= rows.values.map { |r| r.fetch("adventure_id") } if row.fetch("has_formula")
        end
        break if prior == [ids.sort, sources.sort]
      end
      missing = ids - rows.values.map { |r| r.fetch("adventure_id") }
      raise ValidationError, "unresolved protected references: #{missing.join(', ')}" unless missing.empty?
      (ids | records.map { |r| r.fetch("adventure_id") }).sort
    end

    def numeric_or_blank?(value)
      value.nil? || value == "" || (value.is_a?(Numeric) && value.finite?)
    end

    def cell_attributes(cell)
      return {} unless cell
      cell.attributes.to_h.reject { |name, _| name == "t" }.transform_values(&:to_s)
    end

    def scalar_cell?(cell)
      return true unless cell
      [nil, "n"].include?(cell.attributes["t"]) && cell.elements.to_a.all? { |child| child.name == "v" } &&
        cell.elements.to_a.length <= 1
    end

    def result(proof, decision, reason, details = [])
      proof.merge("decision" => decision, "reason" => reason, "details" => details)
    end
  end
end
