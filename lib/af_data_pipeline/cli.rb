# frozen_string_literal: true
require "optparse"
require "shellwords"
module AfDataPipeline
  class CLI
    def self.run(argv,out:$stdout,err:$stderr); new(out:,err:).run(argv.dup); end
    def initialize(out:,err:); @out=out; @err=err; end
    def run(argv)
      command=argv.shift
      case command
      when nil,"help","--help","-h" then @out.puts(help); 0
      when "version","--version","-v" then @out.puts(AfDataPipeline::VERSION); 0
      when "evidence-lookup" then evidence_lookup_command(argv)
      when "evidence-retrieve" then evidence_retrieve_command(argv)
      when "evidence-index-verify" then evidence_index_verify_command(argv)
      when "scan" then scan_command(argv)
      when "normalize" then normalize_command(argv)
      when "horizontal-review" then horizontal_review_command(argv)
      when "production-review" then production_review_command(argv)
      when "prepare-review" then prepare_review_command(argv)
      when "prepare-workload-review" then prepare_workload_review_command(argv)
      when "editorial-audit-init" then editorial_audit_init_command(argv)
      when "editorial-audit-validate" then editorial_audit_validate_command(argv)
      when "boundary-freeze-init" then boundary_freeze_init_command(argv)
      when "boundary-freeze-validate" then boundary_freeze_validate_command(argv)
      when "boundary-freeze-apply" then boundary_freeze_apply_command(argv)
      when "boundary-freeze-stage" then boundary_freeze_stage_command(argv)
      when "amc-apply" then amc_apply_command(argv)
      when "amc-finalize" then amc_finalize_command(argv)
      else @err.puts("ERROR: unknown command #{command.inspect}\n\n#{help}"); 2 end
    rescue OptionParser::ParseError, AfDataPipeline::Error => e
      @err.puts("ERROR: #{e.message}"); 2
    end
    private
    def scan_command(argv)
      options,source=parse_source_command(argv,default_output:"output/scan")
      with_scan(source) do |entries,workspace|
        FileUtils.mkdir_p(options[:output]); write_jsonl(File.join(options[:output],"inventory.jsonl"),entries.map(&:to_h))
        report={"schema_version"=>"af-data-integrity-report/v0.1","source"=>File.expand_path(source),"source_type"=>workspace.source_type,"files_scanned"=>entries.length}
        File.write(File.join(options[:output],"integrity_report.json"),JSON.pretty_generate(report)+"\n")
        @out.puts("Scanned #{entries.length} files\nWrote #{options[:output]}")
      end; 0
    end
    def normalize_command(argv)
      options,source=parse_source_command(argv,default_output:"output/review")
      status=0
      with_scan(source) do |entries,workspace|
        n=Normalizer.new.normalize(entries); ReviewPacketWriter.new(options[:output]).write!(entries:,normalization:n,source:,source_type:workspace.source_type)
        @out.puts("Scanned: #{entries.length}\nNormalized records: #{n.records.length}\nUnrecognized files: #{n.unrecognized_files.length}\nErrors: #{n.errors.length}\nWrote #{options[:output]}")
        status=1 unless n.errors.empty?
      end; status
    end
    def horizontal_review_command(argv)
      options={output:PrivateDataRoot.default_path("output/horizontal-review"),through:nil,dimension:nil,expected_count:nil}
      OptionParser.new do |o|
        o.on("--output DIR","Output directory (default: output/horizontal-review)") { |v| options[:output]=v }
        o.on("--through ADV_ID","Inclusive Adventure ID boundary") { |v| options[:through]=v }
        o.on("--dimension NAME","Inclusive dimension boundary") { |v| options[:dimension]=v }
        o.on("--expect-count N",Integer,"Fail closed unless exactly N logical results are selected") { |v| options[:expected_count]=v }
      end.parse!(argv)
      source=argv.shift
      raise OptionParser::MissingArgument,"PATH" unless source
      raise OptionParser::MissingArgument,"--through ADV_ID" unless options[:through]
      raise OptionParser::MissingArgument,"--dimension NAME" unless options[:dimension]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      status=0
      with_scan(source) do |entries,workspace,root|
        extraction=Adapters::HorizontalDiscoveryV1.new(root:,entries:).extract(
          through:options[:through],
          dimension:options[:dimension],
          expected_count:options[:expected_count]
        )
        HorizontalReviewWriter.new(options[:output]).write!(entries:,extraction:,source:,source_type:workspace.source_type)
        @out.puts("Scanned: #{entries.length}\nLogical results discovered: #{extraction.all_records.length}\nSelected through boundary: #{extraction.records.length}\nRecords after boundary: #{extraction.excluded_records.length}\nErrors: #{extraction.errors.length}\nWrote #{options[:output]}")
        status=1 unless extraction.errors.empty?
      end
      status
    end
    def production_review_command(argv)
      options={output:PrivateDataRoot.default_path("output/production-review"),expected_candidates:nil,progress:nil}
      OptionParser.new do |o|
        o.on("--output DIR","Output directory (default: output/production-review)") { |v| options[:output]=v }
        o.on("--expect-candidates N",Integer,"Fail closed unless exactly N complete production candidates are found") do |v|
          raise OptionParser::InvalidArgument,"--expect-candidates must be positive" unless v.positive?
          options[:expected_candidates]=v
        end
        o.on("--progress","Force incremental progress output on stderr") { options[:progress]=true }
        o.on("--no-progress","Suppress incremental progress output") { options[:progress]=false }
      end.parse!(argv)
      source=argv.shift
      raise OptionParser::MissingArgument,"PATH" unless source
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      status=0
      progress = progress_callback(options[:progress])
      @err.puts("[open] #{source}") if progress
      with_scan(source, progress:) do |entries,workspace,root|
        extraction=Adapters::ProductionSnapshotV1.new(root:,entries:,progress:).extract(expected_candidates:options[:expected_candidates])
        @err.puts("[write] writing review packet to #{options[:output]}") if progress
        ProductionReviewWriter.new(options[:output]).write!(entries:,extraction:,source:,source_type:workspace.source_type)
        lines = [
          "Scanned: #{entries.length}",
          "Run packages discovered: #{extraction.runs.length}",
          "Incomplete runs: #{extraction.runs.count { |run| run['mechanical_status'] == 'incomplete' }}",
          "Production candidates: #{extraction.candidates.length}",
          "Review holds: #{extraction.holds.length}",
          "Unique candidate keys: #{extraction.candidates.map { |candidate| candidate['candidate_key'] }.uniq.length}",
          "Errors: #{extraction.errors.length}",
          "Wrote #{options[:output]}"
        ]
        if extraction.errors.empty?
          repo_root = File.expand_path("../..", __dir__)
          executable = File.join(repo_root, "bin", "af-data")
          lines << ""
          lines << "Next command template:"
          lines << "  1. cd #{Shellwords.escape(repo_root)}"
          lines << "     #{Shellwords.escape(executable)} editorial-audit-init " \
                   "#{Shellwords.escape(File.expand_path(options[:output]))} --audit-dir AUDIT_DIR"
        end
        @out.puts(lines.join("\n"))
        status=1 unless extraction.errors.empty?
      end
      status
    end
    def prepare_review_command(argv)
      options={afw_root:nil,review_dir:nil,audit_dir:nil}
      OptionParser.new do |o|
        o.on("--afw-root DIR","AFW repository root used to resolve receipt artifact references") { |v| options[:afw_root]=v }
        o.on("--review-dir DIR","Deterministic generated review package directory") { |v| options[:review_dir]=v }
        o.on("--audit-dir DIR","Durable existing editorial decision ledger directory") { |v| options[:audit_dir]=v }
      end.parse!(argv)
      receipt_path=argv.shift
      raise OptionParser::MissingArgument,"AFW_RECEIPT" unless receipt_path
      raise OptionParser::MissingArgument,"--afw-root DIR" unless options[:afw_root]
      raise OptionParser::MissingArgument,"--review-dir DIR" unless options[:review_dir]
      raise OptionParser::MissingArgument,"--audit-dir DIR" unless options[:audit_dir]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      result=ScoringReviewPackage.prepare!(
        receipt_path:,
        afw_root:options[:afw_root],
        review_dir:options[:review_dir],
        audit_dir:options[:audit_dir]
      )
      lines = [
        "Review package ID: #{result.package_id}",
        "Review package: #{result.review_dir}",
        "Package reused: #{result.reused}",
        "Editorial ledger: #{result.audit_dir}",
        "Ledger state: #{result.ledger_state}",
        "Accepted: #{result.accepted}",
        "Held: #{result.held}",
        "Rejected: #{result.rejected}",
        "Pending: #{result.pending}"
      ]
      if result.next_human_decision
        ledger = File.join(result.audit_dir, "editorial_decisions.csv")
        lines << "NEXT HUMAN DECISION: edit #{ledger} and choose #{result.next_human_decision.join('/')} for each pending candidate."
      else
        lines << "NEXT HUMAN DECISION: none; every candidate already has a preserved editorial decision."
      end
      @out.puts(lines.join("\n"))
      0
    end
    def prepare_workload_review_command(argv)
      options={afw_root:nil,review_dir:nil,audit_dir:nil}
      OptionParser.new do |o|
        o.on("--afw-root DIR","AFW repository root used to validate manifest references") { |v| options[:afw_root]=v }
        o.on("--review-dir DIR","Deterministic generated workload review package directory") { |v| options[:review_dir]=v }
        o.on("--audit-dir DIR","Durable existing editorial decision ledger directory") { |v| options[:audit_dir]=v }
      end.parse!(argv)
      manifest_path=argv.shift
      raise OptionParser::MissingArgument,"AFW_MANIFEST" unless manifest_path
      raise OptionParser::MissingArgument,"--afw-root DIR" unless options[:afw_root]
      raise OptionParser::MissingArgument,"--review-dir DIR" unless options[:review_dir]
      raise OptionParser::MissingArgument,"--audit-dir DIR" unless options[:audit_dir]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      result=WorkloadScoringReviewPackage.prepare!(
        manifest_path:,
        afw_root:options[:afw_root],
        review_dir:options[:review_dir],
        audit_dir:options[:audit_dir]
      )
      lines = [
        "Workload review package ID: #{result.package_id}",
        "AFW manifest ID: #{result.manifest_id}",
        "Review package: #{result.review_dir}",
        "Package reused: #{result.reused}",
        "Editorial ledger: #{result.audit_dir}",
        "Intended cases: #{result.intended_cases}",
        "Evidence-ready cases: #{result.ready_cases}",
        "Unresolved cases: #{result.unresolved_cases}",
        "Candidate rows: #{result.candidate_count}",
        "Workload evidence complete: #{result.workload_complete}",
        "Editorial complete: #{result.editorial_complete}",
        "Accepted: #{result.accepted}",
        "Held: #{result.held}",
        "Rejected: #{result.rejected}",
        "Pending: #{result.pending}"
      ]
      if result.next_human_decision
        ledger = File.join(result.audit_dir, "editorial_decisions.csv")
        lines << "NEXT HUMAN DECISION: edit #{ledger} and choose #{result.next_human_decision.join('/')} for each pending candidate."
      elsif result.workload_complete
        lines << "NEXT HUMAN DECISION: none; every candidate already has a preserved editorial decision."
      else
        lines << "NEXT HUMAN DECISION: none for ready candidates; unresolved workload cases remain explicit and require upstream resolution."
      end
      @out.puts(lines.join("\n"))
      0
    end
    def editorial_audit_init_command(argv)
      options={audit_dir:nil}
      OptionParser.new do |o|
        o.on("--audit-dir DIR","Durable audit directory containing the human decision ledger") { |v| options[:audit_dir]=v }
      end.parse!(argv)
      review_dir=argv.shift
      raise OptionParser::MissingArgument,"REVIEW_DIR" unless review_dir
      raise OptionParser::MissingArgument,"--audit-dir DIR" unless options[:audit_dir]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      manifest=EditorialAudit.initialize!(review_dir:,audit_dir:options[:audit_dir])
      repo_root = File.expand_path("../..", __dir__)
      executable = File.join(repo_root, "bin", "af-data")
      audit_path = File.expand_path(options[:audit_dir])
      @out.puts(
        "Production candidates: #{manifest['candidate_count']}\n" \
        "Source review holds: #{manifest['source_hold_count']}\n" \
        "Editorial audit rows: #{manifest['audit_row_count']}\n" \
        "Wrote #{audit_path}\n\n" \
        "HUMAN REVIEW REQUIRED: edit #{File.join(audit_path, 'editorial_decisions.csv')} before validation.\n" \
        "After the reviewed ledger is saved, run:\n" \
        "  1. cd #{Shellwords.escape(repo_root)}\n" \
        "     #{Shellwords.escape(executable)} editorial-audit-validate #{Shellwords.escape(audit_path)}"
      )
      0
    end
    def editorial_audit_validate_command(argv)
      options={output:"output/editorial-audit-validation"}
      OptionParser.new do |o|
        o.on("--output DIR","Validation output directory (default: output/editorial-audit-validation)") { |v| options[:output]=v }
      end.parse!(argv)
      audit_dir=argv.shift
      raise OptionParser::MissingArgument,"AUDIT_DIR" unless audit_dir
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      validation=EditorialAudit.validate!(audit_dir:,output_dir:options[:output])
      repo_root = File.expand_path("../..", __dir__)
      executable = File.join(repo_root, "bin", "af-data")
      audit_path = File.expand_path(audit_dir)
      output_path = File.expand_path(options[:output])
      lines = [
        "Editorial rows: #{validation.rows.length}",
        "Accepted: #{validation.accepted.length}",
        "Held: #{validation.held.length}",
        "Rejected: #{validation.rejected.length}",
        "Source holds: #{validation.source_holds.length}",
        "Pending: #{validation.pending.length}",
        "Errors: #{validation.errors.length}",
        "Complete: #{validation.complete}",
        "Wrote #{options[:output]}",
        ""
      ]
      if validation.complete
        lines << "Next command template:"
        lines << "  1. cd #{Shellwords.escape(repo_root)}"
        lines << "     #{Shellwords.escape(executable)} amc-apply #{Shellwords.escape(audit_path)} " \
                 "--amc SOURCE.xlsx --output NEW.xlsx"
      else
        lines << "After resolving pending editorial decisions, rerun:"
        lines << "  1. cd #{Shellwords.escape(repo_root)}"
        lines << "     #{Shellwords.escape(executable)} editorial-audit-validate #{Shellwords.escape(audit_path)} " \
                 "--output #{Shellwords.escape(output_path)}"
      end
      @out.puts(lines.join("\n"))
      validation.complete ? 0 : 1
    end
    def boundary_freeze_init_command(argv)
      options={source_root:nil,source_id:nil,amc:nil,output:nil,registry:nil}
      OptionParser.new do |o|
        o.on("--source-root DIR","Canonical Markdown corpus root") { |v| options[:source_root]=v }
        o.on("--source-id ID","Exact canonical source identity from source_registry.yml") { |v| options[:source_id]=v }
        o.on("--amc PATH","Explicit base Adventure Master Catalog workbook") { |v| options[:amc]=v }
        o.on("--output PATH","New draft af-boundary-freeze/v0.1 YAML path") { |v| options[:output]=v }
        o.on("--registry PATH","Registry path (default: source_registry.yml beneath source root)") { |v| options[:registry]=v }
      end.parse!(argv)
      raise OptionParser::MissingArgument,"--source-root DIR" unless options[:source_root]
      raise OptionParser::MissingArgument,"--source-id ID" unless options[:source_id]
      raise OptionParser::MissingArgument,"--amc PATH" unless options[:amc]
      raise OptionParser::MissingArgument,"--output PATH" unless options[:output]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      result=BoundaryFreeze.init!(
        source_root:options[:source_root],
        source_id:options[:source_id],
        amc_path:options[:amc],
        output_path:options[:output],
        registry_path:options[:registry]
      )
      artifact=result.artifact
      message=(
        "Boundary freeze initialized: #{artifact.fetch('state')}\n" \
        "Source: #{artifact.dig('source','canonical_source_id')}\n" \
        "Markdown files: #{artifact.dig('source','markdown_files').length}\n" \
        "Base AMC: #{artifact.dig('base_amc','filename')}\n" \
        "No Adventure IDs assigned\n" \
        "Wrote #{result.path}"
      )
      continuation=boundary_freeze_editorial_continuation(result.path)
      message << "\n#{continuation}" if continuation
      @out.puts(message)
      0
    end
    def boundary_freeze_editorial_continuation(freeze_path)
      freeze_path=File.expand_path(freeze_path)
      suffix="-boundary-freeze-draft.yml"
      basename=File.basename(freeze_path)
      return nil unless basename.end_with?(suffix)

      editorial_dir=File.join(
        File.dirname(freeze_path),
        "#{basename.delete_suffix(suffix)}-boundary-editorial"
      )
      return nil unless File.file?(File.join(editorial_dir,"editorial_context.json"))
      return nil unless File.file?(File.join(editorial_dir,"editorial_decisions.yml"))

      repo_root=File.expand_path("../..",__dir__)
      executable=File.join(repo_root,"bin","af-ingest-next")
      "\n" \
        "Next command:\n" \
        "  1. cd #{Shellwords.escape(repo_root)}\n" \
        "     #{Shellwords.escape(executable)} #{Shellwords.escape(editorial_dir)}"
    end
    def boundary_freeze_validate_command(argv)
      options={source_root:nil,amc:nil,registry:nil}
      OptionParser.new do |o|
        o.on("--source-root DIR","Canonical Markdown corpus root") { |v| options[:source_root]=v }
        o.on("--amc PATH","Explicit base Adventure Master Catalog workbook") { |v| options[:amc]=v }
        o.on("--registry PATH","Registry path (default: source_registry.yml beneath source root)") { |v| options[:registry]=v }
      end.parse!(argv)
      freeze_path=argv.shift
      raise OptionParser::MissingArgument,"FREEZE.yml" unless freeze_path
      raise OptionParser::MissingArgument,"--source-root DIR" unless options[:source_root]
      raise OptionParser::MissingArgument,"--amc PATH" unless options[:amc]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      result=BoundaryFreeze.validate!(
        freeze_path:,
        source_root:options[:source_root],
        amc_path:options[:amc],
        registry_path:options[:registry]
      )
      repo_root=File.expand_path("../..",__dir__)
      executable=File.join(repo_root,"bin","af-ingest-next")
      @out.puts(
        "Boundary freeze validation: PASS\n" \
        "Source: #{result.artifact.dig('source','canonical_source_id')}\n" \
        "Frozen records: #{result.record_count}\n" \
        "Freeze SHA-256: #{result.sha256}\n" \
        "No Adventure IDs assigned; AMC unchanged\n\n" \
        "Next command:\n" \
        "  1. cd #{Shellwords.escape(repo_root)}\n" \
        "     #{Shellwords.escape(executable)} #{Shellwords.escape(File.expand_path(freeze_path))}"
      )
      0
    end
    def boundary_freeze_apply_command(argv)
      options={source_root:nil,amc:nil,publisher:nil,output:nil,report:nil,successor_version:nil,amc_dir:nil,registry:nil,progress:nil}
      OptionParser.new do |o|
        o.on("--source-root DIR","Canonical Markdown corpus root") { |v| options[:source_root]=v }
        o.on("--amc PATH","Explicit base Adventure Master Catalog workbook") { |v| options[:amc]=v }
        o.on("--publisher NAME","Exact Book Publisher value for new rows") { |v| options[:publisher]=v }
        o.on("--output PATH","New successor AMC workbook path") { |v| options[:output]=v }
        o.on("--report PATH","Integrity report path (default: derived by output mode)") { |v| options[:report]=v }
        o.on("--successor-version VERSION","Explicit successor AMC version; derives output and default report paths") { |v| options[:successor_version]=v }
        o.on("--amc-dir DIR","Directory for a deterministically named successor AMC") { |v| options[:amc_dir]=v }
        o.on("--registry PATH","Registry path (default: source_registry.yml beneath source root)") { |v| options[:registry]=v }
        o.on("--progress","Force incremental progress output on stderr") { options[:progress]=true }
        o.on("--no-progress","Suppress incremental progress output") { options[:progress]=false }
      end.parse!(argv)
      freeze_path=argv.shift
      raise OptionParser::MissingArgument,"FREEZE.yml" unless freeze_path
      raise OptionParser::MissingArgument,"--source-root DIR" unless options[:source_root]
      raise OptionParser::MissingArgument,"--amc PATH" unless options[:amc]
      raise OptionParser::MissingArgument,"--publisher NAME" unless options[:publisher]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      if options[:output] && options[:successor_version]
        raise OptionParser::InvalidArgument,"--output and --successor-version cannot be used together"
      end
      if options[:output]
        if options[:amc_dir]
          raise OptionParser::InvalidArgument,"--amc-dir is only valid with --successor-version"
        end
      else
        raise OptionParser::MissingArgument,"--successor-version VERSION" unless options[:successor_version]
        raise OptionParser::MissingArgument,"--amc-dir DIR" unless options[:amc_dir]
        paths = BoundaryFreezeApply.derive_successor_paths(
          freeze_path:,
          amc_path:options[:amc],
          successor_version:options[:successor_version],
          amc_dir:options[:amc_dir],
          report_path:options[:report]
        )
        options[:output] = paths.output_path
        options[:report] = paths.report_path
      end

      progress = options[:progress].nil? ? (@err.respond_to?(:tty?) && @err.tty?) : options[:progress]
      result=BoundaryFreezeApply.apply!(
        freeze_path:,
        source_root:options[:source_root],
        amc_path:options[:amc],
        publisher:options[:publisher],
        output_path:options[:output],
        report_path:options[:report],
        registry_path:options[:registry],
        progress: progress ? ->(message) { @err.puts(message) } : nil
      )
      counts=result.report.fetch("counts")
      repo_root=File.expand_path("../..",__dir__)
      executable=File.join(repo_root,"bin","af-ingest-next")
      @out.puts(
        "Frozen records applied: #{counts.fetch('frozen_records')}\n" \
        "Adventure IDs assigned: #{counts.fetch('adventure_ids_assigned')}\n" \
        "Ordinary rows created: #{counts.fetch('ordinary_rows_created')}\n" \
        ">=100-page rows created: #{counts.fetch('large_rows_created')}\n" \
        "Wrote #{result.output_path}\n" \
        "Wrote #{result.report_path}\n\n" \
        "Next command:\n" \
        "  1. cd #{Shellwords.escape(repo_root)}\n" \
        "     #{Shellwords.escape(executable)} #{Shellwords.escape(result.report_path)}"
      )
      0
    end
    def boundary_freeze_stage_command(argv)
      options={operation_input:nil,successor_authority:nil,source_root:nil,catalog_root:nil,project_state:nil,registry:nil,progress:nil}
      OptionParser.new do |o|
        o.on("--operation-input FILE","AdventureFinder operation routing projection") { |v| options[:operation_input]=v }
        o.on("--successor-authority FILE","AdventureFinder successor-version authorization projection") { |v| options[:successor_authority]=v }
        o.on("--source-root DIR","Canonical Markdown corpus root") { |v| options[:source_root]=v }
        o.on("--catalog-root DIR","AMC artifact root containing the frozen base and PROJECT_STATE.yml") { |v| options[:catalog_root]=v }
        o.on("--project-state FILE","Explicit project-state manifest (default: PROJECT_STATE.yml beneath catalog root)") { |v| options[:project_state]=v }
        o.on("--registry PATH","Registry path (default: source_registry.yml beneath source root)") { |v| options[:registry]=v }
        o.on("--progress","Force incremental progress output on stderr") { options[:progress]=true }
        o.on("--no-progress","Suppress incremental progress output") { options[:progress]=false }
      end.parse!(argv)
      freeze_path=argv.shift
      raise OptionParser::MissingArgument,"FREEZE.yml" unless freeze_path
      raise OptionParser::MissingArgument,"--operation-input FILE" unless options[:operation_input]
      raise OptionParser::MissingArgument,"--successor-authority FILE" unless options[:successor_authority]
      raise OptionParser::MissingArgument,"--source-root DIR" unless options[:source_root]
      raise OptionParser::MissingArgument,"--catalog-root DIR" unless options[:catalog_root]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      progress = options[:progress].nil? ? (@err.respond_to?(:tty?) && @err.tty?) : options[:progress]
      result=BoundaryFreezeStage.stage!(
        freeze_path:,
        operation_input_path:options[:operation_input],
        successor_authorization_path:options[:successor_authority],
        source_root:options[:source_root],
        catalog_root:options[:catalog_root],
        project_state_path:options[:project_state],
        registry_path:options[:registry],
        progress: progress ? ->(message) { @err.puts(message) } : nil
      )
      if result.status == "no_successor_needed"
        @out.puts(
          "NO SUCCESSOR NEEDED\n" \
          "Frozen records: 0\n" \
          "Trace receipt: #{result.stage_path}\n" \
          "Shared catalog_head promoted: false"
        )
      else
        @out.puts(
          "VERIFIED STAGED SUCCESSOR\n" \
          "Frozen records applied: #{result.record_count}\n" \
          "Successor AMC: #{result.output_path}\n" \
          "Apply integrity report: #{result.report_path}\n" \
          "Staging receipt: #{result.stage_path}\n" \
          "Replay reused exact artifacts: #{result.reused}\n" \
          "Shared catalog_head promoted: false\n" \
          "Scoring authorized: false"
        )
      end
      0
    end
    def amc_apply_command(argv)
      options={amc:nil,output:nil,report:nil,progress:nil}
      OptionParser.new do |o|
        o.on("--amc PATH","Source Adventure Master Catalog workbook") { |v| options[:amc]=v }
        o.on("--output PATH","New promoted workbook path") { |v| options[:output]=v }
        o.on("--report PATH","Integrity report path (default: beside output workbook)") { |v| options[:report]=v }
        o.on("--progress","Force incremental progress output on stderr") { options[:progress]=true }
        o.on("--no-progress","Suppress incremental progress output") { options[:progress]=false }
      end.parse!(argv)
      audit_dir=argv.shift
      raise OptionParser::MissingArgument,"AUDIT_DIR" unless audit_dir
      raise OptionParser::MissingArgument,"--amc PATH" unless options[:amc]
      raise OptionParser::MissingArgument,"--output PATH" unless options[:output]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      progress = options[:progress].nil? ? (@err.respond_to?(:tty?) && @err.tty?) : options[:progress]
      result=AmcApply.apply!(
        audit_dir:,
        amc_path:options[:amc],
        output_path:options[:output],
        report_path:options[:report],
        progress: progress ? ->(message) { @err.puts(message) } : nil
      )
      counts=result.report.fetch("counts")
      repo_root = File.expand_path("../..", __dir__)
      executable = File.join(repo_root, "bin", "af-data")
      finalize_args = [
        executable,
        "amc-finalize",
        "--amc",
        result.output_path,
        "--apply-report",
        result.report_path,
        "--output",
        "FINAL.xlsx"
      ]
      written = counts.fetch("new_cells_written")
      finalize_args.concat(["--expect-cells", written.to_s]) if written.positive?
      finalize_command = finalize_args.map { |value| Shellwords.escape(value.to_s) }.join(" ")
      @out.puts(
        "Accepted candidates considered: #{counts.fetch('accepted_candidates_considered')}\n" \
        "New cells written: #{written}\n" \
        "Already present: #{counts.fetch('already_present_exact_matches')}\n" \
        "Source holds: #{counts.fetch('source_holds')}\n" \
        "Held candidates: #{counts.fetch('held_candidates')}\n" \
        "Rejected candidates: #{counts.fetch('rejected_candidates')}\n" \
        "Conflicts: #{counts.fetch('conflicts')}\n" \
        "Errors: #{counts.fetch('errors')}\n" \
        "Wrote #{result.output_path}\n" \
        "Wrote #{result.report_path}\n\n" \
        "Next command template:\n" \
        "  1. cd #{Shellwords.escape(repo_root)}\n" \
        "     #{finalize_command}"
      )
      0
    end
    def amc_finalize_command(argv)
      options={amc:nil,apply_report:nil,output:nil,report:nil,expected_cells:nil,progress:nil}
      OptionParser.new do |o|
        o.on("--amc PATH","Applied AMC workbook containing red production-ingest cells") { |v| options[:amc]=v }
        o.on("--apply-report PATH","amc-apply integrity report identifying the cells written by that apply") { |v| options[:apply_report]=v }
        o.on("--output PATH","New finalized AMC workbook path") { |v| options[:output]=v }
        o.on("--report PATH","Finalization integrity report path (default: beside output workbook)") { |v| options[:report]=v }
        o.on("--expect-cells N",Integer,"Fail closed unless exactly N apply-written cells are finalized") do |v|
          raise OptionParser::InvalidArgument,"--expect-cells must be positive" unless v.positive?
          options[:expected_cells]=v
        end
        o.on("--progress","Force incremental progress output on stderr") { options[:progress]=true }
        o.on("--no-progress","Suppress incremental progress output") { options[:progress]=false }
      end.parse!(argv)
      raise OptionParser::MissingArgument,"--amc PATH" unless options[:amc]
      raise OptionParser::MissingArgument,"--apply-report PATH" unless options[:apply_report]
      raise OptionParser::MissingArgument,"--output PATH" unless options[:output]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      progress = options[:progress].nil? ? (@err.respond_to?(:tty?) && @err.tty?) : options[:progress]
      result=AmcFinalize.finalize!(
        amc_path:options[:amc],
        apply_report_path:options[:apply_report],
        output_path:options[:output],
        report_path:options[:report],
        expected_cells:options[:expected_cells],
        progress: progress ? ->(message) { @err.puts(message) } : nil
      )
      verification=result.report.fetch("verification")
      repo_root = File.expand_path("../..", __dir__)
      project_state = File.join(repo_root, "bin", "af-project-state")
      @out.puts(
        "Finalized cells: #{result.report.dig('counts','finalized_cells')}\n" \
        "Fill transition: #{verification.fetch('source_fill')} -> #{verification.fetch('accepted_fill')}\n" \
        "Formula cells checked: #{verification.fetch('formula_cells_checked')}\n" \
        "Unauthorized cell changes: #{verification.fetch('unauthorized_cell_changes')}\n" \
        "Errors: #{result.report.dig('counts','errors')}\n" \
        "Wrote #{result.output_path}\n" \
        "Wrote #{result.report_path}\n\n" \
        "Next compatibility/adoption command:\n" \
        "  1. cd #{Shellwords.escape(repo_root)}\n" \
        "     #{Shellwords.escape(project_state)} adopt #{Shellwords.escape(result.output_path)}"
      )
      0
    end
    def evidence_lookup_command(argv)
      options={index:nil,batch_id:nil,adventure_id:nil,dimension:nil,model:nil,job_id:nil,job_key:nil,run_id:nil,status:nil}
      OptionParser.new do |o|
        o.on("--index PATH","Explicit evidence-index SQLite path") { |v| options[:index]=v }
        o.on("--batch BATCH_ID","Exact evidence batch ID") { |v| options[:batch_id]=v }
        o.on("--adventure ADV_ID","Exact Adventure ID") { |v| options[:adventure_id]=v }
        o.on("--dimension NAME","Exact dimension name") { |v| options[:dimension]=v }
        o.on("--model NAME","Exact job model, model alias, or native run model") { |v| options[:model]=v }
        o.on("--job-id JOB_ID","Exact AFIO job_id") { |v| options[:job_id]=v }
        o.on("--job-key JOB_KEY","Exact canonical batch-local job key") { |v| options[:job_key]=v }
        o.on("--run-id RUN_ID","Exact native scorer run_id") { |v| options[:run_id]=v }
        o.on("--status STATUS","Exact AFIO job status") { |v| options[:status]=v }
      end.parse!(argv)
      raise OptionParser::MissingArgument,"--index PATH" unless options[:index]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      filters=options.reject { |key,value| key == :index || value.nil? }
      raise OptionParser::MissingArgument,"at least one lookup filter is required" if filters.empty?

      rows=EvidenceIndexLookup.new(index_path:options[:index]).lookup(filters)
      rows.each { |row| @out.puts(JSON.generate(row)) }
      0
    end
    def evidence_retrieve_command(argv)
      options={index:nil,evidence_root:nil,output:nil,member_path:nil,batch_id:nil,adventure_id:nil,dimension:nil,model:nil,job_id:nil,job_key:nil,run_id:nil,status:nil}
      OptionParser.new do |o|
        o.on("--index PATH","Explicit evidence-index SQLite path") { |v| options[:index]=v }
        o.on("--evidence-root DIR","Canonical prod-evidence root containing batch directories") { |v| options[:evidence_root]=v }
        o.on("--output PATH","New output file for one member or new directory for one run") { |v| options[:output]=v }
        o.on("--member-path PATH","Exact canonical member_path to retrieve") { |v| options[:member_path]=v }
        o.on("--batch BATCH_ID","Exact evidence batch ID") { |v| options[:batch_id]=v }
        o.on("--adventure ADV_ID","Exact Adventure ID") { |v| options[:adventure_id]=v }
        o.on("--dimension NAME","Exact dimension name") { |v| options[:dimension]=v }
        o.on("--model NAME","Exact job model, model alias, or native run model") { |v| options[:model]=v }
        o.on("--job-id JOB_ID","Exact AFIO job_id") { |v| options[:job_id]=v }
        o.on("--job-key JOB_KEY","Exact canonical batch-local job key") { |v| options[:job_key]=v }
        o.on("--run-id RUN_ID","Exact native scorer run_id") { |v| options[:run_id]=v }
        o.on("--status STATUS","Exact AFIO job status") { |v| options[:status]=v }
      end.parse!(argv)
      raise OptionParser::MissingArgument,"--index PATH" unless options[:index]
      raise OptionParser::MissingArgument,"--evidence-root DIR" unless options[:evidence_root]
      raise OptionParser::MissingArgument,"--output PATH" unless options[:output]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      filters=options.reject { |key,value| %i[index evidence_root output member_path].include?(key) || value.nil? }
      if options[:member_path]
        raise OptionParser::MissingArgument,"at least one lookup filter is required with --member-path" if filters.empty?
      elsif !filters.key?(:run_id)
        raise OptionParser::MissingArgument,"--run-id RUN_ID or --member-path PATH"
      end

      rows=EvidenceIndexLookup.new(index_path:options[:index]).lookup(filters)
      retriever=EvidenceRetriever.new(evidence_root:options[:evidence_root])
      summary = if options[:member_path]
        matches=rows.select { |row| row.fetch("member_path") == options[:member_path] }
        raise ValidationError,"member retrieval matched no canonical evidence" if matches.empty?
        if matches.length > 1
          raise ValidationError,"member retrieval is ambiguous (#{matches.length} matches); refine the lookup"
        end
        result=retriever.extract_member!(locator:matches.fetch(0),output_path:options[:output])
        {
          "batch_id"=>result.batch_id,"run_id"=>result.run_id,"member_path"=>result.member_path,
          "output_path"=>result.output_path,"byte_size"=>result.byte_size,"sha256"=>result.sha256
        }
      else
        raise ValidationError,"run retrieval matched no canonical evidence" if rows.empty?
        result=retriever.extract_run!(locators:rows,output_dir:options[:output])
        {
          "batch_id"=>result.batch_id,"run_id"=>result.run_id,"output_dir"=>result.output_dir,
          "member_count"=>result.members.length,
          "members"=>result.members.map { |member| {
            "member_path"=>member.member_path,"output_path"=>member.output_path,
            "byte_size"=>member.byte_size,"sha256"=>member.sha256
          } }
        }
      end
      @out.puts(JSON.generate(summary))
      0
    end
    def evidence_index_verify_command(argv)
      options={index:nil,evidence_root:nil}
      OptionParser.new do |o|
        o.on("--index PATH","Committed evidence-index SQLite path") { |v| options[:index]=v }
        o.on("--evidence-root DIR","Canonical prod-evidence root containing batch directories") { |v| options[:evidence_root]=v }
      end.parse!(argv)
      raise OptionParser::MissingArgument,"--index PATH" unless options[:index]
      raise OptionParser::MissingArgument,"--evidence-root DIR" unless options[:evidence_root]
      raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      result=EvidenceIndexVerifier.new.verify!(
        evidence_root:options[:evidence_root],
        index_path:options[:index]
      )
      @out.puts(JSON.generate({
        "verified"=>true,
        "index_path"=>result.index_path,
        "index_sha256"=>result.index_sha256,
        "batch_count"=>result.batch_count,
        "member_count"=>result.member_count,
        "job_count"=>result.job_count,
        "run_count"=>result.run_count
      }))
      0
    end
    def parse_source_command(argv,default_output:)
      options={output:PrivateDataRoot.default_path(default_output)}; OptionParser.new { |o| o.on("--output DIR","Output directory (default: #{default_output})") { |v| options[:output]=v } }.parse!(argv)
      options[:output]=PrivateDataRoot.destination!(options[:output])
      source=argv.shift; raise OptionParser::MissingArgument,"PATH" unless source; raise OptionParser::InvalidArgument,"unexpected arguments: #{argv.join(' ')}" unless argv.empty?; [options,source]
    end
    def with_scan(source, progress: nil)
      workspace=SourceWorkspace.new(source); workspace.with_root do |opened|
        root=workspace.source_type=="file" ? File.dirname(opened) : opened
        scanner=workspace.source_type=="file" ? Scanner.new(root:,single_file:opened) : Scanner.new(root:)
        yield scanner.scan(progress:),workspace,root
      end
    end
    def progress_callback(mode)
      enabled = mode.nil? ? (@err.respond_to?(:tty?) && @err.tty?) : mode
      return nil unless enabled

      lambda do |event|
        phase=event.fetch(:phase)
        current=event.fetch(:current)
        total=event.fetch(:total)
        case phase
        when :scan
          percent=total.zero? ? 100.0 : (current.fdiv(total) * 100.0)
          @err.puts(format("[scan] %d/%d files (%.1f%%)",current,total,percent))
        when :discover
          @err.puts("[discover] #{current} run packages")
        when :extract
          @err.puts("[extract] #{current}/#{total} run packages")
        end
      end
    end
    def write_jsonl(path,rows); File.open(path,"w") { |f| rows.each { |r| f.puts(JSON.generate(r)) } }; end
    def help
      <<~HELP
        af-data-pipeline #{AfDataPipeline::VERSION}

        Usage:
          bin/af-data help
          bin/af-data version
          bin/af-data evidence-lookup --index INDEX.sqlite [--batch BATCH_ID] [--adventure ADV_ID] [--dimension NAME] [--model NAME] [--job-id JOB_ID] [--job-key JOB_KEY] [--run-id RUN_ID] [--status STATUS]
          bin/af-data evidence-retrieve --index INDEX.sqlite --evidence-root DIR --output PATH (--run-id RUN_ID | --member-path MEMBER) [--batch BATCH_ID] [--adventure ADV_ID] [--dimension NAME] [--model NAME] [--job-id JOB_ID] [--job-key JOB_KEY] [--status STATUS]
          bin/af-data evidence-index-verify --index INDEX.sqlite --evidence-root DIR
          bin/af-data scan PATH [--output DIR]
          bin/af-data normalize PATH [--output DIR]
          bin/af-data horizontal-review PATH --through ADV_ID --dimension NAME [--expect-count N] [--output DIR]
          bin/af-data production-review PATH [--expect-candidates N] [--output DIR] [--progress|--no-progress]
          bin/af-data prepare-review AFW_RECEIPT --afw-root DIR --review-dir DIR --audit-dir DIR
          bin/af-data prepare-workload-review AFW_MANIFEST --afw-root DIR --review-dir DIR --audit-dir DIR
          bin/af-data editorial-audit-init REVIEW_DIR --audit-dir DIR
          bin/af-data editorial-audit-validate AUDIT_DIR [--output DIR]
          bin/af-data boundary-freeze-init --source-root DIR --source-id ID --amc BASE.xlsx --output FREEZE.yml [--registry PATH]
          bin/af-data boundary-freeze-validate FREEZE.yml --source-root DIR --amc BASE.xlsx [--registry PATH]
          bin/af-data boundary-freeze-apply FREEZE.yml --source-root DIR --amc BASE.xlsx --publisher NAME (--output NEW.xlsx | --successor-version VERSION --amc-dir DIR) [--report REPORT.json] [--registry PATH] [--progress|--no-progress]
          bin/af-data boundary-freeze-stage FREEZE.yml --operation-input FILE --successor-authority FILE --source-root DIR --catalog-root DIR [--project-state FILE] [--registry PATH] [--progress|--no-progress]
          bin/af-data amc-apply AUDIT_DIR --amc SOURCE.xlsx --output NEW.xlsx [--report REPORT.json] [--progress|--no-progress]
          bin/af-data amc-finalize --amc APPLIED.xlsx --apply-report APPLY_REPORT.json --output FINAL.xlsx [--report REPORT.json] [--expect-cells N] [--progress|--no-progress]

        Commands:
          evidence-lookup    Query a derived evidence index and emit canonical member locators as JSONL.
          evidence-retrieve  Extract one indexed member or native run and verify retrieved bytes against indexed hashes.
          evidence-index-verify  Rebuild the derived index from canonical evidence and verify logical equivalence.
          scan       Inventory existing evidence and compute SHA-256 hashes.
          normalize          Normalize recognized records and build a review packet.
          horizontal-review  Extract an LME Horizontal Discovery handoff for editorial review.
          production-review        Discover all complete production candidates in an LME evidence snapshot.
          prepare-review           Build or reuse a provenance-bound review package and its existing ACCEPT/HOLD/REJECT ledger from one AFW receipt.
          prepare-workload-review  Build or reuse one complete-denominator workload review package and durable ledger from an AFW manifest.
          editorial-audit-init      Create a durable human ACCEPT/HOLD/REJECT ledger from a clean production review.
          editorial-audit-validate  Validate the ledger and emit promotion-ready accepted candidates only when complete.
          boundary-freeze-init      Bind source-registry/Markdown/base-AMC provenance into a draft frontier-review handoff.
          boundary-freeze-validate  Validate a frozen frontier-review handoff without assigning IDs or mutating the AMC.
          boundary-freeze-apply     Assign IDs and create a verified successor AMC from a validated frozen handoff.
          boundary-freeze-stage     Create/reuse an operation-bound verified staged successor without promoting catalog_head.
          amc-apply                 Apply clean editorial ACCEPTs to a new AMC copy and verify the result.
          amc-finalize              Recolor only amc-apply-written red cells to the existing accepted light-blue style and verify the copy.

        Source evidence and source AMC workbooks are always read-only.
      HELP
    end
  end
end
