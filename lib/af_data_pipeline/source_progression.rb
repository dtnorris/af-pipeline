# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "shellwords"
require "tempfile"
require "yaml"
require_relative "boundary_dossier"
require_relative "boundary_editorial"
require_relative "ingest_next"
require_relative "source_intake"
require_relative "private_data_root"

module AfDataPipeline
  # Copies accepted converter bytes to an explicitly supplied canonical path.
  # The destination is never inferred and an existing conflicting file is never
  # overwritten.
  class SourcePlacement
    Result = Data.define(:destination, :sha256, :bytes, :reused)

    def self.place!(receipt_path:, source_root:, destination:)
      new(receipt_path:, source_root:, destination:).place!
    end

    def initialize(receipt_path:, source_root:, destination:)
      @receipt_path = File.expand_path(receipt_path)
      @source_root = File.expand_path(source_root)
      @destination = File.expand_path(destination)
    end

    def place!
      receipt = load_receipt!
      source = File.expand_path(receipt.dig("output", "path").to_s)
      expected_sha = receipt.dig("output", "sha256").to_s
      raise ValidationError, "accepted converter output does not exist: #{source}" unless File.file?(source)
      verify_file!(source, expected_sha, "accepted converter output")
      validate_destination!

      if File.exist?(@destination)
        raise ValidationError, "canonical Markdown destination is not a file: #{@destination}" unless File.file?(@destination)
        verify_file!(@destination, expected_sha, "existing canonical Markdown destination")
        return Result.new(
          destination: @destination,
          sha256: expected_sha,
          bytes: File.size(@destination),
          reused: true
        )
      end

      parent = File.dirname(@destination)
      raise ValidationError, "canonical Markdown destination directory does not exist: #{parent}" unless File.directory?(parent)

      Tempfile.create([".canonical-markdown-", ".md"], parent) do |temp|
        temp.binmode
        File.open(source, "rb") { |input| IO.copy_stream(input, temp) }
        temp.flush
        temp.fsync
        verify_file!(temp.path, expected_sha, "staged canonical Markdown")
        begin
          File.link(temp.path, @destination)
        rescue Errno::EEXIST
          verify_file!(@destination, expected_sha, "concurrently placed canonical Markdown")
          return Result.new(
            destination: @destination,
            sha256: expected_sha,
            bytes: File.size(@destination),
            reused: true
          )
        end
      end

      Result.new(
        destination: @destination,
        sha256: expected_sha,
        bytes: File.size(@destination),
        reused: false
      )
    rescue JSON::ParserError => e
      raise ValidationError, "invalid conversion receipt JSON: #{e.message}"
    rescue SystemCallError => e
      raise ValidationError, "canonical Markdown placement failed: #{e.message}"
    end

    private

    def load_receipt!
      receipt = JSON.parse(File.binread(@receipt_path))
      unless receipt.is_a?(Hash) && receipt["schema"] == IngestNext::CONVERSION_RECEIPT_SCHEMA
        raise ValidationError, "unsupported conversion receipt schema"
      end
      state = receipt["state"].to_s
      unless receipt["downstream_ready"] == true && %w[ready ready_with_exceptions].include?(state)
        raise ValidationError,
              "conversion receipt is not downstream-ready (state=#{state.inspect}, " \
              "downstream_ready=#{receipt['downstream_ready'].inspect})"
      end
      sha = receipt.dig("output", "sha256").to_s
      unless /\A[0-9a-f]{64}\z/.match?(sha)
        raise ValidationError, "conversion receipt output.sha256 is invalid"
      end
      receipt
    end

    def validate_destination!
      PrivateDataRoot.external_store!(@source_root)
      raise ValidationError, "source root does not exist: #{@source_root}" unless File.directory?(@source_root)
      unless @destination.start_with?("#{@source_root}#{File::SEPARATOR}")
        raise ValidationError, "canonical Markdown destination escapes the configured source root"
      end
      unless File.extname(@destination).downcase == ".md"
        raise ValidationError, "canonical Markdown destination must end in .md"
      end
      if File.symlink?(@destination)
        raise ValidationError, "canonical Markdown destination must not be a symlink"
      end
      real_root = File.realpath(@source_root)
      parent = File.dirname(@destination)
      if File.directory?(parent) &&
         !File.realpath(parent).start_with?("#{real_root}#{File::SEPARATOR}") &&
         File.realpath(parent) != real_root
        raise ValidationError, "canonical Markdown destination escapes the source root through a symlink"
      end
    end

    def verify_file!(path, expected_sha, label)
      actual = Digest::SHA256.file(path).hexdigest
      return if actual == expected_sha

      raise ValidationError, "#{label} SHA-256 mismatch: expected #{expected_sha}, got #{actual}"
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr)
        options = {source_root: nil, destination: nil}
        OptionParser.new do |parser|
          parser.banner = "Usage: bin/af-source-place RECEIPT --source-root DIR --destination FILE.md"
          parser.on("--source-root DIR", "Canonical private Markdown corpus root") { |value| options[:source_root] = value }
          parser.on("--destination FILE", "Explicit operator-selected canonical Markdown path") { |value| options[:destination] = value }
        end.parse!(argv)
        receipt = argv.shift
        raise OptionParser::MissingArgument, "RECEIPT" unless receipt
        raise OptionParser::MissingArgument, "--source-root DIR" unless options[:source_root]
        raise OptionParser::MissingArgument, "--destination FILE" unless options[:destination]
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        result = SourcePlacement.place!(
          receipt_path: receipt,
          source_root: options.fetch(:source_root),
          destination: options.fetch(:destination)
        )
        out.puts(
          "Canonical Markdown placement: PASS\n" \
          "Destination: #{result.destination}\n" \
          "SHA-256: #{result.sha256}\n" \
          "Reused exact bytes: #{result.reused}"
        )
        0
      rescue OptionParser::ParseError, AfDataPipeline::Error => e
        err.puts "ERROR: #{e.message}"
        2
      end
    end
  end

  # Executes at most one operation-bound, deterministic source-side transition.
  # AdventureFinder remains responsible for binding the returned artifact and
  # supplying a fresh operation projection before another transition is run.
  class SourceProgression
    RESULT_SCHEMA = "af-source-progression-result/v0.1"
    ERROR_SCHEMA = "af-source-progression-error/v0.1"
    PIPELINE_ROOT_NAME = "pipeline"
    SOURCE_ROOT_NAME = "source"

    Result = Data.define(
      :status, :state, :transition, :operation, :input, :outputs,
      :evidence, :human_review, :reused
    )

    class Error < AfDataPipeline::Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def self.advance!(artifact_path:, operation_input_path:, source_root:, catalog_root:,
                      pipeline_root: nil, canonical_destination: nil,
                      registry_path: nil, executor: nil, spec_root: nil)
      new(
        artifact_path:, operation_input_path:, source_root:, catalog_root:,
        pipeline_root:, canonical_destination:, registry_path:, spec_root:,
        executor: executor || method(:execute)
      ).advance!
    rescue IngestNext::OperationInput::Error => e
      raise Error.new(e.code, e.message)
    rescue IngestNext::Error => e
      raise Error.new("INVALID_CONTINUATION_EVIDENCE", e.message)
    end

    def self.execute(argv, cwd)
      stdout, stderr, status = Open3.capture3(*argv, chdir: cwd)
      [status.exitstatus, stdout, stderr]
    rescue SystemCallError => e
      [127, "", e.message]
    end

    def initialize(artifact_path:, operation_input_path:, source_root:, catalog_root:,
                   pipeline_root:, canonical_destination:, registry_path:, executor:, spec_root: nil)
      @artifact_path = File.expand_path(artifact_path)
      @operation = IngestNext::OperationInput.load(operation_input_path)
      @source_root = File.expand_path(source_root)
      @catalog_root = File.expand_path(catalog_root)
      @pipeline_root = PrivateDataRoot.resolve(pipeline_root)
      PrivateDataRoot.destination!(File.join(@pipeline_root, "audits", "pre-scoring"))
      @canonical_destination = canonical_destination && File.expand_path(canonical_destination)
      @registry_path = registry_path && File.expand_path(registry_path)
      @spec_root = spec_root
      @executor = executor
      @router = IngestNext.new(
        source_root: @source_root,
        catalog_root: @catalog_root,
        spec_root: @spec_root,
        operation_input: @operation
      )
    end

    def advance!
      PrivateDataRoot.destination!(File.join(@pipeline_root, "audits", "pre-scoring"))
      route = @router.inspect(artifact_path: @artifact_path)
      case route.artifact_type
      when "conversion_receipt" then advance_conversion(route)
      when "source_intake" then advance_intake(route)
      when "boundary_dossier" then advance_dossier(route)
      else gate(route)
      end
    rescue IngestNext::OperationInput::Error => e
      raise Error.new(e.code, e.message)
    rescue ValidationError, IngestNext::Error => e
      raise Error.new("INVALID_CONTINUATION_EVIDENCE", e.message)
    rescue JSON::ParserError => e
      raise Error.new("INVALID_CONTINUATION_EVIDENCE", "invalid continuation JSON: #{e.message}")
    end

    private

    def advance_conversion(route)
      return gate(route) unless route.state == "NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
      return gate(route) unless @canonical_destination

      destination = canonical_destination!
      intake_dir = File.join(
        @pipeline_root,
        "audits",
        "pre-scoring",
        "#{slug(File.basename(destination, File.extname(destination)))}-source-intake"
      )
      json_path = File.join(intake_dir, SourceIntake::JSON_FILENAME)
      markdown_path = File.join(intake_dir, SourceIntake::MARKDOWN_FILENAME)
      reused = []

      if File.exist?(destination)
        SourcePlacement.place!(
          receipt_path: @artifact_path,
          source_root: @source_root,
          destination:
        )
        reused << "canonical_markdown"
      else
        run!(
          [
            File.join(IngestNext::REPO_ROOT, "bin", "af-source-place"),
            @artifact_path,
            "--source-root", @source_root,
            "--destination", destination
          ],
          "canonical Markdown placement"
        )
        unless File.file?(destination)
          fail!("INVALID_CONTINUATION_OUTPUT", "canonical Markdown placement passed but destination is missing")
        end
        SourcePlacement.place!(
          receipt_path: @artifact_path,
          source_root: @source_root,
          destination:
        )
      end

      existing = [json_path, markdown_path].select { |path| File.exist?(path) }
      if existing.length == 2
        reused << "source_intake"
      elsif existing.any?
        fail!("PARTIAL_CONTINUATION_OUTPUT", "partial source-intake publication exists: #{existing.join(', ')}")
      else
        argv = [
          File.join(IngestNext::REPO_ROOT, "bin", "af-source-intake"),
          destination,
          "--source-root", @source_root,
          "--output", intake_dir,
          "--conversion-receipt", @artifact_path
        ]
        argv.concat(["--registry", @registry_path]) if @registry_path
        run!(argv, "source intake")
      end

      report = validate_source_intake!(json_path, markdown_path, destination)
      pass(
        state: "SOURCE_INTAKE_READY",
        transition: "accepted_conversion_to_source_intake",
        artifact_type: route.artifact_type,
        outputs: [artifact_binding("source_intake", SourceIntake::SCHEMA_VERSION, json_path)],
        evidence: [
          "Accepted converter bytes placed at the explicit canonical destination.",
          "Source intake schema, conversion provenance, Markdown digest, and registry snapshot validated."
        ],
        reused: reused,
        extra_outputs: [root_binding(SOURCE_ROOT_NAME, destination), companion_binding(markdown_path)],
        report:
      )
    end

    def advance_intake(route)
      return gate(route) unless %w[READY_FOR_SOURCE_REGISTRATION READY_FOR_BOUNDARY_DOSSIER].include?(route.state)

      intake = JSON.parse(File.binread(@artifact_path))
      source_id = @operation.document.dig("source", "source_id")
      return gate_with(route, "NEEDS_SOURCE_IDENTITY", ["Bind an explicit canonical source identity in the operation."]) unless source_id

      markdown = source_markdown_path!(intake)
      validate_bound_intake!(intake, markdown, source_id)
      base = frozen_base_path!
      dossier_dir = dossier_output_dir(source_id)
      dossier_json = File.join(dossier_dir, BoundaryDossier::JSON_FILENAME)
      dossier_markdown = File.join(dossier_dir, BoundaryDossier::MARKDOWN_FILENAME)
      existing = [dossier_json, dossier_markdown].select { |path| File.exist?(path) }
      if existing.length == 2
        ensure_single_file_registration!(intake, source_id, markdown)
        dossier = validate_dossier!(dossier_json, dossier_markdown, source_id, base)
        return pass(
          state: "BOUNDARY_DOSSIER_READY",
          transition: "source_intake_to_boundary_dossier",
          artifact_type: route.artifact_type,
          outputs: [artifact_binding("boundary_dossier", dossier.fetch("schema_version"), dossier_json)],
          evidence: ["Exact existing dossier validated and reused."],
          reused: %w[source_registration boundary_dossier],
          extra_outputs: [companion_binding(dossier_markdown)],
          report: dossier
        )
      elsif existing.any?
        fail!("PARTIAL_CONTINUATION_OUTPUT", "partial boundary-dossier publication exists: #{existing.join(', ')}")
      end

      registration_reused = ensure_single_file_registration!(intake, source_id, markdown)
      argv = [
        File.join(IngestNext::REPO_ROOT, "bin", "af-boundary-dossier"),
        "--source-root", @source_root,
        "--source-id", source_id,
        "--amc", base,
        "--output", dossier_dir
      ]
      argv.concat(["--registry", @registry_path]) if @registry_path
      run!(argv, "boundary dossier")
      dossier = validate_dossier!(dossier_json, dossier_markdown, source_id, base)
      pass(
        state: "BOUNDARY_DOSSIER_READY",
        transition: "source_intake_to_boundary_dossier",
        artifact_type: route.artifact_type,
        outputs: [artifact_binding("boundary_dossier", dossier.fetch("schema_version"), dossier_json)],
        evidence: [
          "Explicit single-file source registration validated.",
          "Boundary dossier source, registry, canonical Markdown, and frozen base provenance validated."
        ],
        reused: registration_reused ? ["source_registration"] : [],
        extra_outputs: [companion_binding(dossier_markdown)],
        report: dossier
      )
    end

    # Validate source QA and replay existing exact bundles without changing
    # their selection. A new bundle requires the router's explicit selection;
    # missing selection returns its human gate before any initialization.
    def advance_dossier(route)
      return gate(route) unless %w[READY_FOR_EDITORIAL_HANDOFF NEEDS_EDITORIAL_SPECIFICATIONS].include?(route.state)

      dossier_path = resolve_dossier_path
      dossier = validate_dossier!(
        dossier_path,
        File.join(File.dirname(dossier_path), BoundaryDossier::MARKDOWN_FILENAME),
        @operation.document.dig("source", "source_id"),
        frozen_base_path!
      )
      qa_findings = dossier_qa_findings(dossier)
      unless qa_findings.empty?
        return gate_with(
          route,
          "NEEDS_SOURCE_QA_REVIEW",
          [
            "Resolve or explicitly review unknown/ambiguous page mappings and conversion-quality flags before deterministic editorial initialization.",
            *qa_findings
          ]
        )
      end

      source_id = dossier.dig("source", "canonical_source_id")
      bundle_dir = editorial_output_dir(source_id)
      paths = {
        context: File.join(bundle_dir, BoundaryEditorial::CONTEXT_FILENAME),
        decisions: File.join(bundle_dir, BoundaryEditorial::DECISIONS_FILENAME),
        review: File.join(bundle_dir, BoundaryEditorial::REVIEW_FILENAME)
      }
      existing = paths.values.select { |path| File.exist?(path) }
      reused = false
      if existing.length == paths.length
        reused = true
      elsif existing.any?
        fail!("PARTIAL_CONTINUATION_OUTPUT", "partial boundary-editorial publication exists: #{existing.join(', ')}")
      else
        return gate(route) if route.state == "NEEDS_EDITORIAL_SPECIFICATIONS"

        run!(
          [
            File.join(IngestNext::REPO_ROOT, "bin", "af-boundary-editorial"),
            "init",
            "--dossier", dossier_path,
            "--source-root", @source_root,
            "--output", bundle_dir,
            "--spec-root", @spec_root
          ],
          "boundary editorial initialization"
        )
      end

      validation = validate_editorial_bundle!(bundle_dir, dossier_path, dossier, newly_created: !reused)
      pass(
        state: "BOUNDARY_EDITORIAL_HANDOFF_READY",
        transition: "boundary_dossier_to_editorial_handoff",
        artifact_type: route.artifact_type,
        outputs: [
          artifact_binding("editorial_context", BoundaryEditorial::CONTEXT_SCHEMA_VERSION, paths.fetch(:context)),
          artifact_binding(
            "editorial_decisions",
            validation.decisions.fetch("schema_version"),
            paths.fetch(:decisions)
          )
        ],
        evidence: [
          "Editorial context is bound to the exact dossier, source, registry, Markdown, and frozen base.",
          "Editable decisions ledger is structurally valid and preserved."
        ],
        human_review: [
          "Stop for Phase 1, Phase 1b, Phase 2, and David approval; this PASS does not create candidates or approval."
        ],
        reused: reused ? ["editorial_bundle"] : [],
        extra_outputs: [companion_binding(paths.fetch(:review))],
        report: validation.context
      )
    end

    def ensure_single_file_registration!(intake, source_id, markdown)
      registry = BoundaryFreeze.registry_context(@source_root, @registry_path)
      sources = registry.fetch("sources")
      relative = BoundaryFreeze.relative_under_root!(@source_root, markdown, "Markdown source")
      entry = sources[source_id]
      if entry
        normalized = BoundaryFreeze.normalize_registry_entry(source_id, entry)
        if normalized[:segments] || normalized.fetch(:files) != [relative] || entry.key?("page_marker_offset")
          raise Error.new(
            "NEEDS_MANUAL_SOURCE_REGISTRATION",
            "existing source identity is not the exact supported unsegmented, offset-free single-file mapping"
          )
        end
        return true
      end

      conflicts = sources.filter_map do |existing_id, value|
        normalized = BoundaryFreeze.normalize_registry_entry(existing_id, value)
        existing_id if normalized.fetch(:files).include?(relative)
      end
      unless conflicts.empty?
        raise Error.new(
          "BLOCKED_SOURCE_IDENTITY",
          "canonical Markdown is already registered to #{conflicts.sort.join(', ')}"
        )
      end
      unless intake.dig("registry", "registration_status") == "unregistered"
        raise Error.new(
          "INVALID_CONTINUATION_EVIDENCE",
          "source intake registration status conflicts with the current source registry"
        )
      end

      argv = [
        File.join(IngestNext::REPO_ROOT, "bin", "af-source-register"),
        markdown,
        "--source-root", @source_root,
        "--source-id", source_id
      ]
      argv.concat(["--registry", @registry_path]) if @registry_path
      run!(argv, "source registration")

      refreshed = BoundaryFreeze.registry_context(@source_root, @registry_path)
      refreshed_entry = refreshed.fetch("sources").fetch(source_id)
      normalized = BoundaryFreeze.normalize_registry_entry(
        source_id,
        refreshed_entry
      )
      unless normalized.fetch(:files) == [relative] && normalized[:segments].nil? &&
             !refreshed_entry.key?("page_marker_offset")
        fail!("INVALID_CONTINUATION_OUTPUT", "source registration did not publish the exact single-file mapping")
      end
      false
    rescue KeyError
      fail!("INVALID_CONTINUATION_OUTPUT", "source registration exited successfully without the selected source identity")
    end

    def validate_source_intake!(json_path, markdown_path, canonical)
      require_complete_files!([json_path, markdown_path], "source intake")
      report = JSON.parse(File.binread(json_path))
      unless report["schema_version"] == SourceIntake::SCHEMA_VERSION
        fail!("INVALID_CONTINUATION_OUTPUT", "source intake has the wrong schema")
      end
      relative = BoundaryFreeze.relative_under_root!(@source_root, canonical, "canonical Markdown")
      expected_sha = Digest::SHA256.file(canonical).hexdigest
      unless File.expand_path(report.fetch("source_root")) == @source_root &&
             report.dig("markdown", "filename") == relative &&
             report.dig("markdown", "sha256") == expected_sha
        fail!("INVALID_CONTINUATION_OUTPUT", "source intake has the wrong canonical Markdown identity")
      end
      provenance = report.fetch("conversion_provenance")
      unless provenance["receipt_status"] == "verified" &&
             provenance["conversion_acceptance_verified"] == true &&
             provenance["receipt_sha256"] == Digest::SHA256.file(@artifact_path).hexdigest
        fail!("INVALID_CONTINUATION_OUTPUT", "source intake has invalid conversion provenance")
      end
      contract = report.fetch("contract")
      unless contract.values_at(
        "canonical_source_identity_inferred", "registry_mutated", "markdown_mutated"
      ) == [false, false, false]
        fail!("INVALID_CONTINUATION_OUTPUT", "source intake violates the no-inference/no-mutation contract")
      end
      validate_source_intake_markdown!(markdown_path, report)
      validate_intake_registry_snapshot!(report, relative)
      report
    rescue KeyError, JSON::ParserError => e
      fail!("INVALID_CONTINUATION_OUTPUT", "invalid source-intake output: #{e.message}")
    end

    def validate_dossier!(json_path, markdown_path, source_id, base)
      require_complete_files!([json_path, markdown_path], "boundary dossier")
      dossier = JSON.parse(File.binread(json_path))
      unless IngestNext::DOSSIER_SCHEMAS.include?(dossier["schema_version"])
        fail!("INVALID_CONTINUATION_OUTPUT", "boundary dossier has the wrong schema")
      end
      unless dossier.dig("source", "canonical_source_id") == source_id &&
             dossier.dig("base_amc", "filename") == File.basename(base) &&
             dossier.dig("base_amc", "sha256") == Digest::SHA256.file(base).hexdigest
        fail!("INVALID_CONTINUATION_OUTPUT", "boundary dossier has the wrong source/base identity")
      end
      registry = BoundaryFreeze.registry_context(@source_root, @registry_path)
      unless dossier.dig("source", "registry_sha256") == BoundaryFreeze.sha256(registry.fetch("path"))
        fail!("INVALID_CONTINUATION_OUTPUT", "boundary dossier registry provenance is stale")
      end
      Array(dossier.dig("source", "markdown_files")).each do |item|
        path = BoundaryFreeze.source_file!(@source_root, item.fetch("filename"))
        unless item.fetch("sha256") == Digest::SHA256.file(path).hexdigest
          fail!("INVALID_CONTINUATION_OUTPUT", "boundary dossier Markdown provenance is stale")
        end
      end
      validate_dossier_markdown!(markdown_path, dossier)
      dossier
    rescue KeyError, JSON::ParserError => e
      fail!("INVALID_CONTINUATION_OUTPUT", "invalid boundary-dossier output: #{e.message}")
    end

    def validate_editorial_bundle!(bundle_dir, dossier_path, dossier, newly_created:)
      validation = BoundaryEditorial.validate!(bundle_dir:, complete: false)
      context = validation.context
      expected_dossier = {
        "filename" => File.basename(dossier_path),
        "sha256" => Digest::SHA256.file(dossier_path).hexdigest,
        "schema_version" => dossier.fetch("schema_version")
      }
      unless context.fetch("dossier") == expected_dossier &&
             context.fetch("source") == dossier.fetch("source") &&
             context.fetch("base_amc") == dossier.fetch("base_amc")
        fail!("INVALID_CONTINUATION_OUTPUT", "editorial handoff has the wrong dossier/source/base identity")
      end
      if @spec_root && context["public_specifications"] != EditorialSpecifications.bind!(@spec_root)
        fail!("INVALID_CONTINUATION_EVIDENCE", "existing editorial bundle has incompatible public specifications")
      end
      review = File.join(bundle_dir, BoundaryEditorial::REVIEW_FILENAME)
      expected_review = BoundaryEditorial.send(:render_review, context)
      unless File.file?(review) && File.binread(review) == expected_review
        fail!("INVALID_CONTINUATION_OUTPUT", "editorial handoff review is missing or not the deterministic rendering")
      end
      if newly_created && !validation.decisions.fetch("candidates").empty?
        fail!("INVALID_CONTINUATION_OUTPUT", "editorial initialization created semantic candidates")
      end
      validation
    rescue KeyError => e
      fail!("INVALID_CONTINUATION_OUTPUT", "invalid editorial handoff output: #{e.message}")
    end

    def dossier_qa_findings(dossier)
      Array(dossier["source_files"]).flat_map do |file|
        filename = file.fetch("filename")
        navigation = file.fetch("navigation_evidence")
        mappings = navigation.fetch("page_mappings")
        unknown = mappings.count { |item| item.fetch("mapping_status") == "unknown" }
        ambiguous = mappings.count { |item| item.fetch("mapping_status") == "ambiguous" }
        quality = Array(file["quality_flags"]).length
        findings = []
        findings << "#{filename}: #{unknown} unknown PDF/printed-page mapping(s)" if unknown.positive?
        findings << "#{filename}: #{ambiguous} ambiguous PDF/printed-page mapping(s)" if ambiguous.positive?
        findings << "#{filename}: #{quality} conversion-quality flag(s)" if quality.positive?
        findings
      end
    rescue KeyError => e
      fail!("INVALID_CONTINUATION_EVIDENCE", "boundary dossier lacks source-QA evidence: #{e.message}")
    end

    def frozen_base_path!
      state_path = File.join(@catalog_root, "PROJECT_STATE.yml")
      state = YAML.safe_load_file(state_path, aliases: false)
      @operation.verify_live_catalog_head!(state)
      @operation.base_catalog_path!(@catalog_root)
    rescue Errno::ENOENT, Psych::Exception, KeyError, TypeError => e
      fail!("INVALID_CONTINUATION_EVIDENCE", "invalid project-state manifest: #{e.message}")
    end

    def validate_bound_intake!(intake, markdown, source_id)
      unless intake["schema_version"] == SourceIntake::SCHEMA_VERSION
        fail!("INVALID_CONTINUATION_EVIDENCE", "source intake has the wrong schema")
      end
      relative = BoundaryFreeze.relative_under_root!(@source_root, markdown, "canonical Markdown")
      contract = intake.fetch("contract")
      unless contract.values_at(
        "canonical_source_identity_inferred", "registry_mutated", "markdown_mutated"
      ) == [false, false, false]
        fail!("INVALID_CONTINUATION_EVIDENCE", "source intake violates the no-inference/no-mutation contract")
      end
      validate_intake_registry_snapshot!(intake, relative, progressing_source_id: source_id)
    rescue KeyError => e
      fail!("INVALID_CONTINUATION_EVIDENCE", "invalid source-intake evidence: #{e.message}")
    end

    def validate_intake_registry_snapshot!(report, relative, progressing_source_id: nil)
      registry = BoundaryFreeze.registry_context(@source_root, @registry_path)
      references = registry.fetch("sources").filter_map do |existing_id, entry|
        normalized = BoundaryFreeze.normalize_registry_entry(existing_id, entry)
        existing_id if normalized.fetch(:files).include?(relative)
      end.sort
      current_sha = BoundaryFreeze.sha256(registry.fetch("path"))
      recorded = report.fetch("registry")
      expected_status = references.empty? ? "unregistered" : references.length == 1 ? "registered" : "conflict_multiple_source_ids"
      exact_snapshot = recorded.fetch("sha256") == current_sha &&
                       recorded.fetch("registration_status") == expected_status &&
                       recorded.fetch("source_ids_referencing_file") == references
      return if exact_snapshot

      # A prior interrupted/replayed progression may already have performed this
      # exact append-only registration. It is the only supported stale snapshot.
      progression_registration = progressing_source_id &&
                                 recorded.fetch("registration_status") == "unregistered" &&
                                 recorded.fetch("source_ids_referencing_file") == [] &&
                                 references == [progressing_source_id]
      return if progression_registration

      fail!("INVALID_CONTINUATION_EVIDENCE", "source intake registry snapshot does not match the current registry")
    end

    def validate_source_intake_markdown!(path, report)
      text = File.binread(path)
      required = [
        "# AdventureFinder source intake",
        "No canonical source identity inferred",
        report.dig("markdown", "filename").to_s,
        report.dig("markdown", "sha256").to_s
      ]
      return if required.all? { |value| !value.empty? && text.include?(value) }

      fail!("INVALID_CONTINUATION_OUTPUT", "source intake Markdown companion is missing bound report evidence")
    end

    def validate_dossier_markdown!(path, dossier)
      text = File.binread(path)
      required = [
        "# AdventureFinder pre-Phase-1 boundary dossier",
        "No boundary decisions made",
        dossier.dig("source", "canonical_source_id").to_s,
        dossier.dig("source", "registry_sha256").to_s,
        dossier.dig("base_amc", "filename").to_s,
        dossier.dig("base_amc", "sha256").to_s
      ]
      return if required.all? { |value| !value.empty? && text.include?(value) }

      fail!("INVALID_CONTINUATION_OUTPUT", "boundary dossier Markdown companion is missing bound report evidence")
    end

    def source_markdown_path!(intake)
      filename = intake.dig("markdown", "filename").to_s
      path = File.expand_path(filename, @source_root)
      unless path.start_with?("#{@source_root}#{File::SEPARATOR}") && File.file?(path)
        fail!("INVALID_CONTINUATION_EVIDENCE", "source intake canonical Markdown is missing or unsafe")
      end
      expected = intake.dig("markdown", "sha256")
      unless Digest::SHA256.file(path).hexdigest == expected
        fail!("INVALID_CONTINUATION_EVIDENCE", "source intake canonical Markdown digest does not match")
      end
      path
    end

    def canonical_destination!
      unless @canonical_destination.start_with?("#{@source_root}#{File::SEPARATOR}") &&
             File.extname(@canonical_destination).downcase == ".md"
        fail!("UNSAFE_CANONICAL_DESTINATION", "canonical destination must be a .md path beneath the source root")
      end
      @canonical_destination
    end

    def resolve_dossier_path
      Dir.exist?(@artifact_path) ? File.join(@artifact_path, BoundaryDossier::JSON_FILENAME) : @artifact_path
    end

    def dossier_output_dir(source_id)
      File.join(@pipeline_root, "audits", "pre-scoring", "#{slug(source_id)}-boundary-dossier")
    end

    def editorial_output_dir(source_id)
      File.join(@pipeline_root, "audits", "pre-scoring", "#{slug(source_id)}-boundary-editorial")
    end

    def pass(state:, transition:, artifact_type:, outputs:, evidence:, reused:,
             extra_outputs:, report:, human_review: [])
      Result.new(
        status: "PASS",
        state:,
        transition:,
        operation: @operation.summary,
        input: input_binding(artifact_type),
        outputs: outputs + extra_outputs,
        evidence:,
        human_review:,
        reused:
      ).tap { validate_report_identity!(report) }
    end

    def gate(route)
      gate_with(route, route.state, route.human_review)
    end

    def gate_with(route, state, review)
      Result.new(
        status: state.start_with?("BLOCKED") ? "REFUSED" : "GATE",
        state:,
        transition: nil,
        operation: @operation.summary,
        input: input_binding(route.artifact_type),
        outputs: [],
        evidence: route.evidence,
        human_review: review,
        reused: []
      )
    end

    def input_binding(artifact_type)
      binding = @operation.document.fetch("artifact")
      {
        "artifact_type" => artifact_type,
        "binding" => binding,
        "validated" => true
      }
    end

    def artifact_binding(kind, contract_version, path)
      {
        "role" => "operation_artifact",
        "kind" => kind,
        "owner" => "af-data-pipeline",
        "contract_version" => contract_version,
        "content" => content_binding(PIPELINE_ROOT_NAME, @pipeline_root, path)
      }
    end

    def companion_binding(path)
      {
        "role" => "companion_evidence",
        "content" => content_binding(PIPELINE_ROOT_NAME, @pipeline_root, path)
      }
    end

    def root_binding(root_name, path)
      root = root_name == SOURCE_ROOT_NAME ? @source_root : @pipeline_root
      {
        "role" => "canonical_source",
        "content" => content_binding(root_name, root, path)
      }
    end

    def content_binding(root_name, root, path)
      expanded = File.expand_path(path)
      relative = Pathname(expanded).relative_path_from(Pathname(File.expand_path(root))).to_s
      if relative == ".." || relative.start_with?("..#{File::SEPARATOR}")
        fail!("INVALID_CONTINUATION_OUTPUT", "output escapes its declared component root")
      end
      {
        "sha256" => Digest::SHA256.file(expanded).hexdigest,
        "bytes" => File.size(expanded),
        "locator" => {"root" => root_name, "path" => relative}
      }
    end

    def run!(argv, label)
      status, stdout, stderr = @executor.call(argv, IngestNext::REPO_ROOT)
      return if status == 0

      detail = [stderr, stdout].map(&:to_s).map(&:strip).reject(&:empty?).join(" | ")
      detail = "no diagnostic output" if detail.empty?
      fail!("TRANSITION_COMMAND_FAILED", "#{label} exited #{status}: #{detail}")
    end

    def require_complete_files!(paths, label)
      missing = paths.reject { |path| File.file?(path) }
      return if missing.empty?

      fail!("INVALID_CONTINUATION_OUTPUT", "#{label} command passed but output is missing: #{missing.join(', ')}")
    end

    def validate_report_identity!(_report)
      true
    end

    def slug(value)
      text = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      text.empty? ? "source" : text
    end

    def fail!(code, message)
      raise Error.new(code, message)
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr, executor: nil)
        options = {
          operation_input: nil,
          source_root: nil,
          catalog_root: nil,
          pipeline_root: nil,
          canonical_destination: nil,
          registry: nil,
          json: false
        }
        OptionParser.new do |parser|
          parser.banner = "Usage: bin/af-source-progress ARTIFACT --operation-input FILE --source-root DIR --catalog-root DIR [options]"
          parser.on("--operation-input FILE", "AdventureFinder operation routing projection") { |value| options[:operation_input] = value }
          parser.on("--source-root DIR", "Canonical private Markdown corpus root") { |value| options[:source_root] = value }
          parser.on("--catalog-root DIR", "af-xlsx-data-sources root containing the frozen base") { |value| options[:catalog_root] = value }
          parser.on("--pipeline-root DIR", "Pipeline root receiving pre-scoring artifacts") { |value| options[:pipeline_root] = value }
          parser.on("--canonical-destination FILE", "Explicit destination for accepted converter bytes") { |value| options[:canonical_destination] = value }
          parser.on("--spec-root DIR", "Explicit absolute pinned public specification root") { |value| options[:spec_root] = value }
          parser.on("--registry FILE", "Explicit source registry path") { |value| options[:registry] = value }
          parser.on("--json", "Emit the versioned machine-readable result") { options[:json] = true }
        end.parse!(argv)
        artifact = argv.shift
        raise OptionParser::MissingArgument, "ARTIFACT" unless artifact
        raise OptionParser::MissingArgument, "--operation-input FILE" unless options[:operation_input]
        raise OptionParser::MissingArgument, "--source-root DIR" unless options[:source_root]
        raise OptionParser::MissingArgument, "--catalog-root DIR" unless options[:catalog_root]
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        result = SourceProgression.advance!(
          artifact_path: artifact,
          operation_input_path: options.fetch(:operation_input),
          source_root: options.fetch(:source_root),
          catalog_root: options.fetch(:catalog_root),
          pipeline_root: options.fetch(:pipeline_root),
          canonical_destination: options[:canonical_destination],
          registry_path: options[:registry],
          spec_root: options[:spec_root],
          executor:
        )
        if options[:json]
          out.puts JSON.pretty_generate(payload(result))
        else
          render(result, out)
        end
        result.status == "REFUSED" ? 2 : 0
      rescue Error => e
        if options && options[:json]
          err.puts JSON.pretty_generate(
            "schema_version" => ERROR_SCHEMA,
            "error" => {"code" => e.code, "message" => e.message}
          )
        else
          err.puts "ERROR [#{e.code}]: #{e.message}"
        end
        2
      rescue OptionParser::ParseError, AfDataPipeline::Error => e
        err.puts "ERROR: #{e.message}"
        2
      end

      def self.payload(result)
        {
          "schema_version" => RESULT_SCHEMA,
          "status" => result.status,
          "state" => result.state,
          "transition" => result.transition,
          "operation" => result.operation,
          "input" => result.input,
          "outputs" => result.outputs,
          "evidence" => result.evidence,
          "human_review" => result.human_review,
          "reused" => result.reused,
          "contract" => {
            "one_transition_maximum" => true,
            "operation_lifecycle_mutated" => false,
            "semantic_choices_created" => false,
            "catalog_roles_mutated" => false,
            "inference_or_scoring_executed" => false
          }
        }
      end

      def self.render(result, out)
        out.puts "SOURCE PROGRESSION: #{result.status}"
        out.puts "State: #{result.state}"
        out.puts "Transition: #{result.transition || 'none'}"
        out.puts "Operation: #{result.operation.fetch('operation_id')} revision #{result.operation.fetch('revision')}"
        result.outputs.each do |output|
          next unless output["role"] == "operation_artifact"

          content = output.fetch("content")
          out.puts "Operation artifact: #{output.fetch('kind')} #{content.dig('locator', 'path')} #{content.fetch('sha256')}"
        end
        result.human_review.each { |line| out.puts "Human gate: #{line}" }
        out.puts "Operation lifecycle mutated: false"
      end
    end
  end
end
