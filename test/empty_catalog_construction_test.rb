# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "rexml/document"
require "rexml/xpath"
require "open3"
require "rbconfig"
require_relative "../lib/af_data_pipeline/project_state"
require_relative "../lib/af_data_pipeline/ingest_next"
require_relative "../lib/af_data_pipeline/amc_compatibility_check"
require_relative "support/empty_catalog_fixture"
require_relative "support/staged_scoring_fixture"

# Uses actual approval, freeze, allocation, stage and compatibility owners with
# mechanical workbook/source bytes. No internal validators or Git are doubled.
class EmptyCatalogConstructionTest < Minitest::Test
  include EmptyCatalogFixture
  include StagedScoringFixture

  # Helper objects returned to pipeline callers translate errors locally;
  # loading both libraries must leave standalone owner failures unchanged.
  def test_helper_errors_preserve_pipeline_rescues_and_standalone_owner_classes
    with_empty_catalog do |_root, base|
      pipeline = AfDataPipeline::BoundaryFreezeApply::Workbook.new(base).sheet_by_name!("Adventure Catalog")
      error = assert_raises(AfDataPipeline::ValidationError) { pipeline.next_available_rows(1000) }
      assert_instance_of AfDataPipeline::ValidationError, error
      owner = AfXlsxFiles::BoundaryFreezeApply::Workbook.new(base).sheet_by_name!("Adventure Catalog")
      assert_instance_of AfXlsxFiles::ValidationError, assert_raises(AfXlsxFiles::ValidationError) { owner.next_available_rows(1000) }
      assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::AmcApply::Workbook.new(base) }
      assert_raises(AfXlsxFiles::ValidationError) { AfXlsxFiles::AmcApply::Workbook.new(base) }
    end
  end

  # Blank, numeric zero, -1 and Uncertain remain distinct through the moved
  # parser. Real PL staging refuses occupied assessment slots without publishing.
  def test_scalar_distinctions_preserve_occupied_target_refusal
    with_empty_catalog do |root, base|
      {"L2" => 0, "M2" => -1, "J2" => "Uncertain"}.each { |reference, value| change_cell(base, reference, value) }
      sheet = AfDataPipeline::BoundaryFreezeApply::Workbook.new(base).sheet_by_name!("Adventure Catalog")
      assert_equal 0, sheet.cell_value("L2")
      assert_equal(-1, sheet.cell_value("M2"))
      assert_equal "Uncertain", sheet.cell_value("J2")
      assert_nil sheet.cell_value("K2")
      %w[L2 M2 J2].each { |reference| refute sheet.blank_cell?(sheet.cell(reference)) }
      assert sheet.blank_cell?(sheet.cell("K2"))
      write_state(File.join(root, "PROJECT_STATE.yml"), base)
      evidence = approved_input(root, base, lengths: [2])
      before = snapshot(root)
      assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::BoundaryFreezeStage.stage!(**evidence) }
      assert_equal before, snapshot(root)
    end
  end

  # Exercise the public constructor and actual staging executable, including a
  # recomputed-digest semantic conflict, missing explicit owner and cold replay.
  # All fixtures remain mechanical; no Git or internal validator is doubled.
  def test_public_owner_constructor_delegates_through_cli
    Dir.mktmpdir("public-xl-stage-", File.realpath(Dir.tmpdir)) do |root|
      base = AfXlsxFiles::EmptyCatalog.create!(path: File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx"),
        version: "0.1", ordinary_capacity: 4, large_capacity: 4, source_capacity: 2, publisher_capacity: 2)
      write_state(File.join(root, "PROJECT_STATE.yml"), base)
      evidence = approved_input(root, base, lengths: [100, 2])
      owner = File.expand_path("../..", $LOADED_FEATURES.find { |path| path.end_with?("/af_xlsx_files.rb") })
      command = [RbConfig.ruby, File.expand_path("../bin/af-data", __dir__), "boundary-freeze-stage",
        evidence.fetch(:freeze_path), "--source-root", evidence.fetch(:source_root), "--catalog-root", root,
        "--operation-input", evidence.fetch(:operation_input_path), "--successor-authority", evidence.fetch(:successor_authorization_path), "--no-progress"]
      original = File.binread(evidence.fetch(:successor_authorization_path))
      projection = JSON.parse(original)
      authorization = projection.fetch("authorization")
      authorization.fetch("operation")["operation_id"] = "22222222-2222-4222-8222-222222222222"
      authorization["authorization_id"] = AUTH.digest(authorization.except("authorization_id"))
      write_json(evidence.fetch(:successor_authorization_path), projection)
      protected = snapshot(root)
      _stdout, stderr, status = Open3.capture3({"AF_XLSX_FILES_ROOT" => owner}, *command)
      assert_equal 2, status.exitstatus
      assert_includes stderr, "authorization conflicts with operation input"
      assert_equal protected, snapshot(root)
      File.binwrite(evidence.fetch(:successor_authorization_path), original)
      protected = snapshot(root)
      _stdout, stderr, status = Open3.capture3({"AF_XLSX_FILES_ROOT" => File.join(root, "missing-owner")}, *command)
      refute status.success?
      assert_includes stderr, "AF_XLSX_FILES_ROOT"
      assert_equal protected, snapshot(root)
      _stdout, stderr, status = Open3.capture3({"AF_XLSX_FILES_ROOT" => owner}, *command)
      assert status.success?, stderr
      result = AfDataPipeline::BoundaryFreezeStage.verify!(**evidence)
      assert_successor(base, result, [100, 2])
      protected = snapshot(root)
      _stdout, stderr, status = Open3.capture3({"AF_XLSX_FILES_ROOT" => owner}, *command)
      assert status.success?, stderr
      assert_equal protected, snapshot(root)
    end
  end

  # Independently inspects zero identities, finite styled capacity and ZIP parts,
  # then submits the representation to the production compatibility validator.
  def test_empty_representation_is_compatible
    with_empty_catalog do |_root, base|
      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(base)
      assert_equal ["Adventure Catalog", "AMC >100pg", "Current Books"], workbook.sheet_identity.map(&:first)
      %w[Adventure\ Catalog AMC\ >100pg].each do |name|
        sheet = workbook.sheet_by_name!(name)
        assert_empty sheet.catalog_records
        sheet.validate_catalog_schema!
        first = name == "Adventure Catalog" ? 2 : 3
        assert_equal [first, first + 1], sheet.next_available_rows(2)
        assert sheet.cell_references.grep(/\d+$/).any?
        assert_equal "3", sheet.cell("A#{first}").attributes["s"]
      end
      books = workbook.sheet_by_name!("Current Books")
      assert_equal [4], books.rows_with_nonblank("C")
      assert_equal [4], books.rows_with_nonblank("H")
      %w[B2 C2 G2 H2].each { |reference| assert_equal 0, books.cell_value(reference) }
      assert_equal "IF($B$2=0,0,B4/$B$2)", books.cell_formula(books.cell("A4"))
      assert_equal "IF($G$2=0,0,G4/$G$2)", books.cell_formula(books.cell("F4"))
      Zip::File.open(base) do |zip|
        assert_includes zip.read("xl/_rels/workbook.xml.rels"), 'Target="styles.xml"'
        assert_includes zip.read("[Content_Types].xml"), 'PartName="/xl/styles.xml"'
        assert_includes zip.read("xl/styles.xml"), 'cellXfs count="4"'
      end
      assert_equal "PASS", AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: base).fetch("status")
      replica = write_empty_catalog(File.join(File.dirname(base), "replica.xlsx"))
      assert_equal Digest::SHA256.file(base).hexdigest, Digest::SHA256.file(replica).hexdigest
    end
  end

  # Each independent first input passes real editorial approval, plan/apply and
  # operation-bound stage; IDs follow frozen order across the two sheet ranges.
  def test_first_ordinary_large_and_mixed_successors
    [[2], [100], [100, 2, 101]].each do |lengths|
      with_empty_catalog do |root, base|
        evidence = approved_input(root, base, lengths: lengths)
        protected = snapshot(root)
        freeze = AfDataPipeline::BoundaryFreeze.validate!(freeze_path: evidence.fetch(:freeze_path), source_root: evidence.fetch(:source_root), amc_path: base)
        assert_equal lengths.length, freeze.artifact.fetch("records").length
        plan = AfDataPipeline::BoundaryFreezeApply.plan!(**apply_options(evidence, base))
        direct = AfDataPipeline::BoundaryFreezeApply.apply!(**apply_options(evidence, base), output_path: File.join(root, "direct.xlsx"))
        assert_equal plan.fetch("records"), direct.report.fetch("records")
        result = AfDataPipeline::BoundaryFreezeStage.stage!(**evidence)
        assert_successor(base, result, lengths)
        assert_equal protected, snapshot(root).slice(*protected.keys)
        replay_before = snapshot(root)
        assert AfDataPipeline::BoundaryFreezeStage.stage!(**evidence).reused
        assert_equal result.receipt, AfDataPipeline::BoundaryFreezeStage.verify!(**evidence).receipt
        assert_equal replay_before, snapshot(root)
      end
    end
  end

  # Separately exercises source and publisher first-template selection. The
  # publisher case supplies a real first source, so no source refusal masks it.
  def test_first_source_uses_declared_blank_styles
    with_empty_catalog do |_root, base|
      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(base)
      ordinary = workbook.sheet_by_name!("Adventure Catalog")
      large = workbook.sheet_by_name!("AMC >100pg")
      books = workbook.sheet_by_name!("Current Books")
      books.refresh_current_books!(ordinary: ordinary, large: large, source_id: "Mechanical Source", publisher: "Mechanical Publisher", large_sheet_mirrors_ordinary: false)
      %w[A B C D E F G H I].each do |column|
        expected = %w[A F].include?(column) ? "2" : (%w[C D H].include?(column) ? "3" : "1")
        assert_equal expected, books.cell("#{column}5").attributes["s"]
      end
      assert_equal "IF($B$2=0,0,B5/$B$2)", books.cell_formula(books.cell("A5"))
      assert_equal 0.0, books.cell_value("A5")
      assert_equal 0.0, books.cell_value("F5")
    end
  end

  # Exercises the publisher branch independently of first-source insertion.
  def test_first_publisher_uses_declared_blank_styles
    with_empty_catalog do |_root, base|
      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(base)
      books = workbook.sheet_by_name!("Current Books")
      # A source identity exists, but there is still no ordinary publisher row.
      books.send(:set_text!, "C5", "Mechanical Source")
      books.send(:set_text!, "D5", "Mechanical Publisher")
      summary = books.refresh_current_books!(ordinary: workbook.sheet_by_name!("Adventure Catalog"), large: workbook.sheet_by_name!("AMC >100pg"), source_id: "Mechanical Source", publisher: "Mechanical Publisher", large_sheet_mirrors_ordinary: false)
      refute summary.fetch("source_added")
      assert summary.fetch("publisher_added")
      assert_equal "Mechanical Publisher", books.cell_value("H5")
    end
  end

  # A second explicitly bound staged base receives subsequent IDs without
  # promoting roles or changing retained first-stage evidence or original bytes.
  def test_second_source_and_publisher_preserve_first_records_and_roles
    with_empty_catalog do |root, base|
      first_evidence = approved_input(root, base, lengths: [2, 100])
      first = AfDataPipeline::BoundaryFreezeStage.stage!(**first_evidence)
      # Direct construction supplies the next explicitly selected mechanical
      # base at its required versioned name. No role adoption is performed.
      next_base = File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx")
      AfDataPipeline::BoundaryFreezeApply.apply!(**apply_options(first_evidence, base), output_path: next_base)
      protected = snapshot(root)
      evidence = approved_input(root, next_base, lengths: [3, 101], source_id: "Second Mechanical Source", publisher: "Second Mechanical Publisher", version: "0.3")
      second = AfDataPipeline::BoundaryFreezeStage.stage!(**evidence)
      report = JSON.parse(File.read(second.report_path))
      assert_equal %w[ADV-0003 ADV-0004], report.fetch("records").map { |record| record.fetch("adventure_id") }
      before = AfDataPipeline::BoundaryFreezeApply::Workbook.new(first.output_path)
      after = AfDataPipeline::BoundaryFreezeApply::Workbook.new(second.output_path)
      ["Adventure Catalog", "AMC >100pg"].each do |name|
        original_sheet = before.sheet_by_name!(name)
        successor_sheet = after.sheet_by_name!(name)
        row = original_sheet.catalog_records.first.fetch("row")
        original_sheet.cell_snapshots.each do |reference, bytes|
          next unless reference.match?(/\D#{row}\z/)
          assert_equal bytes, successor_sheet.cell_snapshots.fetch(reference)
        end
      end
      books = after.sheet_by_name!("Current Books")
      assert_equal "Mechanical Source", books.cell_value("C5")
      assert_equal "Second Mechanical Source", books.cell_value("C6")
      assert_equal "Mechanical Publisher", books.cell_value("H5")
      assert_equal "Second Mechanical Publisher", books.cell_value("H6")
      %w[B2 G2].each { |reference| assert_equal 4, books.cell_value(reference) }
      %w[C2 H2].each { |reference| assert_equal 2, books.cell_value(reference) }
      assert_equal "PASS", AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: second.output_path, base_path: first.output_path).fetch("status")
      assert_equal protected, snapshot(root).slice(*protected.keys)
      replay_before = snapshot(root)
      assert AfDataPipeline::BoundaryFreezeStage.stage!(**evidence).reused
      assert_equal replay_before, snapshot(root)
    end
  end

  # Existing populated split and legacy mirrored layouts keep their established
  # append positions and max-ID allocation. Historical formulas remain literal.
  def test_populated_split_and_legacy_mirrored_layouts_still_append
    [false, true].each do |mirrored|
      Dir.mktmpdir("populated-construction-", File.realpath(Dir.tmpdir)) do |root|
        base = File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx")
        write_compatible_amc(base, mirror_large: mirrored, rows: [
          compatible_row("ADV-0007", title: "Mechanical Existing 1", start_page: 1, end_page: 2),
          compatible_row("ADV-0009", title: "Mechanical Existing 2", start_page: 1, end_page: 100)
        ])
        Zip::File.open(base) do |zip|
          (1..3).each do |number|
            part = "xl/worksheets/sheet#{number}.xml"
            xml = zip.read(part)
            last = xml.scan(/<row r="(\d+)"/).flatten.map(&:to_i).max
            blanks = (last + 1..last + 3).map { |row| xml_row(row, []) }.join
            zip.get_output_stream(part) { |stream| stream.write(xml.sub("</sheetData>", blanks + "</sheetData>")) }
          end
        end
        write_state(File.join(root, "PROJECT_STATE.yml"), base)
        evidence = approved_input(root, base, lengths: [2, 100])
        result = AfDataPipeline::BoundaryFreezeStage.stage!(**evidence)
        report = JSON.parse(File.read(result.report_path))
        assert_equal %w[ADV-0010 ADV-0011], report.fetch("records").map { |record| record.fetch("adventure_id") }
        positions = report.fetch("records").map { |record| [record.fetch("sheet"), record.fetch("row")] }
        expected = mirrored ? [["Adventure Catalog", 4], ["Adventure Catalog", 5]] : [["Adventure Catalog", 3], ["AMC >100pg", 4]]
        assert_equal expected, positions
        books = AfDataPipeline::BoundaryFreezeApply::Workbook.new(result.output_path).sheet_by_name!("Current Books")
        assert_equal "B4/$B$2", books.cell_formula(books.cell("A4"))
        assert_equal "G4/$G$2", books.cell_formula(books.cell("F4"))
        assert_equal "PASS", AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: result.output_path, base_path: base).fetch("status")
      end
    end
  end

  # Malformed headers, summary labels, styles, capacity and occupied targets
  # refuse before any successor/report is published. Never scan past a target.
  def test_malformed_empty_inputs_refuse_without_publication
    cases = [
      [1, text_cell("E1", "Source Book"), text_cell("E1", "Missing"), /missing required headers/],
      [1, text_cell("C1", "Played"), text_cell("C1", "Source Book"), /ambiguous header/],
      [1, '<c r="A2" s="3"/>', text_cell("A2", "occupied"), /target row 2 is not blank/],
      [2, '<c r="A3" s="3"/>', formula_cell("A3", "0", 0), /target row 3 is not blank/],
      [1, '<row r="2">', '<row r="20">', /missing row 2/],
      [3, text_cell("C4", ">100 page Adventures"), text_cell("C4", "Missing"), /exactly one/],
      [3, '<c r="A5" s="2"/>', formula_cell("A5", "0", 0), /target row 5 is not blank/],
      [3, '<c r="F5" s="2"/>', formula_cell("F5", "0", 0), /target row 5 is not blank/],
      [3, '<c r="C5" s="3"/>', '<c r="C5"/>', /styled blank first-insertion template/],
      [3, '<c r="H5" s="3"/>', '<c r="H5" s="999"/>', /styled blank first-insertion template/],
      [3, '<row r="5">', '<row r="50">', /missing row 5/]
    ]
    cases.each do |sheet, original, replacement, message|
      with_empty_catalog do |root, base|
        replace_zip_text(base, "xl/worksheets/sheet#{sheet}.xml", original, replacement)
        evidence = approved_input(root, base, lengths: [100, 2])
        before = snapshot(root)
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::BoundaryFreezeApply.apply!(**apply_options(evidence, base), output_path: File.join(root, "refused.xlsx"))
        end
        assert_match message, error.message
        assert_equal before, snapshot(root)
      end
    end
  end

  # Exact formula alternatives and caches are checked at zero/nonzero totals;
  # a changed guard or fabricated cache cannot masquerade as zero safety.
  def test_guarded_ratio_extension_is_exact_and_preserves_legacy_formulas
    with_empty_catalog do |root, base|
      assert_equal "PASS", AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: base).fetch("status")
      legacy = File.join(root, "legacy.xlsx")
      write_compatible_amc(legacy, rows: [compatible_row("ADV-0001", title: "Mechanical Record")])
      assert_equal "PASS", AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: legacy).fetch("status")
      replace_zip_text(base, "xl/worksheets/sheet3.xml", "IF($G$2=0,0,G4/$G$2)", "G4/$G$2")
      assert_equal "FAIL", AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: base).fetch("status")
      replace_zip_text(base, "xl/worksheets/sheet3.xml", "G4/$G$2", "IF($G$2=0,0,G4/$G$2)")
      replace_zip_text(base, "xl/worksheets/sheet3.xml", "IF($B$2=0,0,B4/$B$2)", "IF($B$2=0,1,B4/$B$2)")
      report = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: base)
      assert_equal "FAIL", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("A4 formula") }
      replace_zip_text(base, "xl/worksheets/sheet3.xml", "IF($B$2=0,1,B4/$B$2)", "IF($B$2=0,0,B4/$B$2)")
      replace_zip_text(base, "xl/worksheets/sheet3.xml", formula_cell("A4", "IF($B$2=0,0,B4/$B$2)", 0), formula_cell("A4", "IF($B$2=0,0,B4/$B$2)", 1))
      assert_equal "FAIL", AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: base).fetch("status")
    end
  end

  # Existing duplicate identities and exhausted finite capacity remain owner
  # refusals. A later source cannot consume an occupied or nonexistent slot.
  def test_duplicate_identities_and_exhausted_capacity_refuse
    ["id", "source", "publisher", "summary"].each do |kind|
      with_empty_catalog do |root, base|
        first_evidence = approved_input(root, base, lengths: [2, 3])
        next_base = File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx")
        AfDataPipeline::BoundaryFreezeApply.apply!(**apply_options(first_evidence, base), output_path: next_base)
        case kind
        when "id" then set_fixture_text(next_base, 1, "A3", "ADV-0001")
        when "source" then set_fixture_text(next_base, 3, "C6", "Mechanical Source")
        when "publisher" then set_fixture_text(next_base, 3, "H6", "Mechanical Publisher")
        when "summary" then set_fixture_text(next_base, 3, "C6", ">100 page Adventures")
        end
        evidence = approved_input(root, next_base, lengths: [4], version: "0.3")
        before = snapshot(root)
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::BoundaryFreezeApply.apply!(**apply_options(evidence, next_base), output_path: File.join(root, "refused.xlsx"))
        end
        assert_match(/duplicate|exactly one/, error.message)
        assert_equal before, snapshot(root)
      end
    end
    [2, 100].each do |length|
      with_empty_catalog do |root, base|
        evidence = approved_input(root, base, lengths: [length] * 5)
        before = snapshot(root)
        error = assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::BoundaryFreezeStage.stage!(**evidence) }
        assert_match(/insufficient preallocated blank rows/, error.message)
        assert_equal before, snapshot(root)
      end
    end
  end

  # Replay verifies the immutable operation/source/base/authorization tuple.
  # Partial and conflicting publications retain all bytes, without reallocation.
  def test_stage_replay_refuses_changed_inputs_and_partial_or_conflicting_destinations
    with_empty_catalog do |root, base|
      evidence = approved_input(root, base, lengths: [100, 2])
      result = AfDataPipeline::BoundaryFreezeStage.stage!(**evidence)
      mutations = [
        [evidence.fetch(:operation_input_path), ->(bytes) { bytes.sub('"revision": 1', '"revision": 2') }, /different|match|replay|inputs/],
        [evidence.fetch(:successor_authorization_path), ->(bytes) { bytes.sub('"successor_version": "0.2"', '"successor_version": "0.4"') }, /authorization/],
        [File.join(evidence.fetch(:source_root), "mechanical.md"), ->(bytes) { bytes + "changed\n" }, /changed|sha256|match/],
        [base, ->(bytes) { bytes + "changed" }, /changed|sha256|match/],
        [result.output_path, ->(bytes) { bytes + "changed" }, /provenance|match/]
      ]
      mutations.each do |path, mutation, message|
        original = File.binread(path)
        File.binwrite(path, mutation.call(original))
        before = snapshot(root)
        error = assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::BoundaryFreezeStage.stage!(**evidence) }
        assert_match message, error.message
        assert_equal before, snapshot(root)
        File.binwrite(path, original)
      end
      report_bytes = File.binread(result.report_path)
      File.unlink(result.report_path)
      before = snapshot(root)
      error = assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::BoundaryFreezeStage.stage!(**evidence) }
      assert_match(/partial staged-successor publication/, error.message)
      assert_equal before, snapshot(root)
      File.binwrite(result.report_path, report_bytes)
      File.binwrite(result.output_path, "conflicting destination")
      before = snapshot(root)
      assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::BoundaryFreezeStage.stage!(**evidence) }
      assert_equal before, snapshot(root)
    end
  end

  # Independent verification rejects an unrelated cell or package change even
  # when all allocated rows and their reported values remain intact.
  def test_integrity_refuses_unrelated_cell_and_package_changes
    with_empty_catalog do |root, base|
      evidence = approved_input(root, base, lengths: [2])
      result = AfDataPipeline::BoundaryFreezeStage.stage!(**evidence)
      original = File.binread(result.output_path)
      report = JSON.parse(File.read(result.report_path))
      ["cell", "package"].each do |kind|
        if kind == "cell"
          set_fixture_text(result.output_path, 1, "A5", "unrelated")
        else
          Zip::File.open(result.output_path) { |zip| zip.get_output_stream("unrelated.xml") { |stream| stream.write("<unrelated/>") } }
        end
        before = snapshot(root)
        error = assert_raises(AfDataPipeline::ValidationError) do
          AfDataPipeline::BoundaryFreezeApply.verify!(source_amc: base, output_amc: result.output_path, plan: report.fetch("records"), changes: report.fetch("changed_cells"), source_id: "Mechanical Source", publisher: "Mechanical Publisher", current_books: report.fetch("current_books"))
        end
        assert_match(/unauthorized worksheet cell|package member/, error.message)
        assert_equal before, snapshot(root)
        File.binwrite(result.output_path, original)
      end
    end
  end

  private

  # Changes one existing fixture cell while retaining its style and package;
  # missing cells/parts raise rather than silently changing the test case.
  def set_fixture_text(path, sheet_number, reference, value)
    part = "xl/worksheets/sheet#{sheet_number}.xml"
    Zip::File.open(path) do |zip|
      document = REXML::Document.new(zip.read(part))
      target = REXML::XPath.first(document, "//s:c[@r='#{reference}']", AfDataPipeline::AmcApply::NS)
      raise "missing fixture cell #{reference}" unless target
      target.elements.to_a.each { |child| target.delete_element(child) }
      target.attributes["t"] = "str"
      target.add_element("v").text = value
      zip.get_output_stream(part) { |stream| stream.write(document.to_s) }
    end
  end

  # Yields a disposable root and exact empty workbook; fixture errors propagate.
  def with_empty_catalog
    Dir.mktmpdir("empty-catalog-", File.realpath(Dir.tmpdir)) do |root|
      base = write_empty_catalog(File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx"))
      write_state(File.join(root, "PROJECT_STATE.yml"), base)
      yield root, base
    end
  end

  # Creates attributed mechanical decisions through the real approval/freeze
  # owners and exact operation/version projections. Returns public stage kwargs;
  # validation errors propagate rather than manufacturing a passing receipt.
  def approved_input(root, base, lengths:, source_id: "Mechanical Source", publisher: "Mechanical Publisher", version: "0.2")
    source = File.join(root, "source-#{version}")
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "mechanical.md"), (1..lengths.max).map { |page| "<!-- Printed Page #{page} -->\n#{page}\n" }.join)
    File.write(File.join(source, "source_registry.yml"), YAML.dump("schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION, "sources" => {source_id => {"file" => "mechanical.md"}}))
    draft = File.join(root, "draft-#{version}.yml")
    AfDataPipeline::BoundaryFreeze.init!(source_root: source, source_id: source_id, amc_path: base, output_path: draft)
    data = YAML.safe_load_file(draft)
    dossier = File.join(root, "dossier-#{version}.json")
    write_json(dossier, {"schema_version" => "af-boundary-dossier/v0.2", "purpose" => "mechanical", "source" => data.fetch("source"), "base_amc" => data.fetch("base_amc"), "amc_evidence" => {}, "source_files" => [], "review_contract" => {}})
    bundle = File.join(root, "editorial-#{version}")
    AfDataPipeline::BoundaryEditorial.init!(dossier_path: dossier, output_dir: bundle)
    candidates = lengths.each_with_index.map do |length, index|
      {"candidate_key" => "record-#{index}", "provisional_title" => "Mechanical Record #{index}", "playability_evidence" => "Mechanical test decision.", "open_questions" => [], "review_history" => [{"phase" => "phase2", "status" => "accepted", "rationale" => "Mechanical test decision."}], "disposition" => "accept", "decision" => {"canonical_title" => "Mechanical Record #{index}", "printed_pages" => {"start" => 1, "end" => length}, "levels" => nil, "editorial_rationale" => "Mechanical test decision."}}
    end
    File.write(File.join(bundle, "editorial_decisions.yml"), YAML.dump("schema_version" => AfDataPipeline::BoundaryEditorial::LEGACY_DECISIONS_SCHEMA_VERSION, "candidates" => candidates))
    approval = File.join(root, "approval-#{version}.json")
    common = {bundle_dir: bundle, dossier_path: dossier, source_root: source, amc_path: base}
    AfDataPipeline::BoundaryEditorial.approve!(**common, approved_by: "Mechanical reviewer", output_path: approval, clock: -> { Time.iso8601("2026-10-08T01:00:00Z") })
    freeze = File.join(root, "frozen-#{version}.yml")
    AfDataPipeline::BoundaryEditorial.freeze_approved!(**common, approval_path: approval, freeze_path: draft, output_path: freeze)
    operation_identity = {"contract_version" => "adventurefinder-ingest-operation/v0.1", "operation_id" => "11111111-1111-4111-8111-111111111111", "created_at" => "2026-10-08T00:00:00Z"}
    operation = File.join(root, "operation-#{version}.json")
    write_json(operation, {"schema_version" => "af-ingest-routing-input/v0.1", "operation" => operation_identity.except("created_at").merge("revision" => 1, "document_sha256" => "a" * 64), "artifact" => {"kind" => "file", **AUTH.file_binding(freeze)}, "source" => {"source_id" => source_id, "edition" => "mechanical", "pagination_authority" => "printed labels", "publisher" => publisher, "canonical_markdown" => nil}, "base_catalog" => {"filename" => File.basename(base), **AUTH.file_binding(base), "selection_method" => "explicit", "project_state_sha256" => nil}, "policy" => nil})
    authorization = {"contract_version" => "adventurefinder-successor-version-authorization/v0.1", "operation" => operation_identity, "base_catalog" => AUTH.file_binding(base), "successor_version" => version, "selected_by" => "Mechanical operator", "selected_at" => "2026-10-08T00:01:00Z"}
    authorization["authorization_id"] = AUTH.digest(authorization)
    authority = File.join(root, "version-#{version}.json")
    write_json(authority, {"contract_version" => "adventurefinder-successor-version-authorization-projection/v0.1", "authorization" => authorization})
    {freeze_path: freeze, operation_input_path: operation, successor_authorization_path: authority, source_root: source, catalog_root: root, project_state_path: File.join(root, "PROJECT_STATE.yml")}
  end

  # Selects direct apply's explicit inputs from stage evidence; no I/O or errors.
  def apply_options(evidence, base)
    publisher = JSON.parse(File.read(evidence.fetch(:operation_input_path))).dig("source", "publisher")
    evidence.slice(:freeze_path, :source_root).merge(amc_path: base, publisher: publisher)
  end

  # Checks exact output allocation, formulas/caches and independent integrity
  # reconstruction. Production validation failures remain assertion failures.
  def assert_successor(base, result, lengths)
    report = JSON.parse(File.read(result.report_path))
    assert report.dig("verification", "passed")
    assert_equal lengths.each_index.map { |index| format("ADV-%04d", index + 1) }, report.fetch("records").map { |record| record.fetch("adventure_id") }
    assert_equal lengths.map { |length| length < 100 ? "Adventure Catalog" : "AMC >100pg" }, report.fetch("records").map { |record| record.fetch("sheet") }
    workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(result.output_path)
    large = workbook.sheet_by_name!("AMC >100pg")
    assert_equal "COUNTA(A3:A1000)", large.cell_formula(large.cell("B2"))
    assert_equal lengths.count { |length| length >= 100 }, large.cell_value("B2")
    books = workbook.sheet_by_name!("Current Books")
    %w[B2 G2].each { |reference| assert_equal lengths.length, books.cell_value(reference) }
    %w[C2 H2].each { |reference| assert_equal 1, books.cell_value(reference) }
    assert_equal lengths.count { |length| length < 100 }.fdiv(lengths.length), books.cell_value("A5")
    report.fetch("records").each_with_index do |record, index|
      sheet = workbook.sheet_by_name!(record.fetch("sheet"))
      row = record.fetch("row")
      assert_equal lengths[index], sheet.cell_value("D#{row}")
      assert_equal "1+H#{row}-G#{row}", sheet.cell_formula(sheet.cell("D#{row}"))
      assert_equal "COUNT(I#{row}:U#{row})", sheet.cell_formula(sheet.cell("AC#{row}"))
      assert_equal 0, sheet.cell_value("AC#{row}")
      [*("I".."Z"), "AA", "AB"].each { |column| assert_nil sheet.cell_value("#{column}#{row}") }
    end
    assert_equal "PASS", AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: result.output_path, base_path: base).fetch("status")
    options = report.slice("records", "changed_cells", "current_books")
    assert AfDataPipeline::BoundaryFreezeApply.verify!(source_amc: base, output_amc: result.output_path, plan: options.fetch("records"), changes: options.fetch("changed_cells"), source_id: "Mechanical Source", publisher: "Mechanical Publisher", current_books: options.fetch("current_books")).fetch("passed")
  end

  # Captures exact bytes for replay/refusal and protected input comparisons;
  # filesystem errors propagate if an expected file disappears.
  def snapshot(root)
    Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }.to_h { |path| [path, [File.binread(path), File.stat(path).mode & 0o777]] }
  end
end
