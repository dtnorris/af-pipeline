# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/compatibility_amc_fixture"
require "open3"
require "rbconfig"

class AmcCompatibilityExecutableProjectStateTest < Minitest::Test
  include CompatibilityAmcFixture

  BIN = File.expand_path("../bin/af-amc-compatibility-check", __dir__)

  def test_executable_loads_project_state_dependencies_without_aggregate_require
    Dir.mktmpdir("amc-compatibility-executable") do |dir|
      base = File.join(dir, "5e_Adventure_Master_Catalog_1.0.xlsx")
      candidate = File.join(dir, "5e_Adventure_Master_Catalog_1.1.xlsx")

      write_compatible_amc(
        base,
        rows: [compatible_row("ADV-0001", title: "Existing")]
      )
      write_compatible_amc(
        candidate,
        rows: [
          compatible_row("ADV-0001", title: "Existing"),
          compatible_row("ADV-0002", title: "New", levels: nil)
        ]
      )

      manifest = File.join(dir, "PROJECT_STATE.yml")
      File.write(
        manifest,
        {
          "schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
          "catalog_head" => role(base, "1.0"),
          "matcher_authorized_baseline" => role(base, "1.0"),
          "production_dependency_floor" => role(base, "1.0")
        }.to_yaml
      )

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        BIN,
        candidate,
        "--manifest",
        manifest
      )

      assert status.success?, stderr
      assert_empty stderr
      assert_includes stdout, "AMC cross-consumer compatibility: PASS"
      refute_includes stdout, "uninitialized constant"
    end
  end

  private

  def role(path, version)
    {
      "version" => version,
      "filename" => File.basename(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end
end
