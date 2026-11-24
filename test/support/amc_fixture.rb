# frozen_string_literal: true

require "cgi"

module AmcFixture
  def write_amc_workbook(path, rows:, dimensions: ["Seriousness"], duplicate_header: nil, red_style_match: true)
    headers = ["ADV - ID", "Adventure Title", *dimensions, "Derived Formula"]
    headers << duplicate_header if duplicate_header
    header_cells = headers.each_with_index.map do |header, index|
      inline_cell(cell_reference(index + 1, 1), header, style: 0)
    end.join
    body_rows = rows.each_with_index.map do |row, index|
      row_number = index + 2
      cells = []
      cells << inline_cell("A#{row_number}", row.fetch(:adventure_id), style: 0)
      cells << inline_cell("B#{row_number}", row.fetch(:title, "Adventure #{row_number}"), style: 0)
      dimensions.each_with_index do |dimension, dimension_index|
        reference = cell_reference(dimension_index + 3, row_number)
        value = row.fetch(:values, {})[dimension]
        cells << numeric_or_blank_cell(reference, value, style: 1)
      end
      formula_column = dimensions.length + 3
      cells << %(<c r="#{cell_reference(formula_column, row_number)}" s="0"><f>1+2</f><v>3</v></c>)
      %(<row r="#{row_number}" ht="18" customHeight="1">#{cells.join}</row>)
    end.join
    last_column = cell_reference(headers.length, rows.length + 1).sub(/\d+\z/, "")

    worksheet = <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}">
        <dimension ref="A1:#{last_column}#{rows.length + 1}"/>
        <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" state="frozen"/></sheetView></sheetViews>
        <cols><col min="1" max="#{headers.length}" width="16" customWidth="1"/></cols>
        <sheetData><row r="1">#{header_cells}</row>#{body_rows}</sheetData>
        <mergeCells count="1"><mergeCell ref="A20:B20"/></mergeCells>
      </worksheet>
    XML
    styles = styles_xml(red_style_match:)
    entries = {
      "[Content_Types].xml" => content_types_xml,
      "_rels/.rels" => package_rels_xml,
      "docProps/core.xml" => core_properties_xml,
      "xl/workbook.xml" => workbook_xml,
      "xl/_rels/workbook.xml.rels" => workbook_rels_xml,
      "xl/styles.xml" => styles,
      "xl/worksheets/sheet1.xml" => worksheet,
      "xl/worksheets/sheet2.xml" => auxiliary_sheet_xml
    }
    Zip::File.open(path, create: true) do |zip|
      entries.each do |name, content|
        zip.get_output_stream(name) { |stream| stream.write(content) }
      end
    end
    path
  end

  def build_editorial_audit(root, candidates:, decisions: {}, source_holds: [])
    review = File.join(root, "review")
    audit = File.join(root, "audit")
    FileUtils.mkdir_p(review)
    candidate_rows = candidates.map do |candidate|
      dimension = candidate.fetch(:dimension)
      adventure_id = candidate.fetch(:adventure_id)
      {
        "schema_version" => "af-production-candidate/v0.1",
        "candidate_key" => "#{adventure_id}::#{dimension}",
        "adventure_id" => adventure_id,
        "adventure_title" => candidate.fetch(:title, "Fixture Adventure"),
        "dimension" => dimension,
        "value" => candidate.fetch(:value),
        "assessment_state" => "Assessed",
        "review_disposition" => "PASS",
        "rationale" => "Synthetic fixture rationale.",
        "provenance" => {}
      }
    end
    hold_rows = source_holds.map do |hold|
      dimension = hold.fetch(:dimension)
      adventure_id = hold.fetch(:adventure_id)
      {
        "schema_version" => "af-production-hold/v0.1",
        "hold_key" => "#{adventure_id}::#{dimension}",
        "adventure_id" => adventure_id,
        "adventure_title" => hold.fetch(:title, "Fixture Adventure"),
        "dimension" => dimension,
        "value" => nil,
        "assessment_state" => "Uncertain / Requires Source Verification",
        "review_disposition" => "REVIEW_REQUIRED",
        "hold_reason" => "source_verification_required",
        "rationale" => "Synthetic source hold.",
        "provenance" => {}
      }
    end
    write_jsonl_fixture(File.join(review, "candidates.jsonl"), candidate_rows)
    write_jsonl_fixture(File.join(review, "holds.jsonl"), hold_rows)
    integrity = {
      "schema_version" => "af-production-snapshot-integrity-report/v0.1",
      "candidates" => candidate_rows.length,
      "holds" => hold_rows.length,
      "mechanically_invalid_runs" => 0,
      "expectation_match" => true,
      "errors" => []
    }
    File.write(File.join(review, "integrity_report.json"), JSON.pretty_generate(integrity) + "\n")
    AfDataPipeline::EditorialAudit.initialize!(review_dir: review, audit_dir: audit)

    ledger_path = File.join(audit, "editorial_decisions.csv")
    table = CSV.read(ledger_path, headers: true)
    table.each do |row|
      next unless row["record_type"] == "candidate"
      decision = decisions.fetch(row["record_key"], "ACCEPT")
      row["editorial_decision"] = decision
      row["editorial_note"] = "Synthetic editorial note." if %w[HOLD REJECT].include?(decision)
    end
    CSV.open(ledger_path, "w", write_headers: true, headers: table.headers) do |csv|
      table.each { |row| csv << table.headers.map { |header| row[header] } }
    end
    { review:, audit:, ledger: ledger_path }
  end

  def corrupt_inline_cell(path, before:, after:)
    Zip::File.open(path) do |zip|
      entry = zip.find_entry("xl/worksheets/sheet1.xml")
      xml = entry.get_input_stream.read
      raise "fixture text not found" unless xml.include?(before)

      zip.get_output_stream(entry) { |stream| stream.write(xml.sub(before, after)) }
    end
  end

  private

  def write_jsonl_fixture(path, rows)
    File.open(path, "w") { |file| rows.each { |row| file.puts(JSON.generate(row)) } }
  end

  def cell_reference(column_number, row_number)
    number = column_number
    letters = +""
    while number.positive?
      number -= 1
      letters.prepend((65 + (number % 26)).chr)
      number /= 26
    end
    "#{letters}#{row_number}"
  end

  def inline_cell(reference, value, style:)
    %(<c r="#{reference}" s="#{style}" t="inlineStr"><is><t>#{CGI.escapeHTML(value.to_s)}</t></is></c>)
  end

  def numeric_or_blank_cell(reference, value, style:)
    value.nil? ? %(<c r="#{reference}" s="#{style}"/>) : %(<c r="#{reference}" s="#{style}"><v>#{value}</v></c>)
  end

  def styles_xml(red_style_match:)
    red_alignment = red_style_match ? %(horizontal="left" vertical="bottom") : %(horizontal="center" vertical="center")
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <styleSheet xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}">
        <fonts count="1"><font><name val="Arial"/><sz val="10"/></font></fonts>
        <fills count="4">
          <fill><patternFill patternType="none"/></fill>
          <fill><patternFill patternType="gray125"/></fill>
          <fill><patternFill patternType="solid"><fgColor rgb="FFD9EAD3"/><bgColor indexed="64"/></patternFill></fill>
          <fill><patternFill patternType="solid"><fgColor rgb="FFF4CCCC"/><bgColor indexed="64"/></patternFill></fill>
        </fills>
        <borders count="1"><border/></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="6">
          <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
          <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="left" vertical="bottom"/></xf>
          <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment horizontal="center"/></xf>
          <xf numFmtId="0" fontId="0" fillId="1" borderId="0" xfId="0"/>
          <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0"><alignment horizontal="right"/></xf>
          <xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyAlignment="1"><alignment #{red_alignment}/></xf>
        </cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
      </styleSheet>
    XML
  end

  def content_types_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
      </Types>
    XML
  end

  def package_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="#{AfDataPipeline::AmcApply::PACKAGE_REL_NS}">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      </Relationships>
    XML
  end

  def workbook_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}" xmlns:r="#{AfDataPipeline::AmcApply::OFFICE_REL_NS}">
        <sheets><sheet name="Adventure Catalog" sheetId="1" r:id="rId1"/><sheet name="Auxiliary" sheetId="2" r:id="rId2"/></sheets>
      </workbook>
    XML
  end

  def workbook_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="#{AfDataPipeline::AmcApply::PACKAGE_REL_NS}">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      </Relationships>
    XML
  end

  def auxiliary_sheet_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}"><dimension ref="A1"/><sheetData><row r="1"><c r="A1"><v>99</v></c></row></sheetData></worksheet>
    XML
  end

  def core_properties_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Synthetic AMC</dc:title></cp:coreProperties>
    XML
  end
end
