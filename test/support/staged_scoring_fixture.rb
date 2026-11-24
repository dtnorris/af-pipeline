# frozen_string_literal: true

require_relative "compatibility_amc_fixture"
require_relative "../../lib/af_data_pipeline/boundary_editorial"
require_relative "../../lib/af_data_pipeline/boundary_freeze_stage"
require_relative "../../lib/af_data_pipeline/staged_scoring_authority"

module StagedScoringFixture
  include CompatibilityAmcFixture
  AUTH = AfDataPipeline::StagedScoringAuthority
  TEMPLATE_CACHE = {}

  # Resolve the public producer's actual basename, including retained v0.1
  # fixtures. Never substitute a publication filename for a staged input.
  def staged_catalog_path(root)
    receipt = JSON.parse(File.binread(Dir[File.join(root, "*verified-staged-successor*.json")].fetch(0)))
    File.join(root, receipt.fetch("successor").fetch("filename"))
  end

  def build_authority_fixture(root, zero: false, cache_namespace: nil, levels: {"start" => 1, "end" => 5}, units: nil)
    cache_key = [cache_namespace, zero, levels, units]
    if (template = TEMPLATE_CACHE[cache_key])
      template.fetch(:files).each do |name, bytes|
        path = File.join(root, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
      end
      return template.fetch(:options).transform_values { |relative| File.join(root, relative) }
    end
    source = File.join(root, "source")
    FileUtils.mkdir_p(source)
    last_page = units ? units.map { |u| u.fetch(:end) }.max : 11
    File.write(File.join(source, "fixture.md"), (10..last_page).map { |n| "<!-- Printed Page #{n} -->\n" }.join)
    File.write(File.join(source, "source_registry.yml"), YAML.dump(
      "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
      "sources" => {"New Source" => {"file" => "fixture.md"}}
    ))
    base = File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx")
    write_compatible_amc(base, rows: [
      compatible_row("ADV-0001", title: "Unit A", source: "Source A", end_page: units ? 150 : 21),
      compatible_row("ADV-0002", title: "Unit B", source: "Source B")
    ])
    Zip::File.open(base) do |zip|
      (1..3).each do |n|
        name = "xl/worksheets/sheet#{n}.xml"
        xml = zip.read(name)
        xml = xml.gsub(/<f>.*?<\/f>/, "") if n < 3
        last = xml.scan(/<row r="(\d+)"/).flatten.map(&:to_i).max
        xml = xml.sub("</sheetData>", ((last + 1)..12).map { |r| %(<row r="#{r}"></row>) }.join + "</sheetData>")
        if n == 1 && levels.nil?
          xml = xml.sub('<row r="4"></row>', '<row r="4"><c r="J4" s="0"/><c r="K4" s="0"/></row>')
        end
        zip.get_output_stream(name) { |f| f.write(xml) }
      end
    end
    draft = File.join(root, "draft.yml")
    AfDataPipeline::BoundaryFreeze.init!(source_root: source, source_id: "New Source", amc_path: base, output_path: draft)
    draft_data = YAML.safe_load_file(draft)
    dossier = File.join(root, "boundary_dossier.json")
    write_json(dossier, {"schema_version" => "af-boundary-dossier/v0.2", "purpose" => "synthetic",
                         "source" => draft_data.fetch("source"), "base_amc" => draft_data.fetch("base_amc"),
                         "amc_evidence" => {}, "source_files" => [], "review_contract" => {}})
    bundle = File.join(root, "editorial")
    AfDataPipeline::BoundaryEditorial.init!(dossier_path: dossier, output_dir: bundle)
    candidate = {
      "candidate_key" => "unit-c", "provisional_title" => "Unit C", "playability_evidence" => "Synthetic evidence.",
      "open_questions" => [], "review_history" => [{"phase" => "phase2", "status" => "accepted", "rationale" => "Synthetic decision."}],
      "disposition" => zero ? "reject" : "accept"
    }
    if zero
      candidate["decision_rationale"] = "Synthetic exclusion."
    else
      candidate["decision"] = {"canonical_title" => "Unit C", "printed_pages" => {"start" => 10, "end" => 11},
                               "levels" => levels,
                               "parent_adventure_id" => "ADV-0002", "editorial_rationale" => "Synthetic boundary."}
    end
    candidates = if units
                   units.each_with_index.map do |unit, index|
                     candidate.merge("candidate_key" => "unit-#{index}", "decision" => {
                       "canonical_title" => "Unit #{index}", "printed_pages" => {"start" => unit.fetch(:start), "end" => unit.fetch(:end)},
                       "levels" => unit[:levels], "editorial_rationale" => "Synthetic boundary."
                     })
                   end
                 else
                   [candidate]
                 end
    File.write(File.join(bundle, "editorial_decisions.yml"), YAML.dump(
      "schema_version" => AfDataPipeline::BoundaryEditorial::LEGACY_DECISIONS_SCHEMA_VERSION, "candidates" => JSON.parse(JSON.generate(candidates))
    ))
    approval = File.join(root, "approval.json")
    common = {bundle_dir: bundle, dossier_path: dossier, source_root: source, amc_path: base, approval_path: approval}
    AfDataPipeline::BoundaryEditorial.approve!(**common.except(:approval_path), approved_by: "Synthetic reviewer",
                                              output_path: approval, clock: -> { Time.iso8601("2026-10-08T01:00:00Z") })
    freeze = File.join(root, "frozen.yml")
    AfDataPipeline::BoundaryEditorial.freeze_approved!(**common, freeze_path: draft, output_path: freeze)
    state = File.join(root, "PROJECT_STATE.yml")
    write_state(state, base)
    operation_identity = {"contract_version" => "adventurefinder-ingest-operation/v0.1",
                          "operation_id" => "11111111-1111-4111-8111-111111111111", "created_at" => "2026-10-08T00:00:00Z"}
    declarations = {"source_id" => "New Source", "edition" => "synthetic", "pagination_authority" => "printed labels", "publisher" => "Fixture Publisher"}
    operation = File.join(root, "operation.json")
    write_json(operation, {
      "schema_version" => "af-ingest-routing-input/v0.1",
      "operation" => operation_identity.except("created_at").merge("revision" => 1, "document_sha256" => "a" * 64),
      "artifact" => {"kind" => "file", **AUTH.file_binding(freeze)},
      "source" => declarations.merge("canonical_markdown" => nil),
      "base_catalog" => {"filename" => File.basename(base), **AUTH.file_binding(base), "selection_method" => "explicit", "project_state_sha256" => nil},
      "policy" => nil
    })
    successor = {"contract_version" => "adventurefinder-successor-version-authorization/v0.1",
                 "operation" => operation_identity, "base_catalog" => AUTH.file_binding(base),
                 "successor_version" => "0.2", "selected_by" => "Synthetic operator", "selected_at" => "2026-10-08T00:01:00Z"}
    successor["authorization_id"] = AUTH.digest(successor)
    version = File.join(root, "version.json")
    write_json(version, {"contract_version" => "adventurefinder-successor-version-authorization-projection/v0.1", "authorization" => successor})
    options = {freeze_path: freeze, operation_input_path: operation, successor_authorization_path: version,
               source_root: source, catalog_root: root, project_state_path: state}
    AfDataPipeline::BoundaryFreezeStage.stage!(**options)
    retained = File.join(root, "HISTORICAL_PROJECT_STATE.yml")
    FileUtils.cp(state, retained)
    policy = File.join(root, "policy.json")
    FileUtils.cp(File.expand_path("../../config/staged_scoring_input_policy_v0.1.json", __dir__), policy)
    intent = {"schema_version" => AUTH::INTENT_VERSION, "producer" => "adventure-finder", "mode" => "synthetic",
              "operation" => operation_identity, "base_amc" => {"filename" => File.basename(base), **AUTH.file_binding(base)},
              "source" => declarations, "policy" => AUTH::POLICY.slice("policy_id", "policy_version").merge(AUTH.file_binding(policy)),
              "selected_by" => "Synthetic operator", "selected_at" => "2026-10-08T00:00:01Z", "interaction" => "ingest_start",
              "purpose" => "prepare_staged_scoring", "scope" => "operation-approved-new-records", "workload_id" => "synthetic-operation-1"}
    intent["intent_id"] = AUTH.digest(intent)
    intent_path = File.join(root, "intent.json")
    write_json(intent_path, intent)
    result = options.merge(project_state_path: retained, approval_path: approval, bundle_dir: bundle,
                           dossier_path: dossier, intent_path:, policy_path: policy)
    TEMPLATE_CACHE[cache_key] = {
      files: Dir[File.join(root, "**", "*")].select { |p| File.file?(p) }
        .to_h { |p| [p.delete_prefix(root + "/"), File.binread(p).freeze] },
      options: result.transform_values { |p| p == root ? "." : p.delete_prefix(root + "/") }
    }
    result
  end

  def write_state(path, head, base = head)
    role = ->(p) { {"version" => File.basename(p)[/Catalog_(.*)\.xlsx/, 1], "filename" => File.basename(p), **AUTH.file_binding(p)} }
    File.write(path, YAML.dump("schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
                              "catalog_head" => role.call(head), "matcher_authorized_baseline" => role.call(base),
                              "production_dependency_floor" => role.call(base)))
  end

  def write_json(path, value)
    File.write(path, JSON.pretty_generate(value) + "\n")
  end

  def change_cell(path, ref, value, formula: nil)
    Zip::File.open(path) do |zip|
      part = "xl/worksheets/sheet1.xml"
      doc = REXML::Document.new(zip.read(part))
      cell = REXML::XPath.first(doc, "//s:c[@r='#{ref}']", AfDataPipeline::AmcApply::NS)
      cell.elements.to_a.each { |child| cell.delete_element(child) }
      cell.delete_attribute("t")
      if value.is_a?(String)
        cell.add_attribute("t", "inlineStr")
        cell.add_element("is").add_element("t").text = value
      elsif value
        cell.add_element("v").text = value.to_s
      end
      cell.add_element("f").text = formula if formula
      zip.get_output_stream(part) { |f| f.write(doc.to_s) }
    end
  end
end
