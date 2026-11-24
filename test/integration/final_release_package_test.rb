# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/standing_bulk_score_release_fixture"
require "stringio"

class FinalReleasePackageTest < Minitest::Test
  TEMPLATES = {}
  CATALOG_TEMPLATES = {}
  CATALOG_VIEWS = {}
  COMPATIBILITY_RESULTS = {}
  RELEASE_CONSTRUCTOR = AfDataPipeline::StandingBulkScoreRelease.method(:new)
  PACKAGE_CONSTRUCTOR = AfDataPipeline::FinalReleasePackage.method(:new)
  COMPATIBILITY_CONSTRUCTOR = AfDataPipeline::AmcCompatibilityCheck.method(:new)

  module CachedCatalogViews
    def catalog_view(path)
      key = Digest::SHA256.file(path).hexdigest
      cached = FinalReleasePackageTest::CATALOG_VIEWS[key]
      return Marshal.load(cached) if cached

      view = super
      FinalReleasePackageTest::CATALOG_VIEWS[key] = Marshal.dump(view).freeze
      view
    end
  end

  def test_clean_package_and_read_only_replay_bind_complete_standing_authority
    with_package do |fixture, inputs, output|
      result = prepare(inputs, output)
      package = result.package
      assert package.dig("readiness", "ready")
      assert package.dig("readiness", "full_scoring")
      assert_equal "original_ig17", package.dig("candidate", "selection")
      assert_equal 3, package.dig("release", "population", "intended_cases")
      assert_equal 4, package.dig("release", "population", "intended_metrics")
      assert_equal 4, package.dig("release", "counts", "standing_directive_accepted")
      assert_equal 0, package.dig("release", "counts", "individual_human_accepted")
      assert_equal 0, package.dig("release", "counts", "ig16b_machine_accepted")
      assert_equal 0, package.dig("release", "population", "remaining_blank_metrics")
      assert_equal 2, package.dig("release", "population", "preserved_existing_metrics")
      assert_equal ["ADV-0003"], package.dig("transition", "delta", "added_ids")
      assert_equal [], package.dig("transition", "delta", "removed_ids")
      assert_equal "ADV-0002", package.dig("boundary", "allocation", 0, "resolved_parent_adventure_id")
      assert_equal "PASS", package.dig("compatibility", "status")
      assert_equal "not validated by this static workbook gate", package.dig("compatibility", "afw_execution_compatibility")
      assert_equal package.dig("transition", "original_frozen_base", "sha256"), package.dig("provenance", "nodes", "authority:base", "sha256")
      nodes = package.dig("provenance", "nodes")
      assert nodes.key?("release_input:standing_policy")
      assert nodes.key?("release_input:owner_selection")
      assert nodes.key?("release_artifact:authorization")
      assert nodes.key?("authority:source_registry")
      assert nodes.keys.any? { |key| key.end_with?("/receipt/reference/artifacts/raw_response") }
      before = File.stat(output).mtime
      replay = AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output)
      assert replay.reused
      assert_equal package, replay.package
      assert_equal before, File.stat(output).mtime
      assert_equal "SAFE_REUSE", package.dig("scoring_concurrency", "decision")
    end
  end

  def test_terminal_gap_and_declined_frontier_remain_ready_without_full_scoring
    specs = [
      {case_id: "combat", dimension: "Combat Emphasis", metrics: {"Combat Emphasis" => 3}},
      {case_id: "openness", dimension: "Structural Openness", metrics: {"Structural Openness" => 4}},
      {case_id: "social", dimension: "Social Interaction Emphasis", metrics: {"Social Interaction Emphasis" => 2}}
    ]
    with_package(specs:, template_key: :gaps, configure: ->(fixture) { fixture.mutate_policy { |policy| ["Structural Openness", "Social Interaction Emphasis"].each { |metric| policy.dig("scope", "dimensions").delete(metric) } } }) do |fixture, inputs, output|
      original = read_package(output)
      assert original.dig("readiness", "ready")
      refute original.dig("readiness", "full_scoring")
      assert_equal 3, original.dig("release", "population", "intended_metrics")
      assert_equal 2, original.dig("release", "population", "terminal_gap_metrics")
      assert_equal 2, original.dig("release", "population", "remaining_blank_metrics")
      frontier_path = frontier_fixture(fixture, original, declined: true)
      rewrite(inputs) { |document| document["frontier_result_path"] = frontier_path }
      declined = prepare(inputs, output + ".declined").package
      assert declined.dig("readiness", "ready")
      assert_equal "original_ig17", declined.dig("candidate", "selection")
      assert_equal "DECLINED", declined.dig("candidate", "frontier", "disposition")
      assert_equal 2, declined.dig("release", "population", "frontier_no_write_metrics")
      refute declined.dig("readiness", "full_scoring")
    end
  end

  def test_valid_derived_candidate_binds_exact_original_and_separate_frontier_counts
    proofs = nil
    saved_proofs = nil
    specs = [
      {case_id: "combat", dimension: "Combat Emphasis", metrics: {"Combat Emphasis" => 3}},
      {case_id: "openness", dimension: "Structural Openness", metrics: {"Structural Openness" => 4}},
      {case_id: "social", dimension: "Social Interaction Emphasis", metrics: {"Social Interaction Emphasis" => 2}}
    ]
    with_package(specs:, template_key: :gaps, configure: ->(fixture) { fixture.mutate_policy { |policy| ["Structural Openness", "Social Interaction Emphasis"].each { |metric| policy.dig("scope", "dimensions").delete(metric) } } }) do |fixture, inputs, output|
      original = read_package(output)
      original_bytes = File.binread(original.dig("candidate", "original", "path"))
      frontier_path = frontier_fixture(fixture, original, no_write: ["ADV-0003::Social Interaction Emphasis"])
      rewrite(inputs) { |document| document["frontier_result_path"] = frontier_path }
      proofs = AfDataPipeline::FinalReleasePackage.const_get(:PROOFS)
      saved_proofs = proofs.dup
      proofs.replace((0...8).to_h { |index| ["synthetic-proof-#{index}", nil] })
      derived = prepare(inputs, output + ".derived").package
      assert_equal 8, proofs.length
      refute proofs.key?("synthetic-proof-0")
      assert proofs.key?(File.expand_path(inputs))
      assert derived.dig("readiness", "ready")
      assert_equal "ig17f_derived", derived.dig("candidate", "selection")
      assert_equal "0.3", derived.dig("candidate", "version")
      assert_equal original.dig("candidate", "original", "sha256"), derived.dig("candidate", "original", "sha256")
      refute_equal derived.dig("candidate", "original", "sha256"), derived.dig("candidate", "selected", "sha256")
      refute_equal original["package_id"], derived["package_id"]
      assert_equal 3, derived.dig("release", "population", "intended_metrics")
      assert_equal 1, derived.dig("release", "counts", "standing_directive_accepted")
      assert_equal 0, derived.dig("release", "counts", "individual_human_accepted")
      assert_equal 0, derived.dig("release", "counts", "ig16b_machine_accepted")
      assert_equal 1, derived.dig("release", "population", "frontier_written_metrics")
      assert_equal 1, derived.dig("release", "population", "frontier_no_write_metrics")
      assert_equal 1, derived.dig("release", "population", "remaining_blank_metrics")
      assert_equal original_bytes, File.binread(derived.dig("candidate", "original", "path"))
      refute derived.dig("readiness", "full_scoring")
      replay = AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output + ".derived")
      assert_equal derived["package_id"], replay.package["package_id"]
      rewrite(frontier_path) { |document| document["original_candidate"]["sha256"] = "0" * 64; seal(document, "result_id") }
      release_inputs = JSON.parse(File.binread(fixture.inputs_path))
      evidence = release_inputs.dig("staged_scoring", "evidence")
      authority = fixture.authority_projection.fetch("authority")
      base_path = File.join(evidence.fetch("catalog_root"), authority.dig("base_amc", "filename"))
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::FrontierReleaseEvidence.validate!(
          path: frontier_path,
          release_manifest_path: File.join(fixture.output_dir, "release-accounting.json"),
          staged_path: fixture.staged_path,
          base_path:
        )
      end
    end
  ensure
    proofs.replace(saved_proofs) if saved_proofs
  end

  def test_missing_mutated_and_malformed_immutable_references_are_refused
    with_package do |fixture, inputs, output|
      package = read_package(output)
      names = %w[authority:source:fixture.md authority:source_registry authority:freeze_path authority:base authority:staged
                 authority:integrity authority:stage release_artifact:apply_intermediate release_artifact:apply_report
                 release_artifact:final_workbook release_artifact:finalize_report release_input:standing_policy
                 release_input:owner_selection release_input:editorial_ledger]
      names.each do |name|
        path = package.dig("provenance", "nodes", name, "path")
        bytes = File.binread(path)
        File.binwrite(path, bytes + "changed")
        assert_raises(AfDataPipeline::ValidationError, name) { AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output) }
        File.binwrite(path, bytes)
        File.rename(path, path + ".missing")
        assert_raises(AfDataPipeline::ValidationError, name) { AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output) }
        File.rename(path + ".missing", path)
      end
      rewrite(output) { |document| document["release"]["counts"]["metric_candidates"] -= 1; seal(document, "package_id") }
      assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output) }
      File.write(inputs, '{"schema_version":"duplicate","schema_version":"duplicate"}')
      assert_raises(AfDataPipeline::ValidationError) { prepare(inputs, output + ".duplicate") }
    end
  end

  def test_successful_subset_and_rehashed_release_counts_do_not_replace_full_population
    with_package do |fixture, inputs, output|
      release_path = JSON.parse(File.read(inputs)).fetch("release_manifest_path")
      bytes = File.binread(release_path)
      %w[metric_candidates intended_cases standing_directive_accepted new_cells_written boundary_created_ids].each do |count|
        rewrite(release_path) { |document| document["counts"][count] += 1; seal(document, "manifest_id") }
        assert_raises(AfDataPipeline::ValidationError, count) { AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output) }
        if count == "metric_candidates"
          validator = RELEASE_CONSTRUCTOR.call(inputs_path: fixture.inputs_path, output_dir: fixture.output_dir)
          assert_raises(AfDataPipeline::ValidationError) { validator.validate_existing! }
        end
        File.binwrite(release_path, bytes)
      end
      rewrite(fixture.manifest_path) do |document|
        document["cases"].pop
        document["summary"]["intended_cases"] -= 1
        seal(document, "manifest_id")
      end
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(inputs, output + ".subset") }
      assert_match(/denominator|accounting|reference changed/, error.message)
      review = JSON.parse(File.read(fixture.inputs_path)).fetch("workload_review")
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::WorkloadScoringReviewPackage.prepare!(**review.transform_keys(&:to_sym))
      end
      assert_includes error.message, "denominator"
    end
  end


  def test_current_head_advancement_is_scoring_safe_but_lost_score_blocks_promotion
    with_package do |fixture, inputs, output|
      initial = read_package(output)
      catalog = JSON.parse(File.read(inputs)).fetch("catalog_repository_root")
      state_path = File.join(catalog, "PROJECT_STATE.yml")
      head_file = YAML.safe_load_file(state_path).dig("catalog_head", "filename")
      head_path = File.join(catalog, "5e_Adventure_Master_Catalog_0.1.1.xlsx")
      FileUtils.cp(File.join(catalog, head_file), head_path)
      fixture.change_cell(head_path, "L2", 9)
      update_state_hash(state_path, head_path)
      git(catalog, "add", ".")
      git(catalog, "commit", "-qm", "Synthetic concurrent score")
      package = prepare(inputs, output + ".advanced").package
      assert_equal "SAFE_REUSE", package.dig("scoring_concurrency", "decision")
      assert_equal "UNRELATED_SCALAR_SCORES", package.dig("scoring_concurrency", "reason")
      refute package.dig("readiness", "ready")
      assert package.dig("readiness", "reasons").any? { |reason| reason["code"] == "PROMOTION_WOULD_LOSE_CURRENT_CHANGES" }
      assert package.dig("transition", "delta", "changed_cells").any? { |row| row["adventure_id"] == "ADV-0001" && row["before"]["value"] == 9 }
      refute_equal initial.dig("transition", "catalog_repository", "head"), package.dig("transition", "catalog_repository", "head")
      assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output) }
      git(catalog, "commit", "--allow-empty", "-qm", "Synthetic HEAD-only advancement")
      assert_raises(AfDataPipeline::ValidationError) { AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output + ".advanced") }
    end
  end

  def test_current_manifest_and_uncommitted_catalog_bytes_cannot_claim_repository_head
    with_package do |fixture, inputs, output|
      catalog = JSON.parse(File.read(inputs)).fetch("catalog_repository_root")
      state_path = File.join(catalog, "PROJECT_STATE.yml")
      File.open(state_path, "a") { |file| file.write("# changed observation\n") }
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(inputs, output + ".dirty") }
      assert_includes error.message, "repository HEAD differs"
    end
  end


  def test_human_and_source_terminal_exceptions_remain_distinct
    specs = [
      {case_id: "combat", dimension: "Combat Emphasis", metrics: {"Combat Emphasis" => 3}},
      {case_id: "openness", dimension: "Structural Openness", metrics: {"Structural Openness" => 4}, review_disposition: "SOURCE_HOLD", hold_reason: "synthetic source hold"},
      {case_id: "levels", dimension: "Levels", metrics: {"Level Start" => 1, "Level End" => 5}}
    ]
    configure = lambda do |fixture|
      fixture.set_decision("ADV-0003::Combat Emphasis", "ACCEPT")
      fixture.set_decision("ADV-0003::Level Start", "HOLD")
      fixture.set_decision("ADV-0003::Level End", "REJECT")
    end
    with_release(specs:, configure:) do |fixture, result|
      release_inputs = JSON.parse(File.binread(fixture.inputs_path))
      workload = JSON.parse(File.binread(release_inputs.dig("workload_review", "manifest_path")))
      candidates = File.readlines(File.join(fixture.review_dir, "candidates.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      validator = AfDataPipeline::FinalReleasePackage.new(inputs_path: "unused")
      validator.instance_variable_set(:@refs, {"authority:staged" => {"path" => fixture.staged_path}})
      population = validator.send(:reconcile_population!, workload, candidates, result.manifest, result.output_dir)
      counts = result.manifest.fetch("counts")
      assert result.manifest.fetch("release_complete")
      assert_equal 4, population.fetch("intended_metrics")
      assert_equal 1, counts.fetch("individual_human_accepted")
      assert_equal 0, counts.fetch("standing_directive_accepted")
      assert_equal 3, population.fetch("hard_exceptions")
      assert_equal 2, population.fetch("preserved_existing_metrics")
      assert_equal 0, population.fetch("accepted_already_present_metrics")
      assert_equal %w[human_hold human_reject source_hold], population.fetch("gaps").map { |row| row["category"] }.sort
      assert_equal "ADV-0003::Combat Emphasis", population.dig("acceptance", 0, "individual_decision_reference", "record_key")
      refute population.fetch("remaining_blank_metrics").zero? && population.fetch("terminal_gap_metrics").zero?
    end
  end

  def test_unavailable_ig16b_application_control_cannot_be_replaced_by_record_only_authority
    transform = lambda do |release|
      manifest = Marshal.load(Marshal.dump(release.manifest))
      manifest["counts"]["ig16b_machine_accepted"] = 1
      manifest["manifest_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(manifest.except("manifest_id"))
      release.with(manifest:)
    end
    with_package(release_transform: transform) do |_fixture, inputs, output|
      variant = variant_inputs(inputs, "machine")
      error = assert_raises(AfDataPipeline::ValidationError) { prepare(variant, output + ".machine") }
      assert_includes error.message, "unsupported IG-16B authority"
      refute_path_exists output + ".machine"
    end
  end

  def test_preview_is_informational_and_public_cli_validates_without_publication
    transform = lambda do |release|
      manifest = Marshal.load(Marshal.dump(release.manifest))
      preview_path = File.join(release.output_dir, AfDataPipeline::StandingBulkScoreRelease::PREVIEW_NAME)
      FileUtils.cp(File.join(release.output_dir, ".apply-intermediate.xlsx"), preview_path)
      manifest["artifacts"]["explicit_red_cell_preview"] = {
        "filename" => AfDataPipeline::StandingBulkScoreRelease::PREVIEW_NAME,
        **AfDataPipeline::StandingBulkScorePolicy.file_binding(preview_path),
        "authority_effect" => "none"
      }
      manifest["manifest_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(manifest.except("manifest_id"))
      File.write(release.manifest_path, JSON.pretty_generate(manifest) + "\n")
      File.unlink(preview_path)
      release.with(manifest:)
    end
    with_package(release_transform: transform) do |_fixture, inputs, output|
      variant = variant_inputs(inputs, "preview")
      preview_output = output + ".preview"
      package = prepare(variant, preview_output).package
      assert package.dig("readiness", "ready")
      assert_equal true, package.dig("release", "preview", "requested")
      assert_equal false, package.dig("release", "preview", "available")
      out = StringIO.new
      err = StringIO.new
      assert_equal 0, AfDataPipeline::FinalReleasePackage.run(["validate", "--inputs", variant, "--package", preview_output], out:, err:)
      assert_equal package["package_id"], JSON.parse(out.string)["package_id"]
      assert_empty err.string
      assert_equal 2, AfDataPipeline::FinalReleasePackage.run([], out: StringIO.new, err: StringIO.new)
    end
  end

  def test_cached_release_verifier_preserves_historical_observation_and_refuses_changed_promotion
    with_package do |fixture, inputs, output|
      package = read_package(output)
      state_path = package.dig("provenance", "nodes", "current_project_state", "path")
      verifier = AfDataPipeline::StandingBulkScoreRelease.new(inputs_path: fixture.inputs_path, output_dir: fixture.output_dir)
      current = verifier.validate_existing!(current_project_state_path: state_path, replay_observation: nil)
      request = AfDataPipeline::FinalReleaseAdoption.prepare!(inputs_path: inputs, package_path: output,
        output_path: File.join(fixture.root, "historical-replay-request.json"))
      snapshot = AfDataPipeline::FinalReleaseAdoption.validate!(inputs_path: inputs, package_path: output,
        request_path: request.path).snapshot
      FileUtils.cp(snapshot.candidate_path, snapshot.destination)
      AfDataPipeline::ProjectState.new(manifest_path: state_path).promote!(role: "catalog_head",
        artifact_path: snapshot.destination, version: snapshot.version)
      observation = AfDataPipeline::CatalogReplayObservation.new(snapshot:,
        historical_binding: package.dig("provenance", "nodes", "current_project_state"))

      historical = verifier.validate_existing!(current_project_state_path: state_path, replay_observation: observation)
      assert_equal current.projection, historical.projection
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output)
      end
      File.open(state_path, "a") { |file| file.write("# unauthorized promotion change\n") }
      error = assert_raises(AfDataPipeline::Error) do
        verifier.validate_existing!(current_project_state_path: state_path, replay_observation: observation)
      end
      assert_includes error.message, "exact approved promotion"
    end
  end

  private

  def with_package(specs: nil, configure: nil, preview: false, template_key: nil, release_transform: nil)
    with_test_caches do
      template_key ||= :default if specs.nil? && configure.nil? && !preview
      if template_key && TEMPLATES.key?(template_key)
        cached = TEMPLATES.fetch(template_key)
        restore_template(cached)
        reuse_verified_inputs(cached, release_transform:) do
          yield cached.fetch(:fixture), cached.fetch(:inputs), cached.fetch(:output)
        end
      else
        root = Dir.mktmpdir("final-release-package-")
        at_exit { FileUtils.remove_entry(root) if File.directory?(root) }
        fixture = StandingBulkScoreReleaseFixture.new(root:, specs:)
        configure&.call(fixture)
        release = fixture.release(preview:)
        state_path = File.join(root, "PROJECT_STATE.yml")
        catalog = File.join(root, "catalog-repository")
        FileUtils.mkdir_p(catalog)
        FileUtils.cp(state_path, File.join(catalog, "PROJECT_STATE.yml"))
        state = YAML.safe_load_file(state_path)
        state.values.grep(Hash).map { |role| role.fetch("filename") }.uniq.each do |filename|
          FileUtils.cp(File.join(root, filename), catalog)
        end
        initialize_catalog(catalog)
        inputs = File.join(root, "package-inputs.json")
        File.write(inputs, JSON.pretty_generate(
          "schema_version" => AfDataPipeline::FinalReleasePackage::INPUT_SCHEMA,
          "release_inputs_path" => fixture.inputs_path,
          "release_manifest_path" => File.join(fixture.output_dir, "release-accounting.json"),
          "catalog_repository_root" => catalog,
          "current_project_state_path" => File.join(catalog, "PROJECT_STATE.yml"),
          "frontier_result_path" => nil
        ) + "\n")
        output = File.join(root, "package.json")
        release_inputs = JSON.parse(File.read(fixture.inputs_path))
        stage = AfDataPipeline::BoundaryFreezeStage.verify!(**release_inputs.dig("staged_scoring", "evidence").slice(
          "freeze_path", "operation_input_path", "successor_authorization_path", "source_root", "catalog_root", "project_state_path"
        ).transform_keys(&:to_sym))
        cached = {root:, fixture:, inputs:, output:, release:, stage:}
        if template_key
          AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: inputs, output_path: output)
          files = snapshot_files(root)
          directories = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
            .select { |path| File.directory?(path) }.map { |path| path.delete_prefix(root + "/").freeze }.freeze
          TEMPLATES[template_key] = cached.merge(files:, directories:).freeze
        end
        reuse_verified_inputs(cached, release_transform:) { yield fixture, inputs, output }
      end
    end
  end

  def with_release(specs:, configure:)
    root = Dir.mktmpdir("final-release-population-")
    fixture = StandingBulkScoreReleaseFixture.new(root:, specs:)
    configure.call(fixture)
    yield fixture, fixture.release
  ensure
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  def with_test_caches
    package_constructor = lambda do |**options|
      PACKAGE_CONSTRUCTOR.call(**options).extend(CachedCatalogViews)
    end
    compatibility_constructor = lambda do |**options|
      checker = COMPATIBILITY_CONSTRUCTOR.call(**options)
      original_check = checker.method(:check)
      bindings = options.sort.map do |name, path|
        next [name, nil] unless path
        expanded = File.expand_path(path)
        [name, expanded, File.file?(expanded) && Digest::SHA256.file(expanded).hexdigest]
      end
      checker.define_singleton_method(:check) do
        if (cached = FinalReleasePackageTest::COMPATIBILITY_RESULTS[bindings])
          @frontier_evidence = cached.fetch(:frontier) && Marshal.load(cached.fetch(:frontier))
          Marshal.load(cached.fetch(:report))
        else
          report = original_check.call
          FinalReleasePackageTest::COMPATIBILITY_RESULTS[bindings] = {
            report: Marshal.dump(report).freeze,
            frontier: frontier_evidence && Marshal.dump(frontier_evidence).freeze
          }.freeze
          report
        end
      end
      checker
    end
    AfDataPipeline::FinalReleasePackage.stub(:new, package_constructor) do
      AfDataPipeline::AmcCompatibilityCheck.stub(:new, compatibility_constructor) { yield }
    end
  end

  # A byte-identical catalog starts from the same real Git commit. Each copy
  # has its own objects, index and working tree, and all package Git checks and
  # concurrent-commit tests still execute against a real repository.
  def initialize_catalog(catalog)
    key = Dir.glob(File.join(catalog, "*")).sort.map do |path|
      [File.basename(path), Digest::SHA256.file(path).hexdigest]
    end
    if (files = CATALOG_TEMPLATES[key])
      files.each do |relative, (bytes, mode)|
        path = File.join(catalog, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
        File.chmod(mode, path)
      end
    else
      git(catalog, "init", "-q")
      # Keep the identity local to this disposable repository without spawning
      # two extra Git processes for every package variant.
      File.open(File.join(catalog, ".git", "config"), "a") do |file|
        file.write("[user]\n\tname = Synthetic fixture\n\temail = fixture@example.invalid\n")
      end
      git(catalog, "remote", "add", "origin", "fixture://catalog")
      git(catalog, "add", ".")
      git(catalog, "commit", "-qm", "Synthetic catalog")
      CATALOG_TEMPLATES[key] = snapshot_files(File.join(catalog, ".git"))
        .transform_keys { |relative| File.join(".git", relative).freeze }.freeze
    end
  end

  def snapshot_files(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      .to_h { |path| [path.delete_prefix(root + "/").freeze,
                      [File.binread(path).freeze, File.stat(path).mode & 0o777].freeze] }.freeze
  end

  def restore_template(cached)
    root = cached.fetch(:root)
    files = cached.fetch(:files)
    paths = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
    paths.select { |path| File.file?(path) }.each do |path|
      File.unlink(path) unless files.key?(path.delete_prefix(root + "/"))
    end
    files.each do |relative, (bytes, mode)|
      path = File.join(root, relative)
      next if File.file?(path) && File.binread(path) == bytes && (File.stat(path).mode & 0o777) == mode
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
      File.chmod(mode, path)
    end
    # Remove directories left by frontier preparation or Git commits, so each
    # test sees the original fixture tree as well as the original bytes.
    paths.select { |path| File.directory?(path) }.sort_by { |path| -path.length }.each do |path|
      relative = path.delete_prefix(root + "/")
      Dir.rmdir(path) if Dir.empty?(path) && !cached.fetch(:directories).include?(relative)
    end
    cached.fetch(:directories).each { |relative| FileUtils.mkdir_p(File.join(root, relative)) }
  end

  # The real release writer and stage verifier produced these immutable proofs.
  # Reuse them for package composition cases; clean preparation and the native
  # rehashed-count refusal above still exercise the full public replay. All
  # reference hashing, workbook checks, populations and catalog comparisons in
  # the package remain real. Historical observations use the real release
  # verifier rather than replacing their authority with these cached proofs.
  # This mirrors the IG-18A1 fixture-proof convention.
  def reuse_verified_inputs(cached, release_transform: nil)
    fixture = cached.fetch(:fixture)
    release = release_transform ? release_transform.call(cached.fetch(:release)) : cached.fetch(:release)
    verifier = Object.new
    verifier.define_singleton_method(:validate_existing!) do |current_project_state_path:, replay_observation: nil|
      if replay_observation
        return RELEASE_CONSTRUCTOR.call(inputs_path: fixture.inputs_path, output_dir: fixture.output_dir).validate_existing!(
          current_project_state_path:, replay_observation:)
      end
      projection = Marshal.load(Marshal.dump(fixture.authority_projection))
      state = AfDataPipeline::ProjectState.new(manifest_path: current_project_state_path)
      state.validate!
      authority = projection.fetch("authority")
      base = File.join(fixture.root, authority.dig("base_amc", "filename"))
      concurrency = AfDataPipeline::StagedScoringConcurrency.compare(base_path: base, head_path: state.resolve("catalog_head").path,
        records: authority.fetch("allocation"), source_id: authority.dig("intent", "source", "source_id"))
      roles = YAML.safe_load_file(current_project_state_path).slice(*AfDataPipeline::ProjectState::ROLES)
      concurrency["observation"] = {"manifest" => AfDataPipeline::StandingBulkScorePolicy.file_binding(current_project_state_path), "roles" => roles}
      projection["concurrency"] = concurrency
      AfDataPipeline::StandingBulkScoreRelease::Verification.new(release:, projection:)
    end
    constructor = lambda do |**options|
      options[:inputs_path] == fixture.inputs_path ? verifier : RELEASE_CONSTRUCTOR.call(**options)
    end
    AfDataPipeline::StandingBulkScoreRelease.stub(:new, constructor) do
      AfDataPipeline::BoundaryFreezeStage.stub(:verify!, cached.fetch(:stage)) { yield }
    end
  end

  def prepare(inputs, output)
    if File.file?(output)
      AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: output)
    else
      AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: inputs, output_path: output)
    end
  end

  def read_package(path)
    JSON.parse(File.binread(path))
  end

  def variant_inputs(path, name)
    variant = path.sub(/\.json\z/, ".#{name}.json")
    FileUtils.cp(path, variant)
    variant
  end

  def git(root, *args)
    _stdout, stderr, status = Open3.capture3("git", "-C", root, *args)
    raise stderr unless status.success?
  end

  def rewrite(path)
    document = JSON.parse(File.read(path))
    yield document
    File.write(path, JSON.pretty_generate(document) + "\n")
  end

  def seal(document, key)
    document[key] = AfDataPipeline::StandingBulkScorePolicy.digest(document.except(key))
  end

  def update_state_hash(path, workbook)
    document = YAML.safe_load_file(path)
    document["catalog_head"].merge!(AfDataPipeline::StandingBulkScorePolicy.file_binding(workbook),
                                   "filename" => File.basename(workbook), "version" => File.basename(workbook)[/Catalog_(.*)\.xlsx/, 1])
    File.write(path, YAML.dump(document))
  end

  def frontier_fixture(fixture, package, declined: false, no_write: [])
    root = File.join(fixture.root, "frontier")
    FileUtils.mkdir_p(root)
    refs = {}
    package.dig("provenance", "nodes").each do |key, binding|
      next unless binding["path"] && (key.start_with?("release_input:") || key.start_with?("authority:"))
      name = key.delete_prefix("release_input:")
      refs[name] = binding.slice("path", "sha256", "bytes")
    end
    File.write(File.join(root, "rubric.json"), '{"schema_version":"synthetic-rubric/v0.1"}')
    refs["rubric"] = frontier_binding(root, "rubric.json")
    manifest = JSON.parse(File.read(File.join(fixture.output_dir, "release-accounting.json")))
    targets = manifest.fetch("residuals").select { |row| row["category"] == "unsupported_scope" }.map { |row| row.slice("candidate_key", "adventure_id", "dimension").merge("original_value" => nil) }.sort_by { |row| row["candidate_key"] }
    original = package.dig("candidate", "original").slice("sha256", "bytes")
    handoff = {"schema_version" => AfDataPipeline::FrontierReleaseEvidence::HANDOFF_SCHEMA,
               "release_id" => manifest.fetch("release_id"), "manifest_id" => manifest.fetch("manifest_id"),
               "lineage" => manifest.fetch("lineage"), "original_candidate" => original, "targets" => targets, "references" => refs}
    seal(handoff, "handoff_id")
    File.write(File.join(root, "handoff.json"), JSON.pretty_generate(handoff) + "\n")
    artifacts = {"handoff" => frontier_binding(root, "handoff.json")}
    writes = 0
    if !declined
      records = targets.map { |row| {"candidate_key" => row.fetch("candidate_key"), "proposed_value" => no_write.include?(row["candidate_key"]) ? nil : 4,
                                     "reason" => "Synthetic source-linked result", "source_references" => ["authority:source:fixture.md"]} }
      returned = {"schema_version" => AfDataPipeline::FrontierReleaseEvidence::RETURN_SCHEMA, "handoff_id" => handoff.fetch("handoff_id"), "records" => records}
      seal(returned, "return_id")
      File.write(File.join(root, "return.json"), JSON.pretty_generate(returned) + "\n")
      accepted = records.reject { |row| row["proposed_value"].nil? }.map do |row|
        target = targets.find { |entry| entry["candidate_key"] == row["candidate_key"] }
        target.slice("candidate_key", "adventure_id", "dimension").merge("proposed_value" => row.fetch("proposed_value"))
      end
      authorization = {"schema_version" => AfDataPipeline::FrontierReleaseEvidence::AUTHORIZATION_SCHEMA, "release_id" => manifest.fetch("release_id"),
                       "handoff_id" => handoff.fetch("handoff_id"), "return_id" => returned.fetch("return_id"), "authority" => "frontier_manual", "accepted_candidates" => accepted}
      seal(authorization, "authorization_id")
      File.write(File.join(root, "authorization.json"), JSON.pretty_generate(authorization) + "\n")
      applied = AfDataPipeline::AmcApply.apply_authorized!(authorized_candidates: accepted, authorization:,
        accounting: {"source_holds" => 0, "held_candidates" => 0, "rejected_candidates" => 0, "pending_candidates" => 0},
        amc_path: package.dig("candidate", "original", "path"), output_path: File.join(root, "intermediate.xlsx"), report_path: File.join(root, "apply.json"))
      AfDataPipeline::AmcFinalize.finalize!(amc_path: applied.output_path, apply_report_path: applied.report_path,
        output_path: File.join(root, "candidate.xlsx"), report_path: File.join(root, "finalize.json"), expected_cells: accepted.length)
      {"return" => "return.json", "authorization" => "authorization.json", "intermediate" => "intermediate.xlsx",
       "apply_report" => "apply.json", "finalize_report" => "finalize.json", "candidate" => "candidate.xlsx"}.each { |key, name| artifacts[key] = frontier_binding(root, name) }
      writes = accepted.length
    end
    result = {"schema_version" => AfDataPipeline::FrontierReleaseEvidence::SCHEMA, "disposition" => declined ? "DECLINED" : "APPLIED",
              "original_manifest" => AfDataPipeline::StandingBulkScorePolicy.file_binding(File.join(fixture.output_dir, "release-accounting.json")),
              "original_candidate" => original, "artifacts" => artifacts, "version" => declined ? nil : "0.3",
              "counts" => {"writes" => writes, "no_writes" => targets.length - writes}}
    seal(result, "result_id")
    path = File.join(root, "result.json")
    File.write(path, JSON.pretty_generate(result) + "\n")
    path
  end

  def frontier_binding(root, filename)
    {"filename" => filename, **AfDataPipeline::StandingBulkScorePolicy.file_binding(File.join(root, filename))}
  end
end
