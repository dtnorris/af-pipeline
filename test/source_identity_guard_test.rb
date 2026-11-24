# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/af_data_pipeline/ingest_next"

class SourceIdentityGuardTest < Minitest::Test
  def test_router_explains_source_identity_is_human_readable_not_a_path
    router = AfDataPipeline::IngestNext.allocate
    artifact = {
      path: "/tmp/source-intake.json",
      data: {
        "source_root" => "/tmp/source-root",
        "markdown" => {"filename" => "Fixture_LLM_Edition.md"},
        "registry" => {
          "registration_status" => "unregistered",
          "source_ids_referencing_file" => []
        },
        "conversion_provenance" => {
          "conversion_acceptance_verified" => true
        }
      }
    }

    result = router.send(:source_intake_result, artifact, source_id: nil)

    assert_equal "NEEDS_SOURCE_IDENTITY", result.state
    assert result.human_review.any? { |line| line.include?("human-readable") }
    assert result.human_review.any? { |line| line.include?("filesystem path") }
  end

  def test_router_rejects_markdown_path_as_source_identity
    router = AfDataPipeline::IngestNext.allocate
    artifact = {
      data: {
        "source_root" => "/tmp/source-root",
        "markdown" => {"filename" => "Fixture_LLM_Edition.md"},
        "registry" => {
          "registration_status" => "unregistered",
          "source_ids_referencing_file" => []
        },
        "conversion_provenance" => {
          "conversion_acceptance_verified" => true
        }
      }
    }

    error = assert_raises(AfDataPipeline::IngestNext::Error) do
      router.send(
        :source_intake_result,
        artifact,
        source_id: "/Users/example/Fixture_LLM_Edition.md"
      )
    end

    assert_match(/human-readable canonical source identity/, error.message)
    assert_match(/not a filesystem path or source filename/, error.message)
  end

  def test_source_register_rejects_path_identity_without_mutating_registry
    Dir.mktmpdir("source-identity-register") do |root|
      markdown = File.join(root, "Fixture_LLM_Edition.md")
      registry = File.join(root, "source_registry.yml")
      File.write(markdown, "# Fixture\n")
      File.write(
        registry,
        <<~YAML
          schema_version: adventurefinder-source-registry/v0.1
          sources: {}
        YAML
      )
      before = File.binread(registry)

      error = assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::SourceRegister.register!(
          source_root: root,
          source_id: markdown,
          markdown_path: markdown
        )
      end

      assert_match(/human-readable canonical source identity/, error.message)
      assert_equal before, File.binread(registry)
    end
  end

  def test_human_readable_publication_title_remains_valid
    title = "Faster Purple Worm! Everybody Dies! Vol. 1"

    assert_equal(
      title,
      AfDataPipeline::SourceIdentity.validate!(
        title,
        error_class: AfDataPipeline::ValidationError
      )
    )
  end
end
