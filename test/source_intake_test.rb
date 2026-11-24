# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class SourceIntakeTest < Minitest::Test
  def test_intake_measures_unregistered_markdown_without_mutating_inputs
    with_workspace do |root, markdown, registry|
      output = File.join(root, "intake-output")
      source_sha = Digest::SHA256.file(markdown).hexdigest
      registry_sha = Digest::SHA256.file(registry).hexdigest

      result = AfDataPipeline::SourceIntake.generate!(
        markdown_path: markdown,
        source_root: root,
        output_dir: output
      )

      report = result.report
      assert_equal AfDataPipeline::SourceIntake::SCHEMA_VERSION, report.fetch("schema_version")
      assert_equal "unregistered", report.dig("registry", "registration_status")
      assert_empty report.dig("registry", "source_ids_referencing_file")
      assert_equal 2, report.dig("page_evidence", "pdf", "count")
      assert_equal 2, report.dig("page_evidence", "printed", "count")
      assert_equal 9, report.dig("page_evidence", "constant_observed_printed_minus_pdf_offset")
      assert_equal({ 9 => 2 }, report.dig("page_evidence", "observed_printed_minus_pdf_offsets"))
      assert_equal 3, report.fetch("headings").length
      assert report.fetch("metadata_lines").any? { |row| row.fetch("text").include?("Copyright") }
      assert report.fetch("quality_flags").any? { |row| row.fetch("text").include?("ERROR") }
      assert_equal "absent", report.dig("conversion_provenance", "receipt_status")
      refute report.dig("conversion_provenance", "conversion_acceptance_verified")
      assert_includes File.read(result.markdown_path), "WARNING"
      assert_equal source_sha, Digest::SHA256.file(markdown).hexdigest
      assert_equal registry_sha, Digest::SHA256.file(registry).hexdigest
      assert File.file?(result.json_path)
      assert File.file?(result.markdown_path)
      assert_includes File.read(result.markdown_path), "No canonical source identity inferred"
    end
  end

  def test_intake_reports_existing_registry_reference
    with_workspace(register_fixture: true) do |root, markdown, _registry|
      result = AfDataPipeline::SourceIntake.generate!(
        markdown_path: markdown,
        source_root: root,
        output_dir: File.join(root, "intake-output")
      )

      assert_equal "registered", result.report.dig("registry", "registration_status")
      assert_equal ["Fixture Source"], result.report.dig("registry", "source_ids_referencing_file")
    end
  end

  def test_intake_accepts_matching_downstream_ready_conversion_receipt
    with_workspace do |root, markdown, _registry|
      receipt = write_conversion_receipt(
        root,
        markdown,
        state: "ready_with_exceptions",
        downstream_ready: true,
        page_exceptions: [
          {
            "page" => 2,
            "reason" => "Map-only page; no substantive prose or table content is expected"
          }
        ]
      )

      result = AfDataPipeline::SourceIntake.generate!(
        markdown_path: markdown,
        source_root: root,
        output_dir: File.join(root, "intake-output"),
        conversion_receipt_path: receipt
      )

      provenance = result.report.fetch("conversion_provenance")
      assert_equal "verified", provenance.fetch("receipt_status")
      assert provenance.fetch("conversion_acceptance_verified")
      assert_equal "ready_with_exceptions", provenance.fetch("state")
      assert_equal [2], provenance.fetch("reviewed_page_exceptions").map { |row| row.fetch("page") }
      assert_includes File.read(result.markdown_path), "Conversion receipt: verified"
    end
  end

  def test_intake_refuses_supplied_receipt_that_is_not_downstream_ready
    with_workspace do |root, markdown, _registry|
      receipt = write_conversion_receipt(
        root,
        markdown,
        state: "needs_page_review",
        downstream_ready: false
      )
      output = File.join(root, "intake-output")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::SourceIntake.generate!(
          markdown_path: markdown,
          source_root: root,
          output_dir: output,
          conversion_receipt_path: receipt
        )
      end

      assert_match(/not downstream-ready/, error.message)
      refute Dir.exist?(output)
    end
  end

  def test_intake_refuses_supplied_receipt_for_different_markdown_bytes
    with_workspace do |root, markdown, _registry|
      receipt = write_conversion_receipt(
        root,
        markdown,
        state: "ready",
        downstream_ready: true
      )
      File.open(markdown, "a") { |file| file.puts("changed after conversion") }
      output = File.join(root, "intake-output")

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::SourceIntake.generate!(
          markdown_path: markdown,
          source_root: root,
          output_dir: output,
          conversion_receipt_path: receipt
        )
      end

      assert_match(/does not match Markdown source/, error.message)
      refute Dir.exist?(output)
    end
  end

  def test_source_register_appends_explicit_single_file_mapping_and_preserves_existing_text
    with_workspace do |root, markdown, registry|
      before = File.read(registry)

      result = AfDataPipeline::SourceRegister.register!(
        source_root: root,
        source_id: "The Game Master's Book of Tests",
        markdown_path: markdown,
        page_marker_offset: "+9"
      )

      after = File.read(registry)
      assert after.start_with?(before)
      assert_includes after, "# preserve this registry comment"
      parsed = YAML.safe_load_file(registry)
      entry = parsed.fetch("sources").fetch("The Game Master's Book of Tests")
      assert_equal "TGMBo-Tests_LLM_Edition.md", entry.fetch("file")
      assert_equal "+9", entry.fetch("page_marker_offset")
      refute_equal result.registry_sha256_before, result.registry_sha256_after

      context = AfDataPipeline::BoundaryFreeze.registry_context(root, nil)
      normalized = AfDataPipeline::BoundaryFreeze.normalize_registry_entry(
        "The Game Master's Book of Tests",
        context.fetch("sources").fetch("The Game Master's Book of Tests")
      )
      assert_equal ["TGMBo-Tests_LLM_Edition.md"], normalized.fetch(:files)
    end
  end

  def test_source_register_supports_utf8_source_identity_and_filename
    with_workspace do |root, _markdown, registry|
      markdown = File.join(root, "Moria_Shadow_of_Khazad-dûm_LLM_Edition.md")
      File.write(markdown, "# Moria: Shadow of Khazad-dûm\n")
      before = File.binread(registry)

      result = AfDataPipeline::SourceRegister.register!(
        source_root: root,
        source_id: "Moria: Shadow of Khazad-dûm",
        markdown_path: markdown
      )

      after = File.binread(registry)
      assert after.start_with?(before)
      parsed = YAML.safe_load_file(registry)
      entry = parsed.fetch("sources").fetch("Moria: Shadow of Khazad-dûm")
      assert_equal "Moria_Shadow_of_Khazad-dûm_LLM_Edition.md", entry.fetch("file")
      refute_equal result.registry_sha256_before, result.registry_sha256_after

      context = AfDataPipeline::BoundaryFreeze.registry_context(root, nil)
      normalized = AfDataPipeline::BoundaryFreeze.normalize_registry_entry(
        "Moria: Shadow of Khazad-dûm",
        context.fetch("sources").fetch("Moria: Shadow of Khazad-dûm")
      )
      assert_equal ["Moria_Shadow_of_Khazad-dûm_LLM_Edition.md"], normalized.fetch(:files)
    end
  end

  def test_source_register_refuses_duplicate_identity_or_file_and_bad_offset_without_mutation
    with_workspace(register_fixture: true) do |root, markdown, registry|
      before = File.binread(registry)

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::SourceRegister.register!(
          source_root: root,
          source_id: "Fixture Source",
          markdown_path: markdown
        )
      end
      assert_match(/already contains source identity/, error.message)
      assert_equal before, File.binread(registry)

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::SourceRegister.register!(
          source_root: root,
          source_id: "Different Identity",
          markdown_path: markdown
        )
      end
      assert_match(/already registered/, error.message)
      assert_equal before, File.binread(registry)
    end

    with_workspace do |root, markdown, registry|
      before = File.binread(registry)
      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::SourceRegister.register!(
          source_root: root,
          source_id: "Bad Offset",
          markdown_path: markdown,
          page_marker_offset: "9"
        )
      end
      assert_match(/explicitly signed integer/, error.message)
      assert_equal before, File.binread(registry)
    end
  end

  def test_source_intake_and_register_clis
    with_workspace do |root, markdown, _registry|
      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::SourceIntake::CLI.run(
        [markdown, "--source-root", root, "--output", File.join(root, "intake")],
        out:,
        err:
      )
      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "Source intake: PASS"
      assert_includes out.string, "No canonical source identity inferred"
      assert_includes out.string, "Conversion receipt: WARNING"
      assert_includes out.string, "Next command:"
      assert_includes out.string, "bin/af-ingest-next"
      assert_includes out.string, File.join(root, "intake", "source_intake.json")

      out = StringIO.new
      err = StringIO.new
      next_amc = File.join(root, "5e_Adventure_Master_Catalog_9.9.xlsx")
      next_output = File.join(root, "fixture-boundary-dossier")
      status = AfDataPipeline::SourceRegister::CLI.run(
        [
          markdown,
          "--source-root", root,
          "--source-id", "Explicit Fixture Source",
          "--next-amc", next_amc,
          "--next-output", next_output
        ],
        out:,
        err:
      )
      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "Source registration: PASS"
      assert_includes out.string, "No source identity, segmentation, or offset inferred"
      assert_includes out.string, "Next command:"
      assert_includes out.string, "bin/af-boundary-dossier"
      assert_includes out.string, %q{--source-id Explicit\ Fixture\ Source}
      assert_includes out.string, "--amc #{next_amc}"
      assert_includes out.string, "--output #{next_output}"
    end
  end

  def test_source_register_cli_without_continuation_metadata_points_back_to_ingest_router
    with_workspace do |root, markdown, _registry|
      out = StringIO.new
      err = StringIO.new

      status = AfDataPipeline::SourceRegister::CLI.run(
        [
          markdown,
          "--source-root", root,
          "--source-id", "Standalone Fixture Source"
        ],
        out:,
        err:
      )

      assert_equal 0, status, err.string
      assert_empty err.string
      assert_includes out.string, "Source registration: PASS"
      assert_includes out.string, "return to the remaining command(s) emitted by bin/af-ingest-next"
      refute_includes out.string, "Next command:"
    end
  end

  def test_source_register_cli_requires_continuation_metadata_as_a_pair
    with_workspace do |root, markdown, registry|
      before = File.binread(registry)

      [
        ["--next-amc", File.join(root, "base.xlsx")],
        ["--next-output", File.join(root, "boundary-dossier")]
      ].each do |flag, value|
        out = StringIO.new
        err = StringIO.new

        status = AfDataPipeline::SourceRegister::CLI.run(
          [
            markdown,
            "--source-root", root,
            "--source-id", "Incomplete Continuation",
            flag, value
          ],
          out:,
          err:
        )

        assert_equal 2, status
        assert_empty out.string
        assert_includes err.string, "--next-amc PATH and --next-output DIR must be supplied together"
        assert_equal before, File.binread(registry)
      end
    end
  end

  def test_source_register_cli_preserves_registry_override_in_dossier_continuation
    with_workspace do |root, markdown, registry|
      out = StringIO.new
      err = StringIO.new
      next_amc = File.join(root, "5e_Adventure_Master_Catalog_9.9.xlsx")
      next_output = File.join(root, "boundary-dossier")

      status = AfDataPipeline::SourceRegister::CLI.run(
        [
          markdown,
          "--source-root", root,
          "--source-id", "Registry Override Fixture",
          "--registry", registry,
          "--next-amc", next_amc,
          "--next-output", next_output
        ],
        out:,
        err:
      )

      assert_equal 0, status, err.string
      assert_empty err.string
      assert_includes out.string, "Next command:"
      assert_includes out.string, "bin/af-boundary-dossier"
      assert_includes out.string, "--registry #{registry}"
      assert_includes out.string, "--amc #{next_amc}"
      assert_includes out.string, "--output #{next_output}"
    end
  end

  private

  def write_conversion_receipt(root, markdown, state:, downstream_ready:, page_exceptions: [])
    path = File.join(root, "conversion-receipt.json")
    File.write(
      path,
      JSON.pretty_generate(
        {
          "schema" => "pdf-to-llm-md/conversion-receipt/v0.1",
          "state" => state,
          "downstream_ready" => downstream_ready,
          "source" => {
            "path" => File.join(root, "book.pdf"),
            "sha256" => "0" * 64,
            "bytes" => 123
          },
          "output" => {
            "path" => markdown,
            "sha256" => Digest::SHA256.file(markdown).hexdigest,
            "bytes" => File.size(markdown)
          },
          "page_exceptions" => page_exceptions
        }
      ) + "\n"
    )
    path
  end

  def with_workspace(register_fixture: false)
    Dir.mktmpdir("source-intake") do |root|
      markdown = File.join(root, "TGMBo-Tests_LLM_Edition.md")
      File.write(
        markdown,
        <<~MD
          <!-- PDF Page 1 -->
          <!-- Printed Page 10 -->
          # The Game Master's Book of Tests
          Copyright © 2026 Fixture Publisher. All rights reserved.
          ISBN 978-0-00-000000-0
          ## The Glass Vault
          Adventure for Level 3 Characters
          <!-- PDF Page 2 -->
          <!-- Printed Page 11 -->
          ### Conclusion
          Success returns the key to the patron.
          ERROR conversion sentinel for test coverage
        MD
      )
      File.write(File.join(root, "Existing.md"), "# Existing\n")
      sources = {
        "Existing Source" => { "file" => "Existing.md" }
      }
      sources["Fixture Source"] = { "file" => "TGMBo-Tests_LLM_Edition.md" } if register_fixture
      registry = File.join(root, "source_registry.yml")
      File.write(
        registry,
        <<~YAML
          # preserve this registry comment
          schema_version: adventurefinder-source-registry/v0.1
          sources:
        YAML
      )
      File.open(registry, "a") do |file|
        sources.each do |source_id, entry|
          file.puts("  #{source_id.to_json}:")
          file.puts("    file: #{entry.fetch('file').to_json}")
        end
      end
      yield root, markdown, registry
    end
  end
end
