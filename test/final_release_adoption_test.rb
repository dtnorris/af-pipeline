# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/compatibility_amc_fixture"
require "open3"
require "stringio"

class FinalReleaseAdoptionTest < Minitest::Test
  include CompatibilityAmcFixture

  TEST_GIT_ENV = {
    "GIT_AUTHOR_NAME" => "Synthetic fixture",
    "GIT_AUTHOR_EMAIL" => "fixture@example.invalid",
    "GIT_COMMITTER_NAME" => "Synthetic fixture",
    "GIT_COMMITTER_EMAIL" => "fixture@example.invalid"
  }.freeze

  def test_exact_approval_rejects_staleness_survives_interruption_and_replays
    with_handoff do |fixture|
      request = fixture.prepare_request
      decision = fixture.decide(request, "APPROVE")
      before = File.binread(fixture.manifest)
      candidate_bytes = File.binread(fixture.candidate)
      package_bytes = File.binread(fixture.package_path)
      request_bytes = File.binread(request)

      missing = fixture.adopt(request, File.join(fixture.root, "missing-decision.json"))
      assert_equal "NO_APPROVAL", missing.status
      assert_nil missing.path
      assert_equal before, File.binread(fixture.manifest)

      changed_request = JSON.parse(request_bytes)
      changed_request["candidate"]["selection"] = "ig17f_derived"
      changed_request["request_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(changed_request.except("request_id"))
      File.write(request, AfDataPipeline::StagedScoringAuthority.document_bytes(changed_request))
      error = assert_raises(AfDataPipeline::ValidationError) { fixture.adopt(request, decision) }
      assert_includes error.message, "decision does not bind"
      File.binwrite(request, request_bytes)

      File.open(fixture.candidate, "ab") { |file| file.write("changed") }
      assert_raises(AfDataPipeline::Error) { fixture.adopt(request, decision) }
      File.binwrite(fixture.candidate, candidate_bytes)

      File.open(fixture.package_path, "ab") { |file| file.write("changed") }
      assert_raises(AfDataPipeline::Error) { fixture.adopt(request, decision) }
      File.binwrite(fixture.package_path, package_bytes)

      state_document = YAML.safe_load_file(fixture.manifest)
      state_document["matcher_authorized_baseline"] = state_document.fetch("catalog_head")
      File.write(fixture.manifest, YAML.dump(state_document))
      assert_raises(AfDataPipeline::Error) { fixture.adopt(request, decision) }
      File.binwrite(fixture.manifest, before)

      snapshot = AfDataPipeline::CatalogAdoption.prepare!(
        manifest_path: fixture.manifest,
        candidate_path: fixture.candidate,
        version: fixture.version
      )
      error = assert_raises(Interrupt) do
        service = AfDataPipeline::CatalogAdoption.new(manifest_path: fixture.manifest)
        service.define_singleton_method(:before_promotion!) { |_fresh| raise Interrupt, "synthetic stop" }
        service.adopt!(snapshot:)
      end
      assert_equal "synthetic stop", error.message
      assert_equal before, File.binread(fixture.manifest)
      refute_path_exists fixture.destination

      first = fixture.adopt(request, decision)
      assert_equal "PROMOTED", first.status
      assert_equal "PROMOTED", first.document.fetch("status")
      state = AfDataPipeline::ProjectState.new(manifest_path: fixture.manifest)
      assert_equal fixture.candidate_binding, fixture.role_binding(state.resolve("catalog_head"))
      assert_equal fixture.original_roles.except("catalog_head"), fixture.roles.except("catalog_head")
      assert_equal fixture.head, fixture.git("rev-parse", "HEAD").strip
      assert_equal fixture.package.fetch("package_id"), first.document.fetch("package_id")
      assert_equal first.document.fetch("result_id"),
                   AfDataPipeline::StandingBulkScorePolicy.digest(first.document.except("result_id"))

      manifest_after = File.binread(fixture.manifest)
      workbook_after = File.binread(fixture.destination)
      original_result = File.binread(first.path)
      assert_equal first.document, JSON.parse(original_result)
      replay = fixture.adopt(request, decision)
      assert_equal "ALREADY_PROMOTED", replay.status
      assert_equal "ALREADY_PROMOTED", replay.catalog_result.status
      assert_equal "ALREADY_PROMOTED", replay.document.fetch("status")
      assert_equal false, replay.document.fetch("durable")
      assert_equal first.path, replay.path
      assert_equal({"path" => first.path, "status" => "PROMOTED",
                    "result_id" => first.document.fetch("result_id"),
                    **AfDataPipeline::StandingBulkScorePolicy.file_binding(first.path)},
                   replay.document.fetch("durable_result"))
      assert_equal AfDataPipeline::StandingBulkScorePolicy.digest(replay.document.except("result_id")),
                   replay.document.fetch("result_id")
      refute_equal first.document.fetch("result_id"), replay.document.fetch("result_id")

      exit_code, cli_result, cli_error = fixture.adopt_cli(request, decision)
      assert_equal 0, exit_code, cli_error
      assert_equal replay.document, cli_result
      assert_equal original_result, File.binread(first.path)
      assert_equal manifest_after, File.binread(fixture.manifest)
      assert_equal workbook_after, File.binread(fixture.destination)
      assert_equal fixture.original_roles.except("catalog_head"), fixture.roles.except("catalog_head")
      assert_equal fixture.head, fixture.git("rev-parse", "HEAD").strip

      File.unlink(first.path)
      second = fixture.adopt(request, decision)
      assert_equal "ALREADY_PROMOTED", second.status
      assert_equal "ALREADY_PROMOTED", second.document.fetch("status")
      assert_equal AfDataPipeline::StandingBulkScorePolicy.digest(second.document.except("result_id")),
                   second.document.fetch("result_id")
      assert_equal manifest_after, File.binread(fixture.manifest)
      assert_equal workbook_after, File.binread(fixture.destination)
      result_after = File.binread(second.path)
      third = fixture.adopt(request, decision)
      assert_equal "ALREADY_PROMOTED", third.status
      assert_equal second.document, third.document
      assert_equal result_after, File.binread(third.path)
    end
  end

  def test_decline_and_changed_repository_head_never_mutate_catalog
    with_handoff do |fixture|
      request = fixture.prepare_request
      before = File.binread(fixture.manifest)
      declined = fixture.decide(request, "DECLINE")
      result = fixture.adopt(request, declined)
      assert_equal "DECLINED", result.status
      assert_equal before, File.binread(fixture.manifest)
      refute_path_exists fixture.destination

      approved = fixture.decide(request, "APPROVE")
      File.write(File.join(fixture.catalog, "unrelated"), "change\n")
      fixture.git("add", "unrelated")
      fixture.git("commit", "-qm", "concurrent")
      assert_raises(AfDataPipeline::Error) { fixture.adopt(request, approved) }
      assert_equal before, File.binread(fixture.manifest)
      refute_path_exists fixture.destination
      assert_equal fixture.original_roles, fixture.roles
    end
  end

  private

  def with_handoff
    fixture = HandoffFixture.new(self)
    fixture.with_stubbed_validator { yield fixture }
  ensure
    fixture&.close
  end

  class HandoffFixture
    attr_reader :root, :catalog, :manifest, :candidate, :package_path, :package, :version, :head

    def initialize(test)
      @test = test
      @root = Dir.mktmpdir("final-release-adoption-")
      @catalog = File.join(root, "catalog")
      FileUtils.mkdir_p(catalog)
      @manifest = File.join(catalog, "PROJECT_STATE.yml")
      base = File.join(catalog, "5e_Adventure_Master_Catalog_1.0.xlsx")
      @test.write_compatible_amc(base, rows: [@test.compatible_row("ADV-0001", title: "Existing", scores: {"Seriousness" => 3})])
      baseline = File.join(catalog, "5e_Adventure_Master_Catalog_0.5.xlsx")
      FileUtils.cp(base, baseline)
      File.write(manifest, YAML.dump(
        "schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
        "catalog_head" => role_for(base, "1.0"),
        "matcher_authorized_baseline" => role_for(baseline, "0.5"),
        "production_dependency_floor" => role_for(baseline, "0.5")
      ))
      git("init", "-q")
      git("remote", "add", "origin", "fixture://catalog")
      git("add", ".")
      git("commit", "-qm", "synthetic catalog")
      @head = git("rev-parse", "HEAD").strip
      @candidate = File.join(root, "candidate.xlsx")
      @version = "2.0"
      @test.write_compatible_amc(candidate, rows: [
        @test.compatible_row("ADV-0001", title: "Existing", scores: {"Seriousness" => 4}),
        @test.compatible_row("ADV-0002", title: "Added", scores: {})
      ])
      @inputs = File.join(root, "package-inputs.json")
      File.write(@inputs, "{\"schema_version\":\"synthetic-inputs/v0.1\"}\n")
      evidence = File.join(root, "release-accounting.json")
      File.write(evidence, "{\"synthetic\":true}\n")
      @original_roles = roles
      @package_path = File.join(root, "package.json")
      @package = build_package(base, evidence)
      File.write(package_path, AfDataPipeline::StagedScoringAuthority.document_bytes(package))
    end

    def close
      FileUtils.remove_entry(root) if root && File.directory?(root)
    end

    def with_stubbed_validator
      result = AfDataPipeline::FinalReleasePackage::Result.new(package:, path: package_path, reused: true)
      AfDataPipeline::FinalReleasePackage.stub(:validate!, result) { yield }
    end

    def prepare_request
      path = File.join(root, "request.json")
      AfDataPipeline::FinalReleaseAdoption.prepare!(inputs_path: @inputs, package_path:, output_path: path)
      path
    end

    def decide(request, decision)
      path = File.join(root, "decision-#{decision.downcase}.json")
      AfDataPipeline::FinalReleaseAdoption.decide!(inputs_path: @inputs, package_path:, request_path: request,
                                                   output_path: path, decision:, decided_by: "Synthetic owner")
      path
    end

    def adopt(request, decision)
      AfDataPipeline::FinalReleaseAdoption.adopt!(inputs_path: @inputs, package_path:, request_path: request,
                                                  approval_path: decision, result_path: File.join(root, "result.json"))
    end

    def adopt_cli(request, decision)
      out = StringIO.new
      err = StringIO.new
      code = AfDataPipeline::FinalReleaseAdoption.run(
        ["adopt", "--inputs", @inputs, "--package", package_path, "--request", request,
         "--approval", decision, "--result", File.join(root, "result.json")], out:, err:
      )
      [code, JSON.parse(out.string), err.string]
    end

    def destination
      File.join(catalog, "5e_Adventure_Master_Catalog_#{version}.xlsx")
    end

    def original_roles
      @original_roles
    end

    def roles
      state = AfDataPipeline::ProjectState.new(manifest_path: manifest)
      state.validate!
      AfDataPipeline::ProjectState::ROLES.to_h { |role| [role, role_binding(state.resolve(role))] }
    end

    def candidate_binding
      {"version" => version, "filename" => File.basename(destination),
       **AfDataPipeline::StandingBulkScorePolicy.file_binding(candidate)}
    end

    def role_binding(role)
      {"version" => role.version, "filename" => role.filename, "sha256" => role.sha256, "bytes" => role.bytes}
    end

    def git(*args)
      stdout, stderr, status = Open3.capture3(TEST_GIT_ENV, "git", "-C", catalog, *args)
      raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?
      stdout
    end

    private

    def build_package(base, evidence)
      roles = self.roles
      nodes = {
        "current_project_state" => {"path" => manifest, **AfDataPipeline::StandingBulkScorePolicy.file_binding(manifest)},
        "current_role:catalog_head" => {"path" => base, **AfDataPipeline::StandingBulkScorePolicy.file_binding(base)},
        "release_manifest" => {"path" => evidence, **AfDataPipeline::StandingBulkScorePolicy.file_binding(evidence)}
      }
      document = {
        "schema_version" => AfDataPipeline::FinalReleasePackage::SCHEMA,
        "candidate" => {"selection" => "original_ig17", "selected" => {"path" => candidate,
                         **AfDataPipeline::StandingBulkScorePolicy.file_binding(candidate)}},
        "readiness" => {"ready" => true, "approval_authorized" => false, "catalog_adoption_authorized" => false},
        "transition" => {"catalog_repository" => {"remote_url" => "fixture://catalog", "head" => head},
                         "current_roles" => roles, "proposed_catalog_head" => candidate_binding,
                         "independent_roles_preserved" => true},
        "provenance" => {"nodes" => nodes, "edges" => []}
      }
      document["package_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(document)
      document
    end

    def role_for(path, version)
      {"version" => version, "filename" => File.basename(path),
       **AfDataPipeline::StandingBulkScorePolicy.file_binding(path)}
    end
  end
end
