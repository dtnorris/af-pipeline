# frozen_string_literal: true

require_relative "../staged_selection_authority_test"
require_relative "../support/standing_bulk_score_release_fixture"

class StandingBulkSelectionReleaseTest < Minitest::Test
  # Exercise the real V2 selection, frozen workload and release validators in
  # the same catalog root through explicit approval, publication and replay.
  def test_fresh_v2_stage_reaches_final_approval_publication_and_exact_replay
    Dir.mktmpdir("standing-bulk-publication-") do |root|
      root = File.realpath(root)
      fixture, inputs, selection = prepare_release(root)
      release = fixture.release
      state_path = inputs.dig("staged_scoring", "current_project_state_path")
      before = File.binread(state_path)
      roles = YAML.safe_load(before)
      protected = Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }
        .to_h { |path| [path, File.binread(path)] }
      stage = selection.fetch("staged_amc")
      assert_equal File.basename(fixture.staged_path), stage.fetch("filename")
      assert_equal "staged-5e_Adventure_Master_Catalog_0.2.xlsx", stage.fetch("filename")
      refute_equal stage.fetch("sha256"), AfDataPipeline::StandingBulkScorePolicy.file_binding(release.workbook_path).fetch("sha256")
      package_inputs = File.join(root, "package-inputs.json")
      File.binwrite(package_inputs, JSON.pretty_generate(
        "schema_version" => AfDataPipeline::FinalReleasePackage::INPUT_SCHEMA,
        "release_inputs_path" => fixture.inputs_path, "release_manifest_path" => release.manifest_path,
        "catalog_repository_root" => root, "current_project_state_path" => state_path, "frontier_result_path" => nil
      ) + "\n")
      with_catalog_observation(root, state_path, roles) do
        package = AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: package_inputs,
          output_path: File.join(root, "package.json"))
        assert package.package.dig("readiness", "ready")
        assert_equal "0.2", package.package.dig("candidate", "version")
        assert_equal inputs.dig("staged_scoring", "selection_path"),
          package.package.dig("provenance", "nodes", "release_input:afw_selection", "path")
        request = AfDataPipeline::FinalReleaseAdoption.prepare!(inputs_path: package_inputs, package_path: package.path,
          output_path: File.join(root, "request.json"))
        approval_path = File.join(root, "final-approval.json")
        refute_path_exists approval_path
        assert_equal before, File.binread(state_path)
        destination = File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx")
        assert_equal destination, request.document.dig("candidate", "destination")
        refute_path_exists destination
        approval = AfDataPipeline::FinalReleaseAdoption.decide!(inputs_path: package_inputs, package_path: package.path,
          request_path: request.path, output_path: approval_path, decision: "APPROVE", decided_by: "Synthetic final human owner")
        adoption = {inputs_path: package_inputs, package_path: package.path, request_path: request.path,
          approval_path: approval.path, result_path: File.join(root, "adoption-result.json")}
        result = AfDataPipeline::FinalReleaseAdoption.adopt!(**adoption)
        assert_equal "PROMOTED", result.status
        assert_equal File.binread(release.workbook_path), File.binread(destination)
        actual = YAML.safe_load_file(state_path)
        assert_equal roles.except("catalog_head"), actual.except("catalog_head")
        assert_equal package.package.dig("transition", "proposed_catalog_head"), actual.fetch("catalog_head")
        protected.except(state_path).each { |path, bytes| assert_equal bytes, File.binread(path), path }
        after = Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }
          .to_h { |path| [path, File.binread(path)] }
        assert_equal "ALREADY_PROMOTED", AfDataPipeline::FinalReleaseAdoption.adopt!(**adoption).status
        assert_v2_cold_replay(adoption, root, roles, before)
        assert_equal after, after.keys.to_h { |path| [path, File.binread(path)] }
        assert_equal after.keys.sort, Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }.sort
      end
    end
  end

  def test_real_afw_selection_releases_and_replays_without_losing_authority
    Dir.mktmpdir("standing-bulk-selection-") do |root|
      fixture, inputs, selection = prepare_release(root)
      state = inputs.dig("staged_scoring", "current_project_state_path")
      base = File.binread(File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx"))
      selection_path = inputs.dig("staged_scoring", "selection_path")
      publication_path = File.join(File.dirname(selection_path), "publication.json")
      generated = inputs.dig("staged_scoring", "workload_paths", "generated")

      # A change after the apply phase must not publish a partial release.
      original = File.binread(publication_path)
      error = assert_raises(AfDataPipeline::ValidationError) do
        fixture.release(fault_injector: ->(phase) {
          File.binwrite(publication_path, "changed\n") if phase == :after_finalize
        })
      end
      assert_match(/changed during application/, error.message)
      refute File.exist?(fixture.output_dir)
      File.binwrite(publication_path, original)

      first = fixture.release
      assert_equal "VERIFIED_RELEASE_CANDIDATE", first.manifest.fetch("status")
      assert_equal selection.fetch("selection_id"), first.manifest.dig("lineage", "workload_authority", "selection_id")
      assert_equal 11, first.manifest.dig("counts", "intended_cases")
      assert_equal 11, first.manifest.dig("counts", "execution_evidence_ready_cases")
      assert_equal 6, first.manifest.dig("counts", "standing_directive_accepted")
      assert_equal 5, first.manifest.dig("counts", "deferred_or_unsupported")
      assert_equal 0, first.manifest.dig("counts", "individual_human_accepted")
      assert_equal 0, first.manifest.dig("counts", "ig16b_machine_accepted")
      assert_equal base, File.binread(File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx"))
      snapshot = JSON.parse(File.binread(File.join(first.output_dir, "release-authorization.json"))).fetch("input_snapshot")
      assert snapshot.key?("afw_selection")
      assert snapshot.key?("afw_selection_publication")
      assert snapshot.keys.any? { |key| key.start_with?("workload_generated:") }
      stdout, stderr, status = Open3.capture3(
        {"AF_DATA_PIPELINE_DATA_ROOT" => File.realpath(root)}, RbConfig.ruby, *StagedScorerIdentityTransport::PRELOAD,
        File.expand_path("../../bin/af-standing-bulk-score-release", __dir__),
        "--inputs", fixture.inputs_path, "--output", fixture.output_dir
      )
      assert status.success?, stderr
      assert_match(/verified existing release/, stdout)
      verified = AfDataPipeline::StandingBulkScoreRelease.new(inputs_path: fixture.inputs_path, output_dir: fixture.output_dir)
        .validate_existing!(current_project_state_path: state)
      assert_equal selection.fetch("selection_id"), verified.release.manifest.dig("lineage", "workload_authority", "selection_id")
      assert verified.release.reused

      # FinalReleasePackage consumes the same release input snapshot before
      # its independent catalog-Git and workbook checks.
      package = AfDataPipeline::FinalReleasePackage.new(inputs_path: "unused")
      package.instance_variable_set(:@refs, {
        "release_inputs" => {"path" => fixture.inputs_path},
        "release_manifest" => {"path" => first.manifest_path}
      })
      package.send(:bind_release_evidence!, inputs, first.manifest, verified.projection.fetch("authority"))
      assert package.instance_variable_get(:@refs).key?("release_input:afw_selection")

      assert_refused_replay(fixture, selection_path, /selection|authority|input|changed/i)
      assert_refused_replay(fixture, publication_path, /selection|publication|input|changed/i)
      assert_refused_replay(fixture, inputs.dig("staged_scoring", "selection_scorer_config"), /selection|config|input|changed/i)
      File.rename(publication_path, publication_path + ".held")
      assert_raises(AfDataPipeline::Error) { fixture.release }
      File.rename(publication_path + ".held", publication_path)
      generated_file = AfDataPipeline::StandingBulkScoreRelease.generated_files(generated).values.first
      assert_refused_replay(fixture, generated_file, /selection|workload|input|changed/i)
      binding_path = inputs.dig("staged_scoring", "workload_binding_path")
      binding_bytes = File.binread(binding_path)
      forged = JSON.parse(binding_bytes)
      forged["selection_id"] = "f" * 64
      File.binwrite(binding_path, JSON.pretty_generate(forged) + "\n")
      assert_raises(AfDataPipeline::Error) { fixture.release }
      File.binwrite(binding_path, binding_bytes)
      assert_refused_replay(fixture, state, /stale|authority|input|changed|state/i)
      fixture.rewrite_inputs { |document| document.fetch("staged_scoring")["selection_path"] = File.join(root, "elsewhere.json") }
      assert_raises(AfDataPipeline::ValidationError) { fixture.release }
      File.binwrite(fixture.inputs_path, JSON.pretty_generate(inputs) + "\n")
      assert fixture.release.reused
    end
  end

  private

  # Start without process-local proofs. Only the same immutable catalog Git
  # observation is transported; AFW selection and workload verification rerun.
  def assert_v2_cold_replay(adoption, root, roles, manifest_bytes)
    files = roles.values.grep(Hash).map { |role| role.fetch("filename") }.uniq
      .to_h { |name| [name, File.binread(File.join(root, name)).unpack1("H*")] }
    files["PROJECT_STATE.yml"] = manifest_bytes.unpack1("H*")
    observation = {"root" => root, "files" => files, "adoption" => adoption}
    program = <<~'RUBY'
      observation = JSON.parse(STDIN.read)
      original = Open3.method(:capture3)
      root = observation.fetch("root")
      reader = lambda do |*argv, **options|
        next original.call(*argv, **options) unless argv[0, 3] == ["git", "-C", root]
        args = argv.drop(3)
        head = "b" * 40
        stdout = case args
        when ["rev-parse", "--show-toplevel"] then root + "\n"
        when ["rev-parse", "HEAD"] then head + "\n"
        when ["remote", "get-url", "origin"] then "fixture://catalog\n"
        else
          raise "unexpected catalog Git IO" unless args.length == 2 && args.first == "show" && args.last.start_with?(head + ":")
          [observation.fetch("files").fetch(args.last.delete_prefix(head + ":"))].pack("H*")
        end
        [stdout, "", Struct.new(:success?).new(true)]
      end
      Open3.stub(:capture3, reader) do
        result = AfDataPipeline::FinalReleaseAdoption.adopt!(**observation.fetch("adoption").transform_keys(&:to_sym))
        puts JSON.generate("status" => result.status)
      end
    RUBY
    stdout = IO.popen([RbConfig.ruby, *StagedScorerIdentityTransport::PRELOAD,
      "-I#{File.expand_path('../../lib', __dir__)}", "-raf_data_pipeline",
      "-rminitest/mock", "-e", program], "r+", err: [:child, :out]) do |pipe|
      pipe.write(JSON.generate(observation))
      pipe.close_write
      pipe.read
    end
    assert $?.success?, stdout
    assert_equal "ALREADY_PROMOTED", JSON.parse(stdout).fetch("status")
  end

  # Double only the catalog's read-only Git observation, without synthetic
  # commits. The public validators replay through the AFW subprocess and scorer fixture.
  def with_catalog_observation(root, state_path, roles)
    original = Open3.method(:capture3)
    observed = roles.values.grep(Hash).map { |role| role.fetch("filename") }.uniq
      .to_h { |name| [name, File.binread(File.join(root, name))] }
    observed[File.basename(state_path)] = File.binread(state_path)
    head = "b" * 40
    reader = lambda do |*argv, **options|
      command = argv.first.is_a?(Hash) ? argv.drop(1) : argv
      unless command[0, 3] == ["git", "-C", root]
        next original.call(*argv, **options)
      end
      args = command.drop(3)
      stdout = case args
      when ["rev-parse", "--show-toplevel"] then root + "\n"
      when ["rev-parse", "HEAD"] then head + "\n"
      when ["remote", "get-url", "origin"] then "fixture://catalog\n"
      when ["status", "--porcelain=v1", "--", "PROJECT_STATE.yml"]
        raise "Git index refresh enabled" unless argv.first == {"GIT_OPTIONAL_LOCKS" => "0"}
        File.binread(state_path) == observed.fetch("PROJECT_STATE.yml") ? "" : " M PROJECT_STATE.yml\n"
      else
        raise "unexpected catalog Git IO: #{args.inspect}" unless args.length == 2 && args.first == "show" && args.last.start_with?(head + ":")
        observed.fetch(args.last.delete_prefix(head + ":"))
      end
      [stdout, "", Struct.new(:success?).new(true)]
    end
    Open3.stub(:capture3, reader) { yield }
  end

  def assert_refused_replay(fixture, path, message)
    bytes = File.binread(path)
    File.binwrite(path, bytes + "changed\n")
    error = assert_raises(AfDataPipeline::Error) { fixture.release }
    assert_match(message, error.message)
  ensure
    File.binwrite(path, bytes) if bytes
  end

  def prepare_release(root)
    fixture = StandingBulkScoreReleaseFixture.new(root:)
    inputs = JSON.parse(File.binread(fixture.inputs_path))
    old_manifest = JSON.parse(File.binread(fixture.manifest_path))
    staged = inputs.fetch("staged_scoring")
    afw_root = inputs.dig("workload_review", "afw_root")
    scorer = StagedSelectionAuthorityTest.prepare_scorer_fixture(File.join(root, "scorer"))

    FileUtils.rm_rf(afw_root)
    FileUtils.rm_rf(fixture.review_dir)
    FileUtils.rm_rf(fixture.audit_dir)
    helper = StagedSelectionAuthorityTest.new("test_all_deferred_and_zero_allocation_have_distinct_public_results")
    {root:, project: afw_root, scorer:, catalog: fixture.staged_path}.each do |name, value|
      helper.instance_variable_set(:"@#{name}", value)
    end
    helper.send(:prepare_afw_fixture)
    scorer_config = helper.send(:prepare_scorer_config)
    helper.send(:write_prepared_source_template)
    evidence = staged.fetch("evidence").transform_keys(&:to_sym)
    service = StagedSelectionAuthorityTest::InlineAuthority.new(
      evidence:, store_root: staged.fetch("store_root"), mode: "synthetic",
      selection_afw_root: StagedSelectionAuthorityTest::AFW, selection_project_root: afw_root,
      selection_scorer_root: scorer, selection_scorer_config: scorer_config
    )
    owner = StagedSelectionAuthorityTest::ContentAddressedSelection.new(root: StagedSelectionAuthorityTest::AFW, data_root: afw_root, scorer_repo: scorer, scorer_config:)
    service.selection_verifier = owner
    runner = lambda do |command|
      option = ->(name) { command.include?(name) ? command[command.index(name) + 1] : nil }
      begin
        projection = service.validate!(
          current_state_path: staged.fetch("current_project_state_path"),
          selection_path: option.call("--selection"),
          frozen_workload: option.call("--workload-binding") && JSON.parse(File.binread(option.call("--workload-binding"))),
          workload_paths: option.call("--workload-paths") && JSON.parse(File.binread(option.call("--workload-paths")))
        )
        [JSON.generate(projection), "", true]
      rescue AfDataPipeline::Error => e
        ["", e.message, false]
      end
    end
    locator = File.join(root, "locators.json")
    File.binwrite(locator, JSON.pretty_generate({
      "schema_version" => "af-staged-scoring-evidence-locators/v0.1", "evidence" => staged.fetch("evidence")
    }) + "\n")
    config = {
      pipeline_root: File.expand_path("../..", __dir__), inputs_path: locator,
      store_root: staged.fetch("store_root"), project_state_path: staged.fetch("current_project_state_path"),
      operation_id: "11111111-1111-4111-8111-111111111111", mode: "synthetic", command_runner: runner
    }
    staged_input = AFWorkloads::StagedScoringInput.new(root: afw_root, config:)
    result = owner.prepare!(staged_scoring: staged_input, catalog_path: fixture.staged_path,
                            required_context_length: 131_072, require_fully_gpu_resident: true, out: StringIO.new)
    assert_equal "PREPARED", result.fetch("status")
    assert_equal AfDataPipeline::StagedScoringAuthority.file_binding(scorer_config).merge("path" => scorer_config),
      result.dig("selection", "scorer_config")
    workload = result.fetch("workload")
    plan_path = File.join(workload, "execution-plan.json")
    snapshot_path = File.join(workload, "snapshot.yml")
    index_path = File.join(workload, "case_index.csv")
    generated = File.join(afw_root, "build/workloads/synthetic-operation-1")
    binding_path = File.join(afw_root, "workloads/.selections/synthetic-operation-1/frozen-workload.json")
    selection_path = File.join(afw_root, "workloads/.selections/synthetic-operation-1/selection.json")
    rows = CSV.read(index_path, headers: true).map(&:to_h)
    jobs = JSON.parse(File.binread(plan_path)).fetch("jobs")
    wlo_root = File.join(root, "wlo")
    FileUtils.mkdir_p(wlo_root)
    wlo_plan = File.join(wlo_root, "plan.json")
    FileUtils.cp(plan_path, wlo_plan)
    execution_path = File.join(wlo_root, "execution.json")
    File.binwrite(execution_path, JSON.pretty_generate({
      "contract_version" => "wlo-execution-state/v0.1", "plan_id" => "synthetic-operation-1",
      "plan_sha256" => Digest::SHA256.file(plan_path).hexdigest,
      "status" => "completed", "retry_pending" => {}
    }) + "\n")
    builder = StandingBulkScoreReleaseFixture.allocate
    builder.instance_variable_set(:@root, root)
    builder.instance_variable_set(:@afw_root, afw_root)
    specs = rows.map { |row| {case_id: row.fetch("case_id"), dimension: row.fetch("dimension"), metrics: {row.fetch("dimension") => 3}} }
    cases = specs.zip(rows, jobs).map do |spec, row, job|
      builder.send(:build_manifest_case, spec:, state: :ready, row:, job:,
                   case_path: File.join(afw_root, row.fetch("case_path")), plan_path:, snapshot_path:, index_path:,
                   execution_path:, wlo_root:, bindings: row)
    end
    body = old_manifest.except("manifest_id")
    body.fetch("workload")["intended_case_count"] = rows.length
    body.fetch("workload")["afw"] = {
      "execution_plan" => builder.send(:reference, "afw", plan_path, afw_root, wlo_root),
      "snapshot" => builder.send(:reference, "afw", snapshot_path, afw_root, wlo_root),
      "case_index" => builder.send(:reference, "afw", index_path, afw_root, wlo_root)
    }
    body.fetch("workload").fetch("wlo")["plan"] = builder.send(:reference, "wlo", wlo_plan, afw_root, wlo_root)
    body.fetch("workload").fetch("wlo")["execution"] = builder.send(:embedded, execution_path, afw_root, wlo_root)
    body["cases"] = cases
    body["summary"] = {
      "intended_cases" => cases.length, "classified_cases" => cases.length, "accounting_complete" => true,
      "execution_counts" => {"complete" => cases.length}, "evidence_counts" => {"ready" => cases.length},
      "receipt_count" => cases.length, "review_candidate_count" => cases.length, "evidence_complete" => true
    }
    body["manifest_id"] = builder.send(:digest, body)
    manifest_path = File.join(afw_root, "output/workloads/synthetic-operation-1/evidence/manifests/fixture.json")
    FileUtils.mkdir_p(File.dirname(manifest_path))
    builder.send(:write_json, manifest_path, body)
    inputs["schema_version"] = AfDataPipeline::StandingBulkScoreRelease::SELECTION_INPUT_SCHEMA
    staged.merge!("selection_path" => selection_path,
                  "selection_afw_root" => StagedSelectionAuthorityTest::AFW,
                  "selection_project_root" => afw_root,
                  "selection_scorer_root" => scorer,
                  "selection_scorer_config" => scorer_config,
                  "workload_binding_path" => binding_path,
                  "workload_paths" => {"plan" => plan_path, "snapshot" => snapshot_path,
                                       "index" => index_path, "generated" => generated})
    inputs.fetch("workload_review")["manifest_path"] = manifest_path
    File.binwrite(fixture.inputs_path, JSON.pretty_generate(inputs) + "\n")
    review = AfDataPipeline::WorkloadScoringReviewPackage.prepare!(
      manifest_path:, afw_root:, review_dir: fixture.review_dir, audit_dir: fixture.audit_dir
    )
    assert_equal rows.length, review.intended_cases
    [fixture, inputs, result.fetch("selection")]
  end
end
