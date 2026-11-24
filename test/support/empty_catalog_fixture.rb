# frozen_string_literal: true

require_relative "compatibility_amc_fixture"

# Builds content-free, finite XLSX capacity from public test helpers, never a
# private catalog. Filesystem/ZIP errors propagate to the caller.
module EmptyCatalogFixture
  include CompatibilityAmcFixture

  # Writes a zero-record split workbook to path and returns it. Four catalog
  # slots and two Current Books slots have explicit styles; no identities or
  # assessment values are seeded. Raises ArgumentError for an occupied path,
  # or normal filesystem/ZIP errors for invalid destinations.
  def write_empty_catalog(path)
    raise ArgumentError, "empty fixture destination already exists: #{path}" if File.exist?(path)
    write_compatible_amc(path, rows: [], mirror_large: false)
    Zip::File.open(path) do |zip|
      [1, 2].each do |sheet_number|
        part = "xl/worksheets/sheet#{sheet_number}.xml"
        first = sheet_number == 1 ? 2 : 3
        headers = sheet_number == 1 ? HEADERS : [*HEADERS, ">99 pgs"]
        blanks = (first..first + 3).map do |row|
          xml_row(row, headers.each_with_index.map do |header, index|
            style = %w[ADV\ -\ ID Adventure\ Title Source\ Book Book\ Publisher].include?(header) ? 3 : 1
            %(<c r="#{cell_ref(index + 1, row)}" s="#{style}"/>)
          end)
        end.join
        xml = zip.read(part).sub("</sheetData>", blanks + "</sheetData>")
        zip.get_output_stream(part) { |stream| stream.write(xml) }
      end
      part = "xl/worksheets/sheet3.xml"
      xml = zip.read(part).sub("B4/$B$2", "IF($B$2=0,0,B4/$B$2)").sub("G4/$G$2", "IF($G$2=0,0,G4/$G$2)")
      xml = xml.sub(text_cell("D4", "Various"), blank_cell("D4"))
      # Split totals include the large summary once; fixed ranges include both
      # declared identity slots, including after a second insertion.
      {"SUM(A3:A4)-A4" => "SUM(A3:A6)", "SUM(B3:B4)-B4" => "SUM(B3:B6)",
       "SUM(F3:F4)-F4" => "SUM(F3:F6)", "SUM(G3:G4)-G4" => "SUM(G3:G6)"}.each { |before, after| xml = xml.sub(before, after) }
      blanks = (5..6).map do |row|
        xml_row(row, ("A".."I").map do |column|
          style = %w[A F].include?(column) ? 2 : (%w[C D H].include?(column) ? 3 : 1)
          %(<c r="#{column}#{row}" s="#{style}"/>)
        end)
      end.join
      zip.get_output_stream(part) { |stream| stream.write(xml.sub("</sheetData>", blanks + "</sheetData>")) }
      types = zip.read("[Content_Types].xml").sub("</Types>", '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>')
      zip.get_output_stream("[Content_Types].xml") { |stream| stream.write(types) }
      rels = zip.read("xl/_rels/workbook.xml.rels").sub("</Relationships>", '<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>')
      zip.get_output_stream("xl/_rels/workbook.xml.rels") { |stream| stream.write(rels) }
      zip.get_output_stream("xl/styles.xml") do |stream|
        stream.write(<<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <styleSheet xmlns="#{AfDataPipeline::AmcApply::MAIN_NS}">
            <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
            <borders count="1"><border/></borders>
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
            <cellXfs count="4">
              <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
              <xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
              <xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
              <xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
            </cellXfs>
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
          </styleSheet>
        XML
      end
      zip.each { |entry| entry.time = Time.local(2026, 1, 1) }
    end
    path
  end
end
