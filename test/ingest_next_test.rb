# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "minitest/mock"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../lib/af_data_pipeline/ingest_next"
require_relative "../lib/af_data_pipeline/boundary_editorial"

class IngestNextTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("af-ingest-next")
    @source_root = File.join(@tmpdir, "md-for-llm-book-content")
    @catalog_root = File.join(@tmpdir, "af-xlsx-data-sources")
    @afio_root = File.join(@tmpdir, "af-inference-orchestrator-production")
    @pdf_root = File.join(@tmpdir, "pdf-to-llm-md-converter")
    [@source_root, @catalog_root, @afio_root, @pdf_root].each { |path| FileUtils.mkdir_p(path) }

    @head = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.0.xlsx")
    File.write(@head, "catalog-head")
    File.write(
      File.join(@catalog_root, "PROJECT_STATE.yml"),
      {
        "schema_version" => "adventurefinder-project-state/v0.2",
        "catalog_head" => role(@head, "7.0"),
        "matcher_authorized_baseline" => role(@head, "7.0"),
        "production_dependency_floor" => role(@head, "7.0")
      }.to_yaml
    )

    @router = AfDataPipeline::IngestNext.new(
      source_root: @source_root,
      catalog_root: @catalog_root,
      afio_root: @afio_root,
      adventure_finder_root: File.join(@tmpdir, "adventure-finder"),
      pdf_converter_root: @pdf_root
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_page_review_routes_to_diagnostic_then_catalog_front_door
    source_pdf = File.join(@tmpdir, "Fixture Book.pdf")
    markdown = File.join(@tmpdir, "Fixture_Book_LLM_Edition.md")
    receipt = File.join(@tmpdir, "Fixture_Book_LLM_Edition.conversion-receipt.json")
    File.write(source_pdf, "%PDF fixture")
    File.write(markdown, "# retained diagnostic markdown")

    fingerprint = "f" * 64
    File.write(
      receipt,
      JSON.pretty_generate(
        "schema" => "pdf-to-llm-md/conversion-receipt/v0.1",
        "state" => "needs_page_review",
        "downstream_ready" => false,
        "source" => {"path" => source_pdf},
        "output" => {"path" => markdown},
        "extraction_quality" => {
          "issues" => [
            {
              "page" => 136,
              "backend" => "docling",
              "reason" => "coverage collapse",
              "fingerprint" => fingerprint
            }
          ]
        },
        "unresolved_issue_fingerprints" => [fingerprint]
      )
    )

    result = @router.inspect(artifact_path: receipt)

    assert_equal "NEEDS_PAGE_REVIEW", result.state
    assert_equal 2, result.commands.length
    assert_includes result.commands.first.fetch("command"), "review-page-exception"
    assert_includes result.commands.first.fetch("command"), "--page 136"

    resume = result.commands.last
    expected_front_door = @router.adventure_finder_root
    assert_equal expected_front_door, resume.fetch("cwd")
    assert_includes resume.fetch("command"), "bin/af-catalog"
    assert_includes resume.fetch("command"), Shellwords.escape(source_pdf)
    assert result.human_review.any? { |line| line.include?("return to the AdventureFinder catalog front door") }
  end

  def test_canonical_markdown_placement_prints_explicit_ingest_resume_command
    source_pdf = File.join(@tmpdir, "Fixture Book.pdf")
    markdown = File.join(@tmpdir, "Fixture_Book_LLM_Edition.md")
    receipt = File.join(@tmpdir, "Fixture_Book_LLM_Edition.conversion-receipt.json")
    File.write(source_pdf, "%PDF fixture")
    File.write(markdown, "# accepted markdown\n")

    File.write(
      receipt,
      JSON.pretty_generate(
        "schema" => "pdf-to-llm-md/conversion-receipt/v0.1",
        "state" => "ready",
        "downstream_ready" => true,
        "source" => {"path" => source_pdf},
        "output" => {
          "path" => markdown,
          "sha256" => Digest::SHA256.file(markdown).hexdigest
        }
      )
    )

    result = @router.inspect(artifact_path: receipt)

    assert_equal "NEEDS_CANONICAL_MARKDOWN_PLACEMENT", result.state
    assert_empty result.commands

    review = result.human_review.join("\n")
    assert_includes review, "Copy or place the accepted converter output there unchanged."
    assert_includes review, "Resume command after canonical Markdown placement:"
    assert_includes review, "bin/af-ingest-next"
    assert_includes review, Shellwords.escape(receipt)
    assert_includes review, "--canonical-markdown PATH"
    refute_includes review, "rerun this command"
  end

  def test_source_identity_gate_prints_explicit_ingest_resume_command
    markdown = File.join(@source_root, "Fixture_LLM_Edition.md")
    File.write(markdown, "# Fixture\n")
    intake = File.join(@tmpdir, "source_intake.json")
    File.write(
      intake,
      JSON.pretty_generate(
        "schema_version" => "af-source-intake/v0.1",
        "source_root" => @source_root,
        "markdown" => {
          "filename" => "Fixture_LLM_Edition.md",
          "sha256" => Digest::SHA256.file(markdown).hexdigest
        },
        "registry" => {
          "registration_status" => "unregistered",
          "source_ids_referencing_file" => []
        },
        "conversion_provenance" => {
          "receipt_status" => "absent",
          "conversion_acceptance_verified" => false,
          "warning" => "No conversion receipt supplied."
        }
      )
    )

    result = @router.inspect(artifact_path: intake)

    assert_equal "NEEDS_SOURCE_IDENTITY", result.state
    assert_empty result.commands

    review = result.human_review.join("\\n")
    assert_includes review, "Resume command after choosing the canonical source identity:"
    assert_includes review, "bin/af-ingest-next"
    assert_includes review, Shellwords.escape(intake)
    assert_includes review, "--source-id Exact\\ Canonical\\ Source\\ Identity"
    refute_includes review, "Rerun with --source-id"
  end

  def test_empty_frontier_ledger_prints_exact_ingest_resume_command
    bundle = File.join(@tmpdir, "fixture-editorial")
    FileUtils.mkdir_p(bundle)
    File.write(
      File.join(bundle, "editorial_context.json"),
      JSON.pretty_generate(
        "schema_version" => "af-boundary-editorial-context/v0.1",
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
            {"filename" => "Fixture.md", "sha256" => "c" * 64}
          ]
        },
        "base_amc" => {
          "filename" => File.basename(@head),
          "sha256" => Digest::SHA256.file(@head).hexdigest
        },
        "rebind_history" => []
      )
    )
    File.write(
      File.join(bundle, "editorial_decisions.yml"),
      {
        "schema_version" => "af-boundary-editorial-decisions/v0.1",
        "candidates" => []
      }.to_yaml
    )

    result = @router.inspect(artifact_path: bundle)

    assert_equal "NEEDS_FRONTIER_EDITORIAL_REVIEW", result.state
    assert_empty result.commands
    review = result.human_review.join("\n")
    assert_includes review, "Resume command after the reviewed ledger is saved:"
    assert_includes review, "bin/af-ingest-next"
    assert_includes review, Shellwords.escape(bundle)
  end

  def test_unregistered_source_registration_command_carries_exact_dossier_continuation
    markdown = File.join(@source_root, "Fixture_LLM_Edition.md")
    File.write(markdown, "# Fixture\n")
    intake = File.join(@tmpdir, "source_intake.json")
    File.write(
      intake,
      JSON.pretty_generate(
        "schema_version" => "af-source-intake/v0.1",
        "source_root" => @source_root,
        "markdown" => {
          "filename" => "Fixture_LLM_Edition.md",
          "sha256" => Digest::SHA256.file(markdown).hexdigest
        },
        "registry" => {
          "registration_status" => "unregistered",
          "source_ids_referencing_file" => []
        },
        "conversion_provenance" => {
          "receipt_status" => "absent",
          "conversion_acceptance_verified" => false,
          "warning" => "No conversion receipt supplied."
        }
      )
    )

    result = @router.inspect(artifact_path: intake, source_id: "Fixture Book")

    assert_equal "READY_FOR_SOURCE_REGISTRATION", result.state
    assert_equal 2, result.commands.length
    register = result.commands.first.fetch("command")
    dossier = result.commands.last.fetch("command")
    assert_includes register, "bin/af-source-register"
    assert_includes register, "--next-amc #{Shellwords.escape(@head)}"
    assert_includes register, "--next-output"
    assert_includes dossier, "bin/af-boundary-dossier"
  end

  def test_pending_editorial_ledger_requires_complete_validation_before_resume
    bundle = File.join(@tmpdir, "pending-editorial")
    FileUtils.mkdir_p(bundle)
    decisions_path = File.join(bundle, "editorial_decisions.yml")
    File.write(
      File.join(bundle, "editorial_context.json"),
      JSON.pretty_generate(
        "schema_version" => "af-boundary-editorial-context/v0.1",
        "source" => {"canonical_source_id" => "Fixture Book"}
      )
    )
    File.write(
      decisions_path,
      {
        "schema_version" => "af-boundary-editorial-decisions/v0.1",
        "candidates" => [
          {
            "candidate_key" => "pending",
            "provisional_title" => "Pending",
            "disposition" => "pending"
          }
        ]
      }.to_yaml
    )

    @router.define_singleton_method(:bound_dossier_path) { |_artifact, _context| "/tmp/dossier.json" }
    @router.define_singleton_method(:bound_amc_path) { |_context| "/tmp/base.xlsx" }

    result = @router.inspect(artifact_path: bundle)

    assert_equal "NEEDS_EDITORIAL_REVIEW", result.state
    assert_equal 1, result.commands.length
    review = result.human_review.join("\n")
    assert_includes review, decisions_path
    assert_includes review, "fails closed until the ledger is importable"
    command = result.commands.first.fetch("command")
    assert_includes command, "af-boundary-editorial"
    assert_includes command, "validate"
    assert_includes command, "--complete"
    assert_includes command, Shellwords.escape(bundle)
  end

  def test_registered_source_intake_routes_to_boundary_dossier
    markdown = File.join(@source_root, "Fixture_LLM_Edition.md")
    File.write(markdown, "# Fixture\n")
    intake = File.join(@tmpdir, "source_intake.json")
    File.write(
      intake,
      JSON.pretty_generate(
        "schema_version" => "af-source-intake/v0.1",
        "source_root" => @source_root,
        "markdown" => {
          "filename" => "Fixture_LLM_Edition.md",
          "sha256" => Digest::SHA256.file(markdown).hexdigest
        },
        "registry" => {
          "registration_status" => "registered",
          "source_ids_referencing_file" => ["Fixture Book"]
        },
        "conversion_provenance" => {
          "receipt_status" => "absent",
          "conversion_acceptance_verified" => false,
          "warning" => "No conversion receipt supplied."
        }
      )
    )

    result = @router.inspect(artifact_path: intake)

    assert_equal "READY_FOR_BOUNDARY_DOSSIER", result.state
    assert_equal 1, result.commands.length
    assert_includes result.commands.first.fetch("command"), "af-boundary-dossier"
    assert_includes result.commands.first.fetch("command"), "Fixture\\ Book"
    assert_equal ["No conversion receipt supplied."], result.warnings
  end

  def test_dossier_requires_explicit_editorial_specification_selection
    dossier_dir = File.join(@tmpdir, "dossier")
    FileUtils.mkdir_p(dossier_dir)
    dossier = File.join(dossier_dir, "boundary_dossier.json")
    File.write(
      dossier,
      JSON.pretty_generate(
        "schema_version" => "af-boundary-dossier/v0.2",
        "source" => {"canonical_source_id" => "Fixture Book"},
        "base_amc" => {
          "filename" => File.basename(@head),
          "sha256" => Digest::SHA256.file(@head).hexdigest
        }
      )
    )

    result = @router.inspect(artifact_path: dossier_dir)

    assert_equal "NEEDS_EDITORIAL_SPECIFICATIONS", result.state
    assert_empty result.commands
    assert_includes result.human_review.join("\n"), "--spec-root ABSOLUTE_PUBLIC_DIR"
    assert_includes result.human_review.join("\n"), "af-boundary-editorial init"
  end

  def test_bound_dossier_path_selects_same_named_file_matching_context_sha
    wrong_dir = File.join(@tmpdir, "a-wrong-boundary-dossier")
    right_dir = File.join(@tmpdir, "z-right-boundary-dossier")
    bundle = File.join(@tmpdir, "fixture-editorial")
    [wrong_dir, right_dir, bundle].each { |path| FileUtils.mkdir_p(path) }

    wrong_dossier = File.join(wrong_dir, "boundary_dossier.json")
    right_dossier = File.join(right_dir, "boundary_dossier.json")
    File.write(wrong_dossier, JSON.generate("source" => "wrong"))
    File.write(right_dossier, JSON.generate("source" => "right"))

    artifact = {path: bundle}
    context = {
      "dossier" => {
        "filename" => "boundary_dossier.json",
        "sha256" => Digest::SHA256.file(right_dossier).hexdigest
      }
    }

    Dir.stub(:glob, [wrong_dossier, right_dossier]) do
      resolved = @router.send(:bound_dossier_path, artifact, context)
      assert_equal right_dossier, resolved
    end
  end

  def test_complete_editorial_bundle_routes_to_freeze_draft_then_human_approval
    dossier_dir = File.join(
      File.expand_path("../audits/pre-scoring", AfDataPipeline::IngestNext::REPO_ROOT),
      "fixture-book-boundary-dossier"
    )
    # The router also accepts dossier lookup by filename under audits. For this
    # isolated test, bind an absolute fixture through the editorial bundle's
    # sibling directory instead.
    bundle = File.join(@tmpdir, "fixture-editorial")
    FileUtils.mkdir_p(bundle)
    dossier = File.join(@tmpdir, "boundary_dossier.json")
    File.write(
      dossier,
      JSON.pretty_generate(
        "schema_version" => "af-boundary-dossier/v0.2",
        "source" => {
          "canonical_source_id" => "Fixture Book",
          "registry_filename" => "source_registry.yml",
          "registry_sha256" => "a" * 64,
          "markdown_files" => [{"filename" => "Fixture.md", "sha256" => "b" * 64}]
        },
        "base_amc" => {
          "filename" => File.basename(@head),
          "sha256" => Digest::SHA256.file(@head).hexdigest
        }
      )
    )
    FileUtils.cp(dossier, File.join(bundle, "boundary_dossier.json"))
    context_dossier = File.join(bundle, "boundary_dossier.json")
    File.write(
      File.join(bundle, "editorial_context.json"),
      JSON.pretty_generate(
        "schema_version" => "af-boundary-editorial-context/v0.1",
        "dossier" => {
          "filename" => "boundary_dossier.json",
          "sha256" => Digest::SHA256.file(context_dossier).hexdigest,
          "schema_version" => "af-boundary-dossier/v0.2"
        },
        "source" => {
          "canonical_source_id" => "Fixture Book",
          "registry_filename" => "source_registry.yml",
          "registry_sha256" => "a" * 64,
          "markdown_files" => [{"filename" => "Fixture.md", "sha256" => "b" * 64}]
        },
        "base_amc" => {
          "filename" => File.basename(@head),
          "sha256" => Digest::SHA256.file(@head).hexdigest
        },
        "rebind_history" => []
      )
    )
    File.write(
      File.join(bundle, "editorial_decisions.yml"),
      {
        "schema_version" => "af-boundary-editorial-decisions/v0.1",
        "candidates" => [
          {
            "candidate_key" => "a",
            "provisional_title" => "A",
            "playability_evidence" => "Evidence",
            "review_history" => [],
            "disposition" => "accept",
            "decision" => {
              "canonical_title" => "A",
              "printed_pages" => {"start" => 1, "end" => 2},
              "editorial_rationale" => "Accepted."
            }
          }
        ]
      }.to_yaml
    )

    # Override the deterministic freeze paths so this test does not write to the
    # repository checkout.
    draft_path = File.join(@tmpdir, "fixture-draft.yml")
    final_path = File.join(@tmpdir, "fixture-final.yml")
    @router.define_singleton_method(:freeze_draft_path) { |_source_id| draft_path }
    @router.define_singleton_method(:freeze_final_path) { |_source_id| final_path }

    result = @router.inspect(artifact_path: bundle)
    assert_equal "READY_FOR_FREEZE_DRAFT", result.state
    assert_equal 2, result.commands.length
    assert_includes result.commands.first.fetch("command"), "af-boundary-editorial"
    assert_includes result.commands.first.fetch("command"), "validate"
    assert_includes result.commands.first.fetch("command"), "--complete"
    assert_includes result.commands.last.fetch("command"), "boundary-freeze-init"

    write_fixture_freeze(draft_path, amc_path: @head, state: "draft")
    result = @router.inspect(artifact_path: bundle)
    assert_equal "NEEDS_HUMAN_APPROVAL", result.state
    assert_empty result.commands

    review = result.human_review.join("\n")
    assert_includes review, "Issue the software-timestamped approval after review:"
    assert_includes review, "af-boundary-editorial"
    assert_includes review, "approve"
    assert_includes review, Shellwords.escape(bundle)
    assert_includes review, "--approved-by NAME"
    refute_includes review, "--approved-at"
  end

  def test_rebound_7_3_1_bundle_does_not_reuse_stale_7_2_1_freezes
    old_amc = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.2.1.xlsx")
    current_amc = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.3.1.xlsx")
    File.write(old_amc, "catalog-7.2.1")
    File.write(current_amc, "catalog-7.3.1")

    source_file = File.join(@source_root, "Fixture.md")
    File.write(source_file, "<!-- Printed Page 1 -->\n# Fixture\n")
    registry_file = File.join(@source_root, "source_registry.yml")
    File.write(
      registry_file,
      {
        "schema_version" => AfDataPipeline::BoundaryFreeze::SOURCE_REGISTRY_SCHEMA_VERSION,
        "sources" => {"Fixture Book" => {"file" => "Fixture.md"}}
      }.to_yaml
    )
    source = {
      "canonical_source_id" => "Fixture Book",
      "registry_filename" => "source_registry.yml",
      "registry_sha256" => Digest::SHA256.file(registry_file).hexdigest,
      "markdown_files" => [
        {"filename" => "Fixture.md", "sha256" => Digest::SHA256.file(source_file).hexdigest}
      ]
    }
    old_base_amc = {
      "filename" => File.basename(old_amc),
      "sha256" => Digest::SHA256.file(old_amc).hexdigest
    }
    current_base_amc = {
      "filename" => File.basename(current_amc),
      "sha256" => Digest::SHA256.file(current_amc).hexdigest
    }

    old_dossier_dir = File.join(@tmpdir, "dossier-7.2.1")
    current_dossier_dir = File.join(@tmpdir, "dossier-7.3.1")
    FileUtils.mkdir_p(old_dossier_dir)
    FileUtils.mkdir_p(current_dossier_dir)
    old_dossier = File.join(old_dossier_dir, "boundary_dossier.json")
    current_dossier = File.join(current_dossier_dir, "boundary_dossier.json")
    File.write(
      old_dossier,
      JSON.pretty_generate(
        "schema_version" => "af-boundary-dossier/v0.2",
        "source" => source,
        "base_amc" => old_base_amc
      )
    )
    File.write(
      current_dossier,
      JSON.pretty_generate(
        "schema_version" => "af-boundary-dossier/v0.2",
        "source" => source,
        "base_amc" => current_base_amc
      )
    )

    old_bundle = File.join(@tmpdir, "fixture-editorial-7.2.1")
    AfDataPipeline::BoundaryEditorial.init!(dossier_path: old_dossier, output_dir: old_bundle)
    decisions_path = File.join(old_bundle, "editorial_decisions.yml")
    File.write(
      decisions_path,
      {
        "schema_version" => "af-boundary-editorial-decisions/v0.1",
        "candidates" => [
          {
            "candidate_key" => "a",
            "provisional_title" => "A",
            "playability_evidence" => "Evidence",
            "review_history" => [
              {
                "phase" => "phase2",
                "status" => "accepted",
                "rationale" => "Reviewed."
              }
            ],
            "disposition" => "accept",
            "decision" => {
              "canonical_title" => "A",
              "printed_pages" => {"start" => 1, "end" => 2},
              "editorial_rationale" => "Accepted."
            }
          }
        ]
      }.to_yaml
    )
    reviewed_decisions = File.binread(decisions_path)

    rebound_bundle = File.join(@tmpdir, "fixture-editorial-rebound")
    rebind = AfDataPipeline::BoundaryEditorial.rebind!(
      bundle_dir: old_bundle,
      dossier_path: current_dossier,
      output_dir: rebound_bundle,
      reason: "Catalog head advanced from AMC 7.2.1 to 7.3.1"
    )
    assert_equal current_base_amc, rebind.context.fetch("base_amc")
    assert_equal reviewed_decisions, File.binread(File.join(rebound_bundle, "editorial_decisions.yml"))
    @router.define_singleton_method(:bound_dossier_path) do |_artifact, _context|
  current_dossier
end

    stale_draft = File.join(@tmpdir, "fixture-boundary-freeze-draft.yml")
    stale_final = File.join(@tmpdir, "fixture-boundary-freeze.yml")
    @router.define_singleton_method(:freeze_draft_path) { |_source_id| stale_draft }
    @router.define_singleton_method(:freeze_final_path) { |_source_id| stale_final }
    write_fixture_freeze(stale_draft, amc_path: old_amc, state: "draft", source:)
    write_fixture_freeze(stale_final, amc_path: old_amc, state: "frozen", source:)

    result = @router.inspect(artifact_path: rebound_bundle)

    rebound_draft = File.join(@tmpdir, "fixture-boundary-freeze-draft-from-amc-7.3.1.yml")
    rebound_final = File.join(@tmpdir, "fixture-boundary-freeze-from-amc-7.3.1.yml")
    assert_equal "READY_FOR_FREEZE_DRAFT", result.state
    init_argv = Shellwords.split(result.commands.last.fetch("command"))
    assert_equal rebound_draft, init_argv.fetch(init_argv.index("--output") + 1)
    assert result.warnings.any? { |line| line.include?(stale_draft) && line.include?("preserved") }
    assert result.warnings.any? { |line| line.include?(rebound_draft) }
    assert_includes AfDataPipeline::IngestNext::AUTO_ADVANCE_STATES, "READY_FOR_FREEZE_DRAFT"
    assert_includes AfDataPipeline::IngestNext::AUTO_ADVANCE_STATES, "READY_FOR_EDITORIAL_IMPORT"

    write_fixture_freeze(rebound_draft, amc_path: current_amc, state: "draft", source:)
    approval_path = File.join(@tmpdir, "rebound-approval.json")
    AfDataPipeline::BoundaryEditorial.approve!(
      bundle_dir: rebound_bundle,
      dossier_path: current_dossier,
      source_root: @source_root,
      amc_path: current_amc,
      approved_by: "David Norris",
      output_path: approval_path,
      clock: -> { Time.iso8601("2026-09-26T12:00:00Z") }
    )
    result = @router.inspect(
      artifact_path: rebound_bundle,
      approval_path:
    )

    assert_equal "READY_FOR_EDITORIAL_IMPORT", result.state
    import_argv = Shellwords.split(result.commands.first.fetch("command"))
    assert_equal rebound_draft, import_argv.fetch(import_argv.index("--freeze") + 1)
    assert_equal rebound_final, import_argv.fetch(import_argv.index("--output") + 1)
    assert_equal approval_path, import_argv.fetch(import_argv.index("--approval") + 1)
    refute_includes import_argv, "--approved-at"
    validate_argv = Shellwords.split(result.commands.last.fetch("command"))
    assert_equal rebound_final, validate_argv.fetch(2)
    refute_equal stale_draft, rebound_draft
    refute_equal stale_final, rebound_final

    File.open(File.join(rebound_bundle, "editorial_decisions.yml"), "a") { |file| file.write("\n") }
    blocked = @router.inspect(artifact_path: rebound_bundle, approval_path:)
    assert_equal "BLOCKED_BOUNDARY_APPROVAL", blocked.state
    assert_empty blocked.commands
    assert blocked.evidence.any? { |line| line.include?("approval is stale") }
    assert blocked.human_review.any? { |line| line.include?("new immutable path") }
  end

  def test_ingest_next_cli_rejects_legacy_loose_approval_flags
    out = StringIO.new
    err = StringIO.new

    status = AfDataPipeline::IngestNext::CLI.run(
      ["/tmp/fixture", "--approved-by", "David", "--approved-at", "2026-10-07"],
      out:,
      err:
    )

    assert_equal 2, status
    assert_empty out.string
    assert_match(/legacy loose/, err.string)
    assert_match(/--approval PATH/, err.string)
  end

  def test_verified_boundary_apply_report_routes_to_adoption_then_afw
    successor = File.join(@catalog_root, "5e_Adventure_Master_Catalog_7.1.xlsx")
    File.write(successor, "successor")
    report_path = File.join(@tmpdir, "apply-report.json")
    report = {
      "schema_version" => "af-boundary-freeze-apply-report/v0.1",
      "status" => "complete",
      "source" => {"canonical_source_id" => "Fixture Book"},
      "output_amc" => {
        "path" => successor,
        "sha256" => Digest::SHA256.file(successor).hexdigest
      },
      "records" => [
        {
          "adventure_id" => "ADV-1000",
          "printed_pages" => {"start" => 1, "end" => 50}
        },
        {
          "adventure_id" => "ADV-1001",
          "printed_pages" => {"start" => 1, "end" => 120}
        }
      ],
      "verification" => {"passed" => true}
    }
    File.write(report_path, JSON.pretty_generate(report))

    before = @router.inspect(artifact_path: report_path)
    assert_equal "READY_FOR_CATALOG_ADOPTION", before.state
    assert_includes before.commands.first.fetch("command"), "af-project-state"
    assert_includes before.commands.first.fetch("command"), "adopt"
    assert_includes before.commands.first.fetch("command"), "--resume-artifact"
    assert_includes before.commands.first.fetch("command"), Shellwords.escape(report_path)

    project_state_path = File.join(@catalog_root, "PROJECT_STATE.yml")
    data = YAML.safe_load_file(project_state_path)
    data["catalog_head"] = role(successor, "7.1")
    File.write(project_state_path, data.to_yaml)

    router = AfDataPipeline::IngestNext.new(
      source_root: @source_root,
      catalog_root: @catalog_root,
      afw_root: File.join(@tmpdir, "af-workloads-production"),
      scorer_root: File.join(@tmpdir, "af-cli-scoring-utility-production"),
      scorer_config: File.join(@tmpdir, "explicit selection.yml"),
      pdf_converter_root: @pdf_root
    )

    needs_batch = router.inspect(artifact_path: report_path)
    assert_equal "NEEDS_PRODUCTION_BATCH_NUMBER", needs_batch.state
    assert_empty needs_batch.commands
    assert needs_batch.human_review.any? { |line| line.include?("Resume command after human review:") }
    assert needs_batch.human_review.any? { |line| line.include?("bin/af-ingest-next") }
    assert needs_batch.human_review.any? { |line| line.include?("--batch NNN") }

    error = assert_raises(AfDataPipeline::IngestNext::Error) do
      router.inspect(artifact_path: report_path, batch: "NNN")
    end
    assert_match(/positive numeric batch number/, error.message)

    previous_data_root = ENV["AF_AFW_DATA_ROOT"]
    begin
      ENV["AF_AFW_DATA_ROOT"] = @tmpdir
      after = router.inspect(artifact_path: report_path, batch: "037")
    ensure
      ENV["AF_AFW_DATA_ROOT"] = previous_data_root
    end

    assert_equal "READY_FOR_AFW_WORKLOAD_BUILD", after.state
    assert_equal router.afw_root, after.commands.first.fetch("cwd")
    assert_includes after.evidence, "AFW runnable: 1: ADV-1000"
    assert_includes(
      after.evidence,
      "AFW deferred: 1: ADV-1001 (120 pages; outside proven <100-page scoring envelope)"
    )
    assert after.warnings.any? { |line| line.include?("Deferred 1 Adventure ID") }
    assert after.human_review.any? { |line| line.include?("remain unscored") }

    command = after.commands.first.fetch("command")
    argv = Shellwords.split(command)
    assert_equal File.join(router.afw_root, "bin", "afw-build-workload"), argv.fetch(0)
    assert_equal router.scorer_root, argv.fetch(argv.index("--scorer-repo") + 1)
    assert_equal File.join(@tmpdir, "explicit selection.yml"), argv.fetch(argv.index("--scorer-config") + 1)
    assert_equal "production-batch-037", argv.fetch(argv.index("--workload") + 1)
    assert_equal successor, argv.fetch(argv.index("--catalog") + 1)
    assert_equal "ADV-1000", argv.fetch(argv.index("--ids") + 1)
    assert_equal "131072", argv.fetch(argv.index("--required-context-length") + 1)
    assert_includes argv, "--require-fully-gpu-resident"
    refute_includes argv, "--required-gpu-id"
    # Omitting the compatibility override leaves AFW on its production v0.3 default.
    refute_includes argv, "--wlo-plan-version"
    refute_includes command, "ADV-1001"
    refute_includes command, "build-production-backlog"
    refute_includes command, "--from-boundary-apply"
    refute_includes command, "--dry-run"
    assert after.human_review.any? { |line| line.include?("zero-inference AFW workload") }
    assert after.human_review.any? { |line| line.include?("WLO execution plan") }
  end

  def test_auto_advance_executes_allowlisted_steps_and_stops_at_human_gate
    Dir.mktmpdir("af-ingest-auto") do |dir|
      next_artifact = File.join(dir, "source_intake.json")
      initial = AfDataPipeline::IngestNext::Result.new(
        state: "READY_FOR_SOURCE_INTAKE",
        artifact_type: "conversion_receipt",
        evidence: [],
        human_review: [],
        commands: [
          {
            "cwd" => dir,
            "command" => "/tmp/fake-source-intake --fixture",
            "auto_artifact" => next_artifact
          }
        ],
        warnings: []
      )
      human_gate = AfDataPipeline::IngestNext::Result.new(
        state: "NEEDS_SOURCE_IDENTITY",
        artifact_type: "source_intake",
        evidence: [],
        human_review: ["Choose source identity."],
        commands: [],
        warnings: []
      )
      inspected = []
      router = Object.new
      router.define_singleton_method(:inspect) do |artifact_path:, **options|
        inspected << [artifact_path, options]
        human_gate
      end
      executed = []
      executor = lambda do |item, _out, _err|
        executed << item.fetch("command")
        File.write(next_artifact, "{}\n")
        0
      end
      out = StringIO.new
      err = StringIO.new

      result = AfDataPipeline::IngestNext::CLI.auto_advance(
        router:,
        artifact_path: File.join(dir, "receipt.json"),
        result: initial,
        inspect_options: {source_id: nil},
        out:,
        err:,
        executor:
      )

      assert_same human_gate, result
      assert_equal ["/tmp/fake-source-intake --fixture"], executed
      assert_equal [[next_artifact, {source_id: nil}]], inspected
      assert_includes out.string, "AUTO: READY_FOR_SOURCE_INTAKE"
      assert_includes out.string, "AUTO: running fake-source-intake"
      assert_includes out.string, "AUTO: PASS fake-source-intake"
      assert_empty err.string
    end
  end

  def test_auto_advance_does_not_execute_human_gated_state
    result = AfDataPipeline::IngestNext::Result.new(
      state: "READY_FOR_CATALOG_ADOPTION",
      artifact_type: "boundary_apply_report",
      evidence: [],
      human_review: ["Review catalog delta."],
      commands: [{"cwd" => "/tmp", "command" => "/tmp/adopt"}],
      warnings: []
    )
    executed = false

    final = AfDataPipeline::IngestNext::CLI.auto_advance(
      router: Object.new,
      artifact_path: "/tmp/report.json",
      result:,
      inspect_options: {},
      out: StringIO.new,
      err: StringIO.new,
      executor: ->(_item, _out, _err) { executed = true; 0 }
    )

    assert_same result, final
    refute executed
  end

  private

  def write_fixture_freeze(path, amc_path:, state:, source: nil)
    approval =
      if state == "frozen"
        {"approved_by" => "David Norris", "approved_at" => "2026-09-26"}
      else
        {"approved_by" => nil, "approved_at" => nil}
      end

    File.write(
      path,
      {
        "schema_version" => "af-boundary-freeze/v0.1",
        "state" => state,
        "source" => source || {
          "canonical_source_id" => "Fixture Book",
          "registry_filename" => "source_registry.yml",
          "registry_sha256" => "a" * 64,
          "markdown_files" => [{"filename" => "Fixture.md", "sha256" => "b" * 64}]
        },
        "base_amc" => {
          "filename" => File.basename(amc_path),
          "sha256" => Digest::SHA256.file(amc_path).hexdigest
        },
        "approval" => approval,
        "records" => []
      }.to_yaml
    )
  end

  def role(path, version)
    {
      "version" => version,
      "filename" => File.basename(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end
end
