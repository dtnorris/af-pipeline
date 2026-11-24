# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "open3"
require "stringio"
require_relative "support/compatibility_amc_fixture"

# Exercise the public CLI and real catalog validators with mechanical workbooks.
class AfProjectStateCliGateTest < Minitest::Test
  include CompatibilityAmcFixture

  BIN = File.expand_path("../bin/af-project-state", __dir__)
  load BIN unless defined?(af_project_state_main)

  # Verify fresh executable refusals and the dispatcher without any Git fixture.
  def test_raw_catalog_head_promotion_refuses_every_artifact_before_writing
    with_catalog do |catalog|
      valid = write_workbook(catalog, "3.0")
      incompatible = write_workbook(catalog, "4.0")
      replace_zip_text(incompatible, "xl/worksheets/sheet1.xml", "Exploration Emphasis", "Exploration Missing")
      malformed = workbook_path(catalog, "5.0")
      File.binwrite(malformed, "invalid XLSX")
      manifest = File.join(catalog, "PROJECT_STATE.yml")
      [
        ["--artifact", valid, "--version", "3.0"],
        ["--artifact", incompatible, "--version", "4.0"],
        ["--artifact", malformed, "--version", "5.0"],
        ["--artifact", workbook_path(catalog, "2.0"), "--version", "2.0"],
        ["--artifact", workbook_path(catalog, "6.0"), "--version", "6.0"],
        []
      ].each do |options|
        argv = ["promote", "catalog_head", "--manifest", manifest, *options]
        before = file_snapshot(catalog)
        stdout, stderr, process = Open3.capture3(BIN, *argv, binmode: true)
        assert_promotion_refusal(stdout, stderr, process.exitstatus)
        assert_equal before, file_snapshot(catalog)
      end

      before = file_snapshot(catalog)
      assert_promotion_refusal(*dispatch(["promote", "catalog_head", "--manifest", manifest, "--artifact", valid, "--version", "3.0"]))
      assert_equal before, file_snapshot(catalog)
    end
  end

  # Verify explicit manual approval imports the reviewed bytes, with both independent roles preserved.
  def test_review_decline_eof_and_approval
    with_catalog do |catalog, candidate|
      manifest = File.join(catalog, "PROJECT_STATE.yml")
      before = file_snapshot(File.dirname(catalog))
      roles = YAML.safe_load_file(manifest)
      argv = ["adopt", candidate, "--manifest", manifest]
      with_git_observation(catalog) do
        ["n\n", ""].each do |answer|
          stdout, stderr, status = dispatch(argv, answer)
          assert_equal 0, status, stderr
          assert_review(stdout)
          assert_includes stdout, "No changes made."
          assert_equal before, file_snapshot(File.dirname(catalog))
        end

        stdout, stderr, status = dispatch(argv, "y\n")
        assert_equal 0, status, stderr
        assert_review(stdout)
        assert_includes stdout, "catalog_head promoted successfully."
      end

      destination = workbook_path(catalog, "3.0")
      assert_equal File.binread(candidate), File.binread(destination)
      after = file_snapshot(File.dirname(catalog))
      assert_equal before.except(manifest), after.except(manifest, destination)
      assert_equal before.fetch(manifest).last, after.fetch(manifest).last
      published = YAML.safe_load_file(manifest)
      assert_equal role_entry(destination, "3.0"), published.fetch("catalog_head")
      assert_equal roles.except("catalog_head"), published.except("catalog_head")
    end
  end

  # Verify real compatibility and destination conflicts refuse before prompting.
  def test_manual_adoption_refuses_incompatibility_and_destination_conflict
    with_catalog do |catalog, candidate|
      manifest = File.join(catalog, "PROJECT_STATE.yml")
      compatible = File.binread(candidate)
      replace_zip_text(candidate, "xl/worksheets/sheet1.xml", "Exploration Emphasis", "Exploration Missing")
      with_git_observation(catalog) do
        assert_manual_refusal(catalog, candidate, manifest, /compatibility failed:.*Exploration Emphasis/m)
        File.binwrite(candidate, compatible)
        File.binwrite(workbook_path(catalog, "3.0"), "occupied")
        assert_manual_refusal(catalog, candidate, manifest, /refusing to overwrite existing AMC artifact/)
      end
    end
  end

  # Change real inputs or external Git observations at the prompt and preserve the competing changes.
  def test_manual_adoption_refuses_changes_after_review
    {
      head: /repository HEAD changed after review/,
      remote: /repository (?:remote|origin) changed after review/,
      manifest: /manifest bytes changed after review/,
      role: /manifest bytes changed after review/,
      candidate: /AMC artifact changed after review/,
      destination: /refusing to overwrite existing AMC artifact/
    }.each do |change, diagnostic|
      with_catalog do |catalog, candidate|
        manifest = File.join(catalog, "PROJECT_STATE.yml")
        with_git_observation(catalog) do |git|
          at_confirmation = nil
          stdout, stderr, status = dispatch(["adopt", candidate, "--manifest", manifest], "y\n") do
            case change
            when :head then git[:head] = "b" * 40
            when :remote then git[:remote] = "fixture://different-catalog"
            when :manifest then File.open(manifest, "ab") { |output| output.write("# changed\n") }
            when :role
              AfDataPipeline::ProjectState.new(manifest_path: manifest).promote!(
                role: "production_dependency_floor", artifact_path: workbook_path(catalog, "2.0"), version: "2.0"
              )
            when :candidate then File.binwrite(candidate, File.binread(workbook_path(catalog, "2.0")))
            when :destination then File.binwrite(workbook_path(catalog, "3.0"), "occupied during review")
            end
            at_confirmation = file_snapshot(File.dirname(catalog))
          end
          assert_review(stdout)
          assert_equal 2, status, "#{change}: #{stderr}"
          assert_match diagnostic, stderr
          assert_equal at_confirmation, file_snapshot(File.dirname(catalog))
        end
      end
    end
  end

  # Verify role selection and version and integrity refusals through the public dispatcher.
  def test_independent_promotions_and_read_only_commands
    with_catalog do |catalog|
      manifest = File.join(catalog, "PROJECT_STATE.yml")
      state_class = AfDataPipeline::ProjectState
      before = file_snapshot(catalog)
      stdout, stderr, status = dispatch(["validate", "--manifest", manifest])
      assert_equal 0, status, stderr
      assert_includes stdout, "Project state: PASS"
      state_class::ROLES.each do |role|
        stdout, stderr, status = dispatch(["resolve", role, "--manifest", manifest])
        assert_equal 0, status, stderr
        assert_equal state_class.new(manifest_path: manifest).resolve(role).path, stdout.strip
      end
      assert_equal before, file_snapshot(catalog)

      future = write_workbook(catalog, "3.0")
      head = workbook_path(catalog, "2.0")
      baseline = workbook_path(catalog, "1.0")
      roles = state_class::ROLES - ["catalog_head"]
      roles.each do |role|
        previous = YAML.safe_load_file(manifest)
        before = file_snapshot(catalog)
        args = ["promote", role, "--manifest", manifest]
        stdout, stderr, status = dispatch([*args, "--artifact", head, "--version", "2.0"])
        assert_equal 0, status, stderr
        assert_includes stdout, "Promoted #{role}: 2.0"
        assert_includes stdout, "git add PROJECT_STATE.yml 5e_Adventure_Master_Catalog_2.0.xlsx"
        after = YAML.safe_load_file(manifest)
        assert_equal previous.merge(role => role_entry(head, "2.0")), after
        assert_equal before.except(manifest), file_snapshot(catalog).except(manifest)

        [[future, "3.0", /cannot be newer than catalog_head/],
         [baseline, "1.0", /cannot move backward/]].each do |path, version, diagnostic|
          before = file_snapshot(catalog)
          _stdout, stderr, status = dispatch([*args, "--artifact", path, "--version", version])
          assert_equal 2, status, stderr
          assert_match diagnostic, stderr
          assert_equal before, file_snapshot(catalog)
        end
      end

      bytes = File.binread(head)
      File.binwrite(head, bytes.reverse)
      roles.each do |role|
        before = file_snapshot(catalog)
        _stdout, stderr, status = dispatch(["promote", role, "--manifest", manifest, "--artifact", head, "--version", "2.0"])
        assert_equal 2, status, stderr
        assert_includes stderr, "SHA-256 mismatch"
        assert_equal before, file_snapshot(catalog)
      end
    end
  end

  private

  # Yield a scratch catalog and external mechanical candidate. Propagate fixture and test failures.
  def with_catalog
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      catalog = File.join(root, "catalog")
      Dir.mkdir(catalog)
      baseline = write_workbook(catalog, "1.0")
      head = write_workbook(catalog, "2.0")
      candidate = write_workbook(root, "3.0")
      manifest = File.join(catalog, "PROJECT_STATE.yml")
      state_class = AfDataPipeline::ProjectState
      File.binwrite(manifest, {
        "schema_version" => state_class::SCHEMA_VERSION,
        "catalog_head" => role_entry(head, "2.0"),
        "matcher_authorized_baseline" => role_entry(baseline, "1.0"),
        "production_dependency_floor" => role_entry(baseline, "1.0")
      }.to_yaml)
      File.chmod(0o640, manifest)
      yield catalog, candidate
    end
  end

  # Generate a mechanical workbook and return its canonical path. Propagate write errors.
  def write_workbook(root, version)
    row = compatible_row("ADV-0001", title: "Unit A", scores: {"Seriousness" => version.to_i})
    write_compatible_amc(workbook_path(root, version), rows: [row])
  end

  # Return the canonical workbook path for the fixture version.
  def workbook_path(root, version)
    File.join(root, "5e_Adventure_Master_Catalog_#{version}.xlsx")
  end

  # Measure the fixture workbook for a v0.2 role binding. Propagate file errors.
  def role_entry(path, version)
    {"version" => version, "filename" => File.basename(path),
     "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
  end

  # Return file bytes and modes throughout the scratch root, including temporary leftovers.
  def file_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      .to_h { |path| [path, [File.binread(path), File.stat(path).mode]] }
  end

  # Run the public dispatcher with controlled IO. Return stdout, stderr and exit status.
  # The optional block runs when confirmation reads stdin. Unexpected exceptions propagate.
  def dispatch(argv, answer = "", &before_answer)
    stdin, stdout, stderr = [StringIO.new(answer), StringIO.new, StringIO.new]
    stdin.define_singleton_method(:gets) { before_answer.call; super() } if before_answer
    previous = [$stdin, $stdout, $stderr]
    status = 0
    previous_root = ENV["AF_DATA_PIPELINE_DATA_ROOT"]
    manifest = argv[argv.index("--manifest") + 1] if argv.include?("--manifest")
    ENV["AF_DATA_PIPELINE_DATA_ROOT"] = File.realpath(File.dirname(manifest)) if manifest
    begin
      $stdin, $stdout, $stderr = stdin, stdout, stderr
      af_project_state_main(argv.dup)
    rescue SystemExit => error
      status = error.status
    ensure
      $stdin, $stdout, $stderr = previous
      ENV["AF_DATA_PIPELINE_DATA_ROOT"] = previous_root
    end
    [stdout.string, stderr.string, status]
  end

  # Double only the external read-only Git observations for the catalog directory.
  # Yield mutable HEAD and remote observations. Unexpected Git operations raise.
  def with_git_observation(catalog)
    identity = {head: "a" * 40, remote: "fixture://catalog"}
    manifest = File.join(catalog, "PROJECT_STATE.yml")
    original = File.binread(manifest)
    git = lambda do |*argv|
      environment = argv.shift if argv.first.is_a?(Hash)
      raise "unexpected external command: #{argv.inspect}" unless argv.take(3) == ["git", "-C", catalog]

      stdout = case argv.drop(3)
      when ["rev-parse", "--show-toplevel"] then "#{catalog}\n"
      when ["rev-parse", "HEAD"] then "#{identity.fetch(:head)}\n"
      when ["remote", "get-url", "origin"] then "#{identity.fetch(:remote)}\n"
      when ["status", "--porcelain=v1", "--", "PROJECT_STATE.yml"]
        raise "Git index refresh enabled" unless environment == {"GIT_OPTIONAL_LOCKS" => "0"}
        File.binread(manifest) == original ? "" : " M PROJECT_STATE.yml\n"
      when ["status", "--short"] then " M PROJECT_STATE.yml\n"
      when ["status", "--porcelain=v1", "--", File.basename(workbook_path(catalog, "3.0"))]
        File.file?(workbook_path(catalog, "3.0")) ? "?? #{File.basename(workbook_path(catalog, "3.0"))}\n" : ""
      else raise "unexpected Git observation: #{argv.inspect}"
      end
      [stdout, "", Struct.new(:success?).new(true)]
    end
    Open3.stub(:capture3, git) { yield identity }
  end

  # Assert the public refusal includes the reviewed command and no success output.
  def assert_promotion_refusal(stdout, stderr, status)
    assert_equal 2, status, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    assert_includes stderr, "catalog_head requires reviewed adoption"
    assert_includes stderr, "bin/af-project-state adopt"
    assert_empty stdout
  end

  # Assert the real compatibility report, reviewed field delta and explicit prompt.
  def assert_review(stdout)
    assert_includes stdout, "Cross-consumer compatibility: PASS"
    assert_includes stdout, "Adventure Catalog review:"
    assert_includes stdout, "Seriousness: 2 -> 3"
    assert_includes stdout, "Import this exact workbook and promote it to catalog_head? [y/N]"
  end

  # Assert a manual adoption refusal leaves the exact fixture bytes and modes intact.
  def assert_manual_refusal(catalog, candidate, manifest, diagnostic)
    before = file_snapshot(File.dirname(catalog))
    stdout, stderr, status = dispatch(["adopt", candidate, "--manifest", manifest], "y\n")
    assert_equal 2, status, stderr
    assert_match diagnostic, stderr
    refute_includes stdout, "Import this exact workbook"
    assert_equal before, file_snapshot(File.dirname(catalog))
  end
end
