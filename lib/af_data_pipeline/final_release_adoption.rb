# frozen_string_literal: true

require "json"
require "optparse"
require "digest"
require "tempfile"
require_relative "catalog_adoption"
require_relative "final_release_package"
require_relative "staged_scoring_authority"
require_relative "standing_bulk_score_policy"

module AfDataPipeline
  # Binds a human decision about one exact FinalReleasePackage to the one
  # catalog-adoption transaction owned by this pipeline.
  class FinalReleaseAdoption
    REQUEST_SCHEMA = "af-final-release-adoption-request/v0.1"
    DECISION_SCHEMA = "af-final-release-adoption-decision/v0.1"
    RESULT_SCHEMA = "af-final-release-adoption-result/v0.1"
    Result = Data.define(:document, :path, :status, :catalog_result)
    Validation = Data.define(:request, :snapshot)

    def self.prepare!(inputs_path:, package_path:, output_path:)
      new(inputs_path:, package_path:).prepare!(output_path:)
    end

    def self.validate!(inputs_path:, package_path:, request_path:)
      new(inputs_path:, package_path:).validate!(request_path:)
    end

    def self.decide!(inputs_path:, package_path:, request_path:, output_path:, decision:, decided_by:)
      new(inputs_path:, package_path:).decide!(request_path:, output_path:, decision:, decided_by:)
    end

    def self.adopt!(inputs_path:, package_path:, request_path:, approval_path:, result_path:)
      new(inputs_path:, package_path:).adopt!(request_path:, approval_path:, result_path:)
    end

    def self.run(argv, out: $stdout, err: $stderr)
      action = argv.shift
      options = {}
      OptionParser.new do |opts|
        opts.on("--inputs PATH") { |value| options[:inputs_path] = value }
        opts.on("--package PATH") { |value| options[:package_path] = value }
        opts.on("--request PATH") { |value| options[:request_path] = value }
        opts.on("--output PATH") { |value| options[:output_path] = value }
        opts.on("--approval PATH") { |value| options[:approval_path] = value }
        opts.on("--result PATH") { |value| options[:result_path] = value }
        opts.on("--decided-by TEXT") { |value| options[:decided_by] = value }
      end.parse!(argv)
      raise ValidationError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      common = %i[inputs_path package_path]
      result = case action
               when "prepare"
                 require_options!(options, *common, :output_path)
                 prepare!(**options.slice(*common, :output_path))
               when "validate"
                 require_options!(options, *common, :request_path)
                 validation = validate!(**options.slice(*common, :request_path))
                 Result.new(document: validation.request, path: File.expand_path(options[:request_path]),
                            status: "VALIDATED", catalog_result: nil)
               when "approve", "decline"
                 require_options!(options, *common, :request_path, :output_path, :decided_by)
                 decide!(**options.slice(*common, :request_path, :output_path, :decided_by),
                         decision: action == "approve" ? "APPROVE" : "DECLINE")
               when "adopt"
                 require_options!(options, *common, :request_path, :approval_path, :result_path)
                 adopt!(**options.slice(*common, :request_path, :approval_path, :result_path))
               else
                 raise ValidationError,
                       "usage: af-final-release-adoption prepare|validate|approve|decline|adopt --inputs PATH --package PATH ..."
               end
      out.write StagedScoringAuthority.document_bytes(result.document)
      %w[NO_APPROVAL DECLINED].include?(result.status) ? 3 : 0
    rescue Error, SystemCallError, JSON::ParserError, Psych::Exception, KeyError, TypeError, ArgumentError,
           OptionParser::ParseError => e
      err.puts JSON.generate("schema_version" => RESULT_SCHEMA, "status" => "FAILED", "reason" => e.message)
      2
    end

    def self.require_options!(options, *keys)
      missing = keys.reject { |key| options[key] }
      raise ValidationError, "missing options: #{missing.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ')}" unless missing.empty?
    end
    private_class_method :require_options!

    def initialize(inputs_path:, package_path:)
      @inputs_path = File.expand_path(inputs_path)
      @package_path = File.expand_path(package_path)
    end

    def prepare!(output_path:)
      request, = build_request!
      path, reused = write_document(output_path, request, "adoption request")
      Result.new(document: request, path:, status: reused ? "VALIDATED" : "PREPARED", catalog_result: nil)
    end

    def validate!(request_path:)
      actual = read_json(request_path)
      expected, snapshot = build_request!
      check!(actual == expected && File.binread(request_path) == document_bytes(expected),
             "adoption request or its bound package inputs changed; prepare a fresh request")
      Validation.new(request: expected, snapshot:)
    end

    def decide!(request_path:, output_path:, decision:, decided_by:)
      validation = validate!(request_path:)
      decision = decision.to_s
      check!(%w[APPROVE DECLINE].include?(decision), "decision must be APPROVE or DECLINE")
      check!(decided_by.is_a?(String) && !decided_by.strip.empty?, "decided_by must identify the human decision owner")
      request_binding = binding(request_path)
      document = {
        "schema_version" => DECISION_SCHEMA,
        "issuer" => "af-data-pipeline",
        "decision" => decision,
        "decided_by" => decided_by.strip,
        "request" => {"request_id" => validation.request.fetch("request_id"), "path" => File.expand_path(request_path), **request_binding},
        "package_id" => validation.request.dig("package", "package_id")
      }
      document["decision_id"] = digest(document)
      path, = write_document(output_path, document, "adoption decision")
      status = decision == "APPROVE" ? "APPROVED" : "DECLINED"
      Result.new(document:, path:, status:,
                 catalog_result: nil)
    end

    def adopt!(request_path:, approval_path:, result_path:)
      request_path = File.expand_path(request_path)
      approval_path = File.expand_path(approval_path)
      unless File.file?(approval_path)
        return Result.new(document: transient_result("NO_APPROVAL", request_path), path: nil,
                          status: "NO_APPROVAL", catalog_result: nil)
      end

      request = read_json(request_path)
      decision = read_json(approval_path)
      validate_static_request!(request, request_path)
      validate_decision!(decision, approval_path, request, request_path)
      if decision.fetch("decision") == "DECLINE"
        document = terminal_result("DECLINED", request, decision, nil)
        path, = write_document(result_path, document, "adoption result")
        return Result.new(document:, path:, status: "DECLINED", catalog_result: nil)
      end

      check!(request.dig("package", "path") == @package_path && request.dig("package", "inputs", "path") == @inputs_path,
             "release package or inputs path differs from the adoption request")
      snapshot = snapshot_from_request(request)
      verify_review = lambda do |replay:|
        validate_review_inputs!(request, request_path)
        validate_decision!(decision, approval_path, request, request_path)
        check_result_destination!(result_path, snapshot) unless replay
      end
      CatalogAdoption.adopt!(snapshot:, before_mutation: ->(_fresh) { validate!(request_path:) },
                             verify_review:) do |catalog_result|
        persist_success(result_path, request, decision, catalog_result)
      end
    end

    private

    def build_request!
      package_result = FinalReleasePackage.validate!(inputs_path: @inputs_path, package_path: @package_path)
      package = package_result.package
      check!(package.dig("readiness", "ready"), "final release package is not ready for approval")
      check!(!package.dig("readiness", "approval_authorized") && !package.dig("readiness", "catalog_adoption_authorized"),
             "final release package must remain a decision input, not serialized approval")
      candidate = package.dig("candidate", "selected")
      proposed = package.dig("transition", "proposed_catalog_head")
      check!(candidate.is_a?(Hash) && proposed.is_a?(Hash), "final release package has no exact selected candidate")
      check!(candidate.slice("sha256", "bytes") == proposed.slice("sha256", "bytes"),
             "selected candidate differs from proposed catalog_head")
      snapshot = CatalogAdoption.prepare!(
        manifest_path: package.dig("provenance", "nodes", "current_project_state", "path"),
        candidate_path: candidate.fetch("path"),
        version: proposed.fetch("version"),
        scored_release: scored_release_references(package)
      )
      check!(snapshot.candidate == proposed, "catalog adoption candidate differs from the validated package")
      check!(snapshot.repository_head == package.dig("transition", "catalog_repository", "head") &&
             snapshot.repository_remote == package.dig("transition", "catalog_repository", "remote_url"),
             "catalog repository identity differs from the validated package")
      check!(snapshot.roles == package.dig("transition", "current_roles"),
             "approval-relevant project-state roles differ from the validated package")
      check!(snapshot.prior_manifest == package.dig("provenance", "nodes", "current_project_state").slice("sha256", "bytes"),
             "reviewed project-state manifest differs from the validated package")
      request = {
        "schema_version" => REQUEST_SCHEMA,
        "issuer" => "af-data-pipeline",
        "package" => {"package_id" => package.fetch("package_id"), "path" => @package_path, **binding(@package_path),
                      "inputs" => {"path" => @inputs_path, **binding(@inputs_path)},
                      "provenance_digest" => digest(package.dig("provenance", "nodes"))},
        "candidate" => {"selection" => package.dig("candidate", "selection"), "path" => snapshot.candidate_path,
                        **snapshot.candidate, "destination" => snapshot.destination},
        "catalog" => {"repository_root" => snapshot.repository_root, "remote_url" => snapshot.repository_remote,
                      "head" => snapshot.repository_head, "project_state" => {"path" => snapshot.manifest_path,
                      **snapshot.prior_manifest}, "roles" => snapshot.roles},
        "review" => {"compatibility" => snapshot.compatibility, "delta" => snapshot.review},
        "authority" => {"release_manifest" => package.dig("provenance", "nodes", "release_manifest"),
                        "evidence_digest" => digest(package.dig("provenance", "nodes")),
                        "independent_roles_preserved" => package.dig("transition", "independent_roles_preserved")}
      }
      request["request_id"] = digest(request)
      [request, snapshot]
    end

    def validate_static_request!(request, request_path)
      exact_keys!(request, %w[schema_version issuer package candidate catalog review authority request_id], "adoption request")
      check!(request["schema_version"] == REQUEST_SCHEMA && request["issuer"] == "af-data-pipeline",
             "unsupported adoption request")
      check!(request["request_id"] == digest(request.except("request_id")), "adoption request identity mismatch")
      check!(File.binread(request_path) == document_bytes(request), "adoption request bytes are not canonical")
      check_binding!(request.dig("package", "path"), request.fetch("package"), "release package")
      check_binding!(request.dig("package", "inputs", "path"), request.dig("package", "inputs"), "package inputs")
      package = read_json(request.dig("package", "path"))
      check!(package.fetch("package_id") == request.dig("package", "package_id") &&
             package.fetch("package_id") == digest(package.except("package_id")), "release package identity mismatch")
      check!(digest(package.dig("provenance", "nodes")) == request.dig("package", "provenance_digest") &&
             digest(package.dig("provenance", "nodes")) == request.dig("authority", "evidence_digest"),
             "release package evidence binding mismatch")
      check_binding!(request.dig("candidate", "path"), request.fetch("candidate"), "selected candidate")
      true
    rescue SystemCallError, KeyError, TypeError, NoMethodError => e
      raise ValidationError, "invalid adoption request: #{e.message}"
    end

    def validate_decision!(decision, approval_path, request, request_path)
      exact_keys!(decision, %w[schema_version issuer decision decided_by request package_id decision_id], "adoption decision")
      check!(decision["schema_version"] == DECISION_SCHEMA && decision["issuer"] == "af-data-pipeline",
             "unsupported adoption decision")
      check!(%w[APPROVE DECLINE].include?(decision["decision"]), "invalid adoption decision")
      check!(decision["decided_by"].is_a?(String) && !decision["decided_by"].empty?, "adoption decision has no owner")
      check!(decision["decision_id"] == digest(decision.except("decision_id")), "adoption decision identity mismatch")
      check!(File.binread(approval_path) == document_bytes(decision), "adoption decision bytes are not canonical")
      expected_request = {"request_id" => request.fetch("request_id"), "path" => File.expand_path(request_path), **binding(request_path)}
      check!(decision["request"] == expected_request && decision["package_id"] == request.dig("package", "package_id"),
             "adoption decision does not bind this exact request and package")
      true
    end

    # Check exact request bytes and remaining live package references under the
    # catalog lock. Scored references are revalidated by CatalogAdoption.
    # Returns true or raises ValidationError for changed evidence.
    def validate_review_inputs!(request, request_path)
      validate_static_request!(request, request_path)
      package = read_json(@package_path)
      return true if scored_release_references(package)
      package.dig("provenance", "nodes").each do |name, reference|
        next unless reference["path"]
        next if name == "current_project_state"
        check_binding!(reference.fetch("path"), reference, "package reference #{name}")
      end
      true
    end

    def snapshot_from_request(request)
      CatalogAdoption::Snapshot.new(
        manifest_path: request.dig("catalog", "project_state", "path"),
        repository_root: request.dig("catalog", "repository_root"),
        repository_head: request.dig("catalog", "head"),
        repository_remote: request.dig("catalog", "remote_url"),
        prior_manifest: request.dig("catalog", "project_state").slice("sha256", "bytes"),
        roles: request.dig("catalog", "roles"),
        candidate_path: request.dig("candidate", "path"),
        candidate: request.fetch("candidate").slice("version", "filename", "sha256", "bytes"),
        version: request.dig("candidate", "version"),
        destination: request.dig("candidate", "destination"),
        reuse_existing: nil,
        compatibility: request.dig("review", "compatibility"),
        review: request.dig("review", "delta"),
        scored_release: scored_release_references(read_json(@package_path))
      )
    end

    def scored_release_references(package)
      return nil unless package.dig("compatibility", "scored_new_id_authorization")
      nodes = package.fetch("provenance").fetch("nodes")
      {"release_manifest" => nodes.fetch("release_manifest"),
       "base" => nodes.fetch("authority:base"), "staged" => nodes.fetch("authority:staged"),
       "package" => {"path" => @package_path, **binding(@package_path)},
       "package_inputs" => {"path" => @inputs_path, **binding(@inputs_path)}}
        .merge(nodes["frontier_result"] ? {"frontier" => nodes.fetch("frontier_result")} : {})
        .transform_values { |reference| reference.slice("path", "sha256", "bytes") }
    end

    # Check that the result can be created without competing with catalog
    # storage or an existing output. Returns nil or raises ValidationError.
    def check_result_destination!(path, snapshot)
      PrivateDataRoot.destination!(path)
      path = File.expand_path(path)
      parent = File.dirname(path)
      check!(File.directory?(parent) && File.writable?(parent), "adoption result directory is not writable: #{parent}")
      target = File.join(File.realpath(parent), File.basename(path))
      workbook = File.join(File.realpath(File.dirname(snapshot.destination)), File.basename(snapshot.destination))
      check!(target != workbook && !File.exist?(path) && !File.symlink?(path),
             "adoption result output already exists or conflicts with the catalog destination")
      nil
    end

    def persist_success(path, request, decision, catalog_result)
      if File.file?(path)
        document = read_json(path)
        check!(%w[PROMOTED ALREADY_PROMOTED].include?(document["status"]) &&
               document["request_id"] == request["request_id"] &&
               document["decision_id"] == decision["decision_id"] &&
               document["package_id"] == request.dig("package", "package_id") &&
               document["candidate"] == request.fetch("candidate").slice("version", "filename", "sha256", "bytes") &&
               document["result_id"] == digest(document.except("result_id")) &&
               File.binread(path) == document_bytes(document),
               "existing adoption result does not prove this exact request and decision")
        check_binding!(document.dig("catalog", "project_state", "path"),
                       document.dig("catalog", "project_state"), "adopted project state")
        if document.fetch("status") != catalog_result.status
          check!(document.fetch("status") == "PROMOTED" && catalog_result.status == "ALREADY_PROMOTED",
                 "existing adoption result conflicts with the current catalog outcome")
          durable_path = File.expand_path(path)
          response = document.to_h.merge(
            "status" => catalog_result.status,
            "durable" => false,
            "durable_result" => {"path" => durable_path, "status" => document.fetch("status"),
                                 "result_id" => document.fetch("result_id"), **binding(path)}
          )
          response["result_id"] = digest(response.except("result_id"))
          return Result.new(document: response, path: durable_path, status: catalog_result.status, catalog_result:)
        end
        return Result.new(document:, path: File.expand_path(path), status: catalog_result.status, catalog_result:)
      end
      status = catalog_result.status
      document = terminal_result(status, request, decision, catalog_result)
      result_path, = write_document(path, document, "adoption result")
      Result.new(document:, path: result_path, status:, catalog_result:)
    end

    def terminal_result(status, request, decision, catalog_result)
      document = {
        "schema_version" => RESULT_SCHEMA,
        "issuer" => "af-data-pipeline",
        "status" => status,
        "request_id" => request.fetch("request_id"),
        "decision_id" => decision.fetch("decision_id"),
        "package_id" => request.dig("package", "package_id"),
        "candidate" => request.fetch("candidate").slice("version", "filename", "sha256", "bytes"),
        "catalog" => if catalog_result
                       {"repository_root" => request.dig("catalog", "repository_root"),
                        "head" => request.dig("catalog", "head"),
                        "catalog_head" => request.fetch("candidate").slice("version", "filename", "sha256", "bytes"),
                        "project_state" => {"path" => request.dig("catalog", "project_state", "path"),
                                            **binding(request.dig("catalog", "project_state", "path"))},
                        "independent_roles" => request.dig("catalog", "roles").except("catalog_head")}
                     end
      }
      document["result_id"] = digest(document)
      document
    end

    def transient_result(status, request_path)
      {"schema_version" => RESULT_SCHEMA, "issuer" => "af-data-pipeline", "status" => status,
       "request_path" => File.expand_path(request_path), "durable" => false}
    end

    def write_document(path, document, label)
      PrivateDataRoot.destination!(path)
      path = File.expand_path(path)
      bytes = document_bytes(document)
      if File.exist?(path)
        check!(File.binread(path) == bytes, "#{label} output already exists with different bytes")
        return [path, true]
      end
      Tempfile.create([".final-release-adoption-", ".json"], File.dirname(path)) do |temp|
        temp.write(bytes)
        temp.flush
        temp.fsync
        begin
          File.link(temp.path, path)
        rescue Errno::EEXIST
          check!(File.binread(path) == bytes, "#{label} output was created concurrently with different bytes")
          return [path, true]
        end
      end
      [path, false]
    end

    def binding(path)
      {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
    end

    def check_binding!(path, expected, label)
      check!(binding(path) == expected.slice("sha256", "bytes"), "#{label} changed")
    end

    def digest(value)
      StandingBulkScorePolicy.digest(value)
    end

    def document_bytes(value)
      StagedScoringAuthority.document_bytes(value)
    end

    def read_json(path)
      value = JSON.parse(File.binread(path), object_class: StagedScoringAuthority::UniqueObject)
      check!(value.is_a?(Hash), "JSON reference must contain an object: #{path}")
      value
    end

    def exact_keys!(value, keys, label)
      check!(value.is_a?(Hash) && value.keys.sort == keys.sort, "#{label} has unexpected or missing fields")
    end

    def check!(condition, message)
      raise ValidationError, message unless condition
    end
  end
end
