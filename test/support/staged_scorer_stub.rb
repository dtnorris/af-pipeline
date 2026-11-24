# frozen_string_literal: true

require "digest"
require "yaml"

# Installed as af_scoring.rb in disposable scorer fixtures. Exposes the
# source replay and input-identification calls that AFW makes in subprocesses.
module AFScoring
  class Config
    # Read AFW's runtime selectors for the catalog and synthetic inputs.
    def initialize(project_root:, config_path:, overrides: {})
      @runtime = YAML.safe_load_file(config_path)
    end

    def dig(*keys) = @runtime.dig(*keys)
    def catalog_path = @runtime.fetch("files").fetch("catalog")
    def source_registry_path = File.join(dig("paths", "source_root"), "source_registry.yml")
    def afao_path = File.join(dig("paths", "specification_root"), "AdventureFinder_Analysis_Ontology_AFAO_v1.6.1.md")
    def assessment_spec_path = File.join(dig("paths", "specification_root"), "AdventureFinder_Analysis_Data_Assessment_Specification_v0.1.md")
  end

  class Catalog
    # AFW reads the real XLSX through its separate reader. Identity capture
    # only needs the selected ID to pass into the source resolver.
    def initialize(_path); end
    def fetch(id) = id
  end

  class SourceResolver
    Resolution = Struct.new(:path)

    # Point identity capture at the synthetic source file.
    def initialize(source_root:, registry_path:)
      @source_path = File.join(source_root, "fixture.md")
    end

    def resolve(_adventure) = Resolution.new(@source_path)
  end

  class Runner
    PREPARED_SOURCE_CONTRACT_VERSION = "afsu-prepared-source/v0.2"

    def initialize(config:, logger:)
      @config = config
    end

    # Accept a prepared fixture only for the requested target and runtime catalog.
    # The real scorer's payload and source policy checks live in its own tests.
    def preflight(id, prepared_source:)
      unless prepared_source.dig("adventure", "id") == id &&
             prepared_source.dig("catalog", "path") == @config.catalog_path
        raise ArgumentError, "prepared scorer fixture does not match the target or catalog"
      end
    end
  end
end
