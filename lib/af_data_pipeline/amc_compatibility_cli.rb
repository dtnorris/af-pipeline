# frozen_string_literal: true

require "json"
require "optparse"
require "shellwords"
require_relative "error"
require_relative "project_state"
require_relative "amc_compatibility_check"

module AfDataPipeline
  # Thin, injectable command-line seam for cross-consumer AMC compatibility.
  # The executable remains a tiny wrapper so substantive CLI behavior can be
  # tested in-process without repeated Ruby interpreter startup.
  class AmcCompatibilityCLI
    DEFAULT_MANIFEST = ENV["AF_PROJECT_STATE"]
    CANONICAL_AMC_FILENAME_RE = /\A5e_Adventure_Master_Catalog_\d+(?:\.\d+)*\.xlsx\z/

    def self.run(argv, out: $stdout, err: $stderr, default_manifest: DEFAULT_MANIFEST,
                 checker: AmcCompatibilityCheck, project_state_class: ProjectState)
      new(
        out:,
        err:,
        default_manifest:,
        checker:,
        project_state_class:
      ).run(argv.dup)
    end

    def initialize(out:, err:, default_manifest:, checker:, project_state_class:)
      @out = out
      @err = err
      @default_manifest = default_manifest
      @checker = checker
      @project_state_class = project_state_class
    end

    def run(argv)
      options = {manifest: @default_manifest, against: nil, json: false}
      help_requested = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: bin/af-amc-compatibility-check AMC.xlsx [--against BASE.xlsx] [--manifest PATH] [--json]"
        opts.on("--against PATH", "Explicit comparison AMC; default is current catalog_head") { |value| options[:against] = value }
        opts.on("--manifest PATH", "Project-state manifest used to resolve default catalog_head") { |value| options[:manifest] = value }
        opts.on("--json", "Emit the machine-readable report") { options[:json] = true }
        opts.on("-h", "--help") { help_requested = true }
      end

      parser.parse!(argv)
      if help_requested
        @out.puts parser
        return 0
      end

      candidate = argv.shift
      raise OptionParser::MissingArgument, "AMC.xlsx" unless candidate
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      candidate = File.expand_path(candidate)
      if options[:manifest].to_s.strip.empty? && !options[:against]
        raise OptionParser::MissingArgument, "--manifest PATH (or AF_PROJECT_STATE)"
      end
      manifest = File.expand_path(options[:manifest]) if options[:manifest]
      catalog_head = resolve_catalog_head(manifest, required: !options[:against]) if manifest
      base = options[:against] ? File.expand_path(options[:against]) : catalog_head

      report = @checker.check(candidate_path: candidate, base_path: base)
      adoption_command = adoption_command(
        report:,
        candidate:,
        base:,
        catalog_head:,
        manifest:
      )
      render(report, json: options[:json], adoption_command:)
      report.fetch("status") == "PASS" ? 0 : 2
    rescue AfDataPipeline::Error, OptionParser::ParseError => e
      @err.puts "ERROR: #{e.message}"
      2
    end

    private

    def resolve_catalog_head(manifest, required:)
      state = @project_state_class.new(manifest_path: manifest)
      state.validate!
      state.resolve("catalog_head").path
    rescue AfDataPipeline::Error
      raise if required
      nil
    end

    def adoption_command(report:, candidate:, base:, catalog_head:, manifest:)
      return nil unless report.fetch("status") == "PASS"
      return nil unless catalog_head && same_path?(base, catalog_head)
      return nil if same_path?(candidate, catalog_head)
      return nil unless CANONICAL_AMC_FILENAME_RE.match?(File.basename(candidate))

      repo_root = File.expand_path("../..", __dir__)
      executable = File.join(repo_root, "bin", "af-project-state")
      {
        cwd: repo_root,
        command: [
          executable,
          "adopt",
          candidate,
          "--manifest",
          manifest
        ].map { |value| Shellwords.escape(value.to_s) }.join(" ")
      }
    end

    def same_path?(left, right)
      File.realpath(left) == File.realpath(right)
    rescue SystemCallError
      File.expand_path(left) == File.expand_path(right)
    end

    def render(report, json:, adoption_command:)
      if json
        @out.puts JSON.pretty_generate(report)
        return
      end

      @out.puts "AMC cross-consumer compatibility: #{report.fetch('status')}"
      @out.puts "Candidate: #{report.dig('candidate', 'path')}"
      @out.puts "Against: #{report.dig('against', 'path')}" if report["against"]
      if report["canonical_adventure_count"]
        @out.puts "Canonical Adventure IDs: #{report['canonical_adventure_count']}"
      end
      @out.puts "Added Adventure IDs: #{report.fetch('added_adventure_ids', []).length}"
      @out.puts "Catalog-sheet layout: #{report['mirror_mode']}" if report["mirror_mode"]
      @out.puts "Consumer contracts:"
      if report.fetch("status") == "PASS"
        report.fetch("consumer_contracts").each { |contract| @out.puts "  PASS #{contract}" }
      end
      unless report.fetch("errors").empty?
        @out.puts "Compatibility defects:"
        report.fetch("errors").each { |error| @out.puts "  FAIL #{error}" }
      end
      @out.puts "Matcher baseline: #{report.fetch('matcher_authorized_baseline')}"

      return unless adoption_command

      @out.puts
      @out.puts "Next command:"
      @out.puts "  1. cd #{Shellwords.escape(adoption_command.fetch(:cwd))}"
      @out.puts "     #{adoption_command.fetch(:command)}"
    end
  end
end
