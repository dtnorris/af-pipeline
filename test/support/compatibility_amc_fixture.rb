# frozen_string_literal: true

require "cgi"
require "zip"

module CompatibilityAmcFixture
  WORKBOOK_BYTES_CACHE = {}

  HEADERS = [
    "ADV - ID", "Adventure Title", "Played", "Page Count", "Source Book", "Book Publisher",
    "Start Page", "End Page", "Number of Sessions", "Level Start", "Level End",
    "Combat Emphasis", "Social Interaction Emphasis", "Exploration Emphasis", "Investigation Emphasis",
    "Structural Openness", "Darkness / Horror Intensity", "Player Beginner Suitability",
    "GM Beginner Suitability", "GM Preparation Burden", "Seriousness",
    "Rules / System-Master Demand", "Tactical Complexity", "Lethality / Failure Severity",
    "Puzzle / Problem-Solving Emphasis", "Consequential Player Agency", "Fantastic Weirdness",
    "GM Improvisation Demand", "Scored"
  ].freeze

  def compatible_row(id, title:, source: "Fixture Book", publisher: "Fixture Publisher",
                     start_page: 10, end_page: 21, levels: [3, 5], scores: {})
    {
      id:, title:, source:, publisher:, start_page:, end_page:, levels:, scores:
    }
  end

  def write_compatible_amc(path, rows:, mirror_large: true, large_snapshot_ids: nil)
    cache_key = Marshal.dump([rows, mirror_large, large_snapshot_ids])
    if (bytes = WORKBOOK_BYTES_CACHE[cache_key])
      File.binwrite(path, bytes)
      return path
    end

    ordinary_rows = rows.select { |row| mirror_large || page_count(row) < 100 }
    large_rows = rows.select do |row|
      page_count(row) >= 100 &&
        (large_snapshot_ids.nil? || large_snapshot_ids.include?(row.fetch(:id)))
    end

    ordinary_xml_rows = [xml_row(1, header_cells(HEADERS))]
    ordinary_rows.each_with_index do |row, index|
      ordinary_xml_rows << catalog_xml_row(index + 2, row, HEADERS)
    end

    large_headers = [*HEADERS, ">99 pgs"]
    large_xml_rows = [xml_row(1, header_cells(large_headers))]
    large_xml_rows << xml_row(2, [formula_cell("B2", "COUNTA(A3:A1000)", large_rows.length)])
    large_rows.each_with_index do |row, index|
      large_xml_rows << catalog_xml_row(index + 3, row, large_headers, large: true)
    end

    books_xml_rows = current_books_rows(ordinary_rows, large_rows, mirror_large:)

    entries = {
      "[Content_Types].xml" => compatibility_content_types_xml,
      "_rels/.rels" => package_rels_xml,
      "xl/workbook.xml" => compatibility_workbook_xml,
      "xl/_rels/workbook.xml.rels" => compatibility_workbook_rels_xml,
      "xl/worksheets/sheet1.xml" => worksheet_xml(ordinary_xml_rows),
      "xl/worksheets/sheet2.xml" => worksheet_xml(large_xml_rows),
      "xl/worksheets/sheet3.xml" => worksheet_xml(books_xml_rows)
    }
    Zip::File.open(path, create: true) do |zip|
      entries.each { |name, content| zip.get_output_stream(name) { |stream| stream.write(content) } }
    end
    WORKBOOK_BYTES_CACHE[cache_key] = File.binread(path).freeze
    path
  end

  def replace_zip_text(path, member, before, after)
    Zip::File.open(path) do |zip|
      entry = zip.find_entry(member) or raise "missing fixture member #{member}"
      xml = entry.get_input_stream.read
      raise "fixture text not found: #{before}" unless xml.include?(before)
      zip.get_output_stream(entry) { |stream| stream.write(xml.sub(before, after)) }
    end
  end

  private

  def page_count(row)
    row.fetch(:end_page) - row.fetch(:start_page) + 1
  end

  def header_cells(headers)
    headers.each_with_index.map { |header, index| text_cell(cell_ref(index + 1, 1), header) }
  end

  def catalog_xml_row(row_number, row, headers, large: false)
    columns = headers.each_with_index.to_h { |header, index| [header, cell_ref(index + 1, row_number).sub(/\d+\z/, "")] }
    scores = row.fetch(:scores, {})
    levels = row[:levels]
    values = {
      "Played" => nil,
      "Number of Sessions" => scores["Number of Sessions"],
      "Level Start" => levels && levels[0],
      "Level End" => levels && levels[1],
      "Combat Emphasis" => scores["Combat Emphasis"],
      "Social Interaction Emphasis" => scores["Social Interaction Emphasis"],
      "Exploration Emphasis" => scores["Exploration Emphasis"],
      "Investigation Emphasis" => scores["Investigation Emphasis"],
      "Structural Openness" => scores["Structural Openness"],
      "Darkness / Horror Intensity" => scores["Darkness / Horror Intensity"],
      "Player Beginner Suitability" => scores["Player Beginner Suitability"],
      "GM Beginner Suitability" => scores["GM Beginner Suitability"],
      "GM Preparation Burden" => scores["GM Preparation Burden"],
      "Seriousness" => scores["Seriousness"],
      "Rules / System-Master Demand" => scores["Rules / System-Master Demand"],
      "Tactical Complexity" => scores["Tactical Complexity"],
      "Lethality / Failure Severity" => scores["Lethality / Failure Severity"],
      "Puzzle / Problem-Solving Emphasis" => scores["Puzzle / Problem-Solving Emphasis"],
      "Consequential Player Agency" => scores["Consequential Player Agency"],
      "Fantastic Weirdness" => scores["Fantastic Weirdness"],
      "GM Improvisation Demand" => scores["GM Improvisation Demand"]
    }

    cells = [
      text_cell("#{columns.fetch('ADV - ID')}#{row_number}", row.fetch(:id)),
      text_cell("#{columns.fetch('Adventure Title')}#{row_number}", row.fetch(:title)),
      blank_cell("#{columns.fetch('Played')}#{row_number}"),
      formula_cell("#{columns.fetch('Page Count')}#{row_number}", "1+#{columns.fetch('End Page')}#{row_number}-#{columns.fetch('Start Page')}#{row_number}", page_count(row)),
      text_cell("#{columns.fetch('Source Book')}#{row_number}", row.fetch(:source)),
      text_cell("#{columns.fetch('Book Publisher')}#{row_number}", row.fetch(:publisher)),
      number_cell("#{columns.fetch('Start Page')}#{row_number}", row.fetch(:start_page)),
      number_cell("#{columns.fetch('End Page')}#{row_number}", row.fetch(:end_page))
    ]

    HEADERS[8..27].each do |header|
      reference = "#{columns.fetch(header)}#{row_number}"
      value = values[header]
      cells << (value.nil? ? blank_cell(reference) : number_cell(reference, value))
    end

    scored_cache = HEADERS[8..20].count { |header| values[header].is_a?(Numeric) }
    cells << formula_cell(
      "#{columns.fetch('Scored')}#{row_number}",
      "COUNT(#{columns.fetch('Number of Sessions')}#{row_number}:#{columns.fetch('Seriousness')}#{row_number})",
      scored_cache
    )
    if large
      cells << formula_cell(
        "#{columns.fetch('>99 pgs')}#{row_number}",
        "IF(#{columns.fetch('Page Count')}#{row_number}>99,1,0)",
        1
      )
    end
    xml_row(row_number, cells)
  end

  def current_books_rows(ordinary_rows, large_rows, mirror_large:)
    special = AfDataPipeline::BoundaryFreezeApply::SPECIAL_LARGE_LABEL
    sources = ordinary_rows.group_by { |row| row.fetch(:source) }
    publishers = ordinary_rows.group_by { |row| row.fetch(:publisher) }
    canonical_count = (ordinary_rows.map { |row| row.fetch(:id) } | large_rows.map { |row| row.fetch(:id) }).length

    source_special_row = 4
    source_start = 5
    publisher_special_row = 4
    publisher_start = 5
    source_last = [source_start + sources.length - 1, source_special_row].max
    publisher_last = [publisher_start + publishers.length - 1, publisher_special_row].max

    live_large_count = if mirror_large
                         ordinary_rows.count { |row| page_count(row) >= 100 }
                       else
                         large_rows.length
                       end
    live_large_formula = if mirror_large
                           %(COUNTIF('Adventure Catalog'!D:D,">=100"))
                         else
                           "'AMC >100pg'!B2"
                         end

    rows = [xml_row(1, [])]
    rows << xml_row(2, [
      formula_cell("A2", "SUM(A3:A#{source_last})-A#{source_special_row}", canonical_count.zero? ? 0 : 1.0),
      formula_cell("B2", "SUM(B3:B#{source_last})-B#{source_special_row}", canonical_count),
      formula_cell("C2", "COUNTA(C3:C#{source_last})-COUNTIF(C3:C#{source_last},\"#{special}\")", sources.length),
      formula_cell("F2", "SUM(F3:F#{publisher_last})-F#{publisher_special_row}", canonical_count.zero? ? 0 : 1.0),
      formula_cell("G2", "SUM(G3:G#{publisher_last})-G#{publisher_special_row}", canonical_count),
      formula_cell("H2", "COUNTA(H3:H#{publisher_last})-COUNTIF(H3:H#{publisher_last},\"#{special}\")", publishers.length)
    ])
    rows << xml_row(3, [])
    rows << xml_row(4, [
      formula_cell("A4", "B4/$B$2", canonical_count.zero? ? 0 : live_large_count.fdiv(canonical_count)),
      formula_cell("B4", live_large_formula, live_large_count),
      text_cell("C4", special),
      text_cell("D4", "Various"),
      formula_cell("E4", "$B$2", canonical_count),
      formula_cell("F4", "G4/$G$2", canonical_count.zero? ? 0 : live_large_count.fdiv(canonical_count)),
      formula_cell("G4", live_large_formula, live_large_count),
      text_cell("H4", special),
      formula_cell("I4", "$G$2", canonical_count)
    ])

    sources.keys.sort.each_with_index do |source, index|
      row_number = source_start + index
      entries = sources.fetch(source)
      publisher = entries.map { |row| row.fetch(:publisher) }.uniq.one? ? entries.first.fetch(:publisher) : "Various"
      count = entries.length
      rows << xml_row(row_number, [
        formula_cell("A#{row_number}", "B#{row_number}/$B$2", canonical_count.zero? ? 0 : count.fdiv(canonical_count)),
        formula_cell("B#{row_number}", "COUNTIF('Adventure Catalog'!E:E,C#{row_number})", count),
        text_cell("C#{row_number}", source),
        text_cell("D#{row_number}", publisher),
        formula_cell("E#{row_number}", "$B$2", canonical_count)
      ])
    end

    publishers.keys.sort.each_with_index do |publisher, index|
      row_number = publisher_start + index
      count = publishers.fetch(publisher).length
      existing = rows.find { |xml| xml.start_with?(%(<row r="#{row_number}")) }
      publisher_cells = [
        formula_cell("F#{row_number}", "G#{row_number}/$G$2", canonical_count.zero? ? 0 : count.fdiv(canonical_count)),
        formula_cell("G#{row_number}", "COUNTIF('Adventure Catalog'!F:F,H#{row_number})", count),
        text_cell("H#{row_number}", publisher),
        formula_cell("I#{row_number}", "$G$2", canonical_count)
      ]
      if existing
        rows[rows.index(existing)] = existing.sub("</row>", publisher_cells.join + "</row>")
      else
        rows << xml_row(row_number, publisher_cells)
      end
    end

    rows.sort_by { |xml| xml[/<row r="(\d+)"/, 1].to_i }
  end

  def worksheet_xml(rows)
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}"><sheetData>#{rows.join}</sheetData></worksheet>
    XML
  end

  def xml_row(row, cells)
    %(<row r="#{row}">#{cells.join}</row>)
  end

  def text_cell(reference, value)
    %(<c r="#{reference}" t="str"><v>#{CGI.escapeHTML(value.to_s)}</v></c>)
  end

  def number_cell(reference, value)
    %(<c r="#{reference}" t="n"><v>#{value}</v></c>)
  end

  def blank_cell(reference)
    %(<c r="#{reference}"/>)
  end

  def formula_cell(reference, formula, cache)
    %(<c r="#{reference}"><f>#{CGI.escapeHTML(formula.to_s)}</f><v>#{cache}</v></c>)
  end

  def cell_ref(column_number, row)
    number = column_number
    letters = +""
    while number.positive?
      number -= 1
      letters.prepend((65 + (number % 26)).chr)
      number /= 26
    end
    "#{letters}#{row}"
  end

  def compatibility_content_types_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      </Types>
    XML
  end

  def package_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="#{AfDataPipeline::AmcApply::PACKAGE_REL_NS}">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>
    XML
  end

  def compatibility_workbook_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}" xmlns:r="#{AfDataPipeline::AmcApply::OFFICE_REL_NS}">
        <sheets>
          <sheet name="Adventure Catalog" sheetId="1" r:id="rId1"/>
          <sheet name="AMC &gt;100pg" sheetId="2" r:id="rId2"/>
          <sheet name="Current Books" sheetId="3" r:id="rId3"/>
        </sheets>
      </workbook>
    XML
  end

  def compatibility_workbook_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="#{AfDataPipeline::AmcApply::PACKAGE_REL_NS}">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
      </Relationships>
    XML
  end
end
