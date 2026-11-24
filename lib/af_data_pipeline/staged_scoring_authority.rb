# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"
require "tempfile"
require "time"
require "optparse"
require "open3"
require_relative "boundary_editorial"
require_relative "staged_scoring_concurrency"
require_relative "private_data_root"

module AfDataPipeline
  # Pipeline-owned content authority; no coordinator lifecycle or AFW execution.
  class StagedScoringAuthority
    VERSION = "af-staged-scoring-authority/v0.1"
    INTENT_VERSION = "adventurefinder-staged-scoring-intent/v0.1"
    PROJECTION_VERSION = "af-staged-scoring-authority-projection/v0.1"
    WORKLOAD_VERSION = "af-staged-scoring-workload-binding/v0.1"
    POLICY = {
      "schema_version" => "af-staged-scoring-input-policy/v0.1",
      "policy_id" => "approved-new-records", "policy_version" => "1",
      "scope" => "operation-approved-new-records",
      "selection" => "afw-qualified-default",
      "permissions" => %w[scoring_input workload_preparation].freeze
    }.freeze
    INPUT_KEYS = %i[freeze_path operation_input_path successor_authorization_path source_root
                    catalog_root project_state_path approval_path bundle_dir dossier_path
                    intent_path policy_path].freeze

    class Failure < ValidationError
      attr_reader :code
      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    # Reject duplicate JSON keys before canonical hashing can hide them.
    class UniqueObject < Hash
      def []=(key, value)
        raise Failure.new("MALFORMED_EVIDENCE", "duplicate JSON key #{key}") if key?(key)
        super
      end
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |k| [k, canonical(value.fetch(k))] }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def self.file_binding(path)
      {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
    end

    def self.document_bytes(document)
      JSON.pretty_generate(canonical(document)) + "\n"
    end

    def self.run(argv, out: $stdout, err: $stderr)
      action = argv.shift
      options = {mode: "production"}
      OptionParser.new do |opts|
        opts.on("--inputs FILE") { |v| options[:inputs] = v }
        opts.on("--store DIR") { |v| options[:store] = v }
        opts.on("--project-state FILE") { |v| options[:state] = v }
        opts.on("--synthetic") { options[:mode] = "synthetic" }
        opts.on("--workload-binding FILE") { |v| options[:workload] = v }
        opts.on("--workload-paths FILE") { |v| options[:workload_paths] = v }
        opts.on("--selection FILE") { |v| options[:selection] = v }
        opts.on("--selection-afw-root DIR") { |v| options[:afw_root] = v }
        opts.on("--selection-project-root DIR") { |v| options[:afw_project] = v }
        opts.on("--selection-scorer-config FILE") { |v| options[:scorer_config] = v }
        opts.on("--selection-scorer-root DIR") { |v| options[:scorer_root] = v }
      end.parse!(argv)
      unless %w[issue validate].include?(action) && argv.empty? && %i[inputs store state].all? { |k| options[k] }
        raise Failure.new("USAGE", "issue|validate --inputs FILE --store DIR --project-state FILE [--synthetic]")
      end
      if action == "issue" && (options[:workload] || options[:workload_paths] || options[:selection])
        raise Failure.new("USAGE", "workload evidence is valid only with validate")
      end
      input = JSON.parse(File.binread(options[:inputs]), object_class: UniqueObject)
      unless input.is_a?(Hash) && input.keys.sort == %w[evidence schema_version] && input["schema_version"] == "af-staged-scoring-evidence-locators/v0.1" && input["evidence"].is_a?(Hash)
        raise Failure.new("MALFORMED_EVIDENCE", "unsupported locator envelope")
      end
      service = new(evidence: input.fetch("evidence").transform_keys(&:to_sym), store_root: options[:store], mode: options[:mode], selection_afw_root: options[:afw_root], selection_project_root: options[:afw_project], selection_scorer_root: options[:scorer_root], selection_scorer_config: options[:scorer_config])
      result = if action == "issue"
                 service.issue!(current_state_path: options[:state])
               else
                 binding = options[:workload] && JSON.parse(File.binread(options[:workload]), object_class: UniqueObject)
                 paths = options[:workload_paths] && JSON.parse(File.binread(options[:workload_paths]), object_class: UniqueObject)
                 service.validate!(current_state_path: options[:state], frozen_workload: binding, workload_paths: paths, selection_path: options[:selection])
               end
      out.puts JSON.pretty_generate(result)
      result["preparation_allowed"] || result["status"] == "NO_SUCCESSOR_NEEDED" ? 0 : 2
    rescue Error, OptionParser::ParseError, SystemCallError, JSON::ParserError, Psych::Exception, KeyError, TypeError, ArgumentError => e
      err.puts JSON.generate("schema_version" => "af-staged-scoring-error/v0.1",
                             "error" => {"code" => e.respond_to?(:code) ? e.code : "INVALID_EVIDENCE", "message" => e.message})
      2
    end

    # Select explicit owner code/artifact/config paths; AFW revalidates configuration
    # against its immutable selection. Malformed selectors raise Failure.
    def initialize(evidence:, store_root:, mode: "production", selection_afw_root: nil, selection_project_root: nil, selection_scorer_root: nil, selection_scorer_config: nil)
      check(evidence.is_a?(Hash) && evidence.keys.sort == INPUT_KEYS.sort &&
            evidence.values.all? { |path| path.is_a?(String) && !path.empty? },
            "MALFORMED_EVIDENCE", "exact evidence paths required")
      check(%w[production synthetic].include?(mode), "MALFORMED_EVIDENCE", "unknown mode")
      @paths = evidence.transform_values { |path| File.expand_path(path) }
      @store_root = File.expand_path(PrivateDataRoot.destination!(store_root))
      @mode = mode
      @concurrency = StagedScoringConcurrency.new
      @selection_afw_root = selection_afw_root && File.expand_path(selection_afw_root)
      @selection_project_root = selection_project_root && File.expand_path(selection_project_root)
      check(selection_scorer_config.nil? || (selection_scorer_config.is_a?(String) && !selection_scorer_config.strip.empty?),
            "MALFORMED_EVIDENCE", "selection scorer configuration must be a nonempty file path")
      @selection_scorer_config = selection_scorer_config && File.expand_path(selection_scorer_config)
      @selection_scorer_root = selection_scorer_root && File.expand_path(selection_scorer_root)
    end

    # Only the authority store is written. One immutable publication per
    # operation, including partial-publication refusal after a crash.
    def issue!(current_state_path:)
      PrivateDataRoot.destination!(@store_root)
      authority, observation = candidate(current_state_path)
      return zero_result(observation) unless authority
      require_safe!(observation)
      operation_id = authority.dig("operation", "operation_id")
      FileUtils.mkdir_p(@store_root)
      File.open(File.join(@store_root, "#{operation_id}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        directory = File.join(@store_root, operation_id)
        if File.exist?(directory)
          return validate!(current_state_path:)
        end
        stable!(authority, observation, current_state_path)
        Dir.mkdir(directory)
        publish(File.join(directory, "authority.json"), authority)
        # A race leaves a partial publication that cannot be consumed. It is
        # never silently deleted, rebound, or completed on an ordinary retry.
        stable!(authority, observation, current_state_path)
        publish(File.join(directory, "publication.json"), {"authority_id" => authority.fetch("authority_id")})
        stable!(authority, observation, current_state_path)
        projection(authority, observation)
      end
    rescue SystemCallError, JSON::ParserError, KeyError, TypeError, ArgumentError => e
      fail_with("INVALID_EVIDENCE", e.message)
    end

    # Same proof before build and after freezing. A stale result never edits a
    # workload. Supplied workload evidence is checked even when the head blocks.
    def validate!(current_state_path:, frozen_workload: nil, workload_paths: nil, selection_path: nil, replay_observation: nil)
      PrivateDataRoot.destination!(@store_root)
      check(replay_observation.nil? || replay_observation.instance_of?(CatalogReplayObservation),
            "INVALID_EVIDENCE", "invalid historical catalog observation")
      authority, observation = candidate(current_state_path, replay_observation:)
      unless authority
        check(frozen_workload.nil? && workload_paths.nil? && selection_path.nil?, "WORKLOAD_CONFLICT", "zero-record result cannot have a workload")
        return zero_result(observation)
      end
      directory = File.join(@store_root, authority.dig("operation", "operation_id"))
      authority_path = File.join(directory, "authority.json")
      publication_path = File.join(directory, "publication.json")
      existing = read_json(authority_path)
      publication = read_json(publication_path)
      check(existing == authority && exact_document?(authority_path, authority),
            "AUTHORITY_CONFLICT", "authority bytes, intent or immutable lineage changed")
      expected_publication = {"authority_id" => authority.fetch("authority_id")}
      check(publication == expected_publication && exact_document?(publication_path, expected_publication),
            "PARTIAL_PUBLICATION", "missing or conflicting publication proof")
      selection = verify_selection!(authority, selection_path, frozen_workload, workload_paths) if selection_path
      verify_workload!(authority, frozen_workload, workload_paths, selection:) if frozen_workload || workload_paths
      stable!(authority, observation, current_state_path, replay_observation:)
      check(read_json(authority_path) == existing && exact_document?(authority_path, existing) &&
            read_json(publication_path) == publication && exact_document?(publication_path, publication),
            "INPUT_RACE", "authority publication changed during validation")
      if selection_path
        check(verify_selection!(authority, selection_path, frozen_workload, workload_paths) == selection,
              "INPUT_RACE", "AFW selection changed during validation")
      end
      verify_workload!(authority, frozen_workload, workload_paths, selection:) if frozen_workload || workload_paths
      result = projection(authority, observation, frozen: !frozen_workload.nil?)
      if selection && selection["status"] == "ALL_DEFERRED"
        result.merge!("status" => "ALL_DEFERRED", "preparation_allowed" => false)
      end
      result
    rescue SystemCallError, JSON::ParserError, KeyError, TypeError, ArgumentError => e
      fail_with("INVALID_EVIDENCE", e.message)
    end

    private

    def candidate(current_state_path, replay_observation: nil)
      initial = evidence_snapshot
      # Process-local proof cache only. Every referenced byte is rehashed on
      # every call; cache entries are never accepted from a caller or disk.
      if @proof && initial == @proof[:inputs] && fingerprints(@proof[:paths]) == @proof[:extra]
        body = JSON.parse(JSON.generate(@proof[:body]))
        return [body, observe(body, @proof[:base], current_state_path, replay_observation:)]
      end
      intent = read_json(@paths.fetch(:intent_path))
      validate_intent!(intent)
      stage_options = @paths.slice(:freeze_path, :operation_input_path, :successor_authorization_path,
                                   :source_root, :catalog_root, :project_state_path)
      frozen_source = YAML.safe_load_file(@paths.fetch(:freeze_path), aliases: false).fetch("source")
      registry_path = BoundaryFreeze.source_file!(@paths.fetch(:source_root), frozen_source.fetch("registry_filename"))
      stage_options[:registry_path] = registry_path
      stage = BoundaryFreezeStage.verify!(**stage_options)
      receipt = stage.receipt
      operation = read_json(@paths.fetch(:operation_input_path))
      successor_authority = read_json(@paths.fetch(:successor_authorization_path)).fetch("authorization")
      check(intent.fetch("operation") == successor_authority.fetch("operation"),
            "INTENT_CONFLICT", "operation identity differs")
      base = File.join(@paths.fetch(:catalog_root), receipt.dig("base_amc", "filename"))
      check(intent.fetch("base_amc") == receipt.fetch("base_amc"), "BASE_REBIND", "original base identity differs")
      check(intent.fetch("source") == operation.fetch("source").except("canonical_markdown"),
            "INTENT_CONFLICT", "source declarations differ")
      approval = BoundaryEditorial.validate_approved_freeze!(
        **@paths.slice(:freeze_path, :approval_path, :bundle_dir, :dossier_path, :source_root), amc_path: base, registry_path:
      )
      policy = read_json(@paths.fetch(:policy_path))
      check(policy == POLICY, "UNSUPPORTED_POLICY", "unsupported scoring-input policy definition")
      expected_policy = POLICY.slice("policy_id", "policy_version").merge(self.class.file_binding(@paths.fetch(:policy_path)))
      check(intent.fetch("policy") == expected_policy, "INTENT_CONFLICT", "policy bytes/identity differ")
      if operation["policy"]
        check(operation.dig("policy", "policy_id") == expected_policy["policy_id"] &&
              operation.dig("policy", "policy_version") == expected_policy["policy_version"] &&
              operation.dig("policy", "definition_sha256") == expected_policy["sha256"],
              "INTENT_CONFLICT", "inert operation policy contradicts explicit intent")
      end
      _state, head, observation_binding = current_state(current_state_path, replay_observation:)
      if approval.record_count.zero?
        check(stage.status == "no_successor_needed" && receipt["successor"].nil?,
              "INVALID_EVIDENCE", "zero-record result has a successor")
        check(initial == evidence_snapshot, "INPUT_RACE", "evidence changed during validation")
        check(current_state(current_state_path, replay_observation:)[2] == observation_binding, "HEAD_RACE", "state changed during zero-result validation")
        return [nil, observation_binding]
      end
      check(stage.status == "verified_staged_successor", "INVALID_EVIDENCE", "no verified successor")
      planned = BoundaryFreezeApply.plan!(
        **@paths.slice(:freeze_path, :source_root), amc_path: base, publisher: intent.dig("source", "publisher"), registry_path:
      )
      report = read_json(stage.report_path)
      check(planned == report.slice("records", "changed_cells", "current_books"),
            "ALLOCATION_CONFLICT", "allocation or allowed mutations differ from exact base/freeze")
      plan = planned.fetch("records")
      check(report.fetch("source") == approval.artifact.fetch("source").merge("book_publisher" => intent.dig("source", "publisher")),
            "INVALID_EVIDENCE", "apply source provenance differs")
      observation = @concurrency.compare(
        base_path: base, head_path: head.path, records: plan,
        source_id: approval.artifact.dig("source", "canonical_source_id")
      ).merge("observation" => observation_binding)
      body = {
        "schema_version" => VERSION, "issuer" => "af-data-pipeline", "mode" => @mode,
        "operation" => intent.fetch("operation"), "intent" => intent,
        "permissions" => POLICY.fetch("permissions").dup,
        "base_amc" => receipt.fetch("base_amc"),
        "staged_amc" => receipt.fetch("successor").slice("filename", "sha256", "bytes"),
        "approval_id" => approval.approval_id,
        "allocation" => plan, "protected_ids" => observation["protected_ids"],
        "evidence" => initial.merge(
          "stage" => self.class.file_binding(stage.stage_path),
          "integrity" => self.class.file_binding(stage.report_path),
          "staged" => self.class.file_binding(stage.output_path)
        )
      }
      # Protected closure belongs to base/freeze identity, not observed head.
      # A malformed head may prevent comparison, but cannot change authority.
      base_proof = @concurrency.compare(base_path: base, head_path: base, records: plan,
                                                   source_id: intent.dig("source", "source_id"))
      check(base_proof["decision"] == "SAFE_REUSE", "INVALID_EVIDENCE", "base cannot establish protected closure")
      body["protected_ids"] = base_proof.fetch("protected_ids")
      check(initial == evidence_snapshot, "INPUT_RACE", "evidence changed during validation")
      check(current_state(current_state_path, replay_observation:)[2] == observation_binding, "HEAD_RACE", "shared state changed during observation")
      extra_paths = {"stage" => stage.stage_path, "integrity" => stage.report_path, "staged" => stage.output_path}
      historical = ProjectState.new(manifest_path: @paths[:project_state_path])
      historical.validate!
      ProjectState::ROLES.each { |role| extra_paths[role] = historical.resolve(role).path }
      check(read_json(stage.stage_path) == receipt, "INPUT_RACE", "staging receipt changed")
      check(self.class.file_binding(stage.output_path) == receipt.fetch("successor").slice("sha256", "bytes") &&
            self.class.file_binding(stage.report_path) == {"sha256" => receipt.dig("successor", "apply_report_sha256"), "bytes" => receipt.dig("successor", "apply_report_bytes")},
            "INPUT_RACE", "staged evidence changed")
      body["authority_id"] = self.class.digest(body)
      expected_extra = body.fetch("evidence").slice("stage", "integrity", "staged")
      ProjectState::ROLES.each do |role|
        entry = historical.resolve(role)
        expected_extra[role] = {"sha256" => entry.sha256, "bytes" => entry.bytes}
      end
      check(fingerprints(extra_paths) == expected_extra, "INPUT_RACE", "retained evidence changed")
      @proof = {inputs: initial, paths: extra_paths, extra: expected_extra,
                body: JSON.parse(JSON.generate(body)), base: base}
      [body, observation]
    rescue BoundaryFreezeStage::AllocationConflict => e
      fail_with("ALLOCATION_CONFLICT", e.message)
    rescue IngestNext::OperationInput::Error, Psych::Exception, KeyError, TypeError, ArgumentError, NoMethodError => e
      fail_with("INVALID_EVIDENCE", e.message)
    end

    def validate_intent!(intent)
      keys!(intent, %w[schema_version producer mode operation base_amc source policy selected_by selected_at
                       interaction purpose scope workload_id intent_id])
      check(intent["schema_version"] == INTENT_VERSION && intent["producer"] == "adventure-finder",
            "UNSUPPORTED_INTENT", "unsupported producer or intent schema")
      check(intent["mode"] == @mode, "INTENT_MODE_MISMATCH", "synthetic evidence is not production authority")
      check(intent["purpose"] == "prepare_staged_scoring" && intent["scope"] == POLICY["scope"],
            "MISSING_SCORING_INTENT", "explicit preparation intent required")
      check(%w[ingest_start post_boundary_resume].include?(intent["interaction"]),
            "MALFORMED_INTENT", "unknown intent-capture interaction")
      text!(intent["selected_by"])
      time = intent["selected_at"]
      check(time.is_a?(String) && Time.iso8601(time).utc.iso8601 == time, "MALFORMED_INTENT", "UTC selection timestamp required")
      keys!(intent["operation"], %w[contract_version operation_id created_at])
      check(intent["workload_id"].is_a?(String) && intent["workload_id"].match?(/\A[a-z0-9][a-z0-9_-]{0,63}\z/),
            "MALFORMED_INTENT", "stable AFW workload identity required")
      check(intent["intent_id"] == self.class.digest(intent.except("intent_id")), "INTENT_DIGEST_MISMATCH", "intent content changed")
      keys!(intent["source"], %w[source_id edition pagination_authority publisher])
      intent["source"].each_value { |value| text!(value) }
    end

    def evidence_snapshot
      files = @paths.except(:source_root, :catalog_root, :bundle_dir, :dossier_path)
      files[:dossier] = File.directory?(@paths[:dossier_path]) ? File.join(@paths[:dossier_path], "boundary_dossier.json") : @paths[:dossier_path]
      [BoundaryEditorial::CONTEXT_FILENAME, BoundaryEditorial::DECISIONS_FILENAME, BoundaryEditorial::REVIEW_FILENAME].each do |name|
        files[name] = File.join(@paths[:bundle_dir], name)
      end
      freeze = YAML.safe_load_file(@paths[:freeze_path], aliases: false)
      source = freeze.fetch("source")
      root = @paths.fetch(:source_root)
      files["source_registry"] = BoundaryFreeze.source_file!(root, source.fetch("registry_filename"))
      source.fetch("markdown_files").each do |ref|
        files["source:#{ref.fetch('filename')}"] = BoundaryFreeze.source_file!(root, ref.fetch("filename"))
      end
      files["base"] = File.join(@paths[:catalog_root], freeze.dig("base_amc", "filename"))
      files.to_h { |key, path| [key.to_s, self.class.file_binding(path)] }
    end

    def current_state(path, replay_observation: nil)
      state = replay_observation ? replay_observation.project_state(path) : ProjectState.new(manifest_path: path)
      state.validate!
      roles = ProjectState::ROLES.to_h do |role|
        r = state.resolve(role)
        [role, {"version" => r.version, "filename" => r.filename, "sha256" => r.sha256, "bytes" => r.bytes}]
      end
      [state, state.resolve("catalog_head"), {"manifest" => replay_observation ? replay_observation.file_binding(path) : self.class.file_binding(path), "roles" => roles}]
    end

    def stable!(authority, observation, current_state_path, replay_observation: nil)
      check(@proof && @proof[:body] == authority && evidence_snapshot == @proof[:inputs] &&
            fingerprints(@proof[:paths]) == @proof[:extra] &&
            current_state(current_state_path, replay_observation:)[2] == observation.fetch("observation"),
            "INPUT_RACE", "inputs changed across publication/validation")
    end

    def fingerprints(paths)
      paths.transform_values { |path| self.class.file_binding(path) }
    end

    def observe(authority, base, current_state_path, replay_observation: nil)
      _state, head, binding = current_state(current_state_path, replay_observation:)
      result = @concurrency.compare(
        base_path: base, head_path: head.path, records: authority.fetch("allocation"),
        source_id: authority.dig("intent", "source", "source_id")
      ).merge("observation" => binding)
      check(current_state(current_state_path, replay_observation:)[2] == binding, "HEAD_RACE", "head changed during comparison")
      result
    end

    # Explicit owner executable, never a caller-authored PASS projection or an
    # imported qualification policy. AFW independently re-derives dispositions
    # and validates actual frozen compiler artifacts against its current contract.
    def verify_selection!(authority, path, binding, paths)
      check(@selection_afw_root && @selection_scorer_root, "MISSING_SELECTION_OWNER", "explicit AFW and scorer roots required")
      executable = File.join(@selection_afw_root, "bin", "afw-staged-selection")
      check(File.executable?(executable), "MISSING_SELECTION_OWNER", "AFW public verifier missing")
      check(!binding || paths, "WORKLOAD_CONFLICT", "workload paths required")
      selected = read_json(path)
      before = self.class.file_binding(path)
      Tempfile.create(["pipeline-afw-authority", ".json"]) do |authority_file|
        authority_file.write(JSON.generate(authority)); authority_file.flush
        command = [executable, "verify", "--root", @selection_project_root || @selection_afw_root,
                   "--scorer-repo", @selection_scorer_root, "--authority", authority_file.path,
                   "--catalog", @proof[:paths].fetch("staged"), "--selection", File.expand_path(path)]
        command += ["--scorer-config", @selection_scorer_config] if @selection_scorer_config
        Tempfile.create(["pipeline-afw-binding", ".json"]) do |binding_file|
          Tempfile.create(["pipeline-afw-paths", ".json"]) do |paths_file|
            if binding || paths
              check(binding && paths, "WORKLOAD_CONFLICT", "complete frozen evidence required")
              binding_file.write(JSON.generate(binding)); binding_file.flush
              paths_file.write(JSON.generate(paths)); paths_file.flush
              command += ["--workload-binding", binding_file.path, "--workload-paths", paths_file.path]
            end
            stdout, stderr, status = selection_owner(command)
            check(status.success?, "INVALID_AFW_SELECTION", stderr.strip)
            verified = JSON.parse(stdout, object_class: UniqueObject)
            check(verified == selected && self.class.file_binding(path) == before,
                  "INVALID_AFW_SELECTION", "owner evidence or selection bytes changed")
          end
        end
      end
      check(selected["schema_version"] == "afw-staged-selection/v0.1" && selected["producer"] == "af-workloads" &&
            %w[SELECTED ALL_DEFERRED].include?(selected["status"]) &&
            selected["selection_id"] == self.class.digest(selected.except("selection_id")) &&
            selected["allocation"] == authority["allocation"] && selected["authority_id"] == authority["authority_id"] &&
            selected["operation"] == authority["operation"] && selected["base_amc"] == authority["base_amc"] &&
            selected["staged_amc"] == authority["staged_amc"] && selected["workload_id"] == authority.dig("intent", "workload_id"),
            "INVALID_AFW_SELECTION", "selection authority/allocation lineage differs")
      dispositions = selected.fetch("dispositions")
      check(dispositions.map { |d| d.fetch("adventure_id") } == authority.fetch("allocation").map { |r| r.fetch("adventure_id") } &&
            dispositions.all? { |d| %w[selected-qualified legitimately-deferred].include?(d["disposition"]) } &&
            selected["selected_ids"] == dispositions.select { |d| d["disposition"] == "selected-qualified" }.map { |d| d["adventure_id"] },
            "INVALID_AFW_SELECTION", "full disposition ledger differs")
      selected
    end

    def selection_owner(command)
      capture = -> { Open3.capture3(
        {"AF_CATALOG_WORKBOOK" => nil, "AF_CATALOG_ROLE" => nil, "AF_PROJECT_STATE" => nil}, *command
      ) }
      defined?(Bundler) ? Bundler.with_unbundled_env(&capture) : capture.call
    end

    def verify_workload!(authority, binding, paths, selection: nil)
      binding_keys = %w[schema_version authority_id operation_id workload_id staged_amc intended_ids artifacts]
      binding_keys << "selection_id" if selection
      keys!(binding, binding_keys)
      core = binding.except("artifacts")
      expected = {
        "schema_version" => selection ? "af-staged-scoring-workload-binding/v0.2" : WORKLOAD_VERSION, "authority_id" => authority.fetch("authority_id"),
        "operation_id" => authority.dig("operation", "operation_id"),
        "workload_id" => authority.dig("intent", "workload_id"),
        "staged_amc" => authority.fetch("staged_amc"),
        "intended_ids" => selection ? selection.fetch("selected_ids") : authority.fetch("allocation").map { |r| r.fetch("adventure_id") }
      }
      expected["selection_id"] = selection.fetch("selection_id") if selection
      check(core == expected, "WORKLOAD_CONFLICT", "frozen workload identity/input changed")
      keys!(paths, selection ? %w[plan snapshot index generated] : %w[plan snapshot index])
      keys!(binding["artifacts"], %w[plan snapshot index])
      paths.except("generated").each do |key, path|
        check(self.class.file_binding(path) == binding.dig("artifacts", key), "WORKLOAD_CONFLICT", "#{key} changed")
      end
      snapshot = YAML.safe_load_file(paths.fetch("snapshot"), aliases: false)
      check(snapshot["staged_scoring"] == core, "WORKLOAD_CONFLICT", "snapshot lacks authority binding")
    end

    def projection(authority, observation, frozen: false)
      {"schema_version" => PROJECTION_VERSION, "authority" => authority,
       "concurrency" => observation, "workload_frozen" => frozen,
       "preparation_allowed" => observation["decision"] == "SAFE_REUSE",
       "execution_authorized" => false, "catalog_adoption_authorized" => false}
    end

    def no_successor(observation)
      {"schema_version" => PROJECTION_VERSION, "status" => "NO_SUCCESSOR_NEEDED",
       "authority" => nil, "observation" => observation, "preparation_allowed" => false,
       "execution_authorized" => false, "catalog_adoption_authorized" => false}
    end

    def zero_result(observation)
      operation_id = read_json(@paths[:intent_path]).dig("operation", "operation_id")
      check(!File.exist?(File.join(@store_root, operation_id)), "AUTHORITY_CONFLICT", "zero result conflicts with existing authority")
      no_successor(observation)
    end

    def require_safe!(observation)
      check(observation["decision"] == "SAFE_REUSE", "STALE_INPUT", observation.fetch("reason"))
    end

    def publish(path, document)
      Tempfile.create([".authority-", ".json"], File.dirname(path)) do |tmp|
        tmp.write(self.class.document_bytes(document))
        tmp.flush
        tmp.fsync
        File.link(tmp.path, path)
      end
    end

    def exact_document?(path, document)
      File.binread(path) == self.class.document_bytes(document)
    end

    def read_json(path)
      JSON.parse(File.binread(path), object_class: UniqueObject)
    end

    def keys!(value, keys)
      check(value.is_a?(Hash) && value.keys.sort == keys.sort, "MALFORMED_EVIDENCE", "expected exactly #{keys.join(', ')}")
    end

    def text!(value)
      check(value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/),
            "MALFORMED_INTENT", "attributed nonblank source/selector required")
    end

    def check(condition, code, message)
      fail_with(code, message) unless condition
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
