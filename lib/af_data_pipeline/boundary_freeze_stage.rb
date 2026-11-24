# frozen_string_literal: true

require_relative "private_data_root"

require "digest"
require "json"
require "tempfile"
require "time"

module AfDataPipeline
  # Creates or revalidates an operation-bound successor AMC without promoting
  # any shared catalog role. AdventureFinder supplies operator intent through
  # public projections; pipeline remains the owner of freeze validation and the
  # deterministic workbook transformation.
  class BoundaryFreezeStage
    SCHEMA_VERSION = "af-boundary-freeze-staged-successor/v0.1"
    AUTHORIZATION_PROJECTION_VERSION =
      "adventurefinder-successor-version-authorization-projection/v0.1"
    AUTHORIZATION_VERSION = "adventurefinder-successor-version-authorization/v0.1"
    OPERATION_VERSION = "adventurefinder-ingest-operation/v0.1"
    SUCCESSOR_VERSION_RE = /\A\d+(?:\.\d+)+\z/
    SHA256_RE = /\A[0-9a-f]{64}\z/
    UUID_V4_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    Result = Data.define(
      :status, :output_path, :report_path, :stage_path, :record_count, :reused, :receipt
    )

    # The saved apply report disagrees with the allocation reconstructed from the bound inputs.
    class AllocationConflict < ValidationError; end

    def self.stage!(freeze_path:, operation_input_path:, successor_authorization_path:,
                    source_root:, catalog_root:, project_state_path: nil,
                    registry_path: nil, progress: nil)
      new(
        freeze_path:, operation_input_path:, successor_authorization_path:,
        source_root:, catalog_root:, project_state_path:, registry_path:, progress:
      ).stage!
    end

    # Public read-only verifier. Retained historical project-state evidence is
    # supplied explicitly; this never re-stages a missing or partial result.
    def self.verify!(**options)
      defaults = {project_state_path: nil, registry_path: nil, progress: nil}
      new(**defaults.merge(options)).stage!(verify_only: true)
    end

    def initialize(freeze_path:, operation_input_path:, successor_authorization_path:,
                   source_root:, catalog_root:, project_state_path:, registry_path:, progress:)
      @freeze_path = File.expand_path(freeze_path)
      @operation_input_path = File.expand_path(operation_input_path)
      @successor_authorization_path = File.expand_path(successor_authorization_path)
      @source_root = File.expand_path(source_root)
      @catalog_root = File.expand_path(catalog_root)
      @project_state_path = File.expand_path(
        project_state_path || File.join(@catalog_root, "PROJECT_STATE.yml")
      )
      @registry_path = registry_path
      @progress = progress
    end

    def stage!(verify_only: false)
      operation_input = load_operation_input!
      operation_input.verify_artifact!(@freeze_path)
      base_amc = operation_input.base_catalog_path!(@catalog_root)
      freeze = BoundaryFreeze.validate!(
        freeze_path: @freeze_path,
        source_root: @source_root,
        amc_path: base_amc,
        registry_path: @registry_path
      )
      operation_input.verify_component_bindings!(
        {type: :boundary_freeze, data: freeze.artifact},
        source_root: @source_root
      )
      publisher = operation_input.document.dig("source", "publisher")
      unless publisher.is_a?(String) && !publisher.strip.empty? && publisher == publisher.strip
        raise ValidationError, "operation input has no authoritative publisher binding"
      end

      authorization = load_authorization!(operation_input.document)
      successor_version = authorization.fetch("successor_version")
      paths = BoundaryFreezeApply.derive_successor_paths(
        freeze_path: @freeze_path,
        amc_path: base_amc,
        successor_version:,
        amc_dir: @catalog_root
      )
      stage_path = stage_receipt_path(
        paths.report_path,
        base_version: paths.base_version,
        successor_version:
      )
      paths = staging_paths(paths, stage_path)
      PrivateDataRoot.external_store!(@catalog_root) unless verify_only
      project_state = project_state_snapshot!
      inputs = input_receipt(
        operation_input:, authorization:, freeze:, base_amc:, project_state:
      )

      existing = [paths.output_path, paths.report_path, stage_path].select { |path| File.exist?(path) }
      if verify_only && existing.empty?
        raise ValidationError, "missing staged-successor publication; verification cannot create it"
      end
      unless existing.empty?
        return replay!(
          existing:, paths:, stage_path:, inputs:, freeze:, base_amc:, publisher:,
          project_state:
        )
      end

      if freeze.record_count.zero?
        receipt = build_receipt(
          status: "no_successor_needed",
          inputs:,
          successor: nil,
          record_count: 0,
          verification: {
            "boundary_freeze_valid" => true,
            "project_state_unchanged" => true,
            "successor_created" => false
          }
        )
        ensure_project_state_unchanged!(project_state)
        publish_receipt!(stage_path, receipt)
        return result_for(receipt, paths, stage_path, reused: false)
      end

      progress("[stage] applying exact approved boundary freeze")
      applied = BoundaryFreezeApply.apply!(
        freeze_path: @freeze_path,
        source_root: @source_root,
        amc_path: base_amc,
        publisher:,
        output_path: paths.output_path,
        report_path: paths.report_path,
        registry_path: @registry_path,
        progress: @progress
      )

      begin
        report = validate_apply_evidence!(
          report_path: applied.report_path,
          output_path: applied.output_path,
          freeze:,
          base_amc:,
          publisher:
        )
        ensure_project_state_unchanged!(project_state)
        receipt = build_receipt(
          status: "verified_staged_successor",
          inputs:,
          successor: successor_receipt(applied.output_path, applied.report_path, report),
          record_count: freeze.record_count,
          verification: {
            "boundary_freeze_valid" => true,
            "apply_report_valid" => true,
            "workbook_integrity_verified" => true,
            "base_bytes_unchanged" => true,
            "project_state_unchanged" => true,
            "shared_catalog_role_promoted" => false
          }
        )
        publish_receipt!(stage_path, receipt)
      rescue StandardError
        File.unlink(applied.report_path) if File.file?(applied.report_path)
        File.unlink(applied.output_path) if File.file?(applied.output_path)
        raise
      end
      result_for(receipt, paths, stage_path, reused: false)
    rescue IngestNext::OperationInput::Error => e
      raise ValidationError, "operation input #{e.code}: #{e.message}"
    end

    private

    # New stages use a noncanonical basename beside the catalog. A retained
    # v0.1 receipt selects only its original canonical or staged basename;
    # replay! still reconstructs and checks every receipt/input/workbook byte.
    # Returns SuccessorPaths without moving files. Malformed receipts or a
    # legacy workbook without its receipt raise ValidationError, never restage.
    def staging_paths(paths, stage_path)
      canonical_name = File.basename(paths.output_path)
      staged_name = "staged-#{canonical_name}"
      if File.file?(stage_path)
        receipt = JSON.parse(File.binread(stage_path))
        raise ValidationError, "invalid staged-successor receipt object" unless receipt.is_a?(Hash)
        successor = receipt["successor"]
        if successor.is_a?(Hash)
          filename = successor["filename"]
          unless [canonical_name, staged_name].include?(filename)
            raise ValidationError, "staged-successor receipt has an unexpected workbook filename"
          end
          staged_name = filename
        end
      elsif File.exist?(paths.output_path)
        raise ValidationError, "partial staged-successor publication exists; refusing to claim a valid stage"
      end
      paths.with(output_path: File.join(@catalog_root, staged_name))
    rescue JSON::ParserError => e
      raise ValidationError, "invalid staged-successor receipt JSON: #{e.message}"
    end

    def load_operation_input!
      IngestNext::OperationInput.load(@operation_input_path)
    end

    def load_authorization!(operation_document)
      projection = JSON.parse(File.binread(@successor_authorization_path))
      exact_keys!(projection, %w[contract_version authorization], "successor-version projection")
      unless projection["contract_version"] == AUTHORIZATION_PROJECTION_VERSION
        raise ValidationError, "unsupported successor-version authorization projection"
      end
      authorization = projection.fetch("authorization")
      exact_keys!(
        authorization,
        %w[contract_version operation base_catalog successor_version selected_by selected_at authorization_id],
        "successor-version authorization"
      )
      unless authorization["contract_version"] == AUTHORIZATION_VERSION
        raise ValidationError, "unsupported successor-version authorization contract"
      end

      operation = authorization.fetch("operation")
      exact_keys!(operation, %w[contract_version operation_id created_at], "authorization operation")
      unless operation["contract_version"] == OPERATION_VERSION &&
             UUID_V4_RE.match?(operation["operation_id"].to_s)
        raise ValidationError, "successor-version authorization has invalid operation identity"
      end
      timestamp!(operation["created_at"], "authorization operation created_at")

      base = authorization.fetch("base_catalog")
      exact_keys!(base, %w[sha256 bytes], "authorization base_catalog")
      unless SHA256_RE.match?(base["sha256"].to_s) && base["bytes"].is_a?(Integer) && base["bytes"].positive?
        raise ValidationError, "successor-version authorization has invalid base identity"
      end
      unless SUCCESSOR_VERSION_RE.match?(authorization["successor_version"].to_s)
        raise ValidationError, "successor-version authorization has invalid successor version"
      end
      text!(authorization["selected_by"], "authorization selected_by")
      timestamp!(authorization["selected_at"], "authorization selected_at")

      body = authorization.reject { |key, _value| key == "authorization_id" }
      expected_id = Digest::SHA256.hexdigest(JSON.generate(canonical(body)))
      unless authorization["authorization_id"] == expected_id
        raise ValidationError, "successor-version authorization digest does not match its content"
      end

      routed_operation = operation_document.fetch("operation")
      unless operation["operation_id"] == routed_operation["operation_id"] &&
             operation["contract_version"] == routed_operation["contract_version"]
        raise ValidationError, "successor-version authorization conflicts with operation input"
      end
      routed_base = operation_document.fetch("base_catalog")
      unless base == routed_base.slice("sha256", "bytes")
        raise ValidationError, "successor-version authorization conflicts with frozen base catalog"
      end
      authorization.merge(
        "projection_sha256" => Digest::SHA256.file(@successor_authorization_path).hexdigest
      )
    rescue Errno::ENOENT => e
      raise ValidationError, "missing successor-version authorization projection: #{e.message}"
    rescue JSON::ParserError => e
      raise ValidationError, "invalid successor-version authorization JSON: #{e.message}"
    end

    def project_state_snapshot!
      bytes = File.binread(@project_state_path)
      state = ProjectState.new(manifest_path: @project_state_path)
      state.validate!
      roles = ProjectState::ROLES.to_h do |role|
        resolved = state.resolve(role)
        [
          role,
          {
            "version" => resolved.version,
            "filename" => resolved.filename,
            "sha256" => resolved.sha256,
            "bytes" => resolved.bytes
          }
        ]
      end
      {
        "schema_version" => ProjectState::SCHEMA_VERSION,
        "sha256" => Digest::SHA256.hexdigest(bytes),
        "bytes" => bytes.bytesize,
        "roles" => roles
      }
    rescue Errno::ENOENT => e
      raise ValidationError, "missing project-state manifest: #{e.message}"
    end

    def ensure_project_state_unchanged!(before)
      after = project_state_snapshot!
      return true if after == before

      raise ValidationError, "PROJECT_STATE.yml or one of its three shared role artifacts changed during staging"
    end

    def input_receipt(operation_input:, authorization:, freeze:, base_amc:, project_state:)
      operation = operation_input.document.fetch("operation")
      {
        "operation" => {
          "contract_version" => operation.fetch("contract_version"),
          "operation_id" => operation.fetch("operation_id"),
          "revision" => operation.fetch("revision"),
          "document_sha256" => operation.fetch("document_sha256"),
          "routing_input_sha256" => operation_input.summary.fetch("routing_input_sha256")
        },
        "successor_version_authorization" => authorization.slice(
          "contract_version", "authorization_id", "successor_version", "selected_by",
          "selected_at", "projection_sha256"
        ),
        "boundary_freeze" => {
          "filename" => File.basename(@freeze_path),
          "sha256" => freeze.sha256,
          "bytes" => File.size(@freeze_path),
          "schema_version" => freeze.artifact.fetch("schema_version"),
          "approved_by" => freeze.artifact.dig("approval", "approved_by"),
          "approved_at" => freeze.artifact.dig("approval", "approved_at")
        },
        "base_amc" => {
          "filename" => File.basename(base_amc),
          "sha256" => Digest::SHA256.file(base_amc).hexdigest,
          "bytes" => File.size(base_amc)
        },
        "project_state" => project_state
      }
    end

    def build_receipt(status:, inputs:, successor:, record_count:, verification:)
      {
        "schema_version" => SCHEMA_VERSION,
        "status" => status,
        "generated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        **inputs,
        "successor" => successor,
        "counts" => {"frozen_records" => record_count},
        "verification" => verification,
        "continuation" => {
          "state" => status == "verified_staged_successor" ? "VERIFIED_STAGED_SUCCESSOR" : "NO_SUCCESSOR_NEEDED",
          "catalog_head_promoted" => false,
          "scoring_authorized" => false,
          "next_owner" => status == "verified_staged_successor" ? "later IG-13A+ staged-successor work" : nil
        }
      }
    end

    def successor_receipt(output_path, report_path, report)
      {
        "filename" => File.basename(output_path),
        "sha256" => Digest::SHA256.file(output_path).hexdigest,
        "bytes" => File.size(output_path),
        "apply_report_filename" => File.basename(report_path),
        "apply_report_sha256" => Digest::SHA256.file(report_path).hexdigest,
        "apply_report_bytes" => File.size(report_path),
        "allocation" => report.fetch("allocation"),
        "records" => report.fetch("records"),
        "changed_cells" => report.fetch("changed_cells"),
        "apply_verification" => report.fetch("verification")
      }
    end

    def validate_apply_evidence!(report_path:, output_path:, freeze:, base_amc:, publisher:)
      raise ValidationError, "staged successor workbook is missing: #{output_path}" unless File.file?(output_path)
      raise ValidationError, "staged successor apply report is missing: #{report_path}" unless File.file?(report_path)
      report = JSON.parse(File.binread(report_path))
      unless report["schema_version"] == BoundaryFreezeApply::REPORT_SCHEMA &&
             report["status"] == "complete" && report.dig("verification", "passed") == true
        raise ValidationError, "staged successor apply report is incomplete or unverified"
      end
      checks = {
        report.dig("boundary_freeze", "sha256") => freeze.sha256,
        report.dig("base_amc", "sha256") => Digest::SHA256.file(base_amc).hexdigest,
        report.dig("output_amc", "sha256") => Digest::SHA256.file(output_path).hexdigest,
        report.dig("source", "book_publisher") => publisher
      }
      checks.each do |actual, expected|
        raise ValidationError, "staged successor apply provenance does not match current inputs" unless actual == expected
      end
      unless report.dig("counts", "frozen_records") == freeze.record_count &&
             report.fetch("records").length == freeze.record_count
        raise ValidationError, "staged successor apply report record counts do not reconcile"
      end
      expected = BoundaryFreezeApply.plan!(freeze_path: @freeze_path, source_root: @source_root,
        amc_path: base_amc, publisher:, registry_path: @registry_path)
      unless report.slice("records", "changed_cells", "current_books") == expected
        raise AllocationConflict, "staged successor report differs from reconstructed allocation"
      end
      verified = BoundaryFreezeApply.verify_bound!(freeze_path: @freeze_path,
        source_root: @source_root, amc_path: base_amc, output_amc: output_path, publisher:,
        artifact: freeze.artifact, freeze_sha256: freeze.sha256,
        amc_sha256: freeze.artifact.fetch("base_amc").fetch("sha256"))
      unless verified == report.fetch("verification")
        raise ValidationError, "staged successor verification does not match the retained integrity report"
      end
      report
    rescue JSON::ParserError => e
      raise ValidationError, "invalid staged successor apply report JSON: #{e.message}"
    end

    def replay!(existing:, paths:, stage_path:, inputs:, freeze:, base_amc:, publisher:, project_state:)
      expected_paths = freeze.record_count.zero? ? [stage_path] : [paths.output_path, paths.report_path, stage_path]
      unless existing.sort == expected_paths.sort
        raise ValidationError, "partial staged-successor publication exists; refusing to claim a valid stage"
      end
      receipt = JSON.parse(File.binread(stage_path))
      timestamp!(receipt["generated_at"], "staged successor generated_at")
      successor = nil
      verification = {
        "boundary_freeze_valid" => true,
        "project_state_unchanged" => true,
        "successor_created" => false
      }
      status = "no_successor_needed"
      unless freeze.record_count.zero?
        report = validate_apply_evidence!(
          report_path: paths.report_path,
          output_path: paths.output_path,
          freeze:,
          base_amc:,
          publisher:
        )
        successor = successor_receipt(paths.output_path, paths.report_path, report)
        verification = {
          "boundary_freeze_valid" => true,
          "apply_report_valid" => true,
          "workbook_integrity_verified" => true,
          "base_bytes_unchanged" => true,
          "project_state_unchanged" => true,
          "shared_catalog_role_promoted" => false
        }
        status = "verified_staged_successor"
      end
      expected = build_receipt(
        status:,
        inputs:,
        successor:,
        record_count: freeze.record_count,
        verification:
      )
      expected["generated_at"] = receipt["generated_at"]
      unless receipt == expected
        raise ValidationError, "existing staged-successor receipt conflicts with current exact inputs or evidence"
      end
      ensure_project_state_unchanged!(project_state)
      result_for(receipt, paths, stage_path, reused: true)
    rescue JSON::ParserError => e
      raise ValidationError, "invalid staged-successor receipt JSON: #{e.message}"
    end

    def publish_receipt!(path, receipt)
      directory = File.dirname(path)
      raise ValidationError, "staged-successor receipt directory does not exist: #{directory}" unless File.directory?(directory)
      Tempfile.create([".boundary-freeze-stage-", ".json"], directory) do |temp|
        temp.binmode
        temp.write(JSON.pretty_generate(canonical(receipt)) + "\n")
        temp.flush
        temp.fsync
        begin
          File.link(temp.path, path)
        rescue Errno::EEXIST
          raise ValidationError, "refusing to overwrite staged-successor receipt created concurrently: #{path}"
        end
      end
    end

    def stage_receipt_path(report_path, base_version:, successor_version:)
      report_basename = File.basename(report_path, ".json")
      report_basename = report_basename.sub(/-boundary-freeze-apply-report-from-amc-.*\z/, "")
      File.join(
        File.dirname(report_path),
        "#{report_basename}-verified-staged-successor-from-amc-#{base_version}-to-#{successor_version}.json"
      )
    end

    def result_for(receipt, paths, stage_path, reused:)
      Result.new(
        status: receipt.fetch("status"),
        output_path: receipt["successor"] ? paths.output_path : nil,
        report_path: receipt["successor"] ? paths.report_path : nil,
        stage_path:,
        record_count: receipt.dig("counts", "frozen_records"),
        reused:,
        receipt:
      )
    end

    def exact_keys!(value, keys, label)
      raise ValidationError, "#{label} must be an object" unless value.is_a?(Hash)
      missing = keys - value.keys
      extra = value.keys - keys
      raise ValidationError, "#{label} is missing keys: #{missing.join(', ')}" unless missing.empty?
      raise ValidationError, "#{label} has unknown keys: #{extra.join(', ')}" unless extra.empty?
    end

    def text!(value, label)
      return if value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)

      raise ValidationError, "#{label} must be a non-empty trimmed value"
    end

    def timestamp!(value, label)
      valid = value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/) &&
              Time.iso8601(value).utc.strftime("%Y-%m-%dT%H:%M:%SZ") == value
      raise ValidationError, "#{label} must be a UTC timestamp" unless valid
    rescue ArgumentError
      raise ValidationError, "#{label} must be a UTC timestamp"
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def progress(message)
      @progress&.call(message)
    end
  end
end
