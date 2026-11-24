# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require_relative "../lib/af_data_pipeline/boundary_dossier"
require_relative "../lib/af_data_pipeline/boundary_editorial"
require "stringio"

class IngestContinuationCliTest < Minitest::Test
  class FakeDossierGenerator
    def self.generate!(**)
      AfDataPipeline::BoundaryDossier::Result.new(
        output_dir: "/tmp/fixture-boundary-dossier",
        json_path: "/tmp/fixture-boundary-dossier/boundary_dossier.json",
        markdown_path: "/tmp/fixture-boundary-dossier/boundary_dossier.md",
        report: {
          "source" => {"canonical_source_id" => "Fixture Book"},
          "source_files" => [
            {
              "headings" => [],
              "signal_hits" => [],
              "navigation_evidence" => {
                "anchors" => [],
                "page_mappings" => []
              }
            }
          ],
          "amc_evidence" => {"catalog_record_count" => 0}
        }
      )
    end
  end

  def test_boundary_dossier_cli_prints_ingest_next_continuation
    out = StringIO.new
    err = StringIO.new

    status = AfDataPipeline::BoundaryDossier::CLI.run(
      [
        "--source-root", "/tmp/source",
        "--source-id", "Fixture Book",
        "--amc", "/tmp/amc.xlsx",
        "--output", "/tmp/fixture-boundary-dossier"
      ],
      out:,
      err:,
      generator: FakeDossierGenerator
    )

    assert_equal 0, status
    assert_empty err.string
    assert_includes out.string, "Next command:"
    assert_includes out.string, "bin/af-ingest-next"
    assert_includes out.string, "/tmp/fixture-boundary-dossier"
  end

  def test_boundary_editorial_init_prints_frontier_handoff_and_continuation
    result = AfDataPipeline::BoundaryEditorial::BundleResult.new(
      output_dir: "/tmp/fixture-boundary-editorial",
      context_path: "/tmp/fixture-boundary-editorial/editorial_context.json",
      decisions_path: "/tmp/fixture-boundary-editorial/editorial_decisions.yml",
      review_path: "/tmp/fixture-boundary-editorial/editorial_review.md",
      context: {
        "source" => {
          "canonical_source_id" => "Fixture Book",
          "markdown_files" => [
            {"filename" => "Fixture_Book.md"}
          ]
        },
        "base_amc" => {"filename" => "5e_Adventure_Master_Catalog_9.9.xlsx"}
      },
      decisions: {"candidates" => []}
    )

    out = StringIO.new
    err = StringIO.new

    AfDataPipeline::BoundaryEditorial.stub(:init!, result) do
      status = AfDataPipeline::BoundaryEditorial::CLI.run(
        [
          "init",
          "--dossier", "/tmp/dossier",
          "--source-root", "/tmp/canonical-source",
          "--output", "/tmp/fixture-boundary-editorial"
        ],
        out:,
        err:
      )
      assert_equal 0, status
    end

    assert_empty err.string
    assert_includes out.string, "Frontier editorial handoff required:"
    assert_includes out.string, "Open ChatGPT in normal Chat."
    assert_includes out.string, "/tmp/canonical-source/Fixture_Book.md"
    assert_includes out.string, "/tmp/fixture-boundary-editorial/editorial_review.md"
    assert_includes out.string, "/tmp/fixture-boundary-editorial/editorial_decisions.yml"
    assert_includes out.string, "Inspect the complete canonical source, not a summary."
    assert_includes out.string, "Resume only after the reviewed ledger is saved:"
    assert_includes out.string, "bin/af-ingest-next"
    assert_includes out.string, "/tmp/fixture-boundary-editorial"
  end
  def test_boundary_editorial_validate_prints_router_continuation
    result = AfDataPipeline::BoundaryEditorial::ValidationResult.new(
      bundle_dir: "/tmp/fixture-boundary-editorial",
      context: {},
      decisions: {},
      counts: {
        "accept" => 2,
        "reject" => 1,
        "merge" => 0,
        "hold" => 0,
        "pending" => 0
      },
      complete: true
    )
    out = StringIO.new
    err = StringIO.new

    AfDataPipeline::BoundaryEditorial.stub(:validate!, result) do
      status = AfDataPipeline::BoundaryEditorial::CLI.run(
        ["validate", "/tmp/fixture-boundary-editorial"],
        out:,
        err:
      )
      assert_equal 0, status
    end

    assert_empty err.string
    assert_includes out.string, "Next command:"
    assert_includes out.string, "bin/af-ingest-next"
    assert_includes out.string, "/tmp/fixture-boundary-editorial"
  end

  def test_boundary_editorial_import_prints_exact_freeze_validation_command
    result = AfDataPipeline::BoundaryEditorial::ImportResult.new(
      output_path: "/tmp/frozen.yml",
      record_count: 2,
      sha256: "d" * 64,
      counts: {"reject" => 1, "merge" => 0}
    )
    out = StringIO.new
    err = StringIO.new

    AfDataPipeline::BoundaryEditorial.stub(:import!, result) do
      status = AfDataPipeline::BoundaryEditorial::CLI.run(
        [
          "import",
          "/tmp/fixture-boundary-editorial",
          "--dossier", "/tmp/dossier",
          "--freeze", "/tmp/draft.yml",
          "--source-root", "/tmp/source",
          "--amc", "/tmp/base.xlsx",
          "--approval", "/tmp/approval.json",
          "--output", "/tmp/frozen.yml"
        ],
        out:,
        err:
      )
      assert_equal 0, status
    end

    assert_empty err.string
    assert_includes out.string, "Next command:"
    assert_includes out.string, "boundary-freeze-validate"
    assert_includes out.string, "/tmp/frozen.yml"
    assert_includes out.string, "--source-root /tmp/source"
    assert_includes out.string, "--amc /tmp/base.xlsx"
  end

end
