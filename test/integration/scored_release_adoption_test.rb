# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/standing_bulk_score_release_fixture"
require "minitest/mock"

class ScoredReleaseAdoptionTest < Minitest::Test
  # Run the reviewed release through the executable with read-only Git observations.
  # Only the selected owner's locked storage may change the catalog and result.
  def test_real_scored_package_preserves_authority_through_approval_adoption_and_replay
    with_release(same_root: true) do |fixture|
      protected = [@original_base, fixture.staged_path, File.join(@root, "source/fixture.md"),
                   *Dir[File.join(fixture.output_dir, "**", "*"), File.join(fixture.output_dir, ".*")].select { |path| File.file?(path) }]
        .to_h { |path| [path, File.binread(path)] }
      package = prepare_package
      assert_equal "staged-5e_Adventure_Master_Catalog_0.2.xlsx", File.basename(fixture.staged_path)
      assert_equal "0.2", package.package.dig("candidate", "version")
      refute_equal reference(fixture.staged_path).fetch("sha256"), reference(@release.workbook_path).fetch("sha256")
      request_path = File.join(@root, "request.json")
      approval_path = File.join(@root, "APPROVE.json")
      result_path = File.join(@root, "result-APPROVE.json")
      common = ["--inputs", @inputs, "--package", package.path]
      request = cold_cli!("af-final-release-adoption", "prepare", *common, "--output", request_path)
      destination = request.dig("candidate", "destination")
      assert_equal File.join(@root, "5e_Adventure_Master_Catalog_0.2.xlsx"), destination
      refute_path_exists destination
      before = File.binread(@state_path)
      release_bytes = File.binread(@release.manifest_path)
      assert_equal package.package.dig("compatibility", "scored_new_id_authorization"),
                   request.dig("review", "compatibility", "scored_new_id_authorization")
      snapshot = AfDataPipeline::FinalReleaseAdoption.validate!(inputs_path: @inputs,
        package_path: package.path, request_path:).snapshot
      assert_equal reference(fixture.staged_path), snapshot.scored_release.fetch("staged")
      assert_equal reference(@original_base), snapshot.scored_release.fetch("base")
      assert_equal before, File.binread(@state_path)
      pre_approval = tree_bytes
      missing = AfDataPipeline::FinalReleaseAdoption.adopt!(inputs_path: @inputs, package_path: package.path,
        request_path:, approval_path:, result_path:)
      assert_equal "NO_APPROVAL", missing.status
      assert_equal pre_approval, tree_bytes
      approval = cold_cli!("af-final-release-adoption", "approve", *common, "--request", request_path,
        "--output", approval_path, "--decided-by", "Synthetic test owner")
      assert_equal "APPROVE", approval.fetch("decision")
      before_adopt = tree_bytes
      manifest_mode = File.stat(@state_path).mode
      adopt_args = ["adopt", *common, "--request", request_path, "--approval", approval_path, "--result", result_path]
      result = cold_cli!("af-final-release-adoption", *adopt_args)
      assert_equal "PROMOTED", result.fetch("status")
      assert_equal request.fetch("candidate").slice("sha256", "bytes"), reference(destination).slice("sha256", "bytes")
      assert_equal File.binread(request.dig("candidate", "path")), File.binread(destination)
      assert_equal @roles.except("catalog_head"), YAML.safe_load_file(@state_path).slice(*AfDataPipeline::ProjectState::ROLES).except("catalog_head")
      assert_equal manifest_mode, File.stat(@state_path).mode
      assert_equal 0o600, File.stat(destination).mode & 0o777
      after_adopt = tree_bytes
      assert_equal [@state_path, destination, result_path].sort,
                   (before_adopt.keys | after_adopt.keys).select { |path| before_adopt[path] != after_adopt[path] }.sort
      receipt_inode = File.stat(result_path).ino
      assert_equal "ALREADY_PROMOTED", cold_cli!("af-final-release-adoption", *adopt_args).fetch("status")
      assert_equal after_adopt, tree_bytes
      assert_equal receipt_inode, File.stat(result_path).ino
      assert_equal release_bytes, File.binread(@release.manifest_path)
      assert_equal protected, protected.keys.to_h { |path| [path, File.binread(path)] }
    end
  end

  # A logical catalog locator must retain its reviewed historical binding after
  # promotion. Both public package validation and cold adoption replay must pass;
  # the fresh-process helper also asserts that only its result file is written.
  def test_logical_catalog_path_replays_after_promotion_in_a_fresh_process
    with_release(logical_catalog: true) do |_fixture|
      refute_equal File.dirname(@state_path), @catalog
      assert_equal @catalog, File.realpath(File.dirname(@state_path))
      package = prepare_package
      request = prepare_request(package)
      snapshot = AfDataPipeline::FinalReleaseAdoption.validate!(inputs_path: @inputs,
        package_path: package.path, request_path: request.path).snapshot
      approval = decide(package, request, "APPROVE")
      assert_equal "PROMOTED", adopt(package, request, approval.path).status
      before = tree_bytes
      observation = AfDataPipeline::CatalogReplayObservation.new(snapshot:,
        historical_binding: package.package.dig("provenance", "nodes", "current_project_state"))
      validated = AfDataPipeline::FinalReleasePackage.validate!(inputs_path: @inputs,
        package_path: package.path, replay_observation: observation)
      assert_equal package.package, validated.package
      assert_equal "ALREADY_PROMOTED", adopt(package, request, approval.path).status
      assert_equal before, tree_bytes
      assert_equal "ALREADY_PROMOTED", replay_in_fresh_process(package, request, approval.path)
    end
  end

  def test_missing_mismatched_and_changed_release_provenance_never_publish
    with_release do |fixture|
      candidate = @release.workbook_path
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::CatalogAdoption.prepare!(manifest_path: @state_path, candidate_path: candidate, version: "0.2")
      end
      references = scored_references(fixture)
      wrong_version = assert_raises(AfDataPipeline::Error) do
        AfDataPipeline::CatalogAdoption.prepare!(manifest_path: @state_path, candidate_path: candidate,
          version: "0.3", scored_release: references)
      end
      assert_includes wrong_version.message, "not ready for this exact catalog adoption"
      assert_raises(AfDataPipeline::Error) do
        AfDataPipeline::CatalogAdoption.prepare!(manifest_path: @state_path, candidate_path: candidate,
          version: "0.2", scored_release: references.except("base"))
      end
      wrong = references.merge("staged" => reference(@original_base))
      mismatch = assert_raises(AfDataPipeline::Error) do
        AfDataPipeline::CatalogAdoption.prepare!(manifest_path: @state_path, candidate_path: candidate,
          version: "0.2", scored_release: wrong)
      end
      assert_includes mismatch.message, "references differ from the validated package"
      destination = File.join(@catalog, "5e_Adventure_Master_Catalog_0.2.xlsx")
      File.binwrite(destination, "occupied destination\n")
      conflict = assert_raises(AfDataPipeline::Error) do
        AfDataPipeline::CatalogAdoption.prepare!(manifest_path: @state_path, candidate_path: candidate,
          version: "0.2", scored_release: references)
      end
      assert_includes conflict.message, "refusing to overwrite"
      assert_equal "occupied destination\n", File.binread(destination)
      File.unlink(destination)
      snapshot = AfDataPipeline::CatalogAdoption.prepare!(manifest_path: @state_path, candidate_path: candidate,
        version: "0.2", scored_release: references)
      [@release.manifest_path, File.join(fixture.output_dir, "release-authorization.json")].each do |path|
        bytes = File.binread(path)
        File.open(path, "ab") { |file| file.write("\n") }
        assert_raises(AfDataPipeline::Error) { AfDataPipeline::CatalogAdoption.adopt!(snapshot:) }
        File.binwrite(path, bytes)
        refute_path_exists File.join(@catalog, "5e_Adventure_Master_Catalog_0.2.xlsx")
      end
      assert_equal @roles, YAML.safe_load_file(@state_path).slice(*AfDataPipeline::ProjectState::ROLES)
    end
  end

  def test_changed_candidate_and_stale_approval_are_rejected_without_publication
    with_release do |fixture|
      package = prepare_package
      request = prepare_request(package)
      decision = decide(package, request, "APPROVE")
      before = File.binread(@state_path)
      [@release.workbook_path, fixture.staged_path].each do |path|
        bytes = File.binread(path)
        File.open(path, "ab") { |file| file.write("changed") }
        assert_raises(AfDataPipeline::Error) { adopt(package, request, decision.path) }
        File.binwrite(path, bytes)
      end
      roles = YAML.safe_load_file(@state_path)
      alternate = File.join(@catalog, "5e_Adventure_Master_Catalog_0.0.9.xlsx")
      FileUtils.cp(@original_base, alternate)
      roles["matcher_authorized_baseline"] = roles.fetch("catalog_head").merge(
        "version" => "0.0.9", "filename" => File.basename(alternate))
      File.binwrite(@state_path, YAML.dump(roles))
      AfDataPipeline::ProjectState.new(manifest_path: @state_path).validate!
      assert_raises(AfDataPipeline::Error) { adopt(package, request, decision.path) }
      File.binwrite(@state_path, before)
      File.unlink(alternate)
      @remote = "fixture://changed-catalog"
      assert_raises(AfDataPipeline::Error) { adopt(package, request, decision.path) }
      @remote = "fixture://catalog"
      @head = "c" * 40
      assert_raises(AfDataPipeline::Error) { adopt(package, request, decision.path) }
      assert_equal before, File.binread(@state_path)
      refute_path_exists File.join(@catalog, "5e_Adventure_Master_Catalog_0.2.xlsx")
      assert_equal "APPROVE", JSON.parse(File.binread(decision.path)).fetch("decision")
    end
  end

  def test_decline_and_stale_replay_do_not_renew_approval_or_republish
    with_release do |fixture|
      package = prepare_package
      request = prepare_request(package)
      decline = decide(package, request, "DECLINE")
      assert_equal "DECLINED", adopt(package, request, decline.path).status
      refute_path_exists File.join(@catalog, "5e_Adventure_Master_Catalog_0.2.xlsx")
      approval = decide(package, request, "APPROVE")
      snapshot = AfDataPipeline::FinalReleaseAdoption.validate!(inputs_path: @inputs,
        package_path: package.path, request_path: request.path).snapshot
      assert_equal "PROMOTED", adopt(package, request, approval.path).status
      before = File.binread(@state_path)
      source = package.package.dig("provenance", "nodes", "authority:source:fixture.md", "path")
      source_bytes = File.binread(source)
      File.open(source, "ab") { |file| file.write("\n") }
      stale_source = assert_raises(AfDataPipeline::Error) { AfDataPipeline::CatalogAdoption.adopt!(snapshot:) }
      assert_includes stale_source.message, "package reference changed: authority:source:fixture.md"
      File.binwrite(source, source_bytes)
      File.open(File.join(fixture.output_dir, "release-authorization.json"), "ab") { |file| file.write("\n") }
      assert_raises(AfDataPipeline::Error) { adopt(package, request, approval.path) }
      assert_equal before, File.binread(@state_path)
    end
  end

  def test_supported_catalog_identity_advancement_keeps_original_provenance_and_independent_roles
    with_release do |_fixture|
      advanced = File.join(@catalog, "5e_Adventure_Master_Catalog_0.1.1.xlsx")
      FileUtils.cp(@original_base, advanced)
      AfDataPipeline::ProjectState.new(manifest_path: @state_path).promote!(role: "catalog_head",
        artifact_path: advanced, version: "0.1.1")
      observe_catalog!
      package = prepare_package
      assert package.package.dig("readiness", "ready")
      request = prepare_request(package)
      approval = decide(package, request, "APPROVE")
      assert_equal "PROMOTED", adopt(package, request, approval.path).status
      assert_equal reference(@original_base), package.package.dig("provenance", "nodes", "authority:base").slice("path", "sha256", "bytes")
      assert_equal @roles.except("catalog_head"), YAML.safe_load_file(@state_path).slice(*AfDataPipeline::ProjectState::ROLES).except("catalog_head")
    end
  end

  def test_incompatible_concurrent_update_is_blocked_instead_of_lost
    with_release do |fixture|
      path = File.join(@catalog, "5e_Adventure_Master_Catalog_0.1.1.xlsx")
      FileUtils.cp(@original_base, path)
      fixture.replace_zip_text(path, "xl/worksheets/sheet1.xml", "<v>Unit A</v>", "<v>Concurrent label</v>")
      AfDataPipeline::ProjectState.new(manifest_path: @state_path).promote!(role: "catalog_head",
        artifact_path: path, version: "0.1.1")
      observe_catalog!
      package = prepare_package
      refute package.package.dig("readiness", "ready")
      assert package.package.dig("transition", "delta", "unpreserved").any? { |row| row["reason"] == "CONCURRENT_UPDATE_LOST" }
      assert_raises(AfDataPipeline::Error) { prepare_request(package) }
      refute_path_exists File.join(@catalog, "5e_Adventure_Master_Catalog_0.2.xlsx")
    end
  end

  def test_public_frontier_derived_candidate_retains_the_exact_original_and_frontier_evidence
    with_release(gaps: true) do |fixture|
      original = prepare_package
      rubric = File.join(@root, "rubric.md")
      File.write(rubric, "# Synthetic rubric\nNon-narrative fixture.\n")
      frontier_request = File.join(@root, "frontier-request.json")
      write_document(frontier_request, {
        "schema_version" => AfDataPipeline::FrontierResidualScoring::REQUEST_SCHEMA,
        "original_package_inputs_path" => @inputs, "original_package_path" => original.path,
        "rubric" => {"id" => "Synthetic rubric", **reference(rubric)}, "successor_version" => "0.3"
      })
      packet = File.join(@root, "packet")
      AfDataPipeline::FrontierResidualScoring.prepare!(request_path: frontier_request, output_dir: packet)
      returned = JSON.parse(File.binread(File.join(packet, "return-template.json")))
      returned.fetch("records").each do |row|
        row.merge!("proposed_value" => 4, "reason" => "Synthetic printed page 10 evidence",
                   "source_references" => ["authority:source:fixture.md"])
      end
      returned["return_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(returned.except("return_id"))
      return_path = File.join(@root, "return.json")
      write_document(return_path, returned)
      output = File.join(@root, "supplement")
      AfDataPipeline::FrontierResidualScoring.apply!(request_path: frontier_request,
        packet_dir: packet, return_path:, output_dir: output)
      @inputs = File.join(output, "package-inputs.json")
      derived = AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: @inputs,
        output_path: File.join(@root, "derived-package.json"))
      request = prepare_request(derived)
      validation = AfDataPipeline::FinalReleaseAdoption.validate!(inputs_path: @inputs,
        package_path: derived.path, request_path: request.path)
      references = validation.snapshot.scored_release
      assert_equal reference(File.join(output, "result.json")), references.fetch("frontier")
      assert_equal reference(@original_base), references.fetch("base")
      assert_equal "ig17f_derived", derived.package.dig("candidate", "selection")
      assert_equal original.package.dig("candidate", "selected"), derived.package.dig("candidate", "original")
      missing_frontier = assert_raises(AfDataPipeline::Error) do
        AfDataPipeline::CatalogAdoption.prepare!(manifest_path: @state_path,
          candidate_path: derived.package.dig("candidate", "selected", "path"), version: "0.3",
          scored_release: references.except("frontier"))
      end
      assert_includes missing_frontier.message, "references differ from the validated package"
      assert_equal @roles, YAML.safe_load_file(@state_path).slice(*AfDataPipeline::ProjectState::ROLES)
      assert_equal @release.manifest.fetch("manifest_id"),
                   request.document.dig("review", "compatibility", "scored_new_id_authorization", "manifest_id")
      approval = decide(derived, request, "APPROVE")
      before_publication = tree_bytes
      promoted = adopt(derived, request, approval.path)
      assert_equal "PROMOTED", promoted.status
      after_publication = tree_bytes
      changed = (before_publication.keys | after_publication.keys).select do |path|
        before_publication[path] != after_publication[path]
      end
      assert_equal [@state_path, promoted.path, promoted.catalog_result.destination].sort, changed.sort
      assert_equal File.binread(derived.package.dig("candidate", "selected", "path")),
                   File.binread(File.join(@catalog, "5e_Adventure_Master_Catalog_0.3.xlsx"))
      state_after = File.binread(@state_path)
      before_replay = tree_bytes
      assert_equal "ALREADY_PROMOTED", adopt(derived, request, approval.path).status
      assert_equal before_replay, tree_bytes
      # A fresh Ruby process has no retained semantic proofs. It must rebuild
      # both packages and the complete frontier handoff through the real APIs.
      assert_equal "ALREADY_PROMOTED", replay_in_fresh_process(derived, request, approval.path)
      assert_equal state_after, File.binread(@state_path)
      # Historical replay must not make ordinary live-package validation pass.
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::FinalReleasePackage.validate!(inputs_path: @inputs, package_path: derived.path)
      end

      {
        File.join(output, "handoff.json") => /frontier:handoff/,
        File.join(output, "return.json") => /frontier:return/,
        rubric => /rubric/,
        original.path => /original_package/,
        @original_base => /base evidence/,
        @release.workbook_path => /final_workbook|original_candidate/,
        File.join(@root, "source/fixture.md") => /source:fixture/,
        derived.package.dig("candidate", "selected", "path") => /selected candidate/,
        approval.path => /decision bytes/
      }.each do |path, pattern|
        bytes = File.binread(path)
        File.binwrite(path, bytes + "\n")
        assert_replay_refused(derived, request, approval.path, pattern)
        File.binwrite(path, bytes)
      end

      File.binwrite(@state_path, state_after + "# unauthorized manifest change\n")
      assert_replay_refused(derived, request, approval.path, /exact approved promotion/)
      File.binwrite(@state_path, state_after)
      observed = @observed.fetch("PROJECT_STATE.yml")
      @observed["PROJECT_STATE.yml"] = observed + "# changed historical bytes\n"
      assert_replay_refused(derived, request, approval.path, /historical catalog manifest differs/)
      @observed["PROJECT_STATE.yml"] = observed
      @head = "c" * 40
      assert_replay_refused(derived, request, approval.path, /HEAD changed/)
      @head = "b" * 40

      # Both independent-role edits and a later, otherwise valid catalog
      # advancement remain stale. Replay may neither roll them back nor rebase.
      state = YAML.safe_load_file(@state_path)
      state["matcher_authorized_baseline"] = derived.package.dig("transition", "proposed_catalog_head")
      File.binwrite(@state_path, YAML.dump(state))
      assert_replay_refused(derived, request, approval.path, /project_state/)
      File.binwrite(@state_path, state_after)
      advanced = File.join(@catalog, "5e_Adventure_Master_Catalog_0.4.xlsx")
      FileUtils.cp(promoted.catalog_result.destination, advanced)
      AfDataPipeline::ProjectState.new(manifest_path: @state_path).promote!(role: "catalog_head",
        artifact_path: advanced, version: "0.4")
      assert_replay_refused(derived, request, approval.path, /project_state/)
      assert_equal "0.4", AfDataPipeline::ProjectState.new(manifest_path: @state_path).resolve("catalog_head").version
      File.binwrite(@state_path, state_after)
      File.unlink(advanced)
      assert_equal after_publication, tree_bytes.except(File.join(@root, "recovered-result.json"))
      assert @git_calls.all? { |args| %w[rev-parse status remote show].include?(args.first) }
    end
  end

  def test_changed_release_at_the_locked_boundary_does_not_publish
    with_release do |fixture|
      package = prepare_package
      request = prepare_request(package)
      snapshot = AfDataPipeline::FinalReleaseAdoption.validate!(inputs_path: @inputs,
        package_path: package.path, request_path: request.path).snapshot
      before = File.binread(@state_path)
      bytes = File.binread(@release.manifest_path)
      error = assert_raises(AfDataPipeline::Error) do
        AfDataPipeline::CatalogAdoption.adopt!(snapshot:, before_mutation: ->(_fresh) {
          File.open(@release.manifest_path, "ab") { |file| file.write("\n") }
        })
      end
      assert_includes error.message, "release_manifest evidence is missing or changed"
      assert_equal before, File.binread(@state_path)
      refute_path_exists File.join(@catalog, "5e_Adventure_Master_Catalog_0.2.xlsx")
      File.binwrite(@release.manifest_path, bytes)
      assert_equal @roles, YAML.safe_load_file(@state_path).slice(*AfDataPipeline::ProjectState::ROLES)
    end
  end

  # A competing destination and an interruption cannot promote roles, remove
  # the competing file, or delete the independently preserved staged workbook.
  def test_same_root_transaction_race_and_interruption_preserve_staged_evidence
    with_release(same_root: true) do |fixture|
      package = prepare_package
      request = prepare_request(package)
      approval = decide(package, request, "APPROVE")
      before = File.binread(@state_path)
      staged = File.binread(fixture.staged_path)
      destination = request.document.dig("candidate", "destination")
      original_link = File.method(:link)
      File.stub(:link, lambda { |source, target|
        File.binwrite(target, "competing publication") if target == destination
        original_link.call(source, target)
      }) do
        error = assert_raises(AfDataPipeline::Error) { adopt(package, request, approval.path) }
        assert_includes error.message, "refusing to overwrite"
      end
      assert_equal "competing publication", File.binread(destination)
      assert_equal before, File.binread(@state_path)
      assert_equal staged, File.binread(fixture.staged_path)
      File.unlink(destination)
      before_interruption = tree_bytes
      interrupt = lambda do |_snapshot|
        File.open(@catalog, File::RDONLY) do |competing|
          assert_equal false, competing.flock(File::LOCK_EX | File::LOCK_NB)
        end
        assert_path_exists destination
        raise Interrupt, "synthetic interruption before manifest replacement"
      end
      at_import_boundary(interrupt) { assert_raises(Interrupt) { adopt(package, request, approval.path) } }
      assert_equal before_interruption, tree_bytes

      # Retry in a fresh process and interrupt immediately after the real
      # atomic rename. A second fresh process recovers the missing receipt.
      cold_cli!("af-final-release-adoption", "adopt", "--inputs", @inputs, "--package", package.path,
        "--request", request.path, "--approval", approval.path, "--result", File.join(@root, "result-APPROVE.json"),
        interrupt_after: @state_path)
      refute_equal before, File.binread(@state_path)
      assert_equal File.binread(request.document.dig("candidate", "path")), File.binread(destination)
      refute_path_exists File.join(@root, "result-APPROVE.json")
      assert_equal "ALREADY_PROMOTED", replay_in_fresh_process(package, request, approval.path)
    end
  end

  # Changing the decision, raw prior bytes or receipt destination after import
  # must leave the catalog unpublished and preserve the competing input.
  def test_locked_refusal_preserves_competing_inputs_and_removes_only_its_import
    with_release do |_fixture|
      package = prepare_package
      request = prepare_request(package)
      approval = decide(package, request, "APPROVE")
      decline = decide(package, request, "DECLINE")
      result = File.join(@root, "result-APPROVE.json")
      destination = request.document.dig("candidate", "destination")
      before = tree_bytes
      File.binwrite(result, "occupied result")
      occupied = tree_bytes
      error = assert_raises(AfDataPipeline::Error) { adopt(package, request, approval.path) }
      assert_includes error.message, "adoption result output already exists"
      assert_equal occupied, tree_bytes
      File.unlink(result)

      [
        [approval.path, File.binread(decline.path), /decision bytes/],
        [@state_path, File.binread(@state_path) + "# byte-only competing change\n", /project_state|manifest/],
        [result, "competing result", /result output already exists/]
      ].each do |path, changed, reason|
        original = File.file?(path) ? File.binread(path) : nil
        change = ->(_snapshot) { File.binwrite(path, changed) }
        at_import_boundary(change) do
          error = assert_raises(AfDataPipeline::Error) { adopt(package, request, approval.path) }
          assert_match reason, error.message
        end
        assert_equal changed, File.binread(path)
        refute_path_exists destination
        assert_equal before.except(path), tree_bytes.except(path)
        original ? File.binwrite(path, original) : File.unlink(path)
      end
      assert_equal before, tree_bytes
      assert_equal "PROMOTED", cold_cli!("af-final-release-adoption", "adopt", "--inputs", @inputs,
        "--package", package.path, "--request", request.path, "--approval", approval.path, "--result", result).fetch("status")
    end
  end

  # Exercise the existing manual prompt and bind exact manifest bytes before
  # confirmation. Only an affirmative reviewed run changes the catalog.
  def test_manual_confirmation_and_raw_manifest_binding_use_the_shared_storage
    with_release do |fixture|
      candidate = File.join(@root, "manual-candidate.xlsx")
      fixture.write_compatible_amc(candidate, rows: [
        fixture.compatible_row("ADV-0001", title: "Unit A", source: "Source A"),
        fixture.compatible_row("ADV-0002", title: "Unit B", source: "Source B")
      ])
      snapshot = AfDataPipeline::CatalogAdoption.prepare!(manifest_path: @state_path, candidate_path: candidate, version: "0.2")
      before = tree_bytes
      assert_equal reference(@state_path).slice("sha256", "bytes"), snapshot.prior_manifest
      args = ["adopt", candidate, "--manifest", @state_path, "--version", "0.2"]
      ["n\n", ""].each do |answer|
        assert_includes cold_cli!("af-project-state", *args, stdin_data: answer), "No changes made."
        assert_equal before, tree_bytes
      end

      manifest = File.binread(@state_path)
      File.binwrite(@state_path, manifest + "# changed only the bytes\n")
      stale = tree_bytes
      error = assert_raises(AfDataPipeline::Error) { AfDataPipeline::CatalogAdoption.adopt!(snapshot:) }
      assert_includes error.message, "manifest bytes changed after review"
      assert_equal stale, tree_bytes
      File.binwrite(@state_path, manifest)

      output = cold_cli!("af-project-state", *args, stdin_data: "y\n")
      assert_includes output, "Cross-consumer compatibility: PASS"
      assert_includes output, "catalog_head promoted successfully."
      assert_equal File.binread(candidate), File.binread(snapshot.destination)
      after = YAML.safe_load_file(@state_path)
      assert_equal snapshot.candidate, after.fetch("catalog_head")
      assert_equal @roles.except("catalog_head"), after.slice(*AfDataPipeline::ProjectState::ROLES).except("catalog_head")
    end
  end

  private

  # Inject a controlled failure after the owner has imported the workbook.
  # Return the test action's outcome and propagate its exceptions.
  def at_import_boundary(fault)
    constructor = AfDataPipeline::CatalogAdoption.method(:new)
    interrupted = lambda do |**options|
      constructor.call(**options).tap do |service|
        service.define_singleton_method(:before_promotion!) { |snapshot| fault.call(snapshot) }
      end
    end
    AfDataPipeline::CatalogAdoption.stub(:new, interrupted) { yield }
  end

  def tree_bytes
    Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
       .to_h { |path| [path, [File.binread(path), File.stat(path).mode]] }
  end

  def assert_replay_refused(package, request, approval_path, pattern)
    before = tree_bytes
    error = assert_raises(AfDataPipeline::Error) { adopt(package, request, approval_path) }
    assert_match pattern, error.message
    assert_equal before, tree_bytes
  end

  # Retry with the existing executable and assert only a missing receipt is recovered.
  # All semantic validators run in the fresh process with no retained proof.
  def replay_in_fresh_process(package, request, approval_path)
    result_path = File.join(@root, "recovered-result.json")
    refute_path_exists result_path
    before = tree_bytes
    recovered = cold_cli!("af-final-release-adoption", "adopt", "--inputs", @inputs, "--package", package.path,
      "--request", request.path, "--approval", approval_path, "--result", result_path)
    after = tree_bytes
    assert_equal [result_path], after.keys - before.keys
    assert_equal before, after.except(result_path)
    assert_equal "ALREADY_PROMOTED", recovered.fetch("status")
    assert_equal package.package.dig("transition", "proposed_catalog_head"), recovered.fetch("candidate")
    recovered.fetch("status")
  end

  # Execute the actual bin script in a fresh Ruby process. Only external
  # read-only Git IO is doubled. The fixture travels in stdin before CLI input.
  def cold_cli!(name, *arguments, stdin_data: "", interrupt_after: nil)
    program = <<~'RUBY'
      fixture = JSON.parse(STDIN.gets)
      executable = ARGV.shift
      git = lambda do |*argv|
        environment = argv.shift if argv.first.is_a?(Hash)
        raise "unexpected Git IO" unless argv[0, 2] == ["git", "-C"] && File.realpath(argv[2]) == fixture.fetch("root")
        args = argv.drop(3)
        files = fixture.fetch("files_hex")
        manifest = [files.fetch("PROJECT_STATE.yml")].pack("H*")
        value = case args
                when ["rev-parse", "--show-toplevel"] then fixture.fetch("root") + "\n"
                when ["rev-parse", "HEAD"] then fixture.fetch("head") + "\n"
                when ["remote", "get-url", "origin"] then fixture.fetch("remote") + "\n"
                when ["status", "--short"] then " M PROJECT_STATE.yml\n"
                when ["status", "--porcelain=v1", "--", "5e_Adventure_Master_Catalog_0.2.xlsx"]
                  "?? 5e_Adventure_Master_Catalog_0.2.xlsx\n"
                when ["status", "--porcelain=v1", "--", "PROJECT_STATE.yml"]
                  raise "Git index refresh enabled" unless environment == {"GIT_OPTIONAL_LOCKS" => "0"}
                  File.binread(File.join(fixture.fetch("root"), "PROJECT_STATE.yml")) == manifest ? "" : " M PROJECT_STATE.yml\n"
                else
                  raise "prohibited Git operation" unless args.length == 2 && args.first == "show" && args.last.start_with?(fixture.fetch("head") + ":")
                  [files.fetch(args.last.delete_prefix(fixture.fetch("head") + ":"))].pack("H*")
                end
        [value, "", Struct.new(:success?).new(true)]
      end
      owner = AfXlsxFiles::Internal::CatalogStorage.instance_method(:publish!).source_location.first
      raise "wrong loaded catalog owner" unless File.realpath(owner) == fixture.fetch("owner") &&
        Digest::SHA256.file(owner).hexdigest == fixture.fetch("owner_sha256")
      $PROGRAM_NAME = executable
      Open3.stub(:capture3, git) do
        if (manifest = fixture["interrupt_after"])
          rename = File.method(:rename)
          File.stub(:rename, lambda { |source, target|
            rename.call(source, target)
            raise Interrupt, "synthetic interruption after manifest replacement" if target == manifest
          }) { load(executable) }
        else
          load(executable)
        end
      end
    RUBY
    root = File.expand_path("../..", __dir__)
    owner = File.realpath(AfXlsxFiles::Internal::CatalogStorage.instance_method(:publish!).source_location.first)
    fixture = {"root" => @catalog, "head" => @head, "remote" => @remote,
      "owner" => owner, "owner_sha256" => Digest::SHA256.file(owner).hexdigest, "interrupt_after" => interrupt_after,
      "files_hex" => @observed.transform_values { |value| value.unpack1("H*") }}
    output = IO.popen([{"AF_DATA_PIPELINE_DATA_ROOT" => @root}, RbConfig.ruby, "-I#{root}/lib", "-raf_data_pipeline", "-rminitest/mock",
      "-e", program, "#{root}/bin/#{name}", *arguments], "r+", err: [:child, :out]) do |process|
      process.puts JSON.generate(fixture)
      process.write(stdin_data)
      process.close_write
      process.read
    end
    if interrupt_after
      refute $?.success?, output
      assert_includes output, "synthetic interruption after manifest replacement"
      return
    end
    assert $?.success?, output
    name == "af-final-release-adoption" ? JSON.parse(output) : output
  end

  def with_release(gaps: false, same_root: false, logical_catalog: false)
    @root = File.realpath(Dir.mktmpdir("scored-release-adoption-"))
    fixture = StandingBulkScoreReleaseFixture.new(root: @root, specs: [
      {case_id: "combat", dimension: "Combat Emphasis", metrics: {"Combat Emphasis" => 3}}
    ])
    fixture.mutate_policy { |policy| policy.fetch("scope")["dimensions"] = ["Seriousness"] } if gaps
    @release = fixture.release
    @original_base = File.join(@root, fixture.authority_projection.dig("authority", "base_amc", "filename"))
    @catalog = same_root ? @root : File.join(@root, "catalog")
    FileUtils.mkdir_p(@catalog)
    catalog_locator = @catalog
    if logical_catalog
      catalog_locator = File.join(@root, "logical-catalog")
      File.symlink(@catalog, catalog_locator)
    end
    @state_path = File.join(catalog_locator, "PROJECT_STATE.yml")
    FileUtils.cp(File.join(@root, "PROJECT_STATE.yml"), @state_path) unless same_root
    @roles = YAML.safe_load_file(@state_path).slice(*AfDataPipeline::ProjectState::ROLES)
    @roles.values.map { |role| role.fetch("filename") }.uniq.each do |filename|
      FileUtils.cp(File.join(@root, filename), @catalog) unless same_root
    end
    @head = "b" * 40
    @remote = "fixture://catalog"
    @git_calls = []
    observe_catalog!
    @inputs = File.join(@root, "package-inputs.json")
    File.write(@inputs, JSON.pretty_generate(
      "schema_version" => AfDataPipeline::FinalReleasePackage::INPUT_SCHEMA,
      "release_inputs_path" => fixture.inputs_path, "release_manifest_path" => @release.manifest_path,
      "catalog_repository_root" => catalog_locator, "current_project_state_path" => @state_path,
      "frontier_result_path" => nil
    ) + "\n")
    # Only Git's read-only external IO is doubled. All release, workbook,
    # package, compatibility, approval and adoption validators are real.
    # The immutable observation detects uncommitted changes without making
    # synthetic commits; full Git integration remains in existing suites.
    Open3.stub(:capture3, method(:git_observation)) { yield fixture }
  ensure
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def observe_catalog!
    @observed = Dir.glob(File.join(@catalog, "*")).select { |path| File.file?(path) }
      .to_h { |path| [File.basename(path), File.binread(path)] }
  end

  def git_observation(*argv, **_options)
    environment = argv.shift if argv.first.is_a?(Hash)
    raise "unexpected external IO #{argv.inspect}" unless argv[0, 2] == ["git", "-C"] && File.realpath(argv[2]) == @catalog
    args = argv.drop(3)
    @git_calls << args
    stdout = case args
    when ["rev-parse", "--show-toplevel"] then @catalog + "\n"
    when ["rev-parse", "HEAD"] then @head + "\n"
    when ["remote", "get-url", "origin"] then @remote + "\n"
    when ["status", "--porcelain=v1", "--", "PROJECT_STATE.yml"]
      raise "Git index refresh enabled" unless environment == {"GIT_OPTIONAL_LOCKS" => "0"}
      File.binread(@state_path) == @observed.fetch("PROJECT_STATE.yml") ? "" : " M PROJECT_STATE.yml\n"
    else
      raise "prohibited/unexpected Git operation #{args.inspect}" unless args.length == 2 && args.first == "show" && args.last.start_with?(@head + ":")
      @observed.fetch(args.last.delete_prefix(@head + ":"))
    end
    [stdout, "", Struct.new(:exitstatus) { def success? = exitstatus.zero? }.new(0)]
  end

  def reference(path)
    {"path" => path, **AfDataPipeline::StandingBulkScorePolicy.file_binding(path)}
  end

  def write_document(path, document)
    File.binwrite(path, AfDataPipeline::StagedScoringAuthority.document_bytes(document))
  end

  def scored_references(fixture)
    package = prepare_package
    {"release_manifest" => reference(@release.manifest_path),
     "base" => reference(@original_base), "staged" => reference(fixture.staged_path),
     "package" => reference(package.path), "package_inputs" => reference(@inputs)}
  end

  def prepare_package
    AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: @inputs, output_path: File.join(@root, "package.json"))
  end

  def prepare_request(package)
    AfDataPipeline::FinalReleaseAdoption.prepare!(inputs_path: @inputs, package_path: package.path,
      output_path: File.join(@root, "request.json"))
  end

  def decide(package, request, disposition)
    AfDataPipeline::FinalReleaseAdoption.decide!(inputs_path: @inputs, package_path: package.path,
      request_path: request.path, output_path: File.join(@root, "#{disposition}.json"),
      decision: disposition, decided_by: "Synthetic test owner")
  end

  def adopt(package, request, approval_path)
    AfDataPipeline::FinalReleaseAdoption.adopt!(inputs_path: @inputs, package_path: package.path,
      request_path: request.path, approval_path:,
      result_path: File.join(@root, "result-#{File.basename(approval_path)}"))
  end
end
