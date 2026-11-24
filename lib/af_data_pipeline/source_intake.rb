# frozen_string_literal: true

require_relative "private_data_root"

require "digest"
require "json"
require "optparse"
require "shellwords"
require_relative "source_identity"

module AfDataPipeline
  # Deterministically inspects one canonical Markdown file before source
  # registration. It reports evidence only and never infers source identity.
  class SourceIntake
    SCHEMA_VERSION = "af-source-intake/v0.1"
    JSON_FILENAME = "source_intake.json"
    MARKDOWN_FILENAME = "source_intake.md"
    MAX_METADATA_LINES = 80
    METADATA_RE = /(?:\bISBN\b|copyright|©|all rights reserved|published by|publisher|trademark)/i

    Result = Data.define(:output_dir, :json_path, :markdown_path, :report)

    def self.generate!(markdown_path:, source_root:, output_dir:, registry_path: nil,
                       conversion_receipt_path: nil)
      new(
        markdown_path:, source_root:, output_dir:, registry_path:,
        conversion_receipt_path:
      ).generate!
    end

    def initialize(markdown_path:, source_root:, output_dir:, registry_path:,
                   conversion_receipt_path: nil)
      @markdown_path = markdown_path
      @source_root = source_root
      @output_dir = output_dir
      @registry_path = registry_path
      @conversion_receipt_path = conversion_receipt_path
    end

    def generate!
      root = BoundaryFreeze.expanded_source_root(@source_root)
      markdown = BoundaryFreeze.existing_file!(@markdown_path, "Markdown source")
      relative = BoundaryFreeze.relative_under_root!(root, markdown, "Markdown source")
      raise ValidationError, "Markdown source must end in .md: #{relative}" unless File.extname(relative).downcase == ".md"

      registry = BoundaryFreeze.registry_context(root, @registry_path)
      markdown_sha = BoundaryFreeze.sha256(markdown)
      conversion_provenance = conversion_receipt_evidence(markdown_sha)
      registry_sha = BoundaryFreeze.sha256(registry.fetch("path"))
      references = registry_references(registry, relative)
      evidence = analyze_markdown(markdown)

      report = {
        "schema_version" => SCHEMA_VERSION,
        "purpose" => "Deterministic source-intake evidence; no canonical source identity is inferred.",
        "source_root" => root,
        "markdown" => {
          "filename" => relative,
          "sha256" => markdown_sha,
          "line_count" => evidence.fetch("line_count")
        },
        "registry" => {
          "filename" => registry.fetch("relative_path"),
          "sha256" => registry_sha,
          "registration_status" => registration_status(references),
          "source_ids_referencing_file" => references
        },
        "conversion_provenance" => conversion_provenance,
        "page_evidence" => evidence.fetch("page_evidence"),
        "headings" => evidence.fetch("headings"),
        "metadata_lines" => evidence.fetch("metadata_lines"),
        "quality_flags" => evidence.fetch("quality_flags"),
        "contract" => {
          "canonical_source_identity_inferred" => false,
          "registry_mutated" => false,
          "markdown_mutated" => false
        }
      }

      verify_stable!(markdown, markdown_sha, "Markdown source")
      verify_stable!(registry.fetch("path"), registry_sha, "source registry")
      if @conversion_receipt_identity
        verify_stable!(
          @conversion_receipt_identity.fetch("path"),
          @conversion_receipt_identity.fetch("sha256"),
          "conversion receipt"
        )
      end
      publish!(report)
    end

    # Validate exact converter receipt bytes against the Markdown digest and optional output path.
    # Return pipeline QA provenance or raise ValidationError for invalid or unready receipts.
    def self.validate_conversion_receipt!(receipt_bytes, path:, markdown_sha:, expected_output: nil)
      receipt = JSON.parse(receipt_bytes)
      BoundaryFreeze.mapping!(receipt, "conversion receipt")
      schema = receipt["schema"]
      unless schema == "pdf-to-llm-md/conversion-receipt/v0.1"
        raise ValidationError, "unsupported conversion receipt schema: #{schema.inspect}"
      end

      if expected_output && (!receipt["output"].is_a?(Hash) || receipt.dig("output", "path") != expected_output)
        raise ValidationError, "conversion receipt output path does not match the selected candidate"
      end
      receipt_output_sha = receipt.dig("output", "sha256").to_s
      if receipt_output_sha.empty?
        raise ValidationError, "conversion receipt is missing output.sha256"
      end
      unless receipt_output_sha == markdown_sha
        raise ValidationError,
              "conversion receipt output SHA-256 does not match Markdown source"
      end

      state = receipt["state"].to_s
      downstream_ready = receipt["downstream_ready"]
      ready_states = %w[ready ready_with_exceptions]
      unless downstream_ready == true && ready_states.include?(state)
        raise ValidationError,
              "conversion receipt is not downstream-ready " \
              "(state=#{state.inspect}, downstream_ready=#{downstream_ready.inspect})"
      end

      exceptions = Array(receipt["page_exceptions"]).map do |exception|
        page = exception["page"]
        reason = exception["reason"].to_s.strip
        unless page.is_a?(Integer) && page.positive? && !reason.empty?
          raise ValidationError, "conversion receipt contains an invalid reviewed page exception"
        end
        {
          "page" => page,
          "reason" => reason
        }
      end

      {
        "receipt_status" => "verified",
        "conversion_acceptance_verified" => true,
        "receipt_filename" => File.basename(path),
        "receipt_sha256" => Digest::SHA256.hexdigest(receipt_bytes),
        "schema" => schema,
        "state" => state,
        "downstream_ready" => true,
        "reviewed_page_exceptions" => exceptions.freeze
      }.freeze
    rescue JSON::ParserError => error
      raise ValidationError, "invalid conversion receipt JSON: #{error.message}"
    end

    private

    # Report absent QA or validate the selected receipt, retaining its digest for the final stability check.
    def conversion_receipt_evidence(markdown_sha)
      if @conversion_receipt_path.nil? || @conversion_receipt_path.to_s.strip.empty?
        return {
          "receipt_status" => "absent",
          "conversion_acceptance_verified" => false,
          "warning" => "No conversion receipt supplied; converter acceptance cannot be mechanically verified."
        }.freeze
      end

      path = File.expand_path(@conversion_receipt_path.to_s)
      raise ValidationError, "conversion receipt not found: #{path}" unless File.file?(path)

      evidence = self.class.validate_conversion_receipt!(File.binread(path), path:, markdown_sha:)
      @conversion_receipt_identity = { "path" => path, "sha256" => evidence.fetch("receipt_sha256") }.freeze
      evidence
    end

    def registry_references(registry, relative)
      registry.fetch("sources").filter_map do |source_id, entry|
        normalized = BoundaryFreeze.normalize_registry_entry(source_id, entry)
        source_id if normalized.fetch(:files).include?(relative)
      end.sort
    end

    def registration_status(references)
      case references.length
      when 0 then "unregistered"
      when 1 then "registered"
      else "conflict_multiple_source_ids"
      end
    end

    def analyze_markdown(path)
      lines = File.readlines(path, chomp: true, encoding: "UTF-8")
      headings = []
      metadata_lines = []
      quality_flags = []
      pdf_markers = []
      printed_markers = []
      paired_offsets = []
      current_pdf = nil
      current_printed = nil
      last_pdf_marker = nil

      lines.each_with_index do |line, index|
        line_number = index + 1

        if (match = line.match(/<!--\s*PDF Page\s+(\d+)\s*-->/i))
          current_pdf = Integer(match[1], 10)
          last_pdf_marker = { "line" => line_number, "page" => current_pdf }
          pdf_markers << last_pdf_marker
        end

        if (match = line.match(/<!--\s*Printed Page\s+(\d+)\s*-->/i))
          current_printed = Integer(match[1], 10)
          printed = { "line" => line_number, "page" => current_printed }
          printed_markers << printed
          if last_pdf_marker && line_number - last_pdf_marker.fetch("line") <= 3
            paired_offsets << {
              "pdf_page" => last_pdf_marker.fetch("page"),
              "printed_page" => current_printed,
              "printed_minus_pdf" => current_printed - last_pdf_marker.fetch("page")
            }
          end
        end

        if (match = line.match(/\A(#+)\s+(.+?)\s*\z/)) && match[1].length <= 6
          headings << {
            "line" => line_number,
            "level" => match[1].length,
            "text" => match[2].strip,
            "pdf_page" => current_pdf,
            "printed_page" => current_printed
          }.compact
        end

        if METADATA_RE.match?(line) && metadata_lines.length < MAX_METADATA_LINES
          metadata_lines << source_line_record(line_number, current_printed, current_pdf, line)
        end

        if line.include?("�") || /\bERROR\b/.match?(line)
          quality_flags << source_line_record(line_number, current_printed, current_pdf, line)
        end
      end

      {
        "line_count" => lines.length,
        "headings" => headings,
        "metadata_lines" => metadata_lines,
        "quality_flags" => quality_flags,
        "page_evidence" => {
          "pdf" => marker_diagnostics(pdf_markers),
          "printed" => marker_diagnostics(printed_markers),
          "paired_marker_count" => paired_offsets.length,
          "observed_printed_minus_pdf_offsets" => paired_offsets.map { |item| item.fetch("printed_minus_pdf") }.tally.sort.to_h,
          "constant_observed_printed_minus_pdf_offset" => constant_offset(paired_offsets)
        }
      }
    end

    def marker_diagnostics(markers)
      duplicates = markers.group_by { |marker| marker.fetch("page") }
                          .select { |_page, rows| rows.length > 1 }
                          .map { |page, rows| { "page" => page, "lines" => rows.map { |row| row.fetch("line") } } }
      gaps = []
      non_increasing = []
      markers.each_cons(2) do |left, right|
        from = left.fetch("page")
        to = right.fetch("page")
        if to <= from
          non_increasing << {
            "from_page" => from,
            "from_line" => left.fetch("line"),
            "to_page" => to,
            "to_line" => right.fetch("line")
          }
        elsif to > from + 1
          gaps << {
            "after_page" => from,
            "before_page" => to,
            "missing_start" => from + 1,
            "missing_end" => to - 1
          }
        end
      end

      {
        "count" => markers.length,
        "first_page" => markers.first && markers.first.fetch("page"),
        "last_page" => markers.last && markers.last.fetch("page"),
        "duplicate_pages" => duplicates,
        "gaps" => gaps,
        "non_increasing_transitions" => non_increasing
      }.compact
    end

    def constant_offset(pairs)
      offsets = pairs.map { |item| item.fetch("printed_minus_pdf") }.uniq
      offsets.one? ? offsets.first : nil
    end

    def source_line_record(line_number, printed_page, pdf_page, line)
      {
        "line" => line_number,
        "printed_page" => printed_page,
        "pdf_page" => pdf_page,
        "text" => line.to_s.gsub(/\s+/, " ").strip
      }.compact
    end

    def verify_stable!(path, expected_sha, label)
      actual = File.file?(path) ? BoundaryFreeze.sha256(path) : nil
      raise ValidationError, "#{label} changed during source intake" unless actual == expected_sha
    end

    def publish!(report)
      raise ValidationError, "output directory is required" if @output_dir.nil? || @output_dir.to_s.strip.empty?
      output = File.expand_path(PrivateDataRoot.destination!(@output_dir).to_s)
      json_path = File.join(output, JSON_FILENAME)
      markdown_path = File.join(output, MARKDOWN_FILENAME)
      [json_path, markdown_path].each do |path|
        raise ValidationError, "refusing to overwrite existing source-intake artifact: #{path}" if File.exist?(path)
      end

      FileUtils.mkdir_p(output)
      begin
        File.write(json_path, JSON.pretty_generate(report) + "\n", encoding: "UTF-8")
        File.write(markdown_path, render_markdown(report), encoding: "UTF-8")
      rescue StandardError
        FileUtils.rm_f(json_path)
        FileUtils.rm_f(markdown_path)
        raise
      end
      Result.new(output_dir: output, json_path:, markdown_path:, report:)
    end

    def render_markdown(report)
      page = report.fetch("page_evidence")
      pdf = page.fetch("pdf")
      printed = page.fetch("printed")
      registration = report.fetch("registry")
      lines = []
      lines << "# AdventureFinder source intake"
      lines << ""
      lines << "> **Evidence only.** No canonical source identity inferred and no registry mutation performed."
      lines << ""
      lines << "- Markdown: `#{report.dig('markdown', 'filename')}`"
      lines << "- SHA-256: `#{report.dig('markdown', 'sha256')}`"
      lines << "- Registry status: `#{registration.fetch('registration_status')}`"
      refs = registration.fetch("source_ids_referencing_file")
      lines << "- Existing source IDs referencing this file: #{refs.empty? ? 'none' : refs.map { |value| "`#{value}`" }.join(', ')}"
      conversion = report.fetch("conversion_provenance")
      if conversion.fetch("receipt_status") == "absent"
        lines << "- Conversion receipt: **WARNING — not supplied; converter acceptance not mechanically verified**"
      else
        lines << "- Conversion receipt: verified (`#{conversion.fetch('state')}`)"
        exceptions = conversion.fetch("reviewed_page_exceptions")
        unless exceptions.empty?
          pages = exceptions.map { |exception| exception.fetch("page") }.join(", ")
          lines << "- Reviewed conversion-exception pages: #{pages}"
        end
      end
      lines << "- PDF markers: #{marker_text(pdf)}"
      lines << "- Printed markers: #{marker_text(printed)}"
      constant = page["constant_observed_printed_minus_pdf_offset"]
      lines << "- Paired marker observations: #{page.fetch('paired_marker_count')}"
      lines << "- Constant observed printed-minus-PDF delta: #{constant.nil? ? 'none established' : format('%+d', constant)}"
      lines << "- Conversion-quality flags: #{report.fetch('quality_flags').length}"
      lines << ""

      lines << "## Marker diagnostics"
      lines << ""
      append_marker_diagnostics(lines, "PDF", pdf)
      append_marker_diagnostics(lines, "Printed", printed)
      lines << "Observed printed-minus-PDF deltas: `#{page.fetch('observed_printed_minus_pdf_offsets').inspect}`"
      lines << ""

      lines << "## Headings"
      lines << ""
      lines << "| Line | Depth | Printed | PDF | Heading |"
      lines << "| ---: | ---: | ---: | ---: | --- |"
      report.fetch("headings").each do |heading|
        lines << "| #{heading.fetch('line')} | #{heading.fetch('level')} | #{heading['printed_page'] || ''} | #{heading['pdf_page'] || ''} | #{escape_table(heading.fetch('text'))} |"
      end
      lines << ""

      lines << "## Identity / publication evidence lines"
      lines << ""
      if report.fetch("metadata_lines").empty?
        lines << "No copyright/publisher/ISBN/trademark lines were mechanically detected."
      else
        lines << "| Line | Printed | PDF | Source line |"
        lines << "| ---: | ---: | ---: | --- |"
        report.fetch("metadata_lines").each do |item|
          lines << "| #{item.fetch('line')} | #{item['printed_page'] || ''} | #{item['pdf_page'] || ''} | #{escape_table(item.fetch('text'))} |"
        end
      end
      lines << ""

      unless report.fetch("quality_flags").empty?
        lines << "## Conversion-quality flags"
        lines << ""
        lines << "| Line | Printed | PDF | Source line |"
        lines << "| ---: | ---: | ---: | --- |"
        report.fetch("quality_flags").each do |item|
          lines << "| #{item.fetch('line')} | #{item['printed_page'] || ''} | #{item['pdf_page'] || ''} | #{escape_table(item.fetch('text'))} |"
        end
        lines << ""
      end

      lines << "## Registration boundary"
      lines << ""
      lines << "Choose the canonical library source identity editorially. If this is a new single-file source, register it with `bin/af-source-register` and an explicit `--source-id`. Do not turn the observed page delta above into `page_marker_offset` unless that mapping is independently intended and explicitly supplied."
      lines << ""
      lines.join("\n")
    end

    def append_marker_diagnostics(lines, label, diagnostics)
      lines << "### #{label} markers"
      lines << ""
      lines << "- Count: #{diagnostics.fetch('count')}"
      lines << "- First/last: #{diagnostics['first_page'] || 'n/a'} / #{diagnostics['last_page'] || 'n/a'}"
      lines << "- Duplicate pages: #{diagnostics.fetch('duplicate_pages').empty? ? 'none' : diagnostics.fetch('duplicate_pages').inspect}"
      lines << "- Gaps: #{diagnostics.fetch('gaps').empty? ? 'none' : diagnostics.fetch('gaps').inspect}"
      lines << "- Non-increasing transitions: #{diagnostics.fetch('non_increasing_transitions').empty? ? 'none' : diagnostics.fetch('non_increasing_transitions').inspect}"
      lines << ""
    end

    def marker_text(diagnostics)
      return "0" if diagnostics.fetch("count").zero?
      "#{diagnostics.fetch('count')} (#{diagnostics['first_page']}–#{diagnostics['last_page']})"
    end

    def escape_table(value)
      value.to_s.gsub("|", "\\|").gsub("\n", " ")
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr)
        options = {
          source_root: nil, output: nil, registry: nil, conversion_receipt: nil
        }
        OptionParser.new do |parser|
          parser.banner = "Usage: bin/af-source-intake MARKDOWN --source-root DIR --output DIR [--registry PATH] [--conversion-receipt FILE]"
          parser.on("--source-root DIR", "Canonical Markdown corpus root") { |value| options[:source_root] = value }
          parser.on("--output DIR", "New source-intake output directory") { |value| options[:output] = value }
          parser.on("--registry PATH", "Registry path (default: source_registry.yml beneath source root)") { |value| options[:registry] = value }
          parser.on("--conversion-receipt FILE", "Optional pdf-to-llm-md conversion receipt; supplied receipts are binding") { |value| options[:conversion_receipt] = value }
        end.parse!(argv)
        markdown = argv.shift
        raise OptionParser::MissingArgument, "MARKDOWN" unless markdown
        raise OptionParser::MissingArgument, "--source-root DIR" unless options[:source_root]
        raise OptionParser::MissingArgument, "--output DIR" unless options[:output]
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

        result = SourceIntake.generate!(
          markdown_path: markdown,
          source_root: options[:source_root],
          output_dir: options[:output],
          registry_path: options[:registry],
          conversion_receipt_path: options[:conversion_receipt]
        )
        report = result.report
        conversion = report.fetch("conversion_provenance")
        conversion_line = if conversion.fetch("receipt_status") == "absent"
          "Conversion receipt: WARNING — not supplied; converter acceptance not mechanically verified"
        else
          "Conversion receipt: PASS (#{conversion.fetch('state')}; Markdown SHA-256 verified)"
        end
        out.puts(
          "Source intake: PASS\n" \
          "Markdown: #{report.dig('markdown', 'filename')}\n" \
          "Registry status: #{report.dig('registry', 'registration_status')}\n" \
          "#{conversion_line}\n" \
          "PDF markers: #{report.dig('page_evidence', 'pdf', 'count')}\n" \
          "Printed markers: #{report.dig('page_evidence', 'printed', 'count')}\n" \
          "Headings indexed: #{report.fetch('headings').length}\n" \
          "Metadata lines: #{report.fetch('metadata_lines').length}\n" \
          "Quality flags: #{report.fetch('quality_flags').length}\n" \
          "No canonical source identity inferred; registry unchanged\n" \
          "Wrote #{result.json_path}\n" \
          "Wrote #{result.markdown_path}\n" \
          "\n" \
          "Next command:\n" \
          "  1. cd #{File.expand_path('../..', __dir__)}\n" \
          "     #{File.expand_path('../../bin/af-ingest-next', __dir__)} #{result.json_path}"
        )
        0
      rescue OptionParser::ParseError, AfDataPipeline::Error => e
        err.puts("ERROR: #{e.message}")
        2
      end
    end
  end

  # Pipeline registration entry and CLI; source mutation belongs to MD.
  class SourceRegister
    Result = Data.define(
      :registry_path, :source_id, :filename, :registry_sha256_before,
      :registry_sha256_after, :page_marker_offset
    )

    # Register supplied source inputs through MD; return the historical Result
    # and translate owner validation errors to AfDataPipeline::ValidationError.
    def self.register!(source_root:, source_id:, markdown_path:, registry_path: nil,
                       page_marker_offset: nil)
      new(source_root:, source_id:, markdown_path:, registry_path:, page_marker_offset:).register!
    end

    # Bind explicit source inputs without mutation; owner loading remains lazy.
    def initialize(source_root:, source_id:, markdown_path:, registry_path:, page_marker_offset:)
      @arguments = {source_root:, source_id:, markdown_path:, registry_path:, page_marker_offset:}
    end

    # Return a caller Result after the real owner publishes its validated append;
    # missing/invalid owner and registration refusals raise ValidationError.
    def register!
      PrivateDataRoot.external_store!(@arguments.fetch(:source_root))
      owner = SourceMarkdownOwner.load!(error_class: ValidationError)
      Result.new(**owner::SourceRegister.register!(**@arguments).to_h)
    rescue StandardError => error
      raise ValidationError, error.message if defined?(AFSourceMD::ValidationError) && error.is_a?(AFSourceMD::ValidationError)
      raise
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr)
        if %w[decide apply-approved].include?(argv.first)
          require_relative "source_operation"
          return SourceOperation.run(argv, out:)
        end

        options = {
          source_root: nil,
          source_id: nil,
          registry: nil,
          page_marker_offset: nil,
          next_amc: nil,
          next_output: nil
        }
        OptionParser.new do |parser|
          parser.banner = "Usage: bin/af-source-register MARKDOWN --source-root DIR --source-id ID [--page-marker-offset +N|-N] [--registry PATH] [--next-amc PATH --next-output DIR]"
          parser.on("--source-root DIR", "Canonical Markdown corpus root") { |value| options[:source_root] = value }
          parser.on("--source-id ID", "Explicit canonical source identity") { |value| options[:source_id] = value }
          parser.on("--page-marker-offset OFFSET", "Explicit signed registry offset; never inferred") { |value| options[:page_marker_offset] = value }
          parser.on("--registry PATH", "Registry path (default: source_registry.yml beneath source root)") { |value| options[:registry] = value }
          parser.on("--next-amc PATH", "Exact AMC for the subsequent boundary-dossier continuation") { |value| options[:next_amc] = value }
          parser.on("--next-output DIR", "Exact output directory for the subsequent boundary-dossier continuation") { |value| options[:next_output] = value }
        end.parse!(argv)
        markdown = argv.shift
        raise OptionParser::MissingArgument, "MARKDOWN" unless markdown
        raise OptionParser::MissingArgument, "--source-root DIR" unless options[:source_root]
        raise OptionParser::MissingArgument, "--source-id ID" unless options[:source_id]
        raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
        if options[:next_amc].nil? != options[:next_output].nil?
          raise OptionParser::MissingArgument,
                "--next-amc PATH and --next-output DIR must be supplied together"
        end

        result = SourceRegister.register!(
          source_root: options[:source_root],
          source_id: options[:source_id],
          markdown_path: markdown,
          registry_path: options[:registry],
          page_marker_offset: options[:page_marker_offset]
        )
        lines = [
          "Source registration: PASS",
          "Source ID: #{result.source_id}",
          "Markdown: #{result.filename}",
          "Registry SHA-256 before: #{result.registry_sha256_before}",
          "Registry SHA-256 after: #{result.registry_sha256_after}",
          "No source identity, segmentation, or offset inferred",
          "Updated #{result.registry_path}"
        ]
        if options[:next_amc] && options[:next_output]
          repo_root = File.expand_path("../..", __dir__)
          next_args = [
            File.join(repo_root, "bin", "af-boundary-dossier"),
            "--source-root",
            options.fetch(:source_root),
            "--source-id",
            result.source_id,
            "--amc",
            options.fetch(:next_amc),
            "--output",
            options.fetch(:next_output)
          ]
          next_args.concat(["--registry", options.fetch(:registry)]) if options[:registry]
          lines << ""
          lines << "Next command:"
          lines << "  1. cd #{Shellwords.escape(repo_root)}"
          lines << "     #{next_args.map { |value| Shellwords.escape(value.to_s) }.join(' ')}"
        else
          lines << ""
          lines << "Next: return to the remaining command(s) emitted by bin/af-ingest-next for this source."
        end
        out.puts(lines.join("\n"))
        0
      rescue OptionParser::ParseError, AfDataPipeline::Error => e
        err.puts("ERROR: #{e.message}")
        2
      end
    end
  end
end
