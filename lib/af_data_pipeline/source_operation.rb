# frozen_string_literal: true

require_relative "private_data_root"

require "digest"
require "json"
require "optparse"
require "tempfile"
require "time"
require_relative "boundary_freeze"
require_relative "source_intake"

module AfDataPipeline
  # Issues and verifies operator-attributed decisions for one guarded source operation.
  # Approval, conversion QA and prior editorial context are pipeline policy.
  class SourceOperation
    INTENT_SCHEMA = "af-source-operation-intent/v0.1"
    DECISION_SCHEMA = "af-source-operation-decision/v0.1"
    HANDOFF_SCHEMA = "af-source-md-operation/v0.1"
    REQUIRED = %w[schema_version library_id source_root operation_id revision action source_id edition
                  candidate_path conversion_receipt_path destination registry prior_registry].freeze
    OPTIONAL = %w[page_marker_offset prior_source_id prior_freeze_path base_amc_path].freeze
    DISPOSITIONS = %w[approved declined].freeze

    # Run the decide or apply-approved public subcommand, writing JSON to out.
    # Option and validation errors are reported by the source-register CLI.
    def self.run(argv, out:)
      action = argv.shift
      options = {}
      parser = OptionParser.new do |flags|
        flags.banner = "Usage: bin/af-source-register #{action} INTENT.json --decision DECISION.json"
        flags.on("--decision PATH", "Explicit operator-controlled decision record") { |value| options[:decision] = value }
        if action == "decide"
          flags.on("--decided-by NAME") { |value| options[:actor] = value }
          flags.on("--disposition DISPOSITION", DISPOSITIONS) { |value| options[:disposition] = value }
        end
      end
      parser.parse!(argv)
      intent = argv.shift
      raise OptionParser::MissingArgument, "INTENT.json" unless intent
      raise OptionParser::MissingArgument, "--decision" unless options[:decision]
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      if action == "decide" && (!options[:actor] || !options[:disposition])
        raise OptionParser::MissingArgument, "--decided-by and --disposition"
      end

      operation = new(intent)
      result = if action == "decide"
                 operation.decide!(**options)
               else
                 operation.apply!(decision: options.fetch(:decision))
               end
      out.puts(JSON.pretty_generate(result))
      0
    rescue SystemCallError => error
      raise ValidationError, error.message
    rescue StandardError => error
      raise ValidationError, error.message if defined?(AFSourceMD::Error) && error.is_a?(AFSourceMD::Error)
      raise
    end

    # Bind an exact intent file and the explicitly selected owner. Raise ValidationError for invalid selection or intent.
    def initialize(path)
      unless ENV.key?("AF_SOURCE_MD_ROOT")
        raise ValidationError, "Guarded source operations require explicit AF_SOURCE_MD_ROOT"
      end
      owner = SourceMarkdownOwner.load!(error_class: ValidationError)
      unless defined?(owner::SourceOperation::API_VERSION) && owner::SourceOperation::API_VERSION == HANDOFF_SCHEMA
        raise ValidationError, "Selected source Markdown owner does not support #{HANDOFF_SCHEMA}"
      end
      @owner = owner::SourceOperation
      @intent_file, bytes = @owner.snapshot(File.expand_path(path))
      @intent = parse!(bytes, "source operation intent")
      validate_intent!
      @root = @intent.fetch("source_root")
      unless !@root.include?("\0") && File.realpath(@root) == @root && File.directory?(@root)
        raise ValidationError, "Source operation requires a canonical source root"
      end
    end

    # Persist the operator's disposition and the current exact bindings without replacing a decision.
    # Return the decision, or raise ValidationError on stale inputs or a conflicting record.
    def decide!(decision:, actor:, disposition:)
      PrivateDataRoot.destination!(decision)
      actor = BoundaryFreeze.nonblank_string!(actor, "decided by")
      raise ValidationError, "Unsupported source disposition" unless DISPOSITIONS.include?(disposition)

      selection = bind_current_context!
      record = {
        "schema_version" => DECISION_SCHEMA, "disposition" => disposition, "decided_by" => actor,
        "decided_at" => Time.now.utc.iso8601, "binding" => selection
      }
      path = File.expand_path(decision)
      parent = File.dirname(path)
      unless File.realpath(parent) == parent
        raise ValidationError, "Decision path must use a canonical parent directory"
      end
      Tempfile.create([".source-decision-", ".json"], parent) do |temp|
        temp.write(JSON.pretty_generate(record) + "\n")
        temp.flush
        temp.fsync
        File.link(temp.path, path)
        File.open(parent, "rb", &:fsync)
      end
      record
    rescue Errno::EEXIST
      raise ValidationError, "Refusing to overwrite the source operation decision: #{path}"
    end

    # Validate an explicit decision while the owner holds the store lock; return the published bindings.
    # Approval and live context mismatches raise ValidationError before the owner gets a handoff.
    def apply!(decision:)
      PrivateDataRoot.external_store!(@root)
      path = File.expand_path(decision)
      @owner.publish!(source_root: @root) do
        raise ValidationError, "Source operation decision is missing: #{path}" unless File.file?(path)
        decision_file, bytes = @owner.snapshot(path)
        record = parse!(bytes, "source operation decision")
        keys = %w[schema_version disposition decided_by decided_at binding]
        BoundaryFreeze.exact_keys!(record, keys, "source operation decision")
        BoundaryFreeze.require_keys!(record, keys, "source operation decision")
        unless record["schema_version"] == DECISION_SCHEMA && DISPOSITIONS.include?(record["disposition"])
          raise ValidationError, "Unsupported source operation decision"
        end
        BoundaryFreeze.validate_approval!({ "approved_by" => record["decided_by"], "approved_at" => record["decided_at"] })
        raise ValidationError, "Source operation decision was declined" unless record["disposition"] == "approved"

        current = bind_current_context!
        raise ValidationError, "Stale source operation decision" unless record["binding"] == current

        current.fetch("handoff").merge(
          "decision" => decision_file.merge(record.slice("disposition", "decided_by", "decided_at"))
        )
      end
    end

    private

    # Check the exact intent schema and action-dependent fields. Raise ValidationError for malformed input.
    def validate_intent!
      BoundaryFreeze.exact_keys!(@intent, REQUIRED + OPTIONAL, "source operation intent")
      BoundaryFreeze.require_keys!(@intent, REQUIRED, "source operation intent")
      unless @intent["schema_version"] == INTENT_SCHEMA && @intent["revision"].is_a?(Integer) &&
             @intent["revision"] >= 0 && %w[register correct].include?(@intent["action"])
        raise ValidationError, "Unsupported source operation schema, action or revision"
      end
      (REQUIRED - %w[revision]).each { |field| BoundaryFreeze.nonblank_string!(@intent[field], field) }
      OPTIONAL.each { |field| BoundaryFreeze.nonblank_string!(@intent[field], field) if @intent.key?(field) }
      @owner.store_path!(@intent["source_root"], @intent["destination"])
      @owner.store_path!(@intent["source_root"], @intent["registry"])
      if @intent["action"] == "correct"
        BoundaryFreeze.nonblank_string!(@intent["prior_source_id"], "prior_source_id")
        if @intent["prior_source_id"] == @intent["source_id"]
          raise ValidationError, "Correction requires a new retained source identity"
        end
      elsif (@intent.keys & %w[prior_source_id prior_freeze_path base_amc_path]).any?
        raise ValidationError, "Registration cannot select prior source editorial context"
      end
      if @intent.key?("prior_freeze_path") != @intent.key?("base_amc_path")
        raise ValidationError, "Prior freeze and its base AMC must be selected together"
      end
    end

    # Rebind the current intent, owner, conversion QA, prior store and any selected freeze.
    # Return exact decision inputs or raise ValidationError, without writing to the store.
    def bind_current_context!
      raise ValidationError, "Source operation intent changed" unless @owner.snapshot(@intent_file.fetch("path")).first == @intent_file

      candidate, = @owner.snapshot(@intent.fetch("candidate_path"))
      qa, receipt_bytes = @owner.snapshot(@intent.fetch("conversion_receipt_path"))
      provenance = SourceIntake.validate_conversion_receipt!(
        receipt_bytes, path: qa.fetch("path"), markdown_sha: candidate.fetch("sha256"),
        expected_output: candidate.fetch("path")
      )
      prior, _, _, prior_sources = @owner.prior_state(@root, @intent.fetch("prior_registry"), @intent["prior_source_id"])
      context = [@intent_file, *prior_editorial_context!(prior)]
      handoff = @intent.slice("library_id", "source_root", "operation_id", "revision", "action", "source_id",
                              "edition", "destination", "registry").merge(
        "schema_version" => HANDOFF_SCHEMA, "candidate" => candidate, "qa" => qa,
        "prior_registry" => prior, "prior_source_id" => @intent["prior_source_id"], "prior_sources" => prior_sources,
        "page_marker_offset" => @intent["page_marker_offset"], "context" => context, "owner" => @owner.identity
      )
      { "handoff" => handoff, "conversion_qa" => provenance }
    end

    # Validate a selected prior freeze with the real pipeline validator, returning its file bindings.
    # The optional context never authorizes the new source operation.
    def prior_editorial_context!(prior)
      return [] unless @intent.key?("prior_freeze_path")

      freeze, = @owner.snapshot(@intent.fetch("prior_freeze_path"))
      base, = @owner.snapshot(@intent.fetch("base_amc_path"))
      validation = BoundaryFreeze.validate!(
        freeze_path: freeze.fetch("path"), amc_path: base.fetch("path"),
        source_root: @root, registry_path: prior.fetch("path")
      )
      unless validation.sha256 == freeze.fetch("sha256") &&
             validation.artifact.dig("source", "canonical_source_id") == @intent["prior_source_id"] &&
             validation.artifact.dig("base_amc", "sha256") == base.fetch("sha256")
        raise ValidationError, "Prior editorial context does not match the correction"
      end
      [freeze, base]
    end

    # Parse exact JSON object bytes into a mapping, translating parse failures to ValidationError.
    def parse!(bytes, label)
      BoundaryFreeze.mapping!(JSON.parse(bytes), label)
    rescue JSON::ParserError => error
      raise ValidationError, "Invalid #{label} JSON: #{error.message}"
    end
  end
end
