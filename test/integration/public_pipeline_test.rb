# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/standing_bulk_score_release_fixture"

# Exercises the installed commands with public owners, a fixture execution
# observation at the WLO boundary and no scorer inference.
class PublicPipelineTest < Minitest::Test
  include StagedScoringFixture

  CODE = File.realpath(File.expand_path("../..", __dir__))
  WORKLOAD_ID = "synthetic-operation-1"
  OPERATION_ID = "11111111-1111-4111-8111-111111111111"
  DIMENSION = "Exploration Emphasis"
  ADVENTURE = "ADV-0003"

  # Allocate independent operating, workload and invocation paths for each run.
  def setup
    @scratch = File.realpath(Dir.mktmpdir("af-pipeline-public-"))
    @data = File.join(@scratch, "data")
    @catalog = File.join(@data, "catalog")
    @workloads = File.join(@data, "workloads")
    @cwd = File.join(@scratch, "invocation")
    FileUtils.mkdir_p([@catalog, @workloads, @cwd])
    @environment = {"AF_DATA_PIPELINE_DATA_ROOT" => @data, "GIT_OPTIONAL_LOCKS" => "0"}
    @afw = ENV.fetch("AF_AFW_ROOT")
    @scorer = ENV.fetch("AF_SCORER_ROOT")
    @frontier = ENV.fetch("AF_FRONTIER_PACK_ROOT")
  end

  # Dispose the store and the captured external Git observation.
  def teardown
    FileUtils.remove_entry(@scratch) if @scratch
  end

  # Carry the same workbook, authority and evidence through all subprocesses.
  def test_approved_stage_workload_evidence_and_reviewed_adoption_replay
    @evidence = StandingBulkScoreReleaseFixture.allocate.build_authority_fixture(
      @catalog, cache_namespace: :standing_bulk_score_release
    )
    @state = File.join(@catalog, "PROJECT_STATE.yml")
    @roles = YAML.safe_load_file(@state)
    @base = File.join(@catalog, @roles.dig("catalog_head", "filename"))
    @stage = staged_catalog_path(@catalog)
    original_stage = stage_through_cli
    issue_authority
    binding_path, paths = compile_workload
    manifest = publish_workload_evidence(paths)
    release_inputs = review_workload(manifest, binding_path, paths)
    archived = archive_evidence(manifest)
    adopt_release(release_inputs, manifest, archived)
    assert_equal original_stage, File.binread(@stage)
    assert_empty Dir.children(@cwd)
  end

  private

  # Invoke one real executable from an empty directory; return stdout or assert
  # the exact expected exit and diagnostic. Stderr stays distinct from JSON.
  def run_command(executable, *args, exit_code: 0, diagnostic: nil, environment: @environment, preload: nil)
    arguments = [RbConfig.ruby, *Array(preload), executable, *args]
    stdout, stderr, status = Open3.capture3(environment, *arguments, chdir: @cwd, binmode: true)
    assert_equal exit_code, status.exitstatus, "#{File.basename(executable)} #{args.first}\n#{stdout}\n#{stderr}"
    assert_match diagnostic, stdout + stderr if diagnostic
    stdout
  end

  # Invoke a pipeline executable by its path in the unpacked source tree.
  def pipeline(command, *args, **options)
    run_command(File.join(CODE, "bin", command), *args, **options)
  end

  # Hash durable files under the data root, including hidden publication files.
  def inventory
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @data).sort.filter_map do |path|
      file = File.join(@data, path)
      [path, Digest::SHA256.file(file).hexdigest] if File.file?(file)
    end.to_h
  end

  # Withdraw one exact input, verify refusal without mutation, and restore it.
  def while_changed(path, replacement)
    original = File.binread(path)
    replacement ? File.binwrite(path, replacement) : File.unlink(path)
    before = inventory
    yield
    assert_equal before, inventory
  ensure
    File.binwrite(path, original) if original
  end

  # Stage in real processes, exercising both refusal paths and exact recovery.
  def stage_through_cli
    receipt_path = Dir[File.join(@catalog, "*verified-staged-successor*.json")].fetch(0)
    receipt = JSON.parse(File.binread(receipt_path))
    FileUtils.rm([@stage, receipt_path, File.join(@catalog, receipt.dig("successor", "apply_report_filename"))])
    freeze, operation, successor, source = @evidence.values_at(
      :freeze_path, :operation_input_path, :successor_authorization_path, :source_root
    )
    args = ["boundary-freeze-stage", freeze, "--operation-input", operation, "--successor-authority", successor,
            "--source-root", source, "--catalog-root", @catalog, "--no-progress"]
    before = inventory
    pipeline("af-data", *args, environment: @environment.merge("AF_DATA_PIPELINE_DATA_ROOT" => nil),
             exit_code: 2, diagnostic: /set AF_DATA_PIPELINE_DATA_ROOT/)
    assert_equal before, inventory
    while_changed(successor, nil) do
      pipeline("af-data", *args, exit_code: 2, diagnostic: /missing successor-version authorization/)
    end
    pipeline("af-data", *args, diagnostic: /Replay reused exact artifacts: false/)
    staged = frontier_row(@stage)
    assert_equal ["Unit C", "New Source", 10, 11, nil], staged
    while_changed(freeze, File.binread(freeze) + "# changed fixture\n") do
      pipeline("af-data", *args, exit_code: 2, diagnostic: /DIGEST_MISMATCH/)
    end
    before = inventory
    pipeline("af-data", *args, diagnostic: /Replay reused exact artifacts: true/)
    assert_equal before, inventory
    File.binread(@stage)
  end

  # Verify and issue authority from the approved fixture without modifying it.
  def issue_authority
    @locators = File.join(@data, "locators.json")
    @store = File.join(@data, "authority")
    write_json(@locators, {"schema_version" => "af-staged-scoring-evidence-locators/v0.1", "evidence" => @evidence})
    args = ["issue", "--inputs", @locators, "--store", @store, "--project-state", @state, "--synthetic"]
    while_changed(@evidence.fetch(:approval_path), nil) do
      pipeline("af-staged-scoring-authority", *args, exit_code: 2, diagnostic: /approval/i)
    end
    projection = JSON.parse(pipeline("af-staged-scoring-authority", *args))
    @authority_id = projection.dig("authority", "authority_id")
    assert_match(/\A[0-9a-f]{64}\z/, @authority_id)
  end

  # Build and verify a public scorer preflight and the AFW frozen workload.
  def compile_workload
    config = File.join(@data, "scorer.yml")
    File.write(config, YAML.dump("paths" => {
      "xlsx_root" => @catalog, "source_root" => @evidence.fetch(:source_root),
      "specification_root" => ENV.fetch("AF_PUBLIC_SPEC_ROOT"), "output_root" => File.join(@workloads, "output")
    }))
    args = ["--data-root", @workloads, "--workload", WORKLOAD_ID]
    run_command(File.join(@afw, "bin/afw-build-workload"), *args, "--catalog", @stage, "--ids", ADVENTURE,
      "--dimension", DIMENSION, "--scorer-repo", @scorer, "--scorer-config", config,
      "--staged-authority-inputs", @locators, "--staged-authority-store", @store,
      "--staged-project-state", @state, "--staged-operation", OPERATION_ID, "--staged-pipeline-root", CODE,
      "--staged-authority-mode", "synthetic", "--required-context-length", "131072", "--require-fully-gpu-resident",
      diagnostic: /Model inference: 0/)
    run_command(File.join(@afw, "bin/afw-verify-staged-workload"), *args, diagnostic: /#{@authority_id}/)
    root = File.join(@workloads, "workloads", WORKLOAD_ID)
    paths = %w[execution-plan.json snapshot.yml case_index.csv].map { |name| File.join(root, name) }
    binding = JSON.parse(File.binread(File.join(root, "staged-scoring.json"))).fetch("binding")
    binding_path = File.join(@data, "workload-binding.json")
    write_json(binding_path, binding)
    [binding_path, %w[plan snapshot index].zip(paths).to_h]
  end

  # Supply a content-free terminal attempt and scorer return at the external
  # execution boundary. AFW itself creates, publishes and verifies the receipt.
  def publish_workload_evidence(paths)
    wlo = File.join(@data, "wlo")
    plan = JSON.parse(File.binread(paths.fetch("plan")))
    job = plan.fetch("jobs").fetch(0)
    assert_equal 1, plan.fetch("jobs").length
    job_id = job.fetch("job_id")
    row = CSV.read(paths.fetch("index"), headers: true).first.to_h
    assert_equal [ADVENTURE, DIMENSION], row.values_at("adventure_id", "dimension")
    case_data = YAML.safe_load_file(File.join(@workloads, row.fetch("case_path")))
    preflight = JSON.parse(File.binread(File.join(@workloads, case_data.fetch("preflight_path"))))
    assert_equal "fdd620850b24a5b801eb68391ca3e98c22d4b28a", case_data.fetch("scorer_commit")
    assert_equal "394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf", preflight.dig("run_metadata", "method", "revision")
    runs = File.join(wlo, "runs", job_id)
    FileUtils.mkdir_p(runs)
    FileUtils.cp(paths.fetch("plan"), File.join(wlo, "plan.json"))
    write_json(File.join(wlo, "execution.json"), {
      "contract_version" => "wlo-execution-state/v0.1", "plan_id" => WORKLOAD_ID,
      "plan_sha256" => Digest::SHA256.file(paths.fetch("plan")).hexdigest, "status" => "completed", "retry_pending" => {}
    })
    write_json(File.join(runs, "metadata.json"), job.slice("job_id", "pool_id", "argv").merge(
      "attempt" => 1, "status" => "complete", "exit_status" => 0, "worker" => "fixture-worker",
      "started_at" => "2026-10-04T12:00:00Z", "completed_at" => "2026-10-04T12:02:00Z",
      "worker_execution_identity" => "fixture-execution", "worker_registry_binding" => {"revision" => 1}))
    relative = case_data.fetch("qualification_path")
    source = File.join(@afw, relative)
    assert_equal case_data.fetch("qualification_sha256"), Digest::SHA256.file(source).hexdigest
    # AFW v0.1 evidence resolves this retained qualification from its data root.
    retained = File.join(@workloads, relative)
    FileUtils.mkdir_p(File.dirname(retained))
    FileUtils.cp(source, retained)
    write_proposal(case_data, preflight)
    executable = File.join(@afw, "bin/afw-workload-evidence")
    publication = JSON.parse(run_command(executable, "--data-root", @workloads, "publish", WORKLOAD_ID, wlo))
    document = JSON.parse(File.binread(File.join(@workloads, publication.fetch("manifest_path"))))
    assert_equal [true, 1, 1], publication.values_at("evidence_complete", "receipt_count", "review_candidate_count"),
      document.fetch("cases").map { |entry| entry["classification"] }.inspect
    validation = JSON.parse(run_command(executable, "--data-root", @workloads, "validate", publication.fetch("manifest_path")))
    assert_equal publication.fetch("manifest_id"), validation.fetch("manifest_id")
    File.join(@workloads, publication.fetch("manifest_path"))
  end

  # Write a synthetic proposal bound to the exact real preflight and one metric.
  def write_proposal(case_data, preflight)
    metadata = preflight.fetch("run_metadata")
    target = preflight.fetch("targets").fetch(0)
    output = File.join(@workloads, case_data.fetch("output_path"))
    run_id = "20261004T120100Z_fixture"
    raw = File.join(output, "raw", ADVENTURE, run_id)
    assessments = File.join(output, "assessments")
    FileUtils.mkdir_p([raw, assessments])
    record = metadata.slice("adventure_id", "afao_version", "assessment_spec_version", "provider", "model", "source_file", "source_scope").merge(
      "run_id" => run_id, "status" => "PROPOSED", "review_disposition" => "REVIEW_REQUIRED", "adventure_title" => "Unit C",
      "source_book" => "New Source", "metric" => DIMENSION, "metric_kind" => "ordinal", "value" => "3",
      "confidence" => "0.9", "assessment_state" => "resolved", "evidence" => "[]",
      "rationale" => "Synthetic fixture proposal.", "path_sensitive" => "false", "path_variation_affects_anchor" => "false")
    CSV.open(File.join(assessments, "#{ADVENTURE}_#{run_id}.csv"), "w") do |csv|
      csv << record.keys
      csv << record.values
    end
    request = {"provider" => metadata.fetch("provider"), "payload" => {"model" => metadata.fetch("model"), "messages" => []}}
    write_json(File.join(raw, "#{target.fetch('artifact_name')}_request.json"), target.slice("prompt_sha256", "schema_sha256").merge(
      "record_type" => "provider_request", "recorded_before_inference" => true, "recorded_at" => "2026-10-04T12:01:00Z",
      "request" => request, "request_sha256" => Digest::SHA256.hexdigest(JSON.generate(request))))
    write_json(File.join(raw, "#{target.fetch('artifact_name')}.json"), {"synthetic" => true})
  end

  # Have the pipeline ingest the real AFW publication, then fill its ledger
  # with one attributed fixture decision and return the release inputs path.
  def review_workload(manifest, binding_path, paths)
    review = File.join(@data, "review")
    audit = File.join(@data, "audit")
    pipeline("af-data", "prepare-workload-review", manifest, "--afw-root", @workloads,
      "--review-dir", review, "--audit-dir", audit, diagnostic: /Evidence-ready cases: 1/)
    ledger = File.join(audit, "editorial_decisions.csv")
    table = CSV.read(ledger, headers: true)
    assert_equal 1, table.size
    table.first["editorial_decision"] = "ACCEPT"
    table.first["editorial_note"] = "Synthetic mechanical test decision"
    File.write(ledger, table.to_csv)
    policy, selection = %w[synthetic-policy.json synthetic-owner-selection.json].map do |name|
      File.join(CODE, "test/fixtures/standing_bulk_score", name)
    end
    inputs = File.join(@data, "release-inputs.json")
    write_json(inputs, {"schema_version" => AfDataPipeline::StandingBulkScoreRelease::INPUT_SCHEMA, "mode" => "synthetic",
      "staged_scoring" => {"evidence" => @evidence, "store_root" => @store, "current_project_state_path" => @state,
                          "workload_binding_path" => binding_path, "workload_paths" => paths},
      "workload_review" => {"manifest_path" => manifest, "afw_root" => @workloads, "review_dir" => review, "audit_dir" => audit},
      "standing_policy_path" => policy, "owner_selection_path" => selection, "machine_acceptance" => nil})
    inputs
  end

  # Archive the actual AFW manifest through EV and return the verified paths.
  def archive_evidence(manifest)
    source = File.join(@data, "archive-source")
    Dir.mkdir(source)
    FileUtils.cp(manifest, File.join(source, "workload-manifest.json"))
    receipt = JSON.parse(File.binread(manifest)).fetch("cases").fetch(0).dig("receipt", "reference", "path")
    FileUtils.cp(File.join(@workloads, receipt), File.join(source, "scoring-receipt.json"))
    bundle_path = File.join(@data, "workload.tar.zst")
    manifest_path = File.join(@data, "archive-manifest.json")
    bundle = AfEvidence::EvidenceBundleBuilder.new(batch_root: source, batch_id: "mechanical-workload").build!(output_path: bundle_path)
    AfEvidence::EvidenceManifestBuilder.new(batch_root: source, batch_id: "mechanical-workload").write!(
      output_path: manifest_path, bundle: bundle.bundle, members: bundle.members)
    verify_archive({manifest_path:, bundle_path:, source_root: source})
    {manifest_path:, bundle_path:, source_root: source}
  end

  # Verify exact EV manifest, bundle and source bytes through the selected owner.
  def verify_archive(paths)
    assert AfEvidence::EvidenceBundleVerifier.new.verify!(**paths).source_verified
  end

  # Complete the real release and adopt as a fresh process; retain the exact
  # successor, independent roles, evidence and original receipt on replay.
  def adopt_release(release_inputs, manifest, archived)
    output = File.join(@data, "release")
    pipeline("af-standing-bulk-score-release", "--inputs", release_inputs, "--output", output)
    release = File.join(output, AfDataPipeline::StandingBulkScoreRelease::OUTPUTS.fetch("release_manifest"))
    package_inputs = File.join(@data, "package-inputs.json")
    write_json(package_inputs, {"schema_version" => AfDataPipeline::FinalReleasePackage::INPUT_SCHEMA,
      "release_inputs_path" => release_inputs, "release_manifest_path" => release,
      "catalog_repository_root" => @catalog, "current_project_state_path" => @state, "frontier_result_path" => nil})
    preload = catalog_observer
    package_path = File.join(@data, "package.json")
    request_path = File.join(@data, "request.json")
    approval_path = File.join(@data, "approval.json")
    result_path = File.join(@data, "result.json")
    pipeline("af-final-release-package", "prepare", "--inputs", package_inputs, "--output", package_path, preload:)
    common = ["--inputs", package_inputs, "--package", package_path]
    request = JSON.parse(pipeline("af-final-release-adoption", "prepare", *common, "--output", request_path, preload:))
    destination = request.dig("candidate", "destination")
    refute_path_exists destination
    args = ["adopt", *common, "--request", request_path, "--approval", approval_path, "--result", result_path]
    before = inventory
    pipeline("af-final-release-adoption", *args, preload:, diagnostic: /NO_APPROVAL/, exit_code: 3)
    pipeline("af-project-state", "promote", "catalog_head", "--manifest", @state, "--artifact", @stage, "--version", "0.2",
      diagnostic: /requires reviewed adoption/, exit_code: 2)
    assert_equal before, inventory
    pipeline("af-final-release-adoption", "approve", *common, "--request", request_path,
      "--output", approval_path, "--decided-by", "Synthetic reviewer", preload:)
    while_changed(manifest, File.binread(manifest) + "\n") do
      pipeline("af-final-release-adoption", *args, preload:, exit_code: 2, diagnostic: /changed|differ|mismatch/i)
    end
    while_changed(@state, File.binread(@state) + "# stale state\n") do
      pipeline("af-final-release-adoption", *args, preload:, exit_code: 2, diagnostic: /changed|differ|stale/i)
    end
    before = inventory
    result = JSON.parse(pipeline("af-final-release-adoption", *args, preload:))
    assert_equal "PROMOTED", result.fetch("status")
    assert_equal Digest::SHA256.file(destination).hexdigest, request.dig("candidate", "sha256")
    assert_equal ["Unit C", "New Source", 10, 11, 3], frontier_row(destination)
    after_roles = YAML.safe_load_file(@state)
    assert_equal @roles.except("catalog_head"), after_roles.except("catalog_head")
    assert_equal request.dig("candidate", "sha256"), after_roles.dig("catalog_head", "sha256")
    after = inventory
    assert_equal [@state, destination, result_path].map { |path| path.delete_prefix(@data + "/") }.sort,
      (before.keys | after.keys).select { |path| before[path] != after[path] }.sort
    inode = File.stat(result_path).ino
    replay = JSON.parse(pipeline("af-final-release-adoption", *args, preload:))
    assert_equal "ALREADY_PROMOTED", replay.fetch("status")
    assert_equal inode, File.stat(result_path).ino
    assert_equal after, inventory
    verify_archive(archived)
  end

  # Frontier Pack reads the exact staged or adopted workbook in a new process.
  def frontier_row(workbook)
    program = 'rows = AfFrontier::XlsxCatalogReader.new(ARGV.fetch(0)).rows; puts JSON.generate(rows.find { |r| r["ADV - ID"] == "ADV-0003" }.values_at("Adventure Title", "Source Book", "Start Page", "End Page", "Exploration Emphasis"))'
    command = [RbConfig.ruby, "-I#{@frontier}/lib", "-raf_frontier", "-rjson", "-e", program, workbook]
    stdout, stderr, status = Open3.capture3(@environment, *command, chdir: @cwd, binmode: true)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  # Transport only the catalog's read-only Git observations. Catalog file
  # resolution, lock acquisition, validation and publication remain real.
  def catalog_observer
    observations = File.join(@data, "git-observation.json")
    write_json(observations, [@state, @base].to_h { |path| [File.basename(path), File.binread(path).unpack1("H*")] })
    path = File.join(@scratch, "catalog-observer.rb")
    File.write(path, <<~PROGRAM)
      require "json"
      require "open3"
      root = #{@catalog.inspect}
      files = JSON.parse(File.binread(#{observations.inspect}))
      head = "b" * 40
      original = Open3.method(:capture3)
      Open3.define_singleton_method(:capture3) do |*arguments, **options|
        command = arguments.first.is_a?(Hash) ? arguments.drop(1) : arguments
        next original.call(*arguments, **options) unless command[0, 3] == ["git", "-C", root]
        query = command.drop(3)
        stdout = case query
                 when ["rev-parse", "--show-toplevel"] then root + "\n"
                 when ["rev-parse", "HEAD"] then head + "\n"
                 when ["remote", "get-url", "origin"] then "fixture://catalog\n"
                 when ["status", "--porcelain=v1", "--", "PROJECT_STATE.yml"]
                   raise "unexpected writable Git status" unless arguments.first == {"GIT_OPTIONAL_LOCKS" => "0"}
                   File.binread(File.join(root, "PROJECT_STATE.yml")) == [files.fetch("PROJECT_STATE.yml")].pack("H*") ? "" : " M PROJECT_STATE.yml\n"
                 when ["status", "--porcelain=v1", "--", "5e_Adventure_Master_Catalog_0.2.xlsx"] then "?? 5e_Adventure_Master_Catalog_0.2.xlsx\n"
                 else
                   raise "unexpected catalog Git command \#{query.inspect}" unless query.size == 2 && query.first == "show" && query.last.start_with?(head + ":")
                   [files.fetch(query.last.delete_prefix(head + ":"))].pack("H*")
                 end
        [stdout, "", Struct.new(:success?).new(true)]
      end
    PROGRAM
    ["-r", path]
  end
end
