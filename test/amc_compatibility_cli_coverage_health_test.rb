# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/af_data_pipeline/amc_compatibility_cli"
require "stringio"

class AmcCompatibilityCliCoverageHealthTest < Minitest::Test
  Role = Data.define(:path)

  def test_explicit_against_tolerates_unreadable_optional_project_state
    candidate = "/tmp/coverage-candidate.xlsx"
    base = "/tmp/coverage-base.xlsx"
    checker = passing_checker
    state_class = project_state_class(fail_validation: true)
    out = StringIO.new
    err = StringIO.new

    status = AfDataPipeline::AmcCompatibilityCLI.run(
      [candidate, "--against", base, "--manifest", "/tmp/missing-project-state.yml", "--json"],
      out:,
      err:,
      checker:,
      project_state_class: state_class
    )

    assert_equal 0, status, err.string
    assert_empty err.string
  end

  def test_default_catalog_head_requires_valid_project_state
    out = StringIO.new
    err = StringIO.new

    status = AfDataPipeline::AmcCompatibilityCLI.run(
      ["/tmp/coverage-candidate.xlsx", "--manifest", "/tmp/missing-project-state.yml", "--json"],
      out:,
      err:,
      checker: passing_checker,
      project_state_class: project_state_class(fail_validation: true)
    )

    assert_equal 2, status
    assert_includes err.string, "fixture project-state failure"
  end

  def test_candidate_equal_to_catalog_head_uses_fallback_path_comparison_without_adoption
    candidate = "/tmp/nonexistent/5e_Adventure_Master_Catalog_1.0.xlsx"
    out = StringIO.new
    err = StringIO.new

    status = AfDataPipeline::AmcCompatibilityCLI.run(
      [candidate, "--manifest", "/tmp/project-state.yml", "--json"],
      out:,
      err:,
      checker: passing_checker,
      project_state_class: project_state_class(catalog_head: candidate)
    )

    assert_equal 0, status, err.string
    assert_empty err.string
  end

  def test_noncanonical_candidate_does_not_produce_adoption_command
    candidate = "/tmp/nonexistent/candidate.xlsx"
    catalog_head = "/tmp/nonexistent/5e_Adventure_Master_Catalog_1.0.xlsx"
    out = StringIO.new
    err = StringIO.new

    status = AfDataPipeline::AmcCompatibilityCLI.run(
      [candidate, "--manifest", "/tmp/project-state.yml", "--json"],
      out:,
      err:,
      checker: passing_checker,
      project_state_class: project_state_class(catalog_head:)
    )

    assert_equal 0, status, err.string
    assert_empty err.string
  end

  private

  def passing_checker
    Object.new.tap do |checker|
      checker.define_singleton_method(:check) do |candidate_path:, base_path:|
        {
          "status" => "PASS",
          "candidate" => { "path" => candidate_path },
          "against" => { "path" => base_path }
        }
      end
    end
  end

  def project_state_class(catalog_head: nil, fail_validation: false)
    role = Role.new(catalog_head)
    Class.new do
      define_method(:initialize) { |manifest_path:| @manifest_path = manifest_path }
      define_method(:validate!) do
        raise AfDataPipeline::Error, "fixture project-state failure" if fail_validation

        true
      end
      define_method(:resolve) do |name|
        raise "unexpected role #{name.inspect}" unless name == "catalog_head"

        role
      end
    end
  end
end
