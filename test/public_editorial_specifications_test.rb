# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/staged_scoring_fixture"
require_relative "../lib/af_data_pipeline/ingest_next"
require "stringio"
require "open3"
require "shellwords"

# Real public definitions and mechanical owner fixtures exercise the approval
# seam. Supply the pinned public checkout with AF_PUBLIC_SPEC_ROOT when it is
# not a sibling; absent input is a failure, never a synthetic definition or skip.
class PublicEditorialSpecificationsTest < Minitest::Test
  include StagedScoringFixture
  Editorial = AfDataPipeline::BoundaryEditorial
  Specifications = AfDataPipeline::EditorialSpecifications

  # Verify explicit selection, emitted attachments, definition refusals,
  # restoration, exact approval/freeze replay and rejection of an old approval.
  def test_public_selection_is_bound_through_real_approval_and_freeze
    Dir.mktmpdir("public-editorial") do |root|
      root = File.realpath(root)
      historical = editorial_fixture(root)
      public_root = copy_public_definitions(root)
      File.write(File.join(public_root, "Adventure_Boundary_Detection_Specification_ABDS_v99.md"), "decoy\n")
      bundle = File.join(root, "forward")
      out = StringIO.new
      err = StringIO.new
      assert_equal 0, Editorial::CLI.run(
        ["init", "--dossier", historical.fetch(:dossier_path), "--output", bundle, "--spec-root", public_root], out:, err:
      ), err.string
      context = JSON.parse(File.binread(File.join(bundle, Editorial::CONTEXT_FILENAME)))
      binding = context.fetch("public_specifications")
      assert_equal Specifications::REVISION, binding.fetch("revision")
      assert_equal %w[2.0 1.4], binding.fetch("files").map { |document| document.fetch("version") }
      assert_includes out.string, "Draft"
      assert_includes File.read(File.join(bundle, Editorial::REVIEW_FILENAME)), Specifications::INVENTORY_SHA256
      refute_includes out.string, "ABDS_v99"
      router = AfDataPipeline::IngestNext.new(source_root: historical.fetch(:source_root), catalog_root: root)
      assert_equal "NEEDS_FRONTIER_EDITORIAL_REVIEW", router.inspect(artifact_path: bundle).state
      FileUtils.cp(File.join(historical.fetch(:bundle_dir), Editorial::DECISIONS_FILENAME), bundle)
      forward = historical.merge(bundle_dir: bundle)
      assert_raises(AfDataPipeline::ValidationError) { Editorial.validate_approval!(**forward) }
      approval = File.join(root, "forward-approval.json")
      forward[:approval_path] = approval
      Editorial.approve!(**forward.except(:approval_path), approved_by: "Synthetic reviewer", output_path: approval)
      frozen = File.join(root, "forward-frozen.yml")
      draft = File.join(root, "forward-draft.yml")
      first = Editorial.freeze_approved!(**forward, freeze_path: draft, output_path: frozen)
      assert_equal first.sha256, Editorial.freeze_approved!(**forward, freeze_path: draft, output_path: frozen).sha256

      ["documents.json", *Specifications::DOCUMENTS.map { |document| document.fetch("filename") }].each do |filename|
        path = File.join(public_root, filename)
        bytes = File.binread(path)
        File.unlink(path)
        assert_raises(AfDataPipeline::ValidationError) { Editorial.validate_approved_freeze!(**forward, freeze_path: frozen) }
        assert_raises(AfDataPipeline::ValidationError) { router.inspect(artifact_path: bundle) }
        File.binwrite(path, bytes + "changed version/body\n")
        assert_raises(AfDataPipeline::ValidationError) { Editorial.validate_approved_freeze!(**forward, freeze_path: frozen) }
        File.binwrite(path, bytes)
        assert_equal first.sha256, Editorial.validate_approved_freeze!(**forward, freeze_path: frozen).sha256
      end
      changed = Marshal.load(Marshal.dump(binding))
      changed["revision"] = "0" * 40
      assert_raises(AfDataPipeline::ValidationError) { Specifications.validate!(changed) }
      abds = File.join(public_root, Specifications::DOCUMENTS.last.fetch("filename"))
      File.rename(abds, "#{abds}.original")
      File.symlink("#{abds}.original", abds)
      assert_raises(AfDataPipeline::ValidationError) { Specifications.bind!(public_root) }
      File.unlink(abds)
      File.rename("#{abds}.original", abds)
      rebound = Editorial.rebind!(bundle_dir: bundle, dossier_path: forward.fetch(:dossier_path),
                                 output_dir: File.join(root, "rebound"), reason: "same input recovery")
      assert_equal binding, rebound.context.fetch("public_specifications")
    end
  end

  # Exercise the executable dossier route, its emitted initializer and real
  # automatic child. No selection or invalid bytes may create a forward bundle;
  # restoration must allow the same dossier to initialize with exact identities.
  def test_dossier_route_selects_before_emitted_and_automatic_initialization
    Dir.mktmpdir("public-dossier-route") do |root|
      root = File.realpath(root)
      dossier = File.join(root, "boundary_dossier.json")
      File.write(dossier, JSON.generate(
        "schema_version" => "af-boundary-dossier/v0.2",
        "source" => {"canonical_source_id" => "Synthetic Source", "registry_filename" => "source_registry.yml",
                     "registry_sha256" => "a" * 64,
                     "markdown_files" => [{"filename" => "synthetic.md", "sha256" => "b" * 64}]},
        "base_amc" => {"filename" => "synthetic.xlsx", "sha256" => "c" * 64}
      ))
      public_root = copy_public_definitions(root)
      data_root = File.join(root, "data")
      FileUtils.mkdir_p(data_root)
      environment = {"AF_DATA_PIPELINE_DATA_ROOT" => data_root}
      argv = [File.expand_path("../bin/af-ingest-next", __dir__), dossier,
              "--source-root", root, "--catalog-root", root]
      bundle = File.join(data_root, "audits/pre-scoring/synthetic-source-boundary-editorial")
      stdout, stderr, status = Open3.capture3(environment, *argv, "--auto")
      assert status.success?, stderr
      assert_includes stdout, "NEEDS_EDITORIAL_SPECIFICATIONS"
      assert_includes stdout, "--spec-root ABSOLUTE_PUBLIC_DIR"
      refute_path_exists bundle

      selected = [*argv, "--spec-root", public_root]
      stdout, stderr, status = Open3.capture3(environment, *selected, "--json")
      assert status.success?, stderr
      route = JSON.parse(stdout)
      assert_equal "READY_FOR_EDITORIAL_HANDOFF", route.fetch("state")
      initializer = route.fetch("commands").fetch(0)
      assert_includes Shellwords.split(initializer.fetch("command")), public_root
      stdout, stderr, status = Open3.capture3(environment, *Shellwords.split(initializer.fetch("command")),
                                             chdir: initializer.fetch("cwd"))
      assert status.success?, stderr
      expected = Specifications.bind!(public_root)
      assert_equal expected, JSON.parse(File.read(File.join(bundle, Editorial::CONTEXT_FILENAME))).fetch("public_specifications")
      FileUtils.remove_entry(bundle)

      ["documents.json", *Specifications::DOCUMENTS.map { |document| document.fetch("filename") }].each do |filename|
        path = File.join(public_root, filename)
        bytes = File.binread(path)
        File.unlink(path)
        [nil, bytes + "changed\n"].each do |replacement|
          File.binwrite(path, replacement) if replacement
          stdout, stderr, status = Open3.capture3(environment, *selected, "--auto")
          assert_equal 2, status.exitstatus, stdout
          assert_includes stderr, "missing or changed public specification input"
          refute_path_exists bundle
        end
        File.binwrite(path, bytes)
      end
      stdout, stderr, status = Open3.capture3(environment, *selected, "--auto")
      assert status.success?, stderr
      assert_includes stdout, "NEEDS_FRONTIER_EDITORIAL_REVIEW"
      context = JSON.parse(File.read(File.join(bundle, Editorial::CONTEXT_FILENAME)))
      assert_equal expected, context.fetch("public_specifications")
      review = File.read(File.join(bundle, Editorial::REVIEW_FILENAME))
      expected.fetch("files").each do |document|
        assert_includes review, document.fetch("sha256")
        assert_includes review, document.fetch("status")
      end
    end
  end

  # Existing approval and frozen output remain byte-identical without any public
  # input, and a missing explicit forward root refuses before bundle publication.
  def test_historical_replay_needs_no_public_definitions
    Dir.mktmpdir("historical-editorial") do |root|
      historical = editorial_fixture(root)
      approval_bytes = File.binread(historical.fetch(:approval_path))
      frozen = File.join(root, "frozen.yml")
      frozen_bytes = File.binread(frozen)
      result = Editorial.freeze_approved!(**historical, freeze_path: File.join(root, "draft.yml"), output_path: frozen)
      assert result.reused
      assert_equal approval_bytes, File.binread(historical.fetch(:approval_path))
      assert_equal frozen_bytes, File.binread(frozen)
      refute Editorial.validate!(bundle_dir: historical.fetch(:bundle_dir)).context.key?("public_specifications")
      output = File.join(root, "missing-forward")
      assert_raises(AfDataPipeline::ValidationError) do
        Editorial.init!(dossier_path: historical.fetch(:dossier_path), output_dir: output, spec_root: File.join(root, "missing"))
      end
      refute_path_exists output
    end
  end

  # Reuse the owner fixture's real historical approval inputs. Returns only
  # editorial keyword arguments; fixture/validation errors propagate.
  def editorial_fixture(root)
    fixture = build_authority_fixture(root, cache_namespace: :public_editorial)
    fixture.slice(:bundle_dir, :dossier_path, :source_root, :approval_path).merge(
      amc_path: File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx")
    )
  end

  # Copy only the pinned public inventory and required documents into scratch.
  # Returns its path; unavailable or incompatible real inputs raise ValidationError.
  def copy_public_definitions(root)
    source = ENV.fetch("AF_PUBLIC_SPEC_ROOT", File.expand_path("../../af-specification-md", __dir__))
    Specifications.bind!(source)
    destination = File.join(root, "public")
    FileUtils.mkdir_p(destination)
    ["documents.json", *Specifications::DOCUMENTS.map { |document| document.fetch("filename") }].each do |filename|
      FileUtils.cp(File.join(source, filename), destination)
    end
    destination
  end
end
