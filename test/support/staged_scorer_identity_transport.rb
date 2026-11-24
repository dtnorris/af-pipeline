# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "rbconfig"

# Replace only the identity probe against the disposable staged scorer.
# AFW still parses the response and checks current and frozen input digests.
module StagedScorerIdentityTransport
  PRELOAD = ["-r", __FILE__].freeze
  STUB_PATH = File.expand_path("staged_scorer_stub.rb", __dir__)
  STUB_BYTES = File.binread(STUB_PATH).freeze
  STUB = Module.new
  load(STUB_PATH, STUB)
  SCORER = STUB.const_get(:AFScoring, false)
  Status = Struct.new(:success?)

  module_function

  # Return the scorer fixture's current bindings for the exact AFW probe.
  # Return nil for other commands so Open3 still launches them normally.
  def reply(arguments, options)
    environment, ruby, include_path, flag, program, scorer, runtime, adventure_id = arguments
    return unless defined?(AFWorkloads::FrozenInputIdentities::RESOLVE) &&
                  arguments.length == 8 && environment.is_a?(Hash) &&
                  ruby == RbConfig.ruby && flag == "-e" &&
                  program == AFWorkloads::FrozenInputIdentities::RESOLVE &&
                  options[:chdir] == scorer && include_path == "-I#{File.join(scorer, 'lib')}" &&
                  staged_fixture?(scorer)

    fixture_reply(scorer, runtime, adventure_id)
  end

  # Preload the same stub inside the real AFW verifier for cold AFDP replays.
  # Use argv so Bundler's unbundled environment still applies to the child.
  def verifier_argv(arguments)
    environment, *command = arguments
    return arguments unless environment.is_a?(Hash) && command.first.is_a?(String) &&
                            File.basename(command.first) == "afw-staged-selection" && command[1] == "verify"

    selector = command.index("--scorer-repo")
    return arguments unless selector && staged_fixture?(command[selector + 1])

    [environment, RbConfig.ruby, *PRELOAD, *command]
  end

  # Match the exact scorer entry point written by the test fixture.
  def staged_fixture?(scorer)
    return false unless scorer.is_a?(String)

    entry = File.join(scorer, "lib", "af_scoring.rb")
    File.file?(entry) && File.binread(entry) == STUB_BYTES
  end

  # Format the synthetic scorer's response from live fixture files. Input
  # errors are returned to AFW as a failed transport, just like a child exit.
  def fixture_reply(scorer, runtime, adventure_id)
    config = SCORER::Config.new(project_root: scorer, config_path: runtime)
    adventure = SCORER::Catalog.new(config.catalog_path).fetch(adventure_id)
    source = SCORER::SourceResolver.new(source_root: config.dig("paths", "source_root"),
      registry_path: config.source_registry_path).resolve(adventure)
    bindings = {
      "source_file" => source.path, "source_registry" => config.source_registry_path,
      "ontology" => config.afao_path, "assessment_spec" => config.assessment_spec_path
    }.transform_values do |path|
      {"path" => File.expand_path(path), "sha256" => Digest::SHA256.file(path).hexdigest}
    end
    [JSON.generate(bindings), "", Status.new(true)]
  rescue SystemCallError, KeyError, TypeError, Psych::Exception => error
    ["", error.message, Status.new(false)]
  end
end

# Retain the original method as a bound callable so Minitest's scoped
# Open3.stub can still delegate to it during the catalog observation tests.
staged_scorer_capture = Open3.method(:capture3)
Open3.define_singleton_method(:capture3) do |*arguments, **options, &block|
  StagedScorerIdentityTransport.reply(arguments, options) ||
    staged_scorer_capture.call(*StagedScorerIdentityTransport.verifier_argv(arguments), **options, &block)
end
