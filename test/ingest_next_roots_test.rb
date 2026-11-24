# frozen_string_literal: true

require_relative "test_helper"
require "af_data_pipeline/ingest_next"
require "shellwords"
require "minitest/mock"
require "stringio"

class IngestNextRootsTest < Minitest::Test
  def test_explicit_production_roots_survive_generated_continuation
    router = AfDataPipeline::IngestNext.new(
      afw_root: "/tmp/component space/af-workloads-production",
      scorer_root: "/tmp/component space/af-cli-scoring-utility-production",
      adventure_finder_root: "/tmp/front door/adventure-finder-production"
    )
    command = router.send(:command, AfDataPipeline::IngestNext::REPO_ROOT,
                          File.join(AfDataPipeline::IngestNext::REPO_ROOT, "bin/af-ingest-next"), "receipt.json")
    argv = Shellwords.split(command.fetch("command"))
    assert_equal router.afw_root, argv.fetch(argv.index("--afw-root") + 1)
    assert_equal router.scorer_root, argv.fetch(argv.index("--scorer-repo") + 1)
    assert_equal router.adventure_finder_root, argv.fetch(argv.index("--adventure-finder-root") + 1)
    front = router.send(:catalog_front_door_command, {"source" => {"path" => "/tmp/book source.pdf"}})
    assert_equal router.adventure_finder_root, front.fetch("cwd")
    assert_includes Shellwords.split(front.fetch("command")), "/tmp/front door/adventure-finder-production/bin/af-catalog"
  end

  def test_cli_forwards_explicit_roots_to_router
    captured = nil
    constructor = lambda do |**options|
      captured = options
      raise AfDataPipeline::IngestNext::Error, "inspection stopped after parsing"
    end
    AfDataPipeline::IngestNext.stub(:new, constructor) do
      status = AfDataPipeline::IngestNext::CLI.run(
        ["receipt.json", "--afw-root", "/tmp/af-workloads-production",
         "--scorer-repo", "/tmp/af-cli-scoring-utility-production",
         "--adventure-finder-root", "/tmp/adventure-finder-production"],
        out: StringIO.new, err: StringIO.new
      )
      assert_equal 2, status
    end
    assert_equal "/tmp/af-workloads-production", captured.fetch(:afw_root)
    assert_equal "/tmp/af-cli-scoring-utility-production", captured.fetch(:scorer_root)
    assert_equal "/tmp/adventure-finder-production", captured.fetch(:adventure_finder_root)
  end

  def test_legacy_root_alias_is_explicit_and_conflicts_fail_closed
    router = AfDataPipeline::IngestNext.new(afio_root: "/tmp/retained-checkout")
    assert_equal "/tmp/retained-checkout", router.afw_root
    assert_equal router.afw_root, router.afio_root
    assert_raises(AfDataPipeline::IngestNext::Error) do
      AfDataPipeline::IngestNext.new(afio_root: "/tmp/old", afw_root: "/tmp/new")
    end
  end

  def test_default_active_afw_does_not_select_hold
    router = AfDataPipeline::IngestNext.new
    assert_equal AfDataPipeline::IngestNext::DEFAULT_AFW_ROOT, router.afw_root
    refute_includes router.afw_root, "af-inference-orchestrator"
  end
end
