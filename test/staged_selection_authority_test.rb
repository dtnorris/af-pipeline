# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/staged_scoring_fixture"
require_relative "support/staged_scorer_identity_transport"
require "open3"
require "stringio"

class StagedSelectionAuthorityTest < Minitest::Test
  include StagedScoringFixture
  AFW = File.expand_path(ENV.fetch("AF_AFW_ROOT"), __dir__)
  require File.join(AFW, "lib/af_workloads")
  SCORER = File.expand_path(ENV.fetch("AF_SCORER_ROOT"), __dir__)
  SPEC = File.expand_path(ENV.fetch("AF_PUBLIC_SPEC_ROOT"), __dir__)
  PREPARED_SOURCE_VERSION = "afsu-prepared-source/v0.2"

  class ContentAddressedSelection < AFWorkloads::StagedSelection
    def evaluate(authority:, catalog_path:)
      key = eligibility_key(authority, catalog_path)
      if (bytes = (@eligibility_cache ||= {})[key])
        return JSON.parse(bytes)
      end
      result = super
      @eligibility_cache[key] = JSON.generate(result).freeze
      result
    end

    private

    def eligibility_key(authority, catalog_path)
      paths = [catalog_path, File.join(@root, "config/models.yml")]
      paths << @scorer_config if @scorer_config
      paths.concat(Dir[File.join(@root, "production_backlog", "**", "*")].select { |path| File.file?(path) })
      template = File.join(@scorer, "prepared-template.json")
      if File.file?(template)
        paths << template
        JSON.parse(File.binread(template)).values.grep(Hash).filter_map { |value| value["path"] }.each { |path| paths << path }
      end
      contract = %w[staged_selection.rb workload_compiler.rb current_runtime_policy.rb scorer_environment.rb ../adventure_ingest.rb]
        .map { |name| File.expand_path(name, File.join(AFW, "lib/af_workloads")) }
      state = (paths + contract).uniq.sort.to_h do |path|
        [path, AfDataPipeline::StagedScoringAuthority.file_binding(path)]
      end
      AfDataPipeline::StagedScoringAuthority.digest("authority" => authority, "inputs" => state)
    end
  end

  class InlineAuthority < AUTH
    Status = Struct.new(:ok) { def success? = ok }
    attr_writer :selection_verifier

    private

    def selection_owner(command)
      option = ->(name) { command.include?(name) ? command[command.index(name) + 1] : nil }
      json = ->(name) { option.call(name) && JSON.parse(File.binread(option.call(name))) }
      authority = json.call("--authority")
      workload_paths = json.call("--workload-paths")
      binding = json.call("--workload-binding")
      verifier = @selection_verifier ||= ContentAddressedSelection.new(root: AFW, data_root: option.call("--root"), scorer_repo: option.call("--scorer-repo"), scorer_config: option.call("--scorer-config"))
      result = verifier.verify!(
        authority:, catalog_path: option.call("--catalog"), selection_path: option.call("--selection"),
        workload_paths:, binding:)
      [JSON.generate(result), "", Status.new(true)]
    rescue AFWorkloads::Error => e
      ["", e.message, Status.new(false)]
    end
  end

  class << self
    attr_reader :shared_scorer

    def scorer_fixture
      return @shared_scorer if @shared_scorer
      @shared_scorer = Dir.mktmpdir("pipeline-selection-scorer")
      prepare_scorer_fixture(@shared_scorer)
      @shared_scorer
    end

    # Preserve the pinned Git and XLSX reader inputs. Source calls use the
    # same synthetic scorer in this process and during cold subprocess replay.
    def prepare_scorer_fixture(scorer)
      run_fixture_git("clone", "--quiet", "--shared", "--no-checkout", SCORER, scorer)
      run_fixture_git("-C", scorer, "read-tree", "HEAD")
      run_fixture_git("-C", scorer, "checkout", "HEAD", "--", "lib/af_scoring", "config")
      FileUtils.cp(File.join(__dir__, "support/staged_scorer_stub.rb"), File.join(scorer, "lib/af_scoring.rb"))
      FileUtils.mkdir_p(File.join(scorer, "bin"))
      File.write(File.join(scorer, "bin/af-score"), scorer_executable)
      FileUtils.chmod(0o755, File.join(scorer, "bin/af-score"))
      scorer
    end

    def remove_scorer_fixture
      FileUtils.remove_entry(@shared_scorer) if @shared_scorer && File.exist?(@shared_scorer)
    end

    private

    def run_fixture_git(*args)
      _stdout, stderr, status = Open3.capture3("git", *args)
      raise "fixture Git read failed: #{stderr}" unless status.success?
    end

    def scorer_executable
      <<~'SCRIPT'
        #!/bin/sh
        set -eu
        authorized=0
        destination=""
        dimension="null"
        prepare_source=0
        id=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --prepare-source) destination="$2"; authorized=1; prepare_source=1; shift 2 ;;
            --render-preflight) destination="$2"; shift 2 ;;
            --preflight) authorized=1; shift ;;
            --dimension) dimension="\"$2\""; shift 2 ;;
            --config|--model|--output|--prepared-source) shift 2 ;;
            *) id="$1"; shift ;;
          esac
        done
        [ "$authorized" -eq 1 ] || { echo "inference prohibited" >&2; exit 2; }
        if [ "$prepare_source" -eq 1 ]; then
          scorer_root=$(cd "$(dirname "$0")/.." && pwd)
          cp "$scorer_root/prepared-template.json" "$destination"
        elif [ -n "$destination" ]; then
          printf '{"synthetic":true,"id":"%s","dimension":%s}' "$id" "$dimension" > "$destination"
        fi
      SCRIPT
    end
  end

  Minitest.after_run { remove_scorer_fixture }

  def setup
    @root = Dir.mktmpdir("pipeline-selection")
    @project = File.join(@root, "afw")
    @scorer = self.class.scorer_fixture
    @scorer_lock = File.open(File.join(@scorer, "fixture.lock"), File::RDWR | File::CREAT, 0o600)
    @scorer_lock.flock(File::LOCK_EX)
    @store = File.join(@root, "authorities")
    @state = File.join(@root, "PROJECT_STATE.yml")
    prepare_afw_fixture
    prepare_scorer_config
  end

  def teardown
    FileUtils.rm_f(File.join(@scorer, "prepared-template.json"))
    @scorer_lock.flock(File::LOCK_UN)
    @scorer_lock.close
    FileUtils.remove_entry(@root)
  end

  def test_real_public_owner_contract_prepares_mixed_subset_and_refuses_forgery
    evidence = build_authority_fixture(@root, units: [{start: 10, end: 11}, {start: 12, end: 111}])
    service = service_for(evidence)
    authority = service.issue!(current_state_path: @state).fetch("authority")
    before = inputs
    result = prepare(evidence)
    assert_equal "PREPARED", result.fetch("status"), result.inspect
    selection = result.fetch("selection")
    assert_equal %w[ADV-0003 ADV-0004], selection["dispositions"].map { |d| d["adventure_id"] }
    assert_equal ["ADV-0003"], selection.fetch("selected_ids")
    assert_equal "legitimately-deferred", selection.dig("dispositions", 1, "disposition")
    assert_equal authority.dig("evidence", "source:fixture.md"), selection.dig("dispositions", 0, "evidence", "source_preflight", "source_file")
    assert_equal authority.dig("evidence", "source_registry"), selection.dig("dispositions", 0, "evidence", "source_preflight", "source_registry")
    preflight = selection.dig("dispositions", 0, "evidence", "source_preflight")
    assert_equal PREPARED_SOURCE_VERSION, preflight.fetch("contract_version")
    assert_equal Digest::SHA256.file(File.join(@scorer, "prepared-template.json")).hexdigest,
      preflight.fetch("prepared_source_sha256")
    selection_path = File.join(@project, "workloads/.selections/synthetic-operation-1/selection.json")
    manifest = result.fetch("workload")
    document = JSON.parse(File.read(File.join(manifest, "staged-scoring.json")))
    binding = document.fetch("binding")
    paths = {"plan" => File.join(manifest, "execution-plan.json"), "snapshot" => File.join(manifest, "snapshot.yml"),
             "index" => File.join(manifest, "case_index.csv"), "generated" => File.join(@project, "build/workloads/synthetic-operation-1")}
    assert File.file?(File.join(@project, "workloads/.selections/synthetic-operation-1/frozen-workload.json"))
    assert_equal before, inputs.except(File.join(@root, "inputs.json"))
    refute Dir.exist?(File.join(@project, "output"))
    # A caller's reduced list has no authority without owner verification.
    assert_raises(AUTH::Failure) { service.validate!(current_state_path: @state, frozen_workload: binding, workload_paths: paths) }
    saved = File.binread(selection_path)
    bad = JSON.parse(saved)
    bad["dispositions"][1]["disposition"] = "selected-qualified"
    bad["selected_ids"] << "ADV-0004"
    bad["selection_id"] = AUTH.digest(bad.except("selection_id"))
    File.write(selection_path, JSON.generate(bad))
    assert_raises(AUTH::Failure) { service.validate!(current_state_path: @state, selection_path:) }
    File.binwrite(selection_path, saved)
    anchor = File.join(@project, "workloads/.selections/synthetic-operation-1/frozen-workload.json")
    saved_anchor = File.binread(anchor)
    changed = JSON.parse(saved_anchor)
    changed["artifacts"]["plan"]["sha256"] = "f" * 64
    File.write(anchor, JSON.generate(changed))
    assert_raises(AUTH::Failure) { service.validate!(current_state_path: @state, frozen_workload: binding, workload_paths: paths, selection_path:) }
    File.binwrite(anchor, saved_anchor)
    # Existing authority and AFW suites exercise changed plan and generated
    # runtime bytes. This selected-subset case retains the exact artifact bind.
    assert_equal binding.dig("artifacts", "plan"), AUTH.file_binding(paths.fetch("plan"))
    template_path = File.join(@scorer, "prepared-template.json")
    template = JSON.parse(File.read(template_path))
    template["source_file"]["sha256"] = "a" * 64
    write_json(template_path, template)
    refused = selection_for.evaluate(authority:, catalog_path: @catalog)
    assert_equal "REFUSED", refused["status"]
    assert_equal "refused", refused.dig("dispositions", 0, "disposition")
  end

  def test_all_deferred_and_zero_allocation_have_distinct_public_results
    evidence = build_authority_fixture(@root, units: [{start: 10, end: 109}])
    service = service_for(evidence)
    service.issue!(current_state_path: @state)
    result = prepare(evidence)
    assert_equal "ALL_DEFERRED", result.fetch("status")
    assert_nil result.fetch("workload")
    assert_empty result.dig("selection", "selected_ids")
    selection_path = File.join(@project, "workloads/.selections/synthetic-operation-1/selection.json")
    cold = AUTH.new(evidence:, store_root: @store, mode: "synthetic", selection_afw_root: AFW,
                    selection_project_root: @project, selection_scorer_root: @scorer, selection_scorer_config: @scorer_config)
    projection = cold.validate!(current_state_path: @state, selection_path:)
    assert_equal "ALL_DEFERRED", projection.fetch("status")
    refute projection.fetch("preparation_allowed")
    refute Dir.exist?(File.join(@project, "build"))
    # The existing authority suite exercises the zero-record issuance path.
    # Here the nonempty owner ledger proves that ALL_DEFERRED is not that state.
    refute_equal "NO_SUCCESSOR_NEEDED", result.fetch("status")
    assert_equal 1, result.dig("selection", "allocation").length
  end


  private

  # Write the roots-only config for this mechanical source/catalog fixture.
  # Returns its path for selection and cold replay; filesystem failures raise.
  def prepare_scorer_config
    @scorer_config = File.join(@project, "config/scorer-inputs.yml")
    File.write(@scorer_config, YAML.dump(
      "paths" => {"xlsx_root" => @root, "specification_root" => SPEC,
                  "source_root" => File.join(@root, "source"), "output_root" => File.join(@project, "output")}
    ))
    @scorer_config
  end

  def service_for(evidence)
    @catalog ||= staged_catalog_path(@root)
    @service ||= InlineAuthority.new(evidence:, store_root: @store, mode: "synthetic", selection_afw_root: AFW, selection_project_root: @project, selection_scorer_root: @scorer, selection_scorer_config: @scorer_config).tap do |service|
      service.selection_verifier = selection_for
    end
  end

  def selection_for
    @selection ||= ContentAddressedSelection.new(root: AFW, data_root: @project, scorer_repo: @scorer, scorer_config: @scorer_config)
  end

  def inputs
    Dir[File.join(@root, "**", "*")].select { |p| File.file?(p) && !p.start_with?(@project + "/", @store + "/", @scorer + "/") }
      .to_h { |p| [p, Digest::SHA256.file(p).hexdigest] }
  end

  def prepare(evidence)
    inputs_path = File.join(@root, "inputs.json")
    write_json(inputs_path, {"schema_version" => "af-staged-scoring-evidence-locators/v0.1", "evidence" => evidence})
    write_prepared_source_template
    runner = lambda do |command|
      option = ->(name) { command.include?(name) ? command[command.index(name) + 1] : nil }
      binding_path = option.call("--workload-binding")
      paths_path = option.call("--workload-paths")
      begin
        projection = service_for(evidence).validate!(current_state_path: @state,
          selection_path: option.call("--selection"),
          frozen_workload: binding_path && JSON.parse(File.read(binding_path)),
          workload_paths: paths_path && JSON.parse(File.read(paths_path)))
        [JSON.generate(projection), "", true]
      rescue AfDataPipeline::Error => e
        ["", e.message, false]
      end
    end
    # Run the pipeline and AFW validators and compiler with the synthetic scorer.
    config = {pipeline_root: File.expand_path("..", __dir__), inputs_path:, store_root: @store,
              project_state_path: @state, operation_id: "11111111-1111-4111-8111-111111111111", mode: "synthetic", command_runner: runner}
    staged = AFWorkloads::StagedScoringInput.new(root: @project, config:)
    selection_for.prepare!(
      staged_scoring: staged, catalog_path: @catalog, required_context_length: 131_072,
      require_fully_gpu_resident: true, out: StringIO.new)

  end

  # Bind fixture bytes to the v0.2 fields consumed by AFW. The scorer suite
  # owns the behavior that produces and replays a complete source payload.
  def write_prepared_source_template
    source_root = File.join(@root, "source")
    template = {
      "contract_version" => PREPARED_SOURCE_VERSION,
      "adventure" => {"id" => "ADV-0003"},
      "source_policy" => {"allow_full_source_fallback" => false,
                          "allow_inward_boundary_clamp" => false,
                          "max_inward_boundary_clamp_gap" => nil},
      "target_eligibility" => {"calibration" => "none", "declared" => false}
    }
    {"catalog" => @catalog, "source_registry" => File.join(source_root, "source_registry.yml"),
     "source_file" => File.join(source_root, "fixture.md")}.each do |name, path|
      template[name] = {"path" => path, "sha256" => Digest::SHA256.file(path).hexdigest}
    end
    write_json(File.join(@scorer, "prepared-template.json"), template)
  end

  def prepare_afw_fixture
    run_git("clone", "--quiet", "--shared", "--no-checkout", AFW, @project)
    paths = %w[production_backlog/qualified_dimensions.yml production_backlog/qualified_number_of_sessions.yml production_backlog/qualified_exploration_emphasis.yml production_backlog/qualified_gm_beginner_suitability.yml production_backlog/qualified_gm_preparation_burden.yml production_backlog/qualified_seriousness.yml production_backlog/ee-v0.5-runtime.yml production_backlog/gmpb-v0.6-runtime.yml production_backlog/seriousness-reset-runtime.yml config/models.yml]
    paths.each do |path|
      destination = File.join(@project, path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(File.join(AFW, path), destination)
    end
  end

  def run_git(*args)
    _stdout, stderr, status = Open3.capture3("git", *args)
    raise "fixture Git read failed: #{stderr}" unless status.success?
  end
end
