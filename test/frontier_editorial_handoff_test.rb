# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require_relative "../lib/af_data_pipeline/boundary_editorial"
require_relative "../lib/af_data_pipeline/ingest_next"
require "stringio"

class FrontierEditorialHandoffTest < Minitest::Test
  def context
    {
      "schema_version" => AfDataPipeline::BoundaryEditorial::CONTEXT_SCHEMA_VERSION,
      "dossier" => {
        "filename" => "boundary_dossier.json",
        "sha256" => "a" * 64,
        "schema_version" => "af-boundary-dossier/v0.2"
      },
      "source" => {
        "canonical_source_id" => "Fixture Book",
        "registry_filename" => "source_registry.yml",
        "registry_sha256" => "b" * 64,
        "markdown_files" => [
          {"filename" => "Fixture_Book.md", "sha256" => "c" * 64}
        ]
      },
      "base_amc" => {
        "filename" => "5e_Adventure_Master_Catalog_9.9.xlsx",
        "sha256" => "d" * 64
      },
      "rebind_history" => []
    }
  end

  def test_durable_review_contains_ready_to_use_frontier_prompt
    review = AfDataPipeline::BoundaryEditorial.send(:render_review, context)

    assert_includes review, "## Frontier ChatGPT handoff"
    assert_includes review, "Fixture_Book.md"
    assert_includes review, "Inspect the complete canonical source, not a summary."
    assert_includes review, "Do not assign Adventure IDs."
    assert_includes review, "Return the completed editorial_decisions.yml for David's review."
  end

  def test_init_cli_prints_exact_chatgpt_attachments_prompt_and_resume
    result = AfDataPipeline::BoundaryEditorial::BundleResult.new(
      output_dir: "/tmp/fixture-boundary-editorial",
      context_path: "/tmp/fixture-boundary-editorial/editorial_context.json",
      decisions_path: "/tmp/fixture-boundary-editorial/editorial_decisions.yml",
      review_path: "/tmp/fixture-boundary-editorial/editorial_review.md",
      context: context,
      decisions: {"candidates" => []}
    )
    out = StringIO.new
    err = StringIO.new

    AfDataPipeline::BoundaryEditorial.stub(:init!, result) do
      status = AfDataPipeline::BoundaryEditorial::CLI.run(
        [
          "init",
          "--dossier", "/tmp/fixture-boundary-dossier/boundary_dossier.json",
          "--source-root", "/tmp/canonical-source",
          "--output", "/tmp/fixture-boundary-editorial"
        ],
        out:,
        err:
      )
      assert_equal 0, status
    end

    assert_empty err.string
    assert_includes out.string, "Open ChatGPT in normal Chat."
    assert_includes out.string, "/tmp/canonical-source/Fixture_Book.md"
    assert_includes out.string, "/tmp/fixture-boundary-dossier/boundary_dossier.json"
    assert_includes out.string, "/tmp/fixture-boundary-editorial/editorial_review.md"
    assert_includes out.string, "/tmp/fixture-boundary-editorial/editorial_decisions.yml"
    assert_includes out.string, "Inspect the complete canonical source, not a summary."
    assert_includes out.string, "Resume only after the reviewed ledger is saved:"
    assert_includes out.string, "bin/af-ingest-next"
  end

  def test_router_passes_source_root_to_editorial_init
    router = AfDataPipeline::IngestNext.new(
      source_root: "/tmp/canonical-source",
      catalog_root: "/tmp/catalog",
      afio_root: "/tmp/afio",
      pdf_converter_root: "/tmp/converter"
    )
    artifact = {
      path: "/tmp/fixture-boundary-dossier/boundary_dossier.json",
      data: {
        "source" => {"canonical_source_id" => "Fixture Book"},
        "base_amc" => {"filename" => "5e_Adventure_Master_Catalog_9.9.xlsx"}
      }
    }

    result = router.send(:boundary_dossier_result, artifact)
    assert_equal "NEEDS_EDITORIAL_SPECIFICATIONS", result.state
    assert_empty result.commands
    command = result.human_review.last

    assert_includes command, "--source-root"
    assert_includes command, "/tmp/canonical-source"
  end

  def test_empty_editorial_ledger_cannot_advance_to_freeze
    router = AfDataPipeline::IngestNext.new(
      source_root: "/tmp/canonical-source",
      catalog_root: "/tmp/catalog",
      afio_root: "/tmp/afio",
      pdf_converter_root: "/tmp/converter"
    )
    artifact = {
      path: "/tmp/fixture-boundary-editorial",
      context_path: "/tmp/fixture-boundary-editorial/editorial_context.json",
      decisions_path: "/tmp/fixture-boundary-editorial/editorial_decisions.yml",
      context: context,
      decisions: {
        "schema_version" => AfDataPipeline::BoundaryEditorial::DECISIONS_SCHEMA_VERSION,
        "candidates" => []
      }
    }

    result = router.send(
      :editorial_bundle_result,
      artifact,
      approval_path: nil
    )

    assert_equal "NEEDS_FRONTIER_EDITORIAL_REVIEW", result.state
    assert_empty result.commands
    assert result.human_review.any? { |line| line.include?("frontier ChatGPT handoff") }
  end
end
