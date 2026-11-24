# frozen_string_literal: true

module AfDataPipeline
  # Optional V2 producer for an exact IG-17 release. No inference, approvals,
  # shared-role mutation, latest-file discovery or legacy batch commands.
  class FrontierResidualScoring
    REQUEST_SCHEMA = "af-frontier-residual-request/v0.2"
    PACKET_SCHEMA = "af-frontier-residual-packet/v0.2"
    HANDOFF_SCHEMA = "af-frontier-residual-handoff/v0.2"
    ACCOUNTING_SCHEMA = "af-frontier-supplement-accounting/v0.2"
    PACKET_FILES = %w[handoff.json prompt.md return.schema.json return-template.json packet.json].freeze
    RESULT_FILES = %w[handoff.json return.json authorization.json intermediate.xlsx apply.json finalize.json
                      candidate.xlsx accounting.json package-inputs.json result.json].freeze
    DECLINE_FILES = %w[handoff.json package-inputs.json result.json].freeze
    Result = Data.define(:status, :path, :document, :reused)

    def self.prepare!(request_path:, output_dir:)
      new(request_path:).prepare!(output_dir:)
    end

    def self.apply!(request_path:, packet_dir:, return_path:, output_dir:, fault_injector: nil)
      new(request_path:, fault_injector:).complete!(packet_dir:, return_path:, output_dir:)
    end

    def self.decline!(request_path:, packet_dir:, output_dir:)
      new(request_path:).complete!(packet_dir:, return_path: nil, output_dir:)
    end

    def self.verify!(request_path:, packet_dir:, output_dir:)
      new(request_path:).verify!(packet_dir:, output_dir:)
    end

    def self.run(argv, out: $stdout, err: $stderr)
      action = argv.shift
      allowed = {"prepare" => %w[--request --output], "apply" => %w[--request --packet --return --output],
                 "decline" => %w[--request --packet --output], "verify" => %w[--request --packet --output]}
      flags = allowed[action]
      check!(flags && argv.length == flags.length * 2 && argv.each_slice(2).map(&:first).sort == flags.sort,
             "usage: af-frontier-residual-scoring prepare|apply|decline|verify --request REQUEST.json " \
             "[--packet DIR] [--return RETURN.json] --output DIR")
      options = argv.each_slice(2).to_h
      service = new(request_path: options.fetch("--request"))
      result = case action
               when "prepare" then service.prepare!(output_dir: options.fetch("--output"))
               when "verify" then service.verify!(packet_dir: options.fetch("--packet"), output_dir: options.fetch("--output"))
               else service.complete!(packet_dir: options.fetch("--packet"), return_path: options["--return"],
                                      output_dir: options.fetch("--output"))
               end
      out.puts JSON.pretty_generate("schema_version" => PACKET_SCHEMA, "status" => result.status,
                                   "path" => result.path, "reused" => result.reused, "result" => result.document)
      0
    rescue Error, SystemCallError, JSON::ParserError, Psych::Exception, KeyError, TypeError, ArgumentError => e
      err.puts JSON.generate("schema_version" => PACKET_SCHEMA, "status" => "BLOCKED", "reason" => e.message)
      2
    end

    def initialize(request_path:, fault_injector: nil)
      @request_path = File.expand_path(request_path)
      @fault_injector = fault_injector
    end

    # Read-only reconstruction also used by the independent result consumer.
    # Replaying the public original package rechecks the complete evidence graph,
    # current catalog observation, terminal workload and all editorial authority.
    def handoff!(replay_observation: nil)
      request = read_json(@request_path)
      keys!(request, %w[schema_version original_package_inputs_path original_package_path rubric successor_version])
      check!(request["schema_version"] == REQUEST_SCHEMA, "unsupported frontier request")
      %w[original_package_inputs_path original_package_path].each { |key| absolute!(request.fetch(key)) }
      inputs = read_json(request.fetch("original_package_inputs_path"))
      check!(inputs["frontier_result_path"].nil?, "frontier supplements cannot chain or rebind an earlier supplement")
      package = FinalReleasePackage.validate!(inputs_path: request.fetch("original_package_inputs_path"),
                                              package_path: request.fetch("original_package_path"), replay_observation:).package
      manifest = read_json(inputs.fetch("release_manifest_path"))
      original = package.dig("candidate", "original").fetch("path")
      targets = FrontierReleaseEvidence.residual_targets(manifest:, original:)
      @context = {request:, inputs:, package:, manifest:, original:}
      return nil if targets.empty?

      rubric = request.fetch("rubric")
      keys!(rubric, %w[id path sha256 bytes])
      check!(rubric["id"].is_a?(String) && !rubric["id"].strip.empty?, "explicit frozen rubric identity required")
      absolute!(rubric.fetch("path"))
      check!(binding(rubric.fetch("path")) == rubric.slice("sha256", "bytes") && rubric["bytes"].positive?, "frozen rubric is empty or its bytes differ")
      version = request["successor_version"]
      prior = manifest.dig("lineage", "staged_amc", "filename")[/Catalog_(.*)\.xlsx\z/, 1]
      check!(version.is_a?(String) && ProjectState::VERSION_RE.match?(version) &&
             Gem::Version.new(version) > Gem::Version.new(prior), "explicit newer successor version required")
      refs = package.dig("provenance", "nodes").filter_map do |name, ref|
        next unless ref["path"]
        next if name == "release_input:current_project_state"
        # Include the complete retained evidence graph, not only the score rows.
        [name.delete_prefix("release_input:"), ref.slice("path", "sha256", "bytes")]
      end.to_h
      refs["rubric"] = rubric.slice("path", "sha256", "bytes")
      refs["frontier_request"] = {"path" => @request_path, **binding(@request_path)}
      refs["original_package"] = {"path" => request.fetch("original_package_path"), **binding(request.fetch("original_package_path"))}
      targets = targets.map do |target|
        residual = manifest.fetch("residuals").find { |row| row["candidate_key"] == target["candidate_key"] }
        target.merge("reason" => residual.fetch("reason"), "original_state" => "terminal_unsupported_scope_blank")
      end
      seal({"schema_version" => HANDOFF_SCHEMA, "release_id" => manifest.fetch("release_id"),
            "manifest_id" => manifest.fetch("manifest_id"), "lineage" => manifest.fetch("lineage"),
            "operation" => package.fetch("operation"), "source" => package.fetch("source"),
            "rubric" => rubric.slice("id", "sha256", "bytes"), "successor_version" => version,
            "population" => package.dig("release", "population"),
            "original_candidate" => binding(original), "targets" => targets, "references" => refs}, "handoff_id")
    rescue SystemCallError, JSON::ParserError, Psych::Exception, KeyError, TypeError, NoMethodError, ArgumentError => e
      raise ValidationError, "invalid frontier request: #{e.message}"
    end

    def prepare!(output_dir:)
      PrivateDataRoot.destination!(output_dir)
      handoff = handoff!
      unless handoff
        check!(!File.exist?(output_dir), "no writable gaps; existing packet output is conflicting")
        return Result.new(status: "NO_GAPS", path: nil, document: {"targets" => 0, "frontier_required" => false}, reused: false)
      end
      files = packet_bytes(handoff)
      path = File.expand_path(output_dir)
      guard_output!(path)
      if File.exist?(path)
        exact_directory!(path, files)
        return Result.new(status: "READY", path: File.join(path, "packet.json"), document: JSON.parse(files.fetch("packet.json")), reused: true)
      end
      publish_directory!(path) do
        files.except("packet.json").each { |name, bytes| write_new!(File.join(path, name), bytes) }
        check!(handoff! == handoff, "frontier inputs changed during packet preparation")
        write_new!(File.join(path, "packet.json"), files.fetch("packet.json"))
      end
      Result.new(status: "READY", path: File.join(path, "packet.json"), document: JSON.parse(files.fetch("packet.json")), reused: false)
    end

    def verify!(packet_dir:, output_dir:)
      handoff = validated_packet!(packet_dir)
      verify_result!(File.expand_path(output_dir), handoff)
    end

    def complete!(packet_dir:, return_path:, output_dir:)
      PrivateDataRoot.destination!(output_dir)
      handoff = validated_packet!(packet_dir)
      returned = return_path && read_json(return_path)
      accepted = returned && self.class.validate_return!(handoff:, returned:, original: @context.fetch(:original))
      path = File.expand_path(output_dir)
      guard_output!(path, packet_dir:)
      if File.exist?(path)
        result = verify_result!(path, handoff)
        expected_disposition = returned ? "APPLIED" : "DECLINED"
        check!(result.status == expected_disposition, "conflicting frontier disposition")
        check!(read_json(File.join(path, "return.json")) == returned, "conflicting frontier return") if returned
        return result
      end
      manifest_path = @context.fetch(:inputs).fetch("release_manifest_path")
      result = nil
      publish_directory!(path) do
        write_json!(File.join(path, "handoff.json"), handoff)
        artifacts = {"handoff" => artifact(path, "handoff.json")}
        if returned
          write_json!(File.join(path, "return.json"), returned)
          authorization = seal({"schema_version" => FrontierReleaseEvidence::AUTHORIZATION_SCHEMA,
                                "release_id" => handoff.fetch("release_id"), "handoff_id" => handoff.fetch("handoff_id"),
                                "return_id" => returned.fetch("return_id"), "authority" => "frontier_manual",
                                "accepted_candidates" => accepted}, "authorization_id")
          write_json!(File.join(path, "authorization.json"), authorization)
          applied = AmcApply.apply_authorized!(authorized_candidates: accepted, authorization:,
            accounting: {"source_holds" => 0, "held_candidates" => 0, "rejected_candidates" => 0, "pending_candidates" => 0},
            amc_path: @context.fetch(:original), output_path: File.join(path, "intermediate.xlsx"), report_path: File.join(path, "apply.json"))
          @fault_injector&.call(:after_apply)
          AmcFinalize.finalize!(amc_path: applied.output_path, apply_report_path: applied.report_path,
            output_path: File.join(path, "candidate.xlsx"), report_path: File.join(path, "finalize.json"), expected_cells: accepted.length)
          @fault_injector&.call(:after_finalize)
          accounting = self.class.accounting(handoff:, returned:, candidate_path: File.join(path, "candidate.xlsx"))
          write_json!(File.join(path, "accounting.json"), accounting)
          {"return" => "return.json", "authorization" => "authorization.json", "intermediate" => "intermediate.xlsx",
           "apply_report" => "apply.json", "finalize_report" => "finalize.json", "candidate" => "candidate.xlsx",
           "accounting" => "accounting.json"}.each { |key, name| artifacts[key] = artifact(path, name) }
        end
        document = seal({"schema_version" => FrontierReleaseEvidence::SCHEMA,
                         "disposition" => returned ? "APPLIED" : "DECLINED",
                         "original_manifest" => binding(manifest_path), "original_candidate" => handoff.fetch("original_candidate"),
                         "artifacts" => artifacts, "version" => returned ? handoff.fetch("successor_version") : nil,
                         "counts" => {"writes" => accepted&.length || 0, "no_writes" => handoff.fetch("targets").length - (accepted&.length || 0)}}, "result_id")
        package_inputs = @context.fetch(:inputs).merge("frontier_result_path" => File.join(path, "result.json"))
        write_json!(File.join(path, "package-inputs.json"), package_inputs)
        # A pending result is not a completion marker. Both independent workbook
        # proofs and compatibility must succeed before publishing result.json.
        pending = File.join(path, ".pending-result.json")
        write_json!(pending, document)
        verify_evidence!(pending)
        check!(handoff! == handoff, "frontier inputs changed during supplementation")
        check!(read_json(return_path) == returned, "frontier return changed during application") if return_path
        @fault_injector&.call(:before_publication)
        verify_evidence!(pending)
        File.unlink(pending)
        write_json!(File.join(path, "result.json"), document)
        result = Result.new(status: document.fetch("disposition"), path: File.join(path, "result.json"), document:, reused: false)
      end
      result
    end

    def self.validate_return!(handoff:, returned:, original:)
      keys!(returned, %w[schema_version handoff_id return_id records])
      check!(returned["schema_version"] == FrontierReleaseEvidence::RETURN_SCHEMA &&
             returned["handoff_id"] == handoff["handoff_id"] &&
             returned["return_id"] == StandingBulkScorePolicy.digest(returned.except("return_id")), "frontier return identity differs")
      targets = handoff.fetch("targets").to_h { |row| [row.fetch("candidate_key"), row] }
      rows = returned["records"]
      check!(rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) } &&
             rows.map { |row| row["candidate_key"] }.sort == targets.keys.sort, "exactly one return per target required")
      rows.each do |row|
        keys!(row, %w[candidate_key proposed_value reason source_references])
        refs = row["source_references"]
        check!(row["reason"].is_a?(String) && !row["reason"].strip.empty? &&
               refs.is_a?(Array) && refs.all? { |ref| ref.is_a?(String) } &&
               refs.uniq == refs && !(refs & handoff.fetch("references").keys.grep(/\Aauthority:source:/)).empty? &&
               (refs - handoff.fetch("references").keys).empty?, "source-linked reasoning required for writes and uncertainty")
        value = row["proposed_value"]
        next if value.nil?
        dimension = targets.fetch(row.fetch("candidate_key")).fetch("dimension")
        valid = if ["Level Start", "Level End"].include?(dimension)
                  value.is_a?(Integer) && value.between?(1, 20)
                elsif ["# of Sessions", "Number of Sessions"].include?(dimension)
                  value.is_a?(Integer) && value.positive?
                else
                  value.is_a?(Integer) && value.between?(1, 5)
                end
        check!(AmcApply::DIMENSION_HEADERS.key?(dimension) && valid, "unsupported frontier value for #{dimension}")
      end
      accepted = rows.reject { |row| row["proposed_value"].nil? }.sort_by { |row| row.fetch("candidate_key") }.map do |row|
        targets.fetch(row.fetch("candidate_key")).slice("candidate_key", "adventure_id", "dimension")
          .merge("proposed_value" => row.fetch("proposed_value"))
      end
      validate_levels!(accepted, original)
      accepted
    rescue SystemCallError, KeyError, TypeError, NoMethodError, ArgumentError => e
      raise ValidationError, "invalid frontier return: #{e.message}"
    end

    def self.validate_levels!(accepted, original)
      level_rows = accepted.select { |row| ["Level Start", "Level End"].include?(row["dimension"]) }
      return if level_rows.empty?
      sheet = AmcApply::Workbook.new(original).catalog_sheet!
      sheet.resolve_headers!(["Level Start", "Level End"])
      level_rows.group_by { |row| row.fetch("adventure_id") }.each do |id, rows|
        values = ["Level Start", "Level End"].map do |dimension|
          write = rows.find { |row| row["dimension"] == dimension }
          next write.fetch("proposed_value") if write
          cell = sheet.cell("#{sheet.column_for_dimension(dimension)}#{sheet.row_for_adventure(id)}")
          next nil if sheet.blank_cell?(cell)
          value = sheet.cell_numeric_value(cell)
          check!(!sheet.cell_formula(cell) && value.is_a?(Numeric) && value.finite? &&
                 value == value.to_i && value.between?(1, 20), "unprovable existing Levels sibling")
          value
        end
        check!(!values.all? || values[0] <= values[1], "#{id}: effective Level Start exceeds Level End")
      end
    end

    def self.accounting(handoff:, returned:, candidate_path:)
      before = handoff.fetch("population")
      writes = returned.fetch("records").count { |row| !row["proposed_value"].nil? }
      {"schema_version" => ACCOUNTING_SCHEMA, "handoff_id" => handoff.fetch("handoff_id"),
       "return_id" => returned.fetch("return_id"), "authority" => "frontier_manual",
       "original_candidate" => handoff.fetch("original_candidate"),
       "derived_candidate" => StandingBulkScorePolicy.file_binding(candidate_path),
       "before" => before, "after" => before.merge(
         "frontier_written_metrics" => writes, "frontier_no_write_metrics" => returned.fetch("records").length - writes,
         "remaining_blank_metrics" => before.fetch("remaining_blank_metrics") - writes,
         "present_metrics" => before.fetch("present_metrics") + writes,
         "residual_gap_metrics" => before.fetch("terminal_gap_metrics") - writes),
       "metric_actions" => returned.fetch("records").sort_by { |row| row.fetch("candidate_key") }.map do |row|
         row.merge("action" => row["proposed_value"].nil? ? "no_write" : "written", "authority" => "frontier_manual")
       end}
    end

    def self.check!(condition, message)
      raise ValidationError, message unless condition
    end

    def self.keys!(value, keys)
      check!(value.is_a?(Hash) && value.keys.sort == keys.sort, "unexpected or missing frontier fields")
    end

    private

    def validated_packet!(path)
      handoff = handoff!
      check!(handoff, "no writable residuals; no frontier interaction is required")
      exact_directory!(File.expand_path(path), packet_bytes(handoff))
      handoff
    end

    def verify_result!(path, handoff)
      check!(File.file?(File.join(path, "result.json")), "partial frontier publication: completion result is absent")
      document = read_json(File.join(path, "result.json"))
      names = document["disposition"] == "DECLINED" ? DECLINE_FILES : RESULT_FILES
      check!(Dir.children(path).sort == names.sort, "partial or unexpected frontier publication")
      check!(read_json(File.join(path, "handoff.json")) == handoff, "retained frontier handoff differs")
      check!(read_json(File.join(path, "package-inputs.json")) ==
             @context.fetch(:inputs).merge("frontier_result_path" => File.join(path, "result.json")), "consumer inputs differ")
      verify_evidence!(File.join(path, "result.json"))
      Result.new(status: document.fetch("disposition"), path: File.join(path, "result.json"), document:, reused: true)
    end

    def verify_evidence!(result_path)
      nodes = @context.fetch(:package).dig("provenance", "nodes")
      options = {release_manifest_path: @context.fetch(:inputs).fetch("release_manifest_path"),
                 staged_path: nodes.fetch("authority:staged").fetch("path"),
                 base_path: nodes.fetch("authority:base").fetch("path")}
      proof = FrontierReleaseEvidence.validate!(path: result_path, **options)
      compatibility = AmcCompatibilityCheck.new(candidate_path: proof.candidate_path,
                                                frontier_result_path: result_path, **options).check
      check!(compatibility["status"] == "PASS", "derived candidate compatibility failed: #{compatibility['errors']}")
      proof
    end

    def packet_bytes(handoff)
      template = {"schema_version" => FrontierReleaseEvidence::RETURN_SCHEMA, "handoff_id" => handoff.fetch("handoff_id"),
                  "return_id" => "REPLACE_WITH_CANONICAL_SHA256", "records" => handoff.fetch("targets").map do |row|
                    {"candidate_key" => row.fetch("candidate_key"), "proposed_value" => nil,
                     "reason" => "", "source_references" => []}
                  end}
      sources = handoff.fetch("references").keys.grep(/\Aauthority:source:/).sort
      schema = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object",
                "additionalProperties" => false, "required" => %w[schema_version handoff_id return_id records],
                "properties" => {"schema_version" => {"const" => FrontierReleaseEvidence::RETURN_SCHEMA},
                  "handoff_id" => {"const" => handoff.fetch("handoff_id")}, "return_id" => {"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
                  "records" => {"type" => "array", "minItems" => handoff.fetch("targets").length, "maxItems" => handoff.fetch("targets").length,
                    "items" => {"type" => "object", "additionalProperties" => false,
                      "required" => %w[candidate_key proposed_value reason source_references], "properties" => {
                        "candidate_key" => {"enum" => handoff.fetch("targets").map { |row| row.fetch("candidate_key") }},
                        "proposed_value" => {"type" => ["integer", "null"]}, "reason" => {"type" => "string", "minLength" => 1},
                        "source_references" => {"type" => "array", "minItems" => 1, "uniqueItems" => true,
                          "items" => {"enum" => handoff.fetch("references").keys}, "contains" => {"enum" => sources}}}}}}}
      schema.dig("properties", "records", "items")["allOf"] = handoff.fetch("targets").map do |target|
        dimension = target.fetch("dimension")
        bounds = {"minimum" => 1}
        bounds["maximum"] = ["Level Start", "Level End"].include?(dimension) ? 20 : 5 unless ["# of Sessions", "Number of Sessions"].include?(dimension)
        {"if" => {"properties" => {"candidate_key" => {"const" => target.fetch("candidate_key")}}},
         "then" => {"properties" => {"proposed_value" => {"anyOf" => [{"type" => "null"}, {"type" => "integer", **bounds}]}}}}
      end
      prompt = <<~PROMPT
        Complete only the terminal residual score keys in handoff.json for this exact release.
        Use the frozen rubric #{handoff.dig("rubric", "id")} and canonical source attachments listed below.
        The handoff binds operation, edition/source, approved boundaries, workload/receipt evidence,
        original candidate state, per-key reasons and complete population accounting.
        Do not rescore other keys, override HOLD/REJECT/source decisions, alter a workbook,
        broaden the qualified/page scope, or attribute your response to local inference or human approval.
        Treat Level Start and Level End as independent keys. Integers must be 1..20 for levels,
        positive for sessions, and 1..5 for other supported metrics. Effective start cannot exceed end.
        If a responsible value cannot be supplied, return null and explain the source limitation;
        do not guess a level from its sibling. Cite canonical source reference names and
        page/section evidence in reason for every write or no-write.
        Return return.json matching return.schema.json and the template, exactly once per key.
        Preserve handoff_id. Calculate return_id as SHA-256 of UTF-8 compact JSON with recursively
        sorted object keys, preserving array order and excluding return_id; do not use a placeholder.
        The pipeline checks the digest, exact population and metric/Levels constraints beyond JSON Schema.
        Return structured results only; no original adventure material or fabricated per-score approval.

        Attach handoff.json, return.schema.json, return-template.json, this prompt, and the following
        explicitly named frozen evidence files (paths are locators; SHA-256/bytes are in handoff.json):
        #{handoff.fetch("references").sort.map { |name, ref| "#{name}: #{ref.fetch('path')}" }.join("\n")}
      PROMPT
      files = {"handoff.json" => bytes(handoff), "prompt.md" => prompt,
               "return.schema.json" => bytes(schema), "return-template.json" => bytes(template)}
      packet = seal({"schema_version" => PACKET_SCHEMA, "handoff_id" => handoff.fetch("handoff_id"),
                     "files" => files.to_h { |name, content| [name, {"sha256" => Digest::SHA256.hexdigest(content), "bytes" => content.bytesize}] }}, "packet_id")
      files.merge("packet.json" => bytes(packet))
    end

    def publish_directory!(path)
      check!(File.directory?(File.dirname(path)), "frontier output parent must already exist")
      Dir.mkdir(path)
      # Deliberately retain an interrupted directory: replay requires the exact
      # complete artifact set and can never announce a partial candidate.
      yield
    rescue Errno::EEXIST
      raise ValidationError, "frontier output exists or was created concurrently"
    end

    def guard_output!(path, packet_dir: nil)
      inputs = @context.fetch(:inputs)
      release_inputs = read_json(inputs.fetch("release_inputs_path"))
      staged = release_inputs.fetch("staged_scoring")
      review = release_inputs.fetch("workload_review")
      protected = [File.dirname(inputs.fetch("release_manifest_path")), inputs.fetch("catalog_repository_root"),
                   staged.fetch("store_root"), staged.dig("evidence", "source_root"),
                   review.fetch("review_dir"), review.fetch("audit_dir"), review.fetch("afw_root"), packet_dir].compact
      parent = File.realpath(File.dirname(path))
      resolved = File.exist?(path) ? File.realpath(path) : File.join(parent, File.basename(path))
      protected.each do |root|
        root = File.realpath(root)
        check!(resolved != root && !resolved.start_with?(root + File::SEPARATOR),
               "frontier output overlaps protected source, release, catalog, workload or packet storage")
      end
    end

    def exact_directory!(path, files)
      check!(File.directory?(path) && Dir.children(path).sort == files.keys.sort &&
             files.all? { |name, content| File.binread(File.join(path, name)) == content }, "partial, changed or conflicting frontier packet")
    end

    def write_new!(path, content)
      Tempfile.create([".frontier-", ".tmp"], File.dirname(path)) do |temp|
        temp.binmode
        temp.write(content)
        temp.flush
        temp.fsync
        File.link(temp.path, path)
      end
    end

    def write_json!(path, value) = write_new!(path, bytes(value))
    def bytes(value) = StagedScoringAuthority.document_bytes(value)
    def seal(value, key) = value.merge(key => StandingBulkScorePolicy.digest(value))
    def binding(path) = StandingBulkScorePolicy.file_binding(path)
    def artifact(root, name) = {"filename" => name, **binding(File.join(root, name))}
    def read_json(path)
      JSON.parse(File.binread(path), object_class: StagedScoringAuthority::UniqueObject)
    rescue JSON::ParserError => e
      raise ValidationError, "invalid frontier JSON: #{e.message}"
    end
    def check!(condition, message) = self.class.check!(condition, message)
    def keys!(value, keys) = self.class.keys!(value, keys)
    def absolute!(path) = check!(path.is_a?(String) && Pathname.new(path).absolute?, "explicit absolute artifact locator required")
  end
end
