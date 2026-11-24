# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/standing_bulk_score_release_fixture"
require "stringio"

class FrontierResidualScoringTest < Minitest::Test
  SERVICE = AfDataPipeline::FrontierResidualScoring
  ERROR = AfDataPipeline::ValidationError

  def test_packet_apply_and_final_package_preserve_original_and_separate_authority
    with_frontier do |fixture, request, packet, result|
      original = snapshot(fixture.output_dir)
      shared = snapshot(File.join(fixture.root, "catalog-repository"))
      ledger = File.binread(File.join(fixture.audit_dir, "editorial_decisions.csv"))
      prepared = SERVICE.prepare!(request_path: request, output_dir: packet)
      assert_equal "READY", prepared.status
      handoff = read(File.join(packet, "handoff.json"))
      assert_equal 2, handoff.fetch("targets").length
      assert_equal 4, handoff.dig("population", "intended_metrics")
      assert handoff.fetch("references").key?("authority:source:fixture.md")
      assert_equal "Synthetic rubric 1", handoff.dig("rubric", "id")
      assert_includes File.read(File.join(packet, "prompt.md")), "Level Start and Level End"
      returned = write_return(packet, fixture.root, no_write: ["ADV-0003::Structural Openness"])
      applied = SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result)
      assert_equal "APPLIED", applied.status
      assert_equal({"writes" => 1, "no_writes" => 1}, applied.document.fetch("counts"))
      accounting = read(File.join(result, "accounting.json"))
      assert_equal 1, accounting.dig("after", "remaining_blank_metrics")
      assert_equal 1, accounting.dig("after", "frontier_written_metrics")
      assert_equal accounting.dig("before", "acceptance"), accounting.dig("after", "acceptance")
      package = AfDataPipeline::FinalReleasePackage.prepare!(
        inputs_path: File.join(result, "package-inputs.json"), output_path: File.join(fixture.root, "derived-package.json")
      ).package
      assert_equal "ig17f_derived", package.dig("candidate", "selection")
      assert_equal "frontier_manual", package.dig("candidate", "frontier", "authority")
      assert_equal 1, package.dig("release", "population", "frontier_written_metrics")
      assert_equal 4, package.dig("release", "population", "intended_metrics")
      assert_equal original, snapshot(fixture.output_dir)
      assert_equal shared, snapshot(File.join(fixture.root, "catalog-repository"))
      assert_equal ledger, File.binread(File.join(fixture.audit_dir, "editorial_decisions.csv"))
      packet_bytes = snapshot(packet)
      result_bytes = snapshot(result)
      assert SERVICE.prepare!(request_path: request, output_dir: packet).reused
      assert SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result).reused
      assert SERVICE.verify!(request_path: request, packet_dir: packet, output_dir: result).reused
      assert_equal packet_bytes, snapshot(packet)
      assert_equal result_bytes, snapshot(result)
      assert_raises(ERROR) { SERVICE.decline!(request_path: request, packet_dir: packet, output_dir: result) }
      rewrite(returned) { |doc| doc["records"][0]["proposed_value"] = 3; seal!(doc, "return_id") }
      assert_raises(ERROR) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
      assert_equal result_bytes, snapshot(result)
    end
  end

  def test_no_gap_and_decline_need_no_return_or_inference
    with_frontier(gaps: false) do |fixture, request, packet, _result|
      rewrite(request) { |doc| doc["rubric"] = nil; doc["successor_version"] = nil }
      response = SERVICE.prepare!(request_path: request, output_dir: packet)
      assert_equal "NO_GAPS", response.status
      refute File.exist?(packet)
      assert File.file?(File.join(fixture.output_dir, "release-candidate.xlsx"))
    end
    with_frontier do |fixture, request, packet, result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      response = SERVICE.decline!(request_path: request, packet_dir: packet, output_dir: result)
      assert_equal "DECLINED", response.status
      assert_equal({"writes" => 0, "no_writes" => 2}, response.document.fetch("counts"))
      refute File.exist?(File.join(result, "candidate.xlsx"))
      assert SERVICE.decline!(request_path: request, packet_dir: packet, output_dir: result).reused
      package = AfDataPipeline::FinalReleasePackage.prepare!(
        inputs_path: File.join(result, "package-inputs.json"), output_path: File.join(fixture.root, "declined-package.json")
      ).package
      assert_equal "original_ig17", package.dig("candidate", "selection")
      assert package.dig("readiness", "ready")
      refute package.dig("readiness", "full_scoring")
    end
  end

  def test_levels_are_independent_and_use_effective_unchanged_sibling
    configure = ->(fixture) { fixture.set_decision("ADV-0003::Level End", "ACCEPT") }
    with_frontier(levels: nil, configure:) do |fixture, request, packet, result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      handoff = read(File.join(packet, "handoff.json"))
      keys = handoff.fetch("targets").map { |row| row.fetch("candidate_key") }
      assert_includes keys, "ADV-0003::Level Start"
      refute_includes keys, "ADV-0003::Level End"
      returned = write_return(packet, fixture.root)
      rewrite(returned) do |doc|
        doc["records"].find { |row| row["candidate_key"].end_with?("Level Start") }["proposed_value"] = 6
        seal!(doc, "return_id")
      end
      assert_raises(ERROR) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
      refute File.exist?(result)
      rewrite(returned) do |doc|
        doc["records"].find { |row| row["candidate_key"].end_with?("Level Start") }["proposed_value"] = 2
        seal!(doc, "return_id")
      end
      assert_equal "APPLIED", SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result).status
    end
    with_frontier(levels: nil) do |fixture, request, packet, result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      returned = write_return(packet, fixture.root, no_write: ["ADV-0003::Level Start"])
      response = SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result)
      assert_equal 1, response.document.dig("counts", "no_writes")
      actions = read(File.join(result, "accounting.json")).fetch("metric_actions")
      assert_equal "written", actions.find { |row| row["candidate_key"].end_with?("Level End") }.fetch("action")
      package = AfDataPipeline::FinalReleasePackage.prepare!(
        inputs_path: File.join(result, "package-inputs.json"), output_path: File.join(fixture.root, "partial-levels-package.json")
      ).package
      assert_equal "PASS", package.dig("compatibility", "status")
      refute package.dig("readiness", "full_scoring")
      standalone = AfDataPipeline::AmcCompatibilityCheck.check(candidate_path: File.join(result, "candidate.xlsx"))
      assert_includes standalone.fetch("errors").join(" "), "Level Start and Level End"
    end
  end

  def test_all_uncertain_return_preserves_values_and_is_not_local_inference
    with_frontier do |fixture, request, packet, result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      keys = read(File.join(packet, "handoff.json")).fetch("targets").map { |row| row.fetch("candidate_key") }
      returned = write_return(packet, fixture.root, no_write: keys)
      response = SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result)
      assert_equal({"writes" => 0, "no_writes" => 2}, response.document.fetch("counts"))
      assert_empty read(File.join(result, "authorization.json")).fetch("accepted_candidates")
      assert_equal "frontier_manual", read(File.join(result, "authorization.json")).fetch("authority")
      assert_equal 2, read(File.join(result, "accounting.json")).dig("after", "remaining_blank_metrics")
    end
  end

  def test_adversarial_returns_are_refused_before_any_output
    with_frontier do |fixture, request, packet, result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      returned = write_return(packet, fixture.root)
      original = File.binread(returned)
      mutations = [
        ->(doc) { doc["handoff_id"] = "0" * 64 },
        ->(doc) { doc["records"].pop },
        ->(doc) { doc["records"] << doc["records"].first.dup },
        ->(doc) { doc["records"][0]["candidate_key"] = "ADV-0001::Combat Emphasis" },
        ->(doc) { doc["records"][0]["extra"] = true },
        ->(doc) { doc["records"][0]["proposed_value"] = 6 },
        ->(doc) { doc["records"][0]["proposed_value"] = 2.5 },
        ->(doc) { doc["records"][0]["proposed_value"] = "4" },
        ->(doc) { doc["records"][0]["reason"] = " " },
        ->(doc) { doc["records"][0]["source_references"] = ["rubric"] },
        ->(doc) { doc["records"][0]["source_references"] = ["authority:source:missing.md"] }
      ]
      mutations.each do |mutation|
        File.binwrite(returned, original)
        rewrite(returned) { |doc| mutation.call(doc); seal!(doc, "return_id") }
        assert_raises(ERROR) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
        refute File.exist?(result)
      end
      File.binwrite(returned, original)
      rewrite(returned) { |doc| doc["return_id"] = "0" * 64 }
      assert_raises(ERROR) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
      File.binwrite(returned, original.sub('"records":', '"records": [], "records":'))
      assert_raises(ERROR) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
    end
  end

  def test_changed_bound_artifacts_fail_closed
    with_frontier do |fixture, request, packet, result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      returned = write_return(packet, fixture.root)
      handoff = read(File.join(packet, "handoff.json"))
      refs = handoff.fetch("references")
      names = %w[rubric authority:source:fixture.md authority:staged authority:base workload_manifest editorial_ledger]
      paths = names.map { |name| refs.fetch(name).fetch("path") }
      paths << File.join(fixture.output_dir, "release-candidate.xlsx")
      paths.each do |path|
        original = File.binread(path)
        begin
          File.binwrite(path, original + "\n")
          assert_raises(ERROR) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
          refute File.exist?(result)
        ensure
          File.binwrite(path, original)
        end
      end
      File.write(File.join(packet, "prompt.md"), "changed")
      assert_raises(ERROR) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
    end
  end

  def test_human_and_source_decisions_never_become_frontier_targets
    configure = lambda do |fixture|
      fixture.set_decision("ADV-0003::Combat Emphasis", "HOLD")
      fixture.set_decision("ADV-0003::Level Start", "REJECT")
    end
    specs = [
      {case_id: "combat", dimension: "Combat Emphasis", metrics: {"Combat Emphasis" => 3}},
      {case_id: "openness", dimension: "Structural Openness", metrics: {"Structural Openness" => 4},
       review_disposition: "SOURCE_HOLD", hold_reason: "Synthetic source limitation"},
      {case_id: "levels", dimension: "Levels", metrics: {"Level Start" => 1, "Level End" => 5}}
    ]
    with_frontier(specs:, configure:, levels: nil) do |_fixture, request, packet, _result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      targets = read(File.join(packet, "handoff.json")).fetch("targets")
      assert_equal ["ADV-0003::Level End"], targets.map { |row| row.fetch("candidate_key") }
    end
  end

  def test_real_execution_defect_cannot_be_offered_as_a_gap
    Dir.mktmpdir do |root|
      fixture = StandingBulkScoreReleaseFixture.new(root:, states: [:ready, :failed, :ready])
      assert_raises(ERROR) { fixture.release }
      refute File.exist?(fixture.output_dir)
    end
  end

  def test_session_values_are_positive_integers_and_levels_bounds_are_enforced
    specs = [{case_id: "sessions", dimension: "# of Sessions", metrics: {"# of Sessions" => 3}},
             {case_id: "levels", dimension: "Levels", metrics: {"Level Start" => 1, "Level End" => 5}}]
    with_frontier(specs:, levels: nil) do |fixture, request, packet, result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      returned = write_return(packet, fixture.root)
      original = File.binread(returned)
      [["# of Sessions", 0], ["# of Sessions", -1], ["# of Sessions", 1.5],
       ["Level Start", 0], ["Level End", 21], ["Level Start", 5]].each do |dimension, value|
        File.binwrite(returned, original)
        rewrite(returned) do |doc|
          doc["records"].find { |row| row["candidate_key"] == "ADV-0003::#{dimension}" }["proposed_value"] = value
          seal!(doc, "return_id")
        end
        assert_raises(ERROR) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
        refute File.exist?(result)
      end
      File.binwrite(returned, original)
      response = SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result)
      assert_equal 3, response.document.dig("counts", "writes")
    end
  end

  def test_partial_publication_and_tampered_accounting_are_refused
    with_frontier do |fixture, request, packet, result|
      SERVICE.prepare!(request_path: request, output_dir: packet)
      returned = write_return(packet, fixture.root)
      assert_raises(RuntimeError) do
        SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result,
                       fault_injector: ->(phase) { raise "synthetic interruption" if phase == :after_apply })
      end
      refute File.exist?(File.join(result, "result.json"))
      assert_raises(ERROR, SystemCallError) { SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result) }
      complete = result + "-complete"
      SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: complete)
      rewrite(File.join(complete, "accounting.json")) { |doc| doc["after"]["intended_metrics"] += 1 }
      rewrite(File.join(complete, "result.json")) do |doc|
        doc["artifacts"]["accounting"].merge!(AfDataPipeline::StandingBulkScorePolicy.file_binding(File.join(complete, "accounting.json")))
        seal!(doc, "result_id")
      end
      assert_raises(ERROR) { SERVICE.verify!(request_path: request, packet_dir: packet, output_dir: complete) }
    end
  end

  def test_output_cannot_change_immutable_release_or_source_directory
    with_frontier do |fixture, request, packet, result|
      original = snapshot(fixture.output_dir)
      assert_raises(ERROR) do
        SERVICE.prepare!(request_path: request, output_dir: File.join(fixture.output_dir, "packet"))
      end
      assert_equal original, snapshot(fixture.output_dir)
      SERVICE.prepare!(request_path: request, output_dir: packet)
      returned = write_return(packet, fixture.root)
      assert_raises(ERROR) do
        SERVICE.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: File.join(packet, "result"))
      end
      refute File.exist?(result)
    end
  end

  def test_public_cli_prepare_apply_verify_and_decline
    with_frontier do |fixture, request, packet, result|
      command = [{"AF_DATA_PIPELINE_DATA_ROOT" => fixture.root},
        RbConfig.ruby, File.expand_path("../../bin/af-frontier-residual-scoring", __dir__)]
      stdout, stderr, status = Open3.capture3(*command, "prepare", "--request", request, "--output", packet)
      assert status.success?, stderr
      assert_equal "READY", JSON.parse(stdout).fetch("status")
      returned = write_return(packet, fixture.root)
      stdout, stderr, status = Open3.capture3(*command, "apply", "--request", request, "--packet", packet,
                                            "--return", returned, "--output", result)
      assert status.success?, stderr
      assert_equal "APPLIED", JSON.parse(stdout).fetch("status")
      stdout, stderr, status = Open3.capture3(*command, "verify", "--request", request, "--packet", packet, "--output", result)
      assert status.success?, stderr
      assert JSON.parse(stdout).fetch("reused")
      stdout, stderr, status = Open3.capture3(*command, "decline", "--request", request, "--packet", packet, "--output", result + "-decline")
      assert status.success?, stderr
      assert_equal "DECLINED", JSON.parse(stdout).fetch("status")
    end
  end

  private

  def with_frontier(gaps: true, levels: {"start" => 1, "end" => 5}, specs: nil, configure: nil)
    Dir.mktmpdir("frontier-residual-", File.realpath(Dir.tmpdir)) do |root|
      fixture = StandingBulkScoreReleaseFixture.new(root:, specs:, boundary_levels: levels)
      fixture.mutate_policy { |policy| policy.fetch("scope")["dimensions"] = ["Seriousness"] } if gaps
      configure&.call(fixture)
      fixture.release
      catalog = File.join(root, "catalog-repository")
      FileUtils.mkdir_p(catalog)
      state_path = File.join(root, "PROJECT_STATE.yml")
      FileUtils.cp(state_path, catalog)
      YAML.safe_load_file(state_path).values.grep(Hash).map { |role| role.fetch("filename") }.uniq.each do |name|
        FileUtils.cp(File.join(root, name), catalog)
      end
      git(catalog, "init", "-q")
      git(catalog, "remote", "add", "origin", "fixture://catalog")
      git(catalog, "add", ".")
      git(catalog, "-c", "user.name=Synthetic fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Synthetic catalog")
      package_inputs = File.join(root, "package-inputs.json")
      write(package_inputs, {"schema_version" => AfDataPipeline::FinalReleasePackage::INPUT_SCHEMA,
                            "release_inputs_path" => fixture.inputs_path,
                            "release_manifest_path" => File.join(fixture.output_dir, "release-accounting.json"),
                            "catalog_repository_root" => catalog, "current_project_state_path" => File.join(catalog, "PROJECT_STATE.yml"),
                            "frontier_result_path" => nil})
      package = File.join(root, "package.json")
      AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: package_inputs, output_path: package)
      rubric = File.join(root, "rubric.md")
      File.write(rubric, "# Synthetic rubric 1\nSynthetic non-narrative test fixture.\n")
      request = File.join(root, "frontier-request.json")
      write(request, {"schema_version" => SERVICE::REQUEST_SCHEMA, "original_package_inputs_path" => package_inputs,
                      "original_package_path" => package, "rubric" => {"id" => "Synthetic rubric 1", "path" => rubric,
                        **AfDataPipeline::StandingBulkScorePolicy.file_binding(rubric)}, "successor_version" => "0.3"})
      yield fixture, request, File.join(root, "packet"), File.join(root, "supplement")
    end
  end

  def write_return(packet, root, no_write: [])
    doc = read(File.join(packet, "return-template.json"))
    doc.fetch("records").each do |row|
      row["proposed_value"] = no_write.include?(row["candidate_key"]) ? nil : 4
      row["reason"] = "Synthetic source-linked evidence, printed page 10; null preserves uncertainty."
      row["source_references"] = ["authority:source:fixture.md"]
    end
    seal!(doc, "return_id")
    path = File.join(root, "returned.json")
    write(path, doc)
    path
  end

  def git(root, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", root, *args)
    raise stderr unless status.success?
    stdout
  end

  def read(path) = JSON.parse(File.binread(path))
  def write(path, doc) = File.binwrite(path, AfDataPipeline::StagedScoringAuthority.document_bytes(doc))
  def seal!(doc, key) = doc[key] = AfDataPipeline::StandingBulkScorePolicy.digest(doc.except(key))

  def rewrite(path)
    doc = read(path)
    yield doc
    write(path, doc)
  end

  def snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      .to_h { |path| [path.delete_prefix(root + "/"), Digest::SHA256.file(path).hexdigest] }
  end
end
