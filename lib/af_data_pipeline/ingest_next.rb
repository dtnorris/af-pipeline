# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "optparse"
require "open3"
require "pathname"
require "rexml/document"
require "rexml/xpath"
require "shellwords"
require "time"
require "yaml"
require "zip"
require_relative "amc_apply"
require_relative "boundary_editorial"
require_relative "boundary_freeze_apply"
require_relative "error"
require_relative "private_data_root"
require_relative "source_identity"

module AfDataPipeline
  # Read-only operator router for the new-book ingestion workflow.
  #
  # It does not mutate project state or infer editorial decisions. It inspects a
  # durable workflow artifact, reports the state reached, and renders the next
  # supported command when that command is deterministically knowable.
  class IngestNext
    class Error < StandardError; end

    Result = Data.define(
      :state,
      :artifact_type,
      :evidence,
      :human_review,
      :commands,
      :warnings
    )

    REPO_ROOT = File.expand_path("../..", __dir__)

    DEFAULT_SOURCE_ROOT = ENV["AF_SOURCE_DATA_ROOT"]
    DEFAULT_CATALOG_ROOT = ENV["AF_CATALOG_DATA_ROOT"]
    DEFAULT_AFW_ROOT = ENV["AF_AFW_ROOT"]
    DEFAULT_AFIO_ROOT = DEFAULT_AFW_ROOT # compatibility name; never selects the legacy HOLD checkout
    DEFAULT_SCORER_ROOT = ENV["AF_SCORER_ROOT"]
    DEFAULT_ADVENTURE_FINDER_ROOT = ENV["AF_ADVENTURE_FINDER_ROOT"]
    DEFAULT_PDF_CONVERTER_ROOT = ENV["AF_PDF_CONVERTER_ROOT"]

    CONVERSION_RECEIPT_SCHEMA = "pdf-to-llm-md/conversion-receipt/v0.1"
    SOURCE_INTAKE_SCHEMA = "af-source-intake/v0.1"
    DOSSIER_SCHEMAS = %w[af-boundary-dossier/v0.1 af-boundary-dossier/v0.2].freeze
    EDITORIAL_CONTEXT_SCHEMA = "af-boundary-editorial-context/v0.1"
    EDITORIAL_DECISIONS_SCHEMAS = %w[
      af-boundary-editorial-decisions/v0.1
      af-boundary-editorial-decisions/v0.2
    ].freeze
    FREEZE_SCHEMA = "af-boundary-freeze/v0.1"
    APPLY_REPORT_SCHEMA = "af-boundary-freeze-apply-report/v0.1"
    OPERATION_INPUT_SCHEMA = "af-ingest-routing-input/v0.1"
    OPERATION_RESULT_SCHEMA = "af-ingest-routing-result/v0.1"
    OPERATION_ERROR_SCHEMA = "af-ingest-routing-error/v0.1"
    INGEST_OPERATION_SCHEMA = "adventurefinder-ingest-operation/v0.1"

    # Current production scoring qualification and AFW target selection cover
    # canonical adventure units strictly under 100 printed pages.
    AFW_PAGE_LIMIT_EXCLUSIVE = 100
    AFW_DEFER_REASON = "outside proven <100-page scoring envelope"
    AFW_REQUIRED_CONTEXT_LENGTH = 131_072

    AUTO_ADVANCE_STATES = %w[
      READY_FOR_SOURCE_INTAKE
      READY_FOR_SOURCE_REGISTRATION
      READY_FOR_BOUNDARY_DOSSIER
      READY_FOR_EDITORIAL_HANDOFF
      READY_FOR_FREEZE_DRAFT
      READY_FOR_EDITORIAL_IMPORT
      READY_FOR_AMC_APPLICATION
    ].freeze

    # Narrow, immutable projection of the AdventureFinder-owned ingest
    # operation. It deliberately knows nothing about operation persistence or
    # lifecycle transitions.
    class OperationInput
      SHA256 = /\A[0-9a-f]{64}\z/
      UUID_V4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      SOURCE_KEYS = %w[source_id canonical_markdown edition pagination_authority publisher].freeze

      class Error < IngestNext::Error
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

      attr_reader :document, :path

      def self.load(path)
        expanded = File.expand_path(path.to_s)
        raw = File.binread(expanded)
        document = JSON.parse(raw)
        new(document, path: expanded)
      rescue Errno::ENOENT => e
        raise Error.new("MISSING_OPERATION_INPUT", e.message)
      rescue JSON::ParserError => e
        raise Error.new("MALFORMED_OPERATION_INPUT", "invalid JSON: #{e.message}")
      end

      def initialize(document, path: nil)
        @document = document
        @path = path
        validate!
      end

      def summary
        operation = document.fetch("operation")
        {
          "operation_id" => operation.fetch("operation_id"),
          "revision" => operation.fetch("revision"),
          "document_sha256" => operation.fetch("document_sha256"),
          "routing_input_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(document)))
        }
      end

      def verify_artifact!(artifact_path)
        binding = document.fetch("artifact")
        expanded = File.expand_path(artifact_path.to_s)
        case binding.fetch("kind")
        when "file"
          fail!("ARTIFACT_BINDING_MISMATCH", "operation input expects a file artifact") unless File.file?(expanded)
          verify_content!(expanded, binding.slice("sha256", "bytes"), "routing artifact")
        when "editorial_bundle"
          fail!("ARTIFACT_BINDING_MISMATCH", "operation input expects an editorial bundle") unless Dir.exist?(expanded)
          binding.fetch("members").each do |member|
            member_path = File.join(expanded, member.fetch("filename"))
            verify_content!(member_path, member.slice("sha256", "bytes"), "editorial bundle member")
          end
        end
        expanded
      end

      def resolve_choice!(key, independent, option:)
        bound = document.fetch("source").fetch(key)
        return bound unless independent

        if bound.nil?
          fail!("UNBOUND_INDEPENDENT_INPUT", "#{option} is not bound by the operation input")
        end
        unless independent == bound
          fail!("CONFLICTING_INPUT", "#{option} conflicts with the operation-bound #{key}")
        end
        bound
      end

      def resolve_canonical_markdown!(source_root, independent)
        binding = document.fetch("source").fetch("canonical_markdown")
        if independent && binding.nil?
          fail!(
            "UNBOUND_INDEPENDENT_INPUT",
            "--canonical-markdown is not bound by the operation input"
          )
        end
        return nil unless binding

        bound_path = resolve_relative!(source_root, binding.fetch("filename"), "canonical Markdown")
        if independent && File.expand_path(independent) != bound_path
          fail!("CONFLICTING_INPUT", "--canonical-markdown conflicts with the operation-bound location")
        end
        verify_content!(bound_path, binding.slice("sha256", "bytes"), "canonical Markdown")
      end

      def base_catalog_path!(catalog_root)
        binding = document.fetch("base_catalog")
        path = resolve_relative!(catalog_root, binding.fetch("filename"), "base catalog")
        verify_content!(path, binding.slice("sha256", "bytes"), "base catalog")
      end

      def verify_live_catalog_head!(project_state)
        head = project_state.fetch("catalog_head")
        base = document.fetch("base_catalog")
        return true if head["sha256"] == base["sha256"] &&
                       (!head["bytes"] || head["bytes"] == base["bytes"])

        fail!(
          "STALE_OPERATION_BASE",
          "current catalog_head does not match the operation's frozen base catalog"
        )
      end

      def verify_component_bindings!(artifact, source_root:)
        data = artifact[:data] || artifact[:context]
        return true unless data

        verify_source_binding!(artifact.fetch(:type), data, source_root:)
        verify_catalog_binding!(artifact.fetch(:type), data)
        verify_publisher_binding!(artifact.fetch(:type), data)
        true
      end

      def evidence
        source = document.fetch("source")
        operation = document.fetch("operation")
        lines = [
          "Operation routing input: #{operation.fetch('operation_id')} revision #{operation.fetch('revision')}"
        ]
        lines << "Edition declaration bound: #{source['edition']}" if source["edition"]
        if source["pagination_authority"]
          lines << "Pagination authority bound: #{source['pagination_authority']}"
        end
        if (policy = document["policy"])
          lines << "Policy bound for coordination only: #{policy.fetch('policy_id')}@#{policy.fetch('policy_version')}"
        end
        lines
      end

      private

      def validate!
        exact_keys!(document, %w[schema_version operation artifact source base_catalog policy], "document")
        unless document["schema_version"] == OPERATION_INPUT_SCHEMA
          fail!("UNSUPPORTED_VERSION", "unsupported operation routing input schema")
        end

        operation = document["operation"]
        exact_keys!(
          operation,
          %w[contract_version operation_id revision document_sha256],
          "operation"
        )
        unless operation["contract_version"] == INGEST_OPERATION_SCHEMA
          fail!("UNSUPPORTED_VERSION", "unsupported ingest operation contract")
        end
        fail!("MALFORMED_OPERATION_INPUT", "invalid operation_id") unless UUID_V4.match?(operation["operation_id"].to_s)
        unless operation["revision"].is_a?(Integer) && operation["revision"] >= 0
          fail!("MALFORMED_OPERATION_INPUT", "invalid operation revision")
        end
        sha!(operation["document_sha256"], "operation document")

        artifact = document["artifact"]
        exact_keys_for_artifact!(artifact)

        source = document["source"]
        exact_keys!(source, SOURCE_KEYS, "source")
        %w[source_id edition pagination_authority publisher].each do |key|
          text!(source[key], key) unless source[key].nil?
        end
        content!(source["canonical_markdown"], "canonical Markdown") if source["canonical_markdown"]

        base = document["base_catalog"]
        exact_keys!(
          base,
          %w[filename sha256 bytes selection_method project_state_sha256],
          "base_catalog"
        )
        content!(base.slice("filename", "sha256", "bytes"), "base catalog")
        unless %w[explicit catalog_head].include?(base["selection_method"])
          fail!("MALFORMED_OPERATION_INPUT", "invalid base catalog selection_method")
        end
        if base["selection_method"] == "catalog_head"
          sha!(base["project_state_sha256"], "project-state")
        elsif !base["project_state_sha256"].nil?
          fail!("MALFORMED_OPERATION_INPUT", "explicit base catalog has no project-state binding")
        end

        policy!(document["policy"]) if document["policy"]
      end

      def exact_keys_for_artifact!(artifact)
        fail!("MALFORMED_OPERATION_INPUT", "artifact must be an object") unless artifact.is_a?(Hash)
        case artifact["kind"]
        when "file"
          exact_keys!(artifact, %w[kind sha256 bytes], "artifact")
          sha!(artifact["sha256"], "artifact")
          bytes!(artifact["bytes"], "artifact")
        when "editorial_bundle"
          exact_keys!(artifact, %w[kind members], "artifact")
          members = artifact["members"]
          unless members.is_a?(Array) && members.length == 2
            fail!("MALFORMED_OPERATION_INPUT", "editorial bundle must bind exactly two members")
          end
          filenames = members.map do |member|
            exact_keys!(member, %w[filename sha256 bytes], "artifact member")
            content!(member, "artifact member")
            member["filename"]
          end
          unless filenames.sort == %w[editorial_context.json editorial_decisions.yml]
            fail!("MALFORMED_OPERATION_INPUT", "editorial bundle member set is invalid")
          end
        else
          fail!("MALFORMED_OPERATION_INPUT", "unsupported artifact binding kind")
        end
      end

      def policy!(policy)
        exact_keys!(
          policy,
          %w[policy_id policy_version definition_sha256 selected_values],
          "policy"
        )
        text!(policy["policy_id"], "policy_id")
        text!(policy["policy_version"], "policy_version")
        sha!(policy["definition_sha256"], "policy definition")
        unless policy["selected_values"].is_a?(Hash) && !policy["selected_values"].empty?
          fail!("MALFORMED_OPERATION_INPUT", "policy selected_values must be non-empty")
        end
        json_value!(policy["selected_values"])
      end

      def verify_source_binding!(type, data, source_root:)
        source_id = document.dig("source", "source_id")
        actual_source = case type
                        when :source_intake
                          refs = Array(data.dig("registry", "source_ids_referencing_file"))
                          refs.one? ? refs.first : nil
                        when :boundary_dossier then data.dig("source", "canonical_source_id")
                        when :editorial_bundle, :boundary_freeze, :boundary_apply_report
                          data.dig("source", "canonical_source_id")
                        end
        if source_id && actual_source && source_id != actual_source
          fail!("COMPONENT_ARTIFACT_CONFLICT", "component source identity conflicts with operation input")
        end

        markdown = document.dig("source", "canonical_markdown")
        return unless markdown

        case type
        when :conversion_receipt
          actual_sha = data.dig("output", "sha256")
          if actual_sha && actual_sha != markdown["sha256"]
            fail!("COMPONENT_ARTIFACT_CONFLICT", "conversion output conflicts with canonical Markdown binding")
          end
        when :source_intake
          report_root = data["source_root"].to_s.strip
          unless report_root.empty? || File.expand_path(report_root) == File.expand_path(source_root)
            fail!("COMPONENT_ARTIFACT_CONFLICT", "source intake root conflicts with configured source root")
          end
          actual = data["markdown"]
          unless actual && actual["filename"] == markdown["filename"] &&
                 actual["sha256"] == markdown["sha256"]
            fail!("COMPONENT_ARTIFACT_CONFLICT", "source intake conflicts with canonical Markdown binding")
          end
        when :boundary_dossier, :editorial_bundle, :boundary_freeze, :boundary_apply_report
          files = Array(data.dig("source", "markdown_files"))
          unless files.any? do |item|
            item["filename"] == markdown["filename"] && item["sha256"] == markdown["sha256"]
          end
            fail!("COMPONENT_ARTIFACT_CONFLICT", "component source provenance conflicts with canonical Markdown binding")
          end
        end
      end

      def verify_catalog_binding!(type, data)
        actual = case type
                 when :boundary_dossier, :editorial_bundle, :boundary_freeze, :boundary_apply_report
                   data["base_amc"]
                 end
        return unless actual

        base = document.fetch("base_catalog")
        actual_filename = actual["filename"] || File.basename(actual["path"].to_s)
        unless actual_filename == base["filename"] && actual["sha256"] == base["sha256"]
          fail!("COMPONENT_ARTIFACT_CONFLICT", "component base catalog conflicts with operation input")
        end
      end

      def verify_publisher_binding!(type, data)
        publisher = document.dig("source", "publisher")
        return unless publisher && type == :boundary_apply_report
        return if data.dig("source", "book_publisher") == publisher

        fail!("COMPONENT_ARTIFACT_CONFLICT", "component publisher conflicts with operation input")
      end

      def verify_content!(path, binding, label)
        fail!("MISSING_BOUND_ARTIFACT", "#{label} does not exist: #{path}") unless File.file?(path)
        unless File.size(path) == binding.fetch("bytes")
          fail!("DIGEST_MISMATCH", "#{label} byte-size mismatch: #{path}")
        end
        actual = Digest::SHA256.file(path).hexdigest
        return path if actual == binding.fetch("sha256")

        fail!("DIGEST_MISMATCH", "#{label} SHA-256 mismatch: #{path}")
      end

      def resolve_relative!(root, filename, label)
        expanded_root = File.expand_path(root)
        expanded = File.expand_path(filename, expanded_root)
        unless expanded.start_with?("#{expanded_root}#{File::SEPARATOR}")
          fail!("MALFORMED_OPERATION_INPUT", "#{label} escapes its configured root")
        end
        if File.exist?(expanded) && Dir.exist?(expanded_root)
          real_root = File.realpath(expanded_root)
          real_path = File.realpath(expanded)
          unless real_path.start_with?("#{real_root}#{File::SEPARATOR}")
            fail!("MALFORMED_OPERATION_INPUT", "#{label} escapes its configured root through a symlink")
          end
        end
        expanded
      end

      def content!(content, label)
        exact_keys!(content, %w[filename sha256 bytes], label)
        relative_path!(content["filename"], label)
        sha!(content["sha256"], label)
        bytes!(content["bytes"], label)
      end

      def relative_path!(value, label)
        text!(value, "#{label} filename")
        parts = value.split("/", -1)
        if value.start_with?("/") || value.include?("\\") || value.include?(":") ||
           parts.any? { |part| ["", ".", ".."].include?(part) }
          fail!("MALFORMED_OPERATION_INPUT", "unsafe #{label} filename")
        end
      end

      def sha!(value, label)
        return if SHA256.match?(value.to_s)

        fail!("MALFORMED_OPERATION_INPUT", "#{label} must be a lowercase SHA-256")
      end

      def bytes!(value, label)
        return if value.is_a?(Integer) && value.positive?

        fail!("MALFORMED_OPERATION_INPUT", "#{label} bytes must be positive")
      end

      def text!(value, label)
        return if value.is_a?(String) && !value.empty? && value == value.strip &&
                  !value.match?(/[[:cntrl:]]/)

        fail!("MALFORMED_OPERATION_INPUT", "#{label} must be nonempty trimmed text")
      end

      def exact_keys!(value, expected, label)
        unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) } &&
               value.keys.sort == expected.sort
          fail!("MALFORMED_OPERATION_INPUT", "#{label} must contain exactly #{expected.join(', ')}")
        end
      end

      def json_value!(value)
        case value
        when Hash
          value.each do |key, item|
            text!(key, "policy key")
            json_value!(item)
          end
        when Array
          value.each { |item| json_value!(item) }
        when String, Integer, TrueClass, FalseClass, NilClass
          nil
        when Float
          fail!("MALFORMED_OPERATION_INPUT", "policy value must be finite") unless value.finite?
        else
          fail!("MALFORMED_OPERATION_INPUT", "policy selected_values must be JSON")
        end
      end

      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end

      def fail!(code, message)
        raise Error.new(code, message)
      end
    end

    attr_reader :operation_input, :spec_root

    # Return an explicitly selected route root. An unconfigured dependency raises
    # Error only when the route needs it.
    {
      source_root: "--source-root", catalog_root: "--catalog-root", afw_root: "--afw-root",
      scorer_root: "--scorer-repo", adventure_finder_root: "--adventure-finder-root",
      pdf_converter_root: "--pdf-converter-root"
    }.each do |name, option|
      define_method(name) do
        instance_variable_get(:"@#{name}") || raise(Error, "select #{option} explicitly")
      end
    end
    alias afio_root afw_root

    def initialize(
      source_root: DEFAULT_SOURCE_ROOT,
      catalog_root: DEFAULT_CATALOG_ROOT,
      afw_root: nil,
      afio_root: nil,
      scorer_root: DEFAULT_SCORER_ROOT,
      scorer_config: nil,
      adventure_finder_root: DEFAULT_ADVENTURE_FINDER_ROOT,
      pdf_converter_root: DEFAULT_PDF_CONVERTER_ROOT,
      operation_input: nil,
      spec_root: nil
    )
      @data_root = PrivateDataRoot.resolve
      PrivateDataRoot.destination!(File.join(@data_root, "audits", "pre-scoring"))
      @spec_root = spec_root
      @source_root = File.expand_path(source_root) if source_root
      @catalog_root = File.expand_path(catalog_root) if catalog_root
      if afw_root && afio_root && File.expand_path(afw_root) != File.expand_path(afio_root)
        raise Error, "--afw-root and legacy --afio-root must not select different checkouts"
      end
      afw_selection = afw_root || afio_root || DEFAULT_AFW_ROOT
      @afw_root = File.expand_path(afw_selection) if afw_selection
      @scorer_root = File.expand_path(scorer_root) if scorer_root
      @scorer_config = scorer_config && File.expand_path(scorer_config)
      @adventure_finder_root = File.expand_path(adventure_finder_root) if adventure_finder_root
      @pdf_converter_root = File.expand_path(pdf_converter_root) if pdf_converter_root
      @operation_input = if operation_input.is_a?(OperationInput)
                           operation_input
                         elsif operation_input
                           OperationInput.load(operation_input)
                         end
    end

    def inspect(
      artifact_path:,
      source_id: nil,
      canonical_markdown: nil,
      publisher: nil,
      successor_version: nil,
      approval_path: nil,
      approved_by: nil,
      approved_at: nil,
      batch: nil
    )
      if approved_by || approved_at
        raise Error,
              "legacy loose --approved-by/--approved-at values cannot authorize import; use a bound approval record"
      end
      if operation_input
        operation_input.verify_artifact!(artifact_path)
        source_id = operation_input.resolve_choice!("source_id", source_id, option: "--source-id")
        publisher = operation_input.resolve_choice!("publisher", publisher, option: "--publisher")
        canonical_markdown = operation_input.resolve_canonical_markdown!(
          source_root,
          canonical_markdown
        )
      end
      artifact = resolve_artifact(artifact_path)
      operation_input&.verify_component_bindings!(artifact, source_root:)

      result = case artifact.fetch(:type)
      when :conversion_receipt
        conversion_receipt_result(
          artifact,
          canonical_markdown:
        )
      when :source_intake
        source_intake_result(artifact, source_id:)
      when :boundary_dossier
        boundary_dossier_result(artifact)
      when :editorial_bundle
        editorial_bundle_result(
          artifact,
          approval_path:
        )
      when :boundary_freeze
        boundary_freeze_result(
          artifact,
          publisher:,
          successor_version:
        )
      when :boundary_apply_report
        boundary_apply_report_result(artifact, batch:)
      else
        raise Error, "Unsupported ingestion artifact: #{artifact_path}"
      end
      return result unless operation_input

      Result.new(
        state: result.state,
        artifact_type: result.artifact_type,
        evidence: operation_input.evidence + result.evidence,
        human_review: result.human_review,
        commands: result.commands,
        warnings: result.warnings
      )
    end

    private

    def resolve_artifact(path)
      expanded = File.expand_path(path.to_s)
      if Dir.exist?(expanded)
        context = File.join(expanded, "editorial_context.json")
        decisions = File.join(expanded, "editorial_decisions.yml")
        dossier = File.join(expanded, "boundary_dossier.json")

        if File.file?(context) && File.file?(decisions)
          return {
            type: :editorial_bundle,
            path: expanded,
            context_path: context,
            decisions_path: decisions,
            context: load_json(context),
            decisions: load_yaml(decisions)
          }
        end

        if File.file?(dossier)
          data = load_json(dossier)
          validate_schema!(data["schema_version"], DOSSIER_SCHEMAS, dossier)
          return {type: :boundary_dossier, path: dossier, data:}
        end

        raise Error, "Directory is not a recognized ingestion artifact: #{expanded}"
      end

      raise Error, "Ingestion artifact does not exist: #{expanded}" unless File.file?(expanded)

      if File.extname(expanded).downcase == ".json"
        data = load_json(expanded)
        schema = data["schema"] || data["schema_version"]
        case schema
        when CONVERSION_RECEIPT_SCHEMA
          {type: :conversion_receipt, path: expanded, data:}
        when SOURCE_INTAKE_SCHEMA
          {type: :source_intake, path: expanded, data:}
        when *DOSSIER_SCHEMAS
          {type: :boundary_dossier, path: expanded, data:}
        when APPLY_REPORT_SCHEMA
          {type: :boundary_apply_report, path: expanded, data:}
        else
          raise Error, "Unsupported JSON ingestion schema #{schema.inspect}: #{expanded}"
        end
      else
        data = load_yaml(expanded)
        validate_schema!(data["schema_version"], [FREEZE_SCHEMA], expanded)
        {type: :boundary_freeze, path: expanded, data:}
      end
    end

    def conversion_receipt_result(artifact, canonical_markdown:)
      receipt = artifact.fetch(:data)
      state = receipt.fetch("state", "").to_s
      output = receipt.fetch("output", {})
      output_path = output["path"]

      unless receipt["downstream_ready"] == true && %w[ready ready_with_exceptions].include?(state)
        if state == "needs_page_review"
          page = unresolved_issue_pages(receipt).first
          resume_command = catalog_front_door_command(receipt)
          commands = []
          if page && @pdf_converter_root
            commands << command(
              pdf_converter_root,
              File.join(pdf_converter_root, "bin", "review-page-exception"),
              artifact.fetch(:path),
              "--page",
              page.to_s
            )
          end
          commands << resume_command if resume_command
          return Result.new(
            state: "NEEDS_PAGE_REVIEW",
            artifact_type: "conversion_receipt",
            evidence: [
              "Receipt state: #{state}",
              "Markdown retained: #{output_path || 'unknown'}",
              "Downstream ready: false"
            ],
            human_review: [
              "Inspect each flagged PDF page against the generated Markdown before accepting an exception.",
              "Resolve every flagged page until the conversion reaches READY.",
              if resume_command
                "Then use the final command below to return to the AdventureFinder catalog front door; do not manually advance downstream ingestion."
              end
            ].compact,
            commands:,
            warnings: []
          )
        end

        return Result.new(
          state: "BLOCKED_CONVERSION",
          artifact_type: "conversion_receipt",
          evidence: [
            "Receipt state: #{state.empty? ? 'unknown' : state}",
            "Downstream ready: #{receipt['downstream_ready'].inspect}"
          ],
          human_review: [],
          commands: [],
          warnings: ["Resolve conversion/structural validation before downstream intake."]
        )
      end

      unless canonical_markdown
        resume = command(
          REPO_ROOT,
          File.join(REPO_ROOT, "bin", "af-ingest-next"),
          artifact.fetch(:path),
          "--canonical-markdown",
          "PATH"
        )
        resume_instruction =
          "Resume command after canonical Markdown placement: " \
          "cd #{Shellwords.escape(resume.fetch('cwd'))} && #{resume.fetch('command')}"

        return Result.new(
          state: "NEEDS_CANONICAL_MARKDOWN_PLACEMENT",
          artifact_type: "conversion_receipt",
          evidence: [
            "Receipt state: #{state}",
            "Accepted converter output: #{output_path || 'unknown'}",
            "Output SHA-256: #{output['sha256'] || 'unknown'}"
          ],
          human_review: [
            "Choose the stable canonical private-corpus filename/edition placement.",
            "Copy or place the accepted converter output there unchanged.",
            resume_instruction
          ],
          commands: [],
          warnings: []
        )
      end

      canonical = File.expand_path(canonical_markdown)
      unless File.file?(canonical)
        raise Error, "--canonical-markdown does not exist: #{canonical}"
      end
      expected_sha = output["sha256"].to_s
      actual_sha = Digest::SHA256.file(canonical).hexdigest
      unless expected_sha == actual_sha
        raise Error,
              "canonical Markdown SHA-256 does not match conversion receipt output: " \
              "expected #{expected_sha}, got #{actual_sha}"
      end

      intake_dir = File.join(
        @data_root,
        "audits",
        "pre-scoring",
        "#{slug(File.basename(canonical, File.extname(canonical)))}-source-intake"
      )

      Result.new(
        state: "READY_FOR_SOURCE_INTAKE",
        artifact_type: "conversion_receipt",
        evidence: [
          "Receipt state: #{state}",
          "Canonical Markdown: #{canonical}",
          "Markdown SHA-256 verified against receipt."
        ],
        human_review: [],
        commands: [
          command(
            REPO_ROOT,
            File.join(REPO_ROOT, "bin", "af-source-intake"),
            canonical,
            "--source-root",
            source_root,
            "--output",
            intake_dir,
            "--conversion-receipt",
            artifact.fetch(:path),
            auto_artifact: File.join(intake_dir, "source_intake.json")
          )
        ],
        warnings: []
      )
    end

    def source_intake_result(artifact, source_id:)
      report = artifact.fetch(:data)
      registry = report.fetch("registry")
      status = registry.fetch("registration_status")
      markdown_relative = report.dig("markdown", "filename")
      root = report["source_root"].to_s.strip
      root = source_root if root.empty?
      markdown = File.expand_path(markdown_relative.to_s, root)

      case status
      when "conflict_multiple_source_ids"
        return Result.new(
          state: "BLOCKED_SOURCE_IDENTITY",
          artifact_type: "source_intake",
          evidence: [
            "Markdown: #{markdown}",
            "Registry references: #{registry.fetch('source_ids_referencing_file').join(', ')}"
          ],
          human_review: ["Resolve the conflicting canonical source identities before boundary work."],
          commands: [],
          warnings: []
        )
      when "unregistered"
        unless source_id
          resume = command(
            REPO_ROOT,
            File.join(REPO_ROOT, "bin", "af-ingest-next"),
            artifact.fetch(:path),
            "--source-id",
            "Exact Canonical Source Identity"
          )
          resume_instruction =
            "Resume command after choosing the canonical source identity: " \
            "cd #{Shellwords.escape(resume.fetch('cwd'))} && #{resume.fetch('command')}"

          return Result.new(
            state: "NEEDS_SOURCE_IDENTITY",
            artifact_type: "source_intake",
            evidence: [
              "Markdown: #{markdown}",
              "Registry status: unregistered"
            ],
            human_review: [
              "Choose the exact human-readable canonical source identity (normally the publication/source title).",
              "Do not use the Markdown filename or a filesystem path as the source identity.",
              resume_instruction
            ],
            commands: [],
            warnings: conversion_warning(report)
          )
        end

        source_id = SourceIdentity.validate!(source_id, error_class: Error)
        dossier_dir = dossier_output_dir(source_id)
        routing_catalog = source_routing_catalog_path
        return Result.new(
          state: "READY_FOR_SOURCE_REGISTRATION",
          artifact_type: "source_intake",
          evidence: [
            "Markdown: #{markdown}",
            "Registry status: unregistered",
            "Selected source identity: #{source_id}"
          ],
          human_review: [],
          commands: [
            command(
              REPO_ROOT,
              File.join(REPO_ROOT, "bin", "af-source-register"),
              markdown,
              "--source-root",
              root,
              "--source-id",
              source_id,
              "--next-amc",
              routing_catalog,
              "--next-output",
              dossier_dir
            ),
            command(
              REPO_ROOT,
              File.join(REPO_ROOT, "bin", "af-boundary-dossier"),
              "--source-root",
              root,
              "--source-id",
              source_id,
              "--amc",
              routing_catalog,
              "--output",
              dossier_dir,
              auto_artifact: dossier_dir
            )
          ],
          warnings: conversion_warning(report)
        )
      when "registered"
        refs = registry.fetch("source_ids_referencing_file")
        unless refs.length == 1
          raise Error, "registered source intake must resolve to exactly one source ID"
        end
        canonical_source_id = refs.first
        routing_catalog = source_routing_catalog_path
        return Result.new(
          state: "READY_FOR_BOUNDARY_DOSSIER",
          artifact_type: "source_intake",
          evidence: [
            "Markdown: #{markdown}",
            "Canonical source identity: #{canonical_source_id}",
            if operation_input
              "Frozen operation base: #{File.basename(routing_catalog)}"
            else
              "Catalog head: #{File.basename(routing_catalog)}"
            end
          ],
          human_review: [],
          commands: [
            command(
              REPO_ROOT,
              File.join(REPO_ROOT, "bin", "af-boundary-dossier"),
              "--source-root",
              root,
              "--source-id",
              canonical_source_id,
              "--amc",
              routing_catalog,
              "--output",
              dossier_output_dir(canonical_source_id),
              auto_artifact: dossier_output_dir(canonical_source_id)
            )
          ],
          warnings: conversion_warning(report)
        )
      else
        raise Error, "Unsupported source-intake registry status #{status.inspect}"
      end
    end

    # Route a dossier to a new explicitly bound bundle. Without a selection,
    # return a human gate and an initializer template; invalid selected bytes
    # raise ValidationError before a command or bundle can be published.
    def boundary_dossier_result(artifact)
      dossier = artifact.fetch(:data)
      source_id = dossier.dig("source", "canonical_source_id")
      raise Error, "boundary dossier has no canonical source identity" if source_id.to_s.strip.empty?

      output = editorial_output_dir(source_id)
      selection = EditorialSpecifications.bind!(spec_root) if spec_root
      initializer = command(
        REPO_ROOT,
        File.join(REPO_ROOT, "bin", "af-boundary-editorial"),
        "init",
        "--dossier", artifact.fetch(:path),
        "--source-root", source_root,
        "--output", output,
        "--spec-root", selection ? selection.fetch("root") : "ABSOLUTE_PUBLIC_DIR",
        auto_artifact: output
      )
      evidence = [
        "Source: #{source_id}",
        "Base AMC: #{dossier.dig('base_amc', 'filename')}",
        "Dossier: #{artifact.fetch(:path)}"
      ]
      unless selection
        return Result.new(
          state: "NEEDS_EDITORIAL_SPECIFICATIONS",
          artifact_type: "boundary_dossier",
          evidence:,
          human_review: [
            "Select an absolute public specification root containing the pinned inventory, Editorial Rev 2.0 (Draft) and ABDS 1.4.",
            "Rerun bin/af-ingest-next for this dossier with --spec-root ABSOLUTE_PUBLIC_DIR (and --auto to initialize), or replace ABSOLUTE_PUBLIC_DIR in this explicit initializer:",
            "cd #{Shellwords.escape(initializer.fetch('cwd'))} && #{initializer.fetch('command')}"
          ],
          commands: [],
          warnings: []
        )
      end

      Result.new(
        state: "READY_FOR_EDITORIAL_HANDOFF",
        artifact_type: "boundary_dossier",
        evidence: evidence + EditorialSpecifications.lines(selection),
        human_review: [
          "Phase 1 / Phase 1b / Phase 2 remain human/frontier editorial work inside the generated decision ledger."
        ],
        commands: [initializer],
        warnings: []
      )
    end

    def editorial_bundle_result(artifact, approval_path:)
      context = artifact.fetch(:context)
      decisions = artifact.fetch(:decisions)
      # A forward handoff must remain bound even while its ledger is empty or
      # pending. Historical routing retains its original inspection contract.
      BoundaryEditorial.validate_context!(context) if context.key?("public_specifications")
      validate_schema!(
        context["schema_version"],
        [EDITORIAL_CONTEXT_SCHEMA],
        artifact.fetch(:context_path)
      )
      validate_schema!(
        decisions["schema_version"],
        EDITORIAL_DECISIONS_SCHEMAS,
        artifact.fetch(:decisions_path)
      )

      candidates = Array(decisions["candidates"])
      counts = candidates.map { |item| item["disposition"].to_s }.tally
      pending = counts.fetch("pending", 0)
      held = counts.fetch("hold", 0)
      source_id = context.dig("source", "canonical_source_id")

      if candidates.empty?
        resume = command(
          REPO_ROOT,
          File.join(REPO_ROOT, "bin", "af-ingest-next"),
          artifact.fetch(:path)
        )
        resume_instruction =
          "Resume command after the reviewed ledger is saved: " \
          "cd #{Shellwords.escape(resume.fetch('cwd'))} && #{resume.fetch('command')}"

        return Result.new(
          state: "NEEDS_FRONTIER_EDITORIAL_REVIEW",
          artifact_type: "editorial_bundle",
          evidence: [
            "Source: #{source_id}",
            "Candidates: 0",
            "Editorial review: #{File.join(artifact.fetch(:path), 'editorial_review.md')}",
            "Decision ledger: #{artifact.fetch(:decisions_path)}"
          ],
          human_review: [
            "The editorial decision ledger has not been populated.",
            "Complete the frontier ChatGPT handoff in editorial_review.md before continuing.",
            resume_instruction
          ],
          commands: [],
          warnings: []
        )
      end

      dossier = bound_dossier_path(artifact, context)
      base_amc = bound_amc_path(context)

      if pending.positive? || held.positive?
        return Result.new(
          state: "NEEDS_EDITORIAL_REVIEW",
          artifact_type: "editorial_bundle",
          evidence: [
            "Source: #{source_id}",
            "Candidates: #{candidates.length}",
            "Accepted: #{counts.fetch('accept', 0)}",
            "Rejected: #{counts.fetch('reject', 0)}",
            "Merged: #{counts.fetch('merge', 0)}",
            "Split: #{counts.fetch('split', 0)}",
            "Held: #{held}",
            "Pending: #{pending}"
          ],
          human_review: [
            "Edit #{artifact.fetch(:decisions_path)} and resolve every pending/held candidate while preserving explicit dispositions and review history.",
            "Then run the complete-validation command below. It fails closed until the ledger is importable and prints the exact af-ingest-next resume command when complete."
          ],
          commands: [
            command(
              REPO_ROOT,
              File.join(REPO_ROOT, "bin", "af-boundary-editorial"),
              "validate",
              artifact.fetch(:path),
              "--complete"
            )
          ],
          warnings: []
        )
      end

      preferred_draft_freeze = freeze_draft_path(source_id)
      preferred_frozen_freeze = freeze_final_path(source_id)
      draft_freeze = freeze_path_for_context(
        preferred_draft_freeze,
        context,
        expected_state: "draft"
      )
      frozen_freeze = freeze_path_for_context(
        preferred_frozen_freeze,
        context,
        expected_state: "frozen"
      )
      freeze_warnings = freeze_path_warnings(
        preferred_draft: preferred_draft_freeze,
        draft: draft_freeze,
        preferred_final: preferred_frozen_freeze,
        final: frozen_freeze
      )

      unless File.file?(draft_freeze)
        return Result.new(
          state: "READY_FOR_FREEZE_DRAFT",
          artifact_type: "editorial_bundle",
          evidence: [
            "Source: #{source_id}",
            "Editorial decisions complete: true",
            "Accepted: #{counts.fetch('accept', 0)}",
            "Rejected: #{counts.fetch('reject', 0)}",
            "Merged: #{counts.fetch('merge', 0)}",
            "Split: #{counts.fetch('split', 0)}"
          ],
          human_review: [],
          commands: [
            command(
              REPO_ROOT,
              File.join(REPO_ROOT, "bin", "af-boundary-editorial"),
              "validate",
              artifact.fetch(:path),
              "--complete"
            ),
            command(
              REPO_ROOT,
              File.join(REPO_ROOT, "bin", "af-data"),
              "boundary-freeze-init",
              "--source-root",
              source_root,
              "--source-id",
              source_id,
              "--amc",
              base_amc,
              "--output",
              draft_freeze,
              auto_artifact: artifact.fetch(:path),
              auto_require: draft_freeze
            )
          ],
          warnings: freeze_warnings
        )
      end

      approval_path ||= File.join(artifact.fetch(:path), BoundaryEditorial::APPROVAL_FILENAME)
      unless File.file?(approval_path)
        approval_command = command(
          REPO_ROOT,
          File.join(REPO_ROOT, "bin", "af-boundary-editorial"),
          "approve",
          artifact.fetch(:path),
          "--dossier",
          dossier,
          "--source-root",
          source_root,
          "--amc",
          base_amc,
          "--approved-by",
          "NAME",
          "--output",
          approval_path
        )

        return Result.new(
          state: "NEEDS_HUMAN_APPROVAL",
          artifact_type: "editorial_bundle",
          evidence: [
            "Source: #{source_id}",
            "Editorial decisions complete: true",
            "Draft freeze exists: #{draft_freeze}",
            "Approval record absent: #{approval_path}"
          ],
          human_review: [
            "Review the complete editorial ledger and explicitly approve or revise it.",
            "Approval is a distinct operator action; frontier recommendations and a populated ledger do not approve.",
            "Issue the software-timestamped approval after review: " \
            "cd #{Shellwords.escape(approval_command.fetch('cwd'))} && #{approval_command.fetch('command')}"
          ],
          commands: [],
          warnings: freeze_warnings
        )
      end

      begin
        approval_validation = BoundaryEditorial.validate_approval!(
          approval_path:,
          bundle_dir: artifact.fetch(:path),
          dossier_path: dossier,
          source_root:,
          amc_path: base_amc
        )
      rescue AfDataPipeline::ValidationError => e
        return Result.new(
          state: "BLOCKED_BOUNDARY_APPROVAL",
          artifact_type: "editorial_bundle",
          evidence: [
            "Source: #{source_id}",
            "Approval record: #{approval_path}",
            "Approval validation failed: #{e.message}"
          ],
          human_review: [
            "Preserve the stale or invalid approval record.",
            "Re-review the current complete ledger, issue a new approval to a new immutable path, and resume with --approval PATH."
          ],
          commands: [],
          warnings: freeze_warnings
        )
      end
      approval = approval_validation.approval.fetch("approval")

      Result.new(
        state: "READY_FOR_EDITORIAL_IMPORT",
        artifact_type: "editorial_bundle",
        evidence: [
          "Source: #{source_id}",
          "Editorial decisions complete: true",
          "Draft freeze: #{draft_freeze}",
          "Approval record: #{approval_validation.path}",
          "Approval SHA-256: #{approval_validation.sha256}",
          "Approved by: #{approval.fetch('approved_by')}",
          "Approved at: #{approval.fetch('approved_at')}"
        ],
        human_review: [],
        commands: [
          command(
            REPO_ROOT,
            File.join(REPO_ROOT, "bin", "af-boundary-editorial"),
            "import",
            artifact.fetch(:path),
            "--dossier",
            dossier,
            "--freeze",
            draft_freeze,
            "--source-root",
            source_root,
            "--amc",
            base_amc,
            "--approval",
            approval_validation.path,
            "--output",
            frozen_freeze,
            auto_require: frozen_freeze
          ),
          command(
            REPO_ROOT,
            File.join(REPO_ROOT, "bin", "af-data"),
            "boundary-freeze-validate",
            frozen_freeze,
            "--source-root",
            source_root,
            "--amc",
            base_amc,
            auto_artifact: frozen_freeze
          )
        ],
        warnings: freeze_warnings
      )
    end

    def boundary_freeze_result(artifact, publisher:, successor_version:)
      freeze = artifact.fetch(:data)
      state = freeze["state"].to_s
      source_id = freeze.dig("source", "canonical_source_id")
      base_amc = frozen_base_amc_path(freeze)

      unless state == "frozen"
        return Result.new(
          state: "DRAFT_FREEZE",
          artifact_type: "boundary_freeze",
          evidence: [
            "Source: #{source_id}",
            "Freeze state: #{state.empty? ? 'unknown' : state}"
          ],
          human_review: [
            "Do not edit provenance or assign Adventure IDs manually.",
            "Return to the editorial handoff bundle and complete deterministic import."
          ],
          commands: [],
          warnings: []
        )
      end

      unless publisher && successor_version
        metadata = publisher_metadata(freeze, base_amc)
        source_evidence = publisher_source_evidence_label(metadata.fetch(:source_claims))
        amc_match = publisher_existing_match_label(metadata.fetch(:existing_matches))
        evidence = [
          "Source: #{source_id}",
          "Freeze state: frozen",
          "Base AMC: #{base_amc}",
          "Source publisher/copyright evidence: #{source_evidence}",
          "Existing AMC publisher match: #{amc_match}"
        ]
        suggestion = metadata[:suggestion]
        evidence << "Suggested Book Publisher: #{suggestion.inspect}" if suggestion

        resume = command(
          REPO_ROOT,
          File.join(REPO_ROOT, "bin", "af-ingest-next"),
          artifact.fetch(:path),
          "--publisher",
          suggestion || "TEXT",
          "--successor-version",
          "VERSION"
        )
        resume_instruction =
          "Resume command after human review: cd #{Shellwords.escape(resume.fetch('cwd'))} && #{resume.fetch('command')}"

        human_review = if suggestion
                         [
                           "Confirm Book Publisher #{suggestion.inspect}; this is a suggestion, not an automatic catalog mutation.",
                           "Choose the successor AMC version.",
                           resume_instruction
                         ]
                       else
                         [
                           "Confirm the exact Book Publisher; automatic source/AMC evidence was absent or ambiguous.",
                           "Choose the successor AMC version.",
                           resume_instruction
                         ]
                       end

        return Result.new(
          state: "NEEDS_SUCCESSOR_METADATA",
          artifact_type: "boundary_freeze",
          evidence:,
          human_review:,
          commands: [],
          warnings: [metadata[:warning]].compact
        )
      end

      unless BoundaryFreezeApply::SUCCESSOR_VERSION_RE.match?(successor_version.to_s.strip)
        raise Error,
              "--successor-version must contain only dot-separated numeric components " \
              "(for example, 7.1.2)"
      end

      successor_paths = begin
        BoundaryFreezeApply.derive_successor_paths(
          freeze_path: artifact.fetch(:path),
          amc_path: base_amc,
          successor_version: successor_version,
          amc_dir: catalog_root
        )
      rescue AfDataPipeline::Error => e
        raise Error, e.message
      end

      Result.new(
        state: "READY_FOR_AMC_APPLICATION",
        artifact_type: "boundary_freeze",
        evidence: [
          "Source: #{source_id}",
          "Freeze state: frozen",
          "Base AMC: #{base_amc}",
          "Publisher: #{publisher}",
          "Successor version: #{successor_version}"
        ],
        human_review: [],
        commands: [
          command(
            REPO_ROOT,
            File.join(REPO_ROOT, "bin", "af-data"),
            "boundary-freeze-apply",
            artifact.fetch(:path),
            "--source-root",
            source_root,
            "--amc",
            base_amc,
            "--publisher",
            publisher,
            "--successor-version",
            successor_version,
            "--amc-dir",
            catalog_root,
            "--report",
            successor_paths.report_path,
            auto_artifact: successor_paths.report_path
          )
        ],
        warnings: []
      )
    end

    def boundary_apply_report_result(artifact, batch:)
      report = artifact.fetch(:data)
      unless report["status"] == "complete" && report.dig("verification", "passed") == true
        return Result.new(
          state: "BLOCKED_AMC_APPLICATION",
          artifact_type: "boundary_apply_report",
          evidence: [
            "Apply status: #{report['status'].inspect}",
            "Verification passed: #{report.dig('verification', 'passed').inspect}"
          ],
          human_review: [],
          commands: [],
          warnings: ["Do not adopt or score an unverified successor AMC."]
        )
      end

      output = report.fetch("output_amc")
      output_path = File.expand_path(output.fetch("path"))
      output_sha = output.fetch("sha256")
      source_id = report.dig("source", "canonical_source_id")
      records = Array(report["records"])
      added = records.map { |row| row["adventure_id"] }.compact

      if catalog_head_sha != output_sha
        return Result.new(
          state: "READY_FOR_CATALOG_ADOPTION",
          artifact_type: "boundary_apply_report",
          evidence: [
            "Source: #{source_id}",
            "Verified successor AMC: #{output_path}",
            "Successor SHA-256: #{output_sha}",
            "Adventure IDs: #{added.join(', ')}"
          ],
          human_review: [
            "Review the catalog delta presented by adoption.",
            "The current adoption path also runs the cross-consumer compatibility gate when #3 is present."
          ],
          commands: [
            command(
              REPO_ROOT,
              File.join(REPO_ROOT, "bin", "af-project-state"),
              "adopt",
              output_path,
              "--manifest",
              project_state_manifest,
              "--resume-artifact",
              artifact.fetch(:path)
            )
          ],
          warnings: []
        )
      end

      unless batch
        resume = command(
          REPO_ROOT,
          File.join(REPO_ROOT, "bin", "af-ingest-next"),
          artifact.fetch(:path),
          "--batch",
          "NNN"
        )
        resume_instruction =
          "Resume command after human review: cd #{Shellwords.escape(resume.fetch('cwd'))} && #{resume.fetch('command')}"

        return Result.new(
          state: "NEEDS_PRODUCTION_BATCH_NUMBER",
          artifact_type: "boundary_apply_report",
          evidence: [
            "Source: #{source_id}",
            "Catalog head matches verified successor SHA-256.",
            "Adventure IDs: #{added.join(', ')}"
          ],
          human_review: [
            "Choose the production batch number.",
            resume_instruction
          ],
          commands: [],
          warnings: []
        )
      end

      batch_text = batch.to_s
      unless /\A\d+\z/.match?(batch_text) && batch_text.to_i.positive?
        raise Error,
              "--batch must be a positive numeric batch number " \
              "(for example, 037); replace the NNN placeholder before rerunning"
      end

      workload_id = format("production-batch-%03d", batch_text.to_i)
      runnable, deferred = afw_page_eligibility(records)
      runnable_ids = runnable.map { |entry| entry.fetch("adventure_id") }
      deferred_text = deferred.map do |entry|
        "#{entry.fetch('adventure_id')} (#{entry.fetch('page_count')} pages; #{AFW_DEFER_REASON})"
      end.join(", ")
      eligibility_evidence = [
        "AFW runnable: #{runnable.length}: #{runnable_ids.join(', ')}",
        "AFW deferred: #{deferred.length}: #{deferred.empty? ? 'none' : deferred_text}"
      ]

      if runnable.empty?
        return Result.new(
          state: "BLOCKED_AFW_WORKLOAD_ELIGIBILITY",
          artifact_type: "boundary_apply_report",
          evidence: [
            "Source: #{source_id}",
            "Catalog head matches verified successor SHA-256.",
            "Adventure IDs: #{added.join(', ')}",
            "Selected batch: #{batch}",
            *eligibility_evidence
          ],
          human_review: [
            "No newly added Adventure IDs are inside the currently proven <#{AFW_PAGE_LIMIT_EXCLUSIVE}-page production scoring envelope."
          ],
          commands: [],
          warnings: [
            "All #{deferred.length} Adventure ID(s) remain unscored; do not treat this batch as completing them."
          ]
        )
      end

      Result.new(
        state: "READY_FOR_AFW_WORKLOAD_BUILD",
        artifact_type: "boundary_apply_report",
        evidence: [
          "Source: #{source_id}",
          "Catalog head matches verified successor SHA-256.",
          "Adventure IDs: #{added.join(', ')}",
          *eligibility_evidence,
          "Selected batch: #{batch}",
          "AFW workload: #{workload_id}"
        ],
        human_review: [
          "Build and review the zero-inference AFW workload and generated WLO execution plan before any scoring run.",
          if deferred.any?
            "Review the deferred Adventure IDs above; they remain unscored and are not included in this AFW workload."
          end
        ].compact,
        commands: [
          command(
            afw_root,
            File.join(afw_root, "bin", "afw-build-workload"),
            "--data-root", PrivateDataRoot.destination!(ENV.fetch("AF_AFW_DATA_ROOT") {
              raise Error, "select AF_AFW_DATA_ROOT for the AFW store"
            }),
            "--scorer-repo",
            scorer_root,
            *(@scorer_config ? ["--scorer-config", @scorer_config] : []),
            "--workload",
            workload_id,
            "--catalog",
            output_path,
            "--ids",
            runnable_ids.join(","),
            "--required-context-length",
            AFW_REQUIRED_CONTEXT_LENGTH.to_s,
            "--require-fully-gpu-resident"
          )
        ],
        warnings: if deferred.empty?
                    []
                  else
                    [
                      "Deferred #{deferred.length} Adventure ID(s) because current production scoring qualification covers canonical units under #{AFW_PAGE_LIMIT_EXCLUSIVE} pages only."
                    ]
                  end
      )
    end

    def afw_page_eligibility(records)
      entries = records.map do |record|
        adventure_id = record["adventure_id"].to_s.strip
        if adventure_id.empty?
          raise Error, "boundary apply report record is missing adventure_id"
        end

        pages = record["printed_pages"]
        unless pages.is_a?(Hash)
          raise Error, "#{adventure_id} missing/invalid printed_pages in boundary apply report"
        end

        begin
          start_page = Integer(pages.fetch("start"))
          end_page = Integer(pages.fetch("end"))
        rescue KeyError, ArgumentError, TypeError
          raise Error, "#{adventure_id} missing/invalid printed_pages in boundary apply report"
        end

        if start_page <= 0 || end_page < start_page
          raise Error, "#{adventure_id} missing/invalid printed_pages in boundary apply report"
        end

        {
          "adventure_id" => adventure_id,
          "page_count" => end_page - start_page + 1
        }
      end

      entries.partition do |entry|
        entry.fetch("page_count") < AFW_PAGE_LIMIT_EXCLUSIVE
      end
    end

    def unresolved_issue_pages(receipt)
      unresolved = Array(receipt["unresolved_issue_fingerprints"])
      issues = Array(receipt.dig("extraction_quality", "issues"))
      issues.filter_map do |issue|
        issue["page"] if unresolved.include?(issue["fingerprint"])
      end.uniq.sort
    end

    # Render an advisory resume command only when the receipt and caller select its inputs.
    def catalog_front_door_command(receipt)
      source_pdf = receipt.dig("source", "path").to_s.strip
      return nil if source_pdf.empty? || !@adventure_finder_root

      front_door_root = adventure_finder_root
      command(
        front_door_root,
        "env",
        "AF_ADVENTURE_FINDER_ROOT=#{front_door_root}",
        *(@afw_root ? ["AF_AFW_ROOT=#{@afw_root}"] : []),
        *(@scorer_root ? ["AF_SCORER_ROOT=#{@scorer_root}"] : []),
        *(@scorer_config ? ["AF_SCORER_CONFIG=#{@scorer_config}"] : []),
        *(@pdf_converter_root ? ["AF_PDF_CONVERTER_ROOT=#{@pdf_converter_root}"] : []),
        "AF_DATA_PIPELINE_ROOT=#{REPO_ROOT}",
        File.join(front_door_root, "bin", "af-catalog"),
        source_pdf
      )
    end

    def conversion_warning(report)
      provenance = report["conversion_provenance"] || {}
      return [] if provenance["conversion_acceptance_verified"] == true

      [provenance["warning"] || "Converter acceptance was not mechanically verified."]
    end

    def publisher_metadata(freeze, base_amc)
      source_claims = source_publisher_claims(freeze)
      claim_values = source_claims.map { |claim| claim.fetch("value") }.uniq
      existing_publishers = existing_amc_publishers(base_amc)
      source_claim = claim_values.one? ? claim_values.first : nil

      existing_matches = if source_claim
                           key = publisher_key(source_claim)
                           existing_publishers.select { |value| publisher_key(value) == key }.uniq
                         else
                           []
                         end

      suggestion = if source_claim && existing_matches.one?
                     existing_matches.first
                   elsif source_claim && existing_matches.empty?
                     canonical_publisher_display(source_claim)
                   end

      {
        source_claims:,
        existing_matches:,
        suggestion:,
        warning: nil
      }
    rescue Error, AfDataPipeline::Error, Zip::Error, REXML::ParseException, SystemCallError => e
      {
        source_claims: [],
        existing_matches: [],
        suggestion: nil,
        warning: "Publisher metadata discovery failed: #{e.message}"
      }
    end

    def source_publisher_claims(freeze)
      Array(freeze.dig("source", "markdown_files")).flat_map do |item|
        filename = item.fetch("filename")
        path = File.expand_path(filename, source_root)
        raise Error, "publisher metadata source does not exist: #{path}" unless File.file?(path)

        expected = item.fetch("sha256")
        actual = Digest::SHA256.file(path).hexdigest
        unless actual == expected
          raise Error,
                "publisher metadata source SHA-256 mismatch for #{filename.inspect}: expected #{expected}, got #{actual}"
        end

        claims = []
        File.foreach(path, encoding: "UTF-8").with_index(1) do |line, line_number|
          break if line_number > 500
          claim = publisher_claim_from_line(line)
          next unless claim

          claims << {
            "value" => claim,
            "filename" => filename,
            "line" => line_number
          }
        end
        claims
      end.uniq { |claim| claim.fetch("value") }
    end

    def publisher_claim_from_line(line)
      text = line.to_s
                 .gsub("&amp;", "&")
                 .gsub("&apos;", "'")
                 .gsub("&#39;", "'")
                 .strip
      return nil if text.empty?

      claim = if (match = text.match(/\b(?:Publisher\s*:|Published by)\s*(.+)\z/i))
                match[1]
              elsif (match = text.match(/©\s*(?:\d{4}(?:\s*[-–]\s*\d{2,4})?\s+)?([^,]+?)(?:,|\z)/))
                match[1]
              end
      return nil unless claim

      claim = claim.split(/\.\s+(?=[A-Z])/).first.to_s
      claim = claim.sub(/\s+All rights reserved.*\z/i, "")
      if (legal = claim.match(/\A(.+?\b(?:L\.?L\.?C\.?|Inc(?:orporated)?\.?|Ltd\.?|Limited|Corp(?:oration)?\.?))\b/i))
        claim = legal[1]
      end
      claim = claim.strip.sub(/[.;]\z/, "")
      claim.empty? ? nil : claim
    end

    def existing_amc_publishers(base_amc)
      workbook = BoundaryFreezeApply::Workbook.new(base_amc)

      catalog_publishers = [
        BoundaryFreezeApply::ORDINARY_SHEET,
        BoundaryFreezeApply::LARGE_SHEET
      ].flat_map do |sheet_name|
        workbook.sheet_by_name!(sheet_name).catalog_records.filter_map do |record|
          value = record["publisher"].to_s.strip
          value unless value.empty?
        end
      end

      books = workbook.sheet_by_name!(BoundaryFreezeApply::BOOKS_SHEET)
      book_publishers = books.rows_with_nonblank("H").filter_map do |row|
        value = books.cell_value("H#{row}").to_s.strip
        next if value.empty? || value == BoundaryFreezeApply::SPECIAL_LARGE_LABEL

        value
      end

      (catalog_publishers + book_publishers).uniq
    end

    def canonical_publisher_display(value)
      value.to_s
           .strip
           .sub(/\s+(?:L\.?L\.?C\.?|Inc(?:orporated)?\.?|Ltd\.?|Limited|Corp(?:oration)?\.?)\z/i, "")
           .strip
    end

    def publisher_key(value)
      canonical_publisher_display(value)
        .tr("’", "'")
        .gsub("&", " and ")
        .downcase
        .gsub(/[^a-z0-9]+/, " ")
        .strip
    end

    def publisher_source_evidence_label(claims)
      return "none detected automatically" if claims.empty?

      values = claims.map { |claim| claim.fetch("value") }.uniq
      return "ambiguous (#{values.map(&:inspect).join(', ')})" unless values.one?

      claim = claims.find { |item| item.fetch("value") == values.first }
      "#{values.first.inspect} (#{claim.fetch('filename')}:#{claim.fetch('line')})"
    end

    def publisher_existing_match_label(matches)
      return "none" if matches.empty?
      return matches.first.inspect if matches.one?

      "ambiguous (#{matches.map(&:inspect).join(', ')})"
    end

    def dossier_output_dir(source_id)
      File.join(@data_root, "audits", "pre-scoring", "#{slug(source_id)}-boundary-dossier")
    end

    def editorial_output_dir(source_id)
      File.join(@data_root, "audits", "pre-scoring", "#{slug(source_id)}-boundary-editorial")
    end

    def freeze_draft_path(source_id)
      File.join(@data_root, "audits", "pre-scoring", "#{slug(source_id)}-boundary-freeze-draft.yml")
    end

    def freeze_final_path(source_id)
      File.join(@data_root, "audits", "pre-scoring", "#{slug(source_id)}-boundary-freeze.yml")
    end

    def freeze_path_for_context(preferred_path, context, expected_state:)
      return preferred_path unless File.file?(preferred_path)
      return preferred_path if freeze_bound_to_context?(preferred_path, context, expected_state:)

      rebound_path = provenance_freeze_path(preferred_path, context)
      return rebound_path unless File.file?(rebound_path)
      return rebound_path if freeze_bound_to_context?(rebound_path, context, expected_state:)

      raise Error,
            "Provenance-specific boundary freeze already exists but does not match the current editorial bundle: " \
            "#{rebound_path}"
    end

    def freeze_bound_to_context?(path, context, expected_state:)
      freeze = load_yaml(path)
      return false unless freeze["schema_version"] == FREEZE_SCHEMA
      return false unless freeze["state"] == expected_state
      return false unless freeze["base_amc"] == context["base_amc"]

      freeze_source = freeze["source"]
      context_source = context["source"]
      return false unless freeze_source.is_a?(Hash) && context_source.is_a?(Hash)

      source_keys = %w[canonical_source_id registry_filename registry_sha256 markdown_files]
      source_keys.all? { |key| freeze_source[key] == context_source[key] }
    end

    def provenance_freeze_path(preferred_path, context)
      base = context.fetch("base_amc")
      filename = base.fetch("filename").to_s
      match = BoundaryFreezeApply::AMC_FILENAME_RE.match(filename)
      label = match ? match[:version] : base.fetch("sha256").to_s[0, 12]
      extension = File.extname(preferred_path)
      stem = preferred_path.delete_suffix(extension)
      "#{stem}-from-amc-#{label}#{extension}"
    end

    def freeze_path_warnings(preferred_draft:, draft:, preferred_final:, final:)
      warnings = []
      if draft != preferred_draft
        warnings << "Existing draft freeze has different provenance and is preserved: #{preferred_draft}"
        warnings << "Current rebound draft freeze path: #{draft}"
      end
      if final != preferred_final
        warnings << "Existing frozen boundary artifact has different provenance and is preserved: #{preferred_final}"
        warnings << "Current rebound frozen boundary path: #{final}"
      end
      warnings
    end

    def bound_dossier_path(artifact, context)
      filename = context.dig("dossier", "filename").to_s
      expected = context.dig("dossier", "sha256")
      candidates = [
        File.join(File.dirname(artifact.fetch(:path)), filename),
        File.join(@data_root, "audits", "pre-scoring", filename),
        *Dir.glob(File.join(@data_root, "audits", "pre-scoring", "**", filename))
      ].compact.uniq.select { |candidate| File.file?(candidate) }

      if candidates.empty?
        raise Error, "Cannot locate dossier #{filename.inspect} bound by editorial context"
      end

      path = candidates.find do |candidate|
        Digest::SHA256.file(candidate).hexdigest == expected
      end
      unless path
        raise Error,
              "Cannot locate dossier #{filename.inspect} matching SHA-256 #{expected} bound by editorial context"
      end

      verify_sha!(path, expected, "boundary dossier")
    end

    def bound_amc_path(context)
      base = context.fetch("base_amc")
      path = File.join(catalog_root, base.fetch("filename"))
      verify_sha!(path, base.fetch("sha256"), "base AMC")
      path
    end

    def frozen_base_amc_path(freeze)
      base = freeze.fetch("base_amc")
      path = File.join(catalog_root, base.fetch("filename"))
      verify_sha!(path, base.fetch("sha256"), "base AMC")
      path
    end

    def source_routing_catalog_path
      return catalog_head_path unless operation_input

      operation_input.verify_live_catalog_head!(project_state)
      operation_input.base_catalog_path!(catalog_root)
    end

    def catalog_head_path
      entry = project_state.fetch("catalog_head")
      path = File.join(catalog_root, entry.fetch("filename"))
      verify_sha!(path, entry.fetch("sha256"), "catalog_head")
      if entry["bytes"] && File.size(path) != entry["bytes"]
        raise Error, "catalog_head byte-size mismatch: #{path}"
      end
      path
    end

    def catalog_head_sha
      entry = project_state.fetch("catalog_head")
      catalog_head_path
      entry.fetch("sha256")
    end

    def project_state
      @project_state ||= begin
        path = project_state_manifest
        raise Error, "Project-state manifest not found: #{path}" unless File.file?(path)

        data = load_yaml(path)
        unless data["schema_version"] == "adventurefinder-project-state/v0.2"
          raise Error, "Unsupported project-state schema #{data['schema_version'].inspect}"
        end
        data
      end
    end

    def project_state_manifest
      File.join(catalog_root, "PROJECT_STATE.yml")
    end

    def verify_sha!(path, expected, label)
      raise Error, "#{label} does not exist: #{path}" unless File.file?(path)
      actual = Digest::SHA256.file(path).hexdigest
      return path if actual == expected

      raise Error, "#{label} SHA-256 mismatch: expected #{expected}, got #{actual} (#{path})"
    end

    def validate_schema!(actual, allowed, path)
      return if allowed.include?(actual)

      raise Error,
            "Unsupported artifact schema #{actual.inspect}; expected #{allowed.join(' or ')}: #{path}"
    end

    def slug(value)
      result = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      result.empty? ? "source" : result
    end

    def command(cwd, executable, *args, auto_artifact: nil, auto_require: nil)
      if executable == File.join(REPO_ROOT, "bin", "af-ingest-next")
        {"--source-root" => @source_root, "--catalog-root" => @catalog_root,
         "--afw-root" => @afw_root, "--scorer-repo" => @scorer_root,
         "--adventure-finder-root" => @adventure_finder_root,
         "--pdf-converter-root" => @pdf_converter_root}.each do |option, root|
          args += [option, root] if root
        end
        args += ["--scorer-config", @scorer_config] if @scorer_config
        args += ["--operation-input", operation_input.path] if operation_input&.path
        args += ["--spec-root", spec_root] if spec_root
      end
      invocation = [executable, *args]
      if PrivateDataRoot.selected
        invocation = ["env", "#{PrivateDataRoot::ENV_KEY}=#{@data_root}", *invocation]
      end
      item = {
        "cwd" => File.expand_path(cwd),
        "command" => invocation.map { |value| Shellwords.escape(value.to_s) }.join(" ")
      }
      item["auto_artifact"] = File.expand_path(auto_artifact) if auto_artifact
      item["auto_require"] = File.expand_path(auto_require) if auto_require
      item
    end

    def load_json(path)
      value = JSON.parse(File.read(path, encoding: "UTF-8"))
      raise Error, "JSON artifact must contain an object: #{path}" unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON artifact #{path}: #{e.message}"
    end

    def load_yaml(path)
      value = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false) || {}
      raise Error, "YAML artifact must contain a mapping: #{path}" unless value.is_a?(Hash)
      value
    rescue Psych::Exception => e
      raise Error, "Invalid YAML artifact #{path}: #{e.message}"
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr, executor: nil)
        options = {
          source_root: DEFAULT_SOURCE_ROOT,
          catalog_root: DEFAULT_CATALOG_ROOT,
          afw_root: nil,
          afio_root: nil,
          scorer_root: DEFAULT_SCORER_ROOT,
          scorer_config: ENV["AF_SCORER_CONFIG"],
          adventure_finder_root: DEFAULT_ADVENTURE_FINDER_ROOT,
          pdf_converter_root: DEFAULT_PDF_CONVERTER_ROOT,
          auto: false,
          json: false
        }

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: bin/af-ingest-next ARTIFACT [options]"
          opts.on("--spec-root DIR", "Explicit absolute public specification root for new editorial bundles") { |v| options[:spec_root] = v }
          opts.on("--source-root DIR", "Canonical private Markdown corpus root") { |v| options[:source_root] = v }
          opts.on("--catalog-root DIR", "af-xlsx-data-sources root") { |v| options[:catalog_root] = v }
          opts.on("--afw-root DIR", "Explicit public af-workloads checkout (or AF_AFW_ROOT)") { |v| options[:afw_root] = v }
          opts.on("--afio-root DIR", "Legacy alias for --afw-root; explicitly selects that checkout") { |v| options[:afio_root] = v }
          opts.on("--scorer-config FILE", "Explicit AFW scorer input configuration") { |v| options[:scorer_config] = v }
          opts.on("--scorer-repo DIR", "Explicit public scorer checkout (or AF_SCORER_ROOT)") { |v| options[:scorer_root] = v }
          opts.on("--adventure-finder-root DIR", "Detached front door (AF_ADVENTURE_FINDER_ROOT)") { |v| options[:adventure_finder_root] = v }
          opts.on("--pdf-converter-root DIR", "pdf-to-llm-md-converter checkout root") { |v| options[:pdf_converter_root] = v }
          opts.on("--operation-input FILE", "Versioned AdventureFinder operation routing projection") { |v| options[:operation_input] = v }
          opts.on("--source-id ID", "Editorially selected canonical source identity") { |v| options[:source_id] = v }
          opts.on("--canonical-markdown PATH", "Canonical corpus copy of accepted converter output") { |v| options[:canonical_markdown] = v }
          opts.on("--publisher TEXT", "Exact Book Publisher for AMC application") { |v| options[:publisher] = v }
          opts.on("--successor-version VERSION", "Explicit successor AMC version") { |v| options[:successor_version] = v }
          opts.on("--approval PATH", "Validated boundary editorial approval record") { |v| options[:approval_path] = v }
          opts.on("--approved-by NAME", "Legacy loose approval (rejected)") { |v| options[:approved_by] = v }
          opts.on("--approved-at ISO8601", "Legacy loose approval time (rejected)") { |v| options[:approved_at] = v }
          opts.on("--batch NUMBER", "Production batch number for AFW workload handoff") { |v| options[:batch] = v }
          opts.on("--auto", "Run allowlisted deterministic PASS continuations until the next human/review gate") { options[:auto] = true }
          opts.on("--json", "Emit structured JSON instead of operator text") { options[:json] = true }
          opts.on("-h", "--help", "Show help") do
            out.puts opts
            return 0
          end
        end

        parser.parse!(argv)
        artifact = argv.shift
        if options[:auto] && options[:json]
          raise OptionParser::InvalidArgument, "--auto cannot be combined with --json"
        end
        if options[:auto] && options[:operation_input]
          raise OptionParser::InvalidArgument,
                "--operation-input is read-only and cannot be combined with --auto"
        end
        if options[:approved_by] || options[:approved_at]
          raise OptionParser::InvalidArgument,
                "legacy loose --approved-by/--approved-at values cannot authorize import; use --approval PATH"
        end
        raise OptionParser::MissingArgument, "ARTIFACT" unless artifact
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        router = IngestNext.new(
          source_root: options[:source_root],
          catalog_root: options[:catalog_root],
          afw_root: options[:afw_root],
          afio_root: options[:afio_root],
          scorer_root: options[:scorer_root],
          scorer_config: options[:scorer_config],
          adventure_finder_root: options[:adventure_finder_root],
          pdf_converter_root: options[:pdf_converter_root],
          operation_input: options[:operation_input],
          spec_root: options[:spec_root]
        )
        inspect_options = {
          source_id: options[:source_id],
          canonical_markdown: options[:canonical_markdown],
          publisher: options[:publisher],
          successor_version: options[:successor_version],
          approval_path: options[:approval_path],
          batch: options[:batch]
        }
        result = router.inspect(artifact_path: artifact, **inspect_options)
        if options[:auto]
          result = auto_advance(
            router:,
            artifact_path: artifact,
            result:,
            inspect_options:,
            out:,
            err:,
            executor: executor || method(:execute_auto_command)
          )
        end

        if options[:json]
          route = {
            "state" => result.state,
            "artifact_type" => result.artifact_type,
            "evidence" => result.evidence,
            "human_review" => result.human_review,
            "commands" => result.commands.map { |item| item.slice("cwd", "command") },
            "warnings" => result.warnings
          }
          payload = if router.operation_input
                      {
                        "schema_version" => OPERATION_RESULT_SCHEMA,
                        "operation" => router.operation_input.summary,
                        "route" => route
                      }
                    else
                      route
                    end
          out.puts JSON.pretty_generate(payload)
        else
          render(result, out)
        end

        result.state.start_with?("BLOCKED") ? 2 : 0
      rescue OperationInput::Error => e
        if options && options[:json]
          err.puts JSON.pretty_generate(
            "schema_version" => OPERATION_ERROR_SCHEMA,
            "error" => {"code" => e.code, "message" => e.message}
          )
        else
          err.puts "ERROR [#{e.code}]: #{e.message}"
        end
        2
      rescue OptionParser::ParseError, IngestNext::Error, AfDataPipeline::Error => e
        err.puts "ERROR: #{e.message}"
        2
      end

      def self.auto_advance(router:, artifact_path:, result:, inspect_options:, out:, err:, executor:)
        while AUTO_ADVANCE_STATES.include?(result.state)
          commands = result.commands
          if commands.empty?
            raise IngestNext::Error,
                  "auto-advance state #{result.state} has no deterministic command"
          end

          continuation = commands.reverse_each.find { |item| item["auto_artifact"] }
          unless continuation
            raise IngestNext::Error,
                  "auto-advance state #{result.state} has no declared continuation artifact"
          end

          result.warnings.each { |warning| out.puts "AUTO: #{warning}" }
          count_label = commands.length == 1 ? "command" : "commands"
          out.puts
          out.puts "AUTO: #{result.state} — continuing through #{commands.length} deterministic #{count_label}."

          commands.each do |item|
            argv = Shellwords.split(item.fetch("command"))
            label = File.basename(argv.fetch(0))
            out.puts "AUTO: running #{label}"
            status = executor.call(item, out, err)
            unless status == 0
              raise IngestNext::Error,
                    "auto-advance command failed: #{label} exited #{status}"
            end

            if (required = item["auto_require"]) && !File.exist?(required)
              raise IngestNext::Error,
                    "auto-advance command passed but required artifact is missing: #{required}"
            end
            out.puts "AUTO: PASS #{label}"
          end

          artifact_path = continuation.fetch("auto_artifact")
          unless File.exist?(artifact_path)
            raise IngestNext::Error,
                  "auto-advance continuation artifact is missing after PASS: #{artifact_path}"
          end
          result = router.inspect(artifact_path:, **inspect_options)
        end
        result
      end

      def self.execute_auto_command(item, out, err)
        status = nil
        Open3.popen2e(*Shellwords.split(item.fetch("command")), chdir: item.fetch("cwd")) do |stdin, combined, wait|
          stdin.close
          combined.each_line { |line| out.print("  #{line}") }
          status = wait.value.exitstatus
        end
        status
      rescue SystemCallError => e
        err.puts "ERROR: could not execute auto-advance command: #{e.message}"
        127
      end

      def self.render(result, out)
        out.puts "STATE: #{result.state}"
        out.puts "Artifact: #{result.artifact_type}"

        unless result.evidence.empty?
          out.puts
          out.puts "Evidence:"
          result.evidence.each { |line| out.puts "  - #{line}" }
        end

        unless result.warnings.empty?
          out.puts
          out.puts "Warnings:"
          result.warnings.each { |line| out.puts "  - #{line}" }
        end

        unless result.human_review.empty?
          out.puts
          out.puts "Human review required:"
          result.human_review.each { |line| out.puts "  - #{line}" }
        end

        if result.commands.empty?
          out.puts
          out.puts "Next command: none until the required human decision/review is complete."
        else
          out.puts
          out.puts(result.commands.length == 1 ? "Next command:" : "Next commands:")
          result.commands.each_with_index do |item, index|
            out.puts "  #{index + 1}. cd #{Shellwords.escape(item.fetch('cwd'))}"
            out.puts "     #{item.fetch('command')}"
          end
        end
      end
    end
  end
end
