# frozen_string_literal: true

require_relative "staged_scoring_fixture"
require_relative "amc_fixture"
require_relative "machine_policy_acceptance_fixture"

class StandingBulkScoreReleaseFixture
  include StagedScoringFixture
  include AmcFixture

  INDEX_HEADERS = %w[
    case_id adventure_id dimension profile model_alias ollama_model qualified_model_digest
    qualification_sha256 runtime_sha256 preflight_sha256 case_path
  ].freeze
  ASSESSMENT_HEADERS = %w[
    run_id status adventure_id adventure_title source_book metric metric_kind value range_low range_high confidence
    path_sensitive path_variation_affects_anchor assessment_state rationale adjacent_lower_reason adjacent_higher_reason
    evidence review_disposition hold_reason metric_review_flags package_review_flags afao_version assessment_spec_version
    provider model
  ].freeze
  HEAD = "b" * 40
  MODEL = "qwen3.6:35b-a3b"
  WORKLOAD_ID = "synthetic-operation-1"
  FIXTURE_CACHE = {}
  ISSUED_AUTHORITY_CACHE = {}

  attr_reader :root, :inputs_path, :output_dir, :review_dir, :audit_dir, :manifest_path,
              :policy_path, :selection_path, :authority_projection, :staged_path

  def initialize(root:, specs: nil, states: nil, boundary_levels: {"start" => 1, "end" => 5})
    @root = root
    @boundary_levels = boundary_levels
    @specs = specs || [
      {case_id: "combat", dimension: "Combat Emphasis", metrics: {"Combat Emphasis" => 3}},
      {case_id: "openness", dimension: "Structural Openness", metrics: {"Structural Openness" => 4}},
      {case_id: "levels", dimension: "Levels", metrics: {"Level Start" => 1, "Level End" => 5}}
    ]
    @states = states || Array.new(@specs.length, :ready)
    return restore_cached! if FIXTURE_CACHE.key?(cache_key)

    build!
    cache_fixture!
  end

  def release(preview: false, fault_injector: nil)
    AfDataPipeline::StandingBulkScoreRelease.new(
      inputs_path:,
      output_dir:,
      preview:,
      fault_injector:
    ).release!
  end

  def set_decision(candidate_key, decision)
    path = File.join(audit_dir, "editorial_decisions.csv")
    table = CSV.read(path, headers: true)
    row = table.find { |entry| entry["record_key"] == candidate_key } or raise "candidate not found"
    row["editorial_decision"] = decision
    row["editorial_note"] = "Synthetic #{decision.downcase} decision." if %w[HOLD REJECT].include?(decision)
    rewrite_csv(path, table.headers, table.map(&:to_h))
  end

  def mutate_policy
    document = JSON.parse(File.binread(policy_path))
    yield document
    document["policy_digest"] = AfDataPipeline::StandingBulkScorePolicy.digest(document.except("policy_digest"))
    File.write(policy_path, JSON.pretty_generate(document) + "\n")
  end

  def mutate_first_candidate
    path = File.join(review_dir, "candidates.jsonl")
    rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
    yield rows.first
    File.open(path, "w") { |file| rows.each { |row| file.puts(JSON.generate(row)) } }
  end

  def rewrite_inputs
    document = JSON.parse(File.binread(inputs_path))
    yield document
    File.write(inputs_path, JSON.pretty_generate(document) + "\n")
  end

  def add_machine_acceptance(candidate_key, state: "ACCEPTED")
    candidate = File.readlines(File.join(review_dir, "candidates.jsonl"), chomp: true)
      .map { |line| JSON.parse(line) }
      .find { |row| row["candidate_key"] == candidate_key } or raise "candidate not found"
    manifest = JSON.parse(File.binread(manifest_path))
    machine = MachinePolicyAcceptanceFixture.new(
      root: File.join(root, "machine-authority"),
      dimension: candidate.fetch("dimension"),
      state:
    )
    record = machine.record
    record["candidate"].merge!(
      "key" => candidate.fetch("candidate_key"),
      "adventure_id" => candidate.fetch("adventure_id"),
      "dimension" => candidate.fetch("dimension"),
      "metric" => candidate.fetch("dimension"),
      "proposed_value" => candidate.fetch("value")
    )
    record["candidate"]["content_sha256"] = AfDataPipeline::StandingBulkScorePolicy.digest(
      record["candidate"].except("content_sha256")
    )
    record.dig("evidence", "receipt")["receipt_id"] = candidate.fetch("afw_receipt_id")
    record["workload"]["manifest_id"] = manifest.fetch("manifest_id")
    record["workload"]["case_id"] = candidate.fetch("afw_workload_case_id")
    record["workload"]["job_id"] = candidate.fetch("afw_workload_case_id")
    record["attempt"]["job_id"] = candidate.fetch("afw_workload_case_id")
    machine.rewrite!
    rewrite_inputs do |inputs|
      inputs["machine_acceptance"] = {
        "records" => {candidate_key => machine.path},
        "roots" => machine.roots
      }
    end
    machine
  end

  # Adds the package/style parts required by score apply while retaining the
  # boundary fixture's real three-sheet AMC shape.
  def write_compatible_amc(path, **options)
    super
    styles = send(:styles_xml, red_style_match: true)
      .sub('<fills count="4">', '<fills count="5">')
      .sub(
        "</fills>",
        '<fill><patternFill patternType="solid"><fgColor rgb="FFD0E0E3"/><bgColor indexed="64"/></patternFill></fill></fills>'
      )
      .sub('<cellXfs count="6">', '<cellXfs count="7">')
      .sub(
        "</cellXfs>",
        '<xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0"/></cellXfs>'
      )
    Zip::File.open(path) do |zip|
      zip.get_output_stream("xl/styles.xml") { |stream| stream.write(styles) }
      content = zip.read("[Content_Types].xml")
      content = content.sub(
        "</Types>",
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'
      )
      zip.get_output_stream("[Content_Types].xml") { |stream| stream.write(content) }
      rels = zip.read("xl/_rels/workbook.xml.rels")
      rels = rels.sub(
        "</Relationships>",
        '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
      )
      zip.get_output_stream("xl/_rels/workbook.xml.rels") { |stream| stream.write(rels) }
    end
    path
  end

  private

  def cache_key
    Marshal.dump([@specs, @states, @boundary_levels])
  end

  def cache_fixture!
    path_ivars = %i[
      inputs_path output_dir review_dir audit_dir manifest_path policy_path selection_path staged_path
    ]
    FIXTURE_CACHE[cache_key] = {
      files: Dir[File.join(root, "**", "*"), File.join(root, "**", ".*")].select { |path| File.file?(path) }
        .to_h { |path| [path.delete_prefix(root + "/"), File.binread(path).freeze] },
      paths: path_ivars.to_h do |name|
        value = instance_variable_get(:"@#{name}")
        [name, value.delete_prefix(root + "/")]
      end,
      source_root: root,
      projection: Marshal.dump(authority_projection)
    }
  end

  def restore_cached!
    cached = FIXTURE_CACHE.fetch(cache_key)
    cached.fetch(:files).each do |relative, bytes|
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
    end
    cached.fetch(:paths).each do |name, relative|
      instance_variable_set(:"@#{name}", File.join(root, relative))
    end
    source_root = cached.fetch(:source_root)
    inputs = JSON.parse(File.binread(inputs_path))
    inputs = replace_root(inputs, source_root, root)
    File.write(inputs_path, JSON.pretty_generate(inputs) + "\n")
    @authority_projection = Marshal.load(cached.fetch(:projection))
  end

  def replace_root(value, from, to)
    case value
    when Hash then value.transform_values { |entry| replace_root(entry, from, to) }
    when Array then value.map { |entry| replace_root(entry, from, to) }
    when String then value.sub(/\A#{Regexp.escape(from)}/, to)
    else value
    end
  end

  def build!
    authority_options = build_authority_fixture(root, cache_namespace: :standing_bulk_score_release, levels: @boundary_levels)
    current_state = File.join(root, "PROJECT_STATE.yml")
    @authority = AfDataPipeline::StagedScoringAuthority.new(
      evidence: authority_options,
      store_root: File.join(root, "authority-store"),
      mode: "synthetic"
    )
    authority = issued_authority(current_state)
    @staged_path = File.join(root, authority.dig("staged_amc", "filename"))

    workload = build_workload(authority)
    @authority_projection = @authority.validate!(
      current_state_path: current_state,
      frozen_workload: workload.fetch(:binding),
      workload_paths: workload.fetch(:paths)
    )
    @review_dir = File.join(root, "review")
    @audit_dir = File.join(root, "audit")
    AfDataPipeline::WorkloadScoringReviewPackage.prepare!(
      manifest_path: @manifest_path,
      afw_root: @afw_root,
      review_dir:,
      audit_dir:
    )
    @policy_path = File.join(root, "standing-policy.json")
    @selection_path = File.join(root, "owner-selection.json")
    # Independently authored test inputs retain the real validator's closed
    # schema and scope, but represent no project-owner authorization. Cached
    # fixture copies retain these synthetic bytes and the synthetic input mode.
    FileUtils.cp(File.expand_path("../fixtures/standing_bulk_score/synthetic-policy.json", __dir__), policy_path)
    FileUtils.cp(File.expand_path("../fixtures/standing_bulk_score/synthetic-owner-selection.json", __dir__), selection_path)
    @inputs_path = File.join(root, "release-inputs.json")
    @output_dir = File.join(root, "release")
    write_json(inputs_path, {
      "schema_version" => AfDataPipeline::StandingBulkScoreRelease::INPUT_SCHEMA,
      "mode" => "synthetic",
      "staged_scoring" => {
        "evidence" => authority_options.transform_keys(&:to_s),
        "store_root" => File.join(root, "authority-store"),
        "current_project_state_path" => current_state,
        "workload_binding_path" => workload.fetch(:binding_path),
        "workload_paths" => workload.fetch(:paths)
      },
      "workload_review" => {
        "manifest_path" => manifest_path,
        "afw_root" => @afw_root,
        "review_dir" => review_dir,
        "audit_dir" => audit_dir
      },
      "standing_policy_path" => policy_path,
      "owner_selection_path" => selection_path,
      "machine_acceptance" => nil
    })
  end

  # Workload variants share the same boundary authority. Retain only the real
  # issuer's immutable publication bytes; every workload and release still
  # runs the public authority validator against its own files.
  def issued_authority(current_state)
    key = Marshal.dump(@boundary_levels)
    store = File.join(root, "authority-store")
    if (cached = ISSUED_AUTHORITY_CACHE[key])
      cached.fetch(:files).each do |relative, (bytes, mode)|
        path = File.join(store, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
        File.chmod(mode, path)
      end
      return Marshal.load(cached.fetch(:authority))
    end

    authority = @authority.issue!(current_state_path: current_state).fetch("authority")
    files = Dir.glob(File.join(store, "**", "*")).select { |path| File.file?(path) }
      .to_h { |path| [path.delete_prefix(store + "/").freeze,
                      [File.binread(path).freeze, File.stat(path).mode & 0o777].freeze] }.freeze
    ISSUED_AUTHORITY_CACHE[key] = {files:, authority: Marshal.dump(authority).freeze}.freeze
    authority
  end

  def build_workload(authority)
    @afw_root = File.join(root, "afw")
    wlo_root = File.join(root, "wlo")
    FileUtils.mkdir_p(@afw_root)
    FileUtils.mkdir_p(wlo_root)
    bindings = {
      "profile" => "production",
      "model_alias" => "qwen",
      "ollama_model" => MODEL,
      "qualified_model_digest" => "a" * 64,
      "qualification_sha256" => "1" * 64,
      "runtime_sha256" => "2" * 64,
      "preflight_sha256" => "3" * 64
    }
    rows = []
    jobs = []
    case_paths = {}
    @specs.each do |spec|
      path = File.join(@afw_root, "build", "cases", "#{spec.fetch(:case_id)}.yml")
      FileUtils.mkdir_p(File.dirname(path))
      write_yaml(path, bindings.merge(
        "contract_version" => "afw-workload/v0.1",
        "workload_id" => WORKLOAD_ID,
        "case_id" => spec.fetch(:case_id),
        "adventure_id" => "ADV-0003",
        "dimension" => spec.fetch(:dimension),
        "scorer_commit" => HEAD
      ))
      relative = relative_to_afw(path)
      rows << {
        "case_id" => spec.fetch(:case_id),
        "adventure_id" => "ADV-0003",
        "dimension" => spec.fetch(:dimension),
        "case_path" => relative
      }.merge(bindings)
      jobs << {
        "job_id" => spec.fetch(:case_id),
        "pool_id" => "fixture",
        "group_id" => "ADV-0003",
        "argv" => ["bin/afw-score-job", relative],
        "env" => {},
        "depends_on_job_ids" => []
      }
      case_paths[spec.fetch(:case_id)] = path
    end

    workload_dir = File.join(@afw_root, "workloads", WORKLOAD_ID)
    FileUtils.mkdir_p(workload_dir)
    plan = {
      "contract_version" => "wlo-execution-plan/v0.3",
      "plan_id" => WORKLOAD_ID,
      "failure_policy" => {},
      "pools" => [],
      "jobs" => jobs
    }
    plan_path = File.join(workload_dir, "execution-plan.json")
    write_json(plan_path, plan)
    authority_core = {
      "schema_version" => AfDataPipeline::StagedScoringAuthority::WORKLOAD_VERSION,
      "authority_id" => authority.fetch("authority_id"),
      "operation_id" => authority.dig("operation", "operation_id"),
      "workload_id" => WORKLOAD_ID,
      "staged_amc" => authority.fetch("staged_amc"),
      "intended_ids" => ["ADV-0003"]
    }
    snapshot_path = File.join(workload_dir, "snapshot.yml")
    write_yaml(snapshot_path, {
      "contract_version" => "afw-workload/v0.1",
      "workload_id" => WORKLOAD_ID,
      "scorer_commit" => HEAD,
      "execution_plan_sha256" => sha(File.binread(plan_path)),
      "staged_scoring" => authority_core
    })
    index_path = File.join(workload_dir, "case_index.csv")
    rewrite_csv(index_path, INDEX_HEADERS, rows)
    wlo_plan_path = File.join(wlo_root, "plan.json")
    FileUtils.cp(plan_path, wlo_plan_path)
    execution_path = File.join(wlo_root, "execution.json")
    write_json(execution_path, {
      "contract_version" => "wlo-execution-state/v0.1",
      "plan_id" => WORKLOAD_ID,
      "plan_sha256" => sha(File.binread(plan_path)),
      "status" => "completed",
      "retry_pending" => {}
    })

    manifest_cases = @specs.each_with_index.map do |spec, index|
      build_manifest_case(
        spec:,
        state: @states.fetch(index),
        row: rows.fetch(index),
        job: jobs.fetch(index),
        case_path: case_paths.fetch(spec.fetch(:case_id)),
        plan_path:,
        snapshot_path:,
        index_path:,
        execution_path:,
        wlo_root:,
        bindings:
      )
    end
    summary = {
      "intended_cases" => manifest_cases.length,
      "classified_cases" => manifest_cases.length,
      "accounting_complete" => true,
      "execution_counts" => tally(manifest_cases, "execution_status"),
      "evidence_counts" => tally(manifest_cases, "evidence_status"),
      "receipt_count" => manifest_cases.count { |entry| entry["receipt"] },
      "review_candidate_count" => manifest_cases.sum { |entry| entry.dig("receipt", "review_candidate_count").to_i },
      "evidence_complete" => manifest_cases.all? { |entry| entry.dig("classification", "evidence_status") == "ready" }
    }
    body = {
      "contract_version" => "afw-workload-evidence-manifest/v0.1",
      "semantic_status" => "authoritative_workload_evidence_snapshot",
      "workload" => {
        "plan_id" => WORKLOAD_ID,
        "intended_case_count" => manifest_cases.length,
        "afw" => {
          "execution_plan" => reference("afw", plan_path, @afw_root, wlo_root),
          "snapshot" => reference("afw", snapshot_path, @afw_root, wlo_root),
          "case_index" => reference("afw", index_path, @afw_root, wlo_root)
        },
        "wlo" => {
          "plan" => reference("wlo", wlo_plan_path, @afw_root, wlo_root),
          "execution" => embedded(execution_path, @afw_root, wlo_root),
          "execution_contract" => "wlo-execution-state/v0.1",
          "execution_status" => "completed"
        }
      },
      "summary" => summary,
      "cases" => manifest_cases
    }
    document = body.merge("manifest_id" => digest(body))
    @manifest_path = File.join(@afw_root, "output", "workloads", WORKLOAD_ID, "evidence", "manifests", "fixture.json")
    FileUtils.mkdir_p(File.dirname(@manifest_path))
    write_json(@manifest_path, document)
    paths = {"plan" => plan_path, "snapshot" => snapshot_path, "index" => index_path}
    binding = authority_core.merge(
      "artifacts" => paths.to_h { |name, path| [name, AfDataPipeline::StagedScoringAuthority.file_binding(path)] }
    )
    binding_path = File.join(root, "workload-binding.json")
    write_json(binding_path, binding)
    {paths:, binding:, binding_path:}
  end

  def build_manifest_case(spec:, state:, row:, job:, case_path:, plan_path:, snapshot_path:, index_path:,
                          execution_path:, wlo_root:, bindings:)
    metadata_path = File.join(wlo_root, "runs", spec.fetch(:case_id), "metadata.json")
    FileUtils.mkdir_p(File.dirname(metadata_path))
    status, exit_status = state == :ready ? ["complete", 0] : ["failed", 7]
    metadata = {
      "job_id" => spec.fetch(:case_id),
      "pool_id" => job.fetch("pool_id"),
      "argv" => job.fetch("argv"),
      "attempt" => 1,
      "status" => status,
      "exit_status" => exit_status
    }
    write_json(metadata_path, metadata)
    attempt = {
      "job_id" => spec.fetch(:case_id),
      "attempt" => 1,
      "status" => status,
      "exit_status" => exit_status,
      "evidence_path" => reference("wlo", metadata_path, @afw_root, wlo_root).fetch("path"),
      "evidence_sha256" => sha(File.binread(metadata_path)),
      "superseded_attempts" => []
    }
    ready = state == :ready
    receipt = ready ? write_receipt(
      spec:,
      attempt:,
      plan_path:,
      snapshot_path:,
      index_path:,
      case_path:,
      bindings:,
      row:,
      job:
    ) : nil
    {
      "case_id" => spec.fetch(:case_id),
      "adventure_id" => "ADV-0003",
      "dimension" => spec.fetch(:dimension),
      "intent" => {
        "case_index_row" => row,
        "case" => reference("afw", case_path, @afw_root, wlo_root)
      },
      "job" => {
        "job_id" => job.fetch("job_id"),
        "pool_id" => job.fetch("pool_id"),
        "group_id" => job.fetch("group_id"),
        "argv_sha256" => sha(JSON.generate(canonical(job.fetch("argv")))),
        "plan_job_sha256" => sha(JSON.generate(canonical(job)))
      },
      "classification" => ready ? {
        "outcome" => "evidenced",
        "reason" => "receipt_valid",
        "execution_status" => "complete",
        "evidence_status" => "ready"
      } : {
        "outcome" => "failed",
        "reason" => "wlo_attempt_failed",
        "execution_status" => "failed",
        "evidence_status" => "unresolved"
      },
      "execution" => {
        "current_attempt" => embedded(metadata_path, @afw_root, wlo_root).merge("retained_superseded_attempts" => []),
        "authoritative_attempt" => attempt
      },
      "receipt" => receipt && {
        "reference" => reference("afw", receipt.fetch(:path), @afw_root, wlo_root),
        "receipt_id" => receipt.fetch(:document).fetch("receipt_id"),
        "contract_version" => "afw-scoring-evidence-receipt/v0.1",
        "semantic_status" => "provenance_validated_proposed_scoring_evidence",
        "review_candidate_count" => spec.fetch(:metrics).length
      }
    }
  end

  def write_receipt(spec:, attempt:, plan_path:, snapshot_path:, index_path:, case_path:, bindings:, row:, job:)
    result_dir = File.join(@afw_root, "output", "results", spec.fetch(:case_id))
    assessment_path = File.join(result_dir, "assessment.csv")
    request_path = File.join(result_dir, "request.json")
    response_path = File.join(result_dir, "response.json")
    base = {
      "run_id" => "run-#{spec.fetch(:case_id)}",
      "status" => "PROPOSED",
      "adventure_id" => "ADV-0003",
      "adventure_title" => "Synthetic Unit",
      "source_book" => "New Source",
      "metric_kind" => "ordinal",
      "confidence" => "0.9",
      "path_sensitive" => "false",
      "path_variation_affects_anchor" => "false",
      "assessment_state" => "resolved",
      "rationale" => "Synthetic structural evidence.",
      "evidence" => "[]",
      "review_disposition" => "REVIEW_REQUIRED",
      "afao_version" => "1.6.1",
      "assessment_spec_version" => "0.1",
      "provider" => "ollama",
      "model" => row.fetch("ollama_model")
    }
    rows = spec.fetch(:metrics).map do |metric, value|
      base.merge(
        "metric" => metric,
        "value" => value.to_s,
        "assessment_state" => spec.fetch(:assessment_state, base.fetch("assessment_state")),
        "review_disposition" => spec.fetch(:review_disposition, base.fetch("review_disposition")),
        "hold_reason" => spec[:hold_reason],
        "metric_review_flags" => spec[:metric_review_flags],
        "package_review_flags" => spec[:package_review_flags]
      )
    end
    rewrite_csv(assessment_path, ASSESSMENT_HEADERS, rows)
    File.binwrite(request_path, "{}\n")
    File.binwrite(response_path, "{}\n")
    body = {
      "contract_version" => "afw-scoring-evidence-receipt/v0.1",
      "semantic_status" => "provenance_validated_proposed_scoring_evidence",
      "workload" => {
        "plan_id" => WORKLOAD_ID,
        "plan_sha256" => sha(File.binread(plan_path)),
        "snapshot_sha256" => sha(File.binread(snapshot_path)),
        "case_index_sha256" => sha(File.binread(index_path)),
        "job_id" => spec.fetch(:case_id),
        "pool_id" => job.fetch("pool_id")
      },
      "scoring_intent" => {
        "case_id" => spec.fetch(:case_id),
        "adventure_id" => "ADV-0003",
        "dimension" => spec.fetch(:dimension),
        "profile" => row.fetch("profile"),
        "model_alias" => row.fetch("model_alias"),
        "ollama_model" => row.fetch("ollama_model"),
        "case_sha256" => sha(File.binread(case_path))
      },
      "attempt" => attempt,
      "scorer_provenance" => {
        "scorer_commit" => YAML.safe_load_file(snapshot_path, aliases: false).fetch("scorer_commit"),
        "qualified_model_digest" => bindings.fetch("qualified_model_digest"),
        "qualification_sha256" => bindings.fetch("qualification_sha256"),
        "runtime_sha256" => bindings.fetch("runtime_sha256"),
        "preflight_sha256" => bindings.fetch("preflight_sha256"),
        "prompt_sha256" => "4" * 64,
        "schema_sha256" => "5" * 64
      },
      "artifacts" => {
        "run_id" => base.fetch("run_id"),
        "proposed_assessment" => artifact_ref(assessment_path),
        "raw_request" => artifact_ref(request_path),
        "raw_response" => artifact_ref(response_path)
      }
    }
    document = body.merge("receipt_id" => digest(body))
    path = File.join(@afw_root, "output", "receipts", "#{spec.fetch(:case_id)}.json")
    FileUtils.mkdir_p(File.dirname(path))
    write_json(path, document)
    {path:, document:}
  end

  def artifact_ref(path)
    {"path" => relative_to_afw(path), "sha256" => sha(File.binread(path))}
  end

  def reference(name, path, afw_root, wlo_root)
    root_path = name == "afw" ? afw_root : wlo_root
    {
      "root" => name,
      "path" => Pathname.new(path).relative_path_from(Pathname.new(root_path)).to_s,
      "sha256" => sha(File.binread(path))
    }
  end

  def embedded(path, afw_root, wlo_root)
    {"source" => reference("wlo", path, afw_root, wlo_root), "encoding" => "hex", "content" => File.binread(path).unpack1("H*")}
  end

  def relative_to_afw(path)
    Pathname.new(path).relative_path_from(Pathname.new(@afw_root)).to_s
  end

  def tally(cases, field)
    cases.map { |entry| entry.dig("classification", field) }.tally.sort.to_h
  end

  def rewrite_csv(path, headers, rows)
    FileUtils.mkdir_p(File.dirname(path))
    CSV.open(path, "w") do |csv|
      csv << headers
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def write_yaml(path, value)
    File.write(path, YAML.dump(value))
  end

  def digest(value)
    sha(JSON.generate(canonical(value)))
  end

  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end

  def sha(bytes)
    Digest::SHA256.hexdigest(bytes)
  end
end
