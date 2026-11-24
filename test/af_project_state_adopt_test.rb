# frozen_string_literal: true
require_relative "test_helper"
require_relative "support/amc_fixture"
require_relative "support/compatibility_amc_fixture"
require "open3"
require "rbconfig"
require "stringio"

class AfProjectStateAdoptTest < Minitest::Test
  include AmcFixture
  include CompatibilityAmcFixture

  BIN = File.expand_path("../bin/af-project-state", __dir__)
  load BIN
  TEST_GIT_ENV = {
    "GIT_AUTHOR_NAME" => "Test User",
    "GIT_AUTHOR_EMAIL" => "test@example.invalid",
    "GIT_COMMITTER_NAME" => "Test User",
    "GIT_COMMITTER_EMAIL" => "test@example.invalid"
  }.freeze
  ADOPTION_DIMENSIONS = [
    "Page Count",
    "Source Book",
    "Book Publisher",
    "Start Page",
    "End Page",
    "Level Start",
    "Level End",
    "Seriousness",
    "Scored"
  ].freeze

  def test_adopt_imports_external_candidate_reviews_delta_and_promotes_only_catalog_head
    with_catalog_repo do |dir, manifest|
      Dir.mktmpdir do |external_dir|
        candidate = File.join(external_dir, "downloaded-candidate.xlsx")
        write_review_workbook(
          candidate,
          [
            catalog_row("ADV-0001", title: "Renamed Adventure", seriousness: 4),
            catalog_row("ADV-0002", title: "New Adventure", seriousness: nil)
          ]
        )
        head_before = git(dir, "rev-parse", "HEAD").strip
        resume_artifact = File.join(external_dir, "apply-report.json")
        File.write(resume_artifact, "{}\n")

        stdout, stderr, status = run_adopt(
          candidate,
          manifest,
          "y\n",
          version: "3.0",
          resume_artifact:
        )

        assert status.zero?, stderr
        imported = File.join(dir, "5e_Adventure_Master_Catalog_3.0.xlsx")
        assert File.file?(imported)
        assert_equal Digest::SHA256.file(candidate).hexdigest, Digest::SHA256.file(imported).hexdigest

        state = AfDataPipeline::ProjectState.new(manifest_path: manifest)
        assert_equal "3.0", state.resolve("catalog_head").version
        assert_equal "1.0", state.resolve("matcher_authorized_baseline").version
        assert_equal "1.0", state.resolve("production_dependency_floor").version

        assert_equal head_before, git(dir, "rev-parse", "HEAD").strip
        assert_includes stdout, "canonical IDs: 1 -> 2"
        assert_includes stdout, "+ ADV-0002 \"New Adventure\""
        assert_includes stdout, "~ ADV-0001 \"Renamed Adventure\""
        assert_includes stdout, "Seriousness: 3 -> 4"
        assert_includes stdout, "Cross-consumer compatibility: PASS"
        assert_includes stdout, "No commit or push was performed."
        assert_includes stdout, "catalog_head promoted successfully."
        assert_includes stdout, "Repository persistence required:"
        assert_includes stdout, "git add PROJECT_STATE.yml 5e_Adventure_Master_Catalog_3.0.xlsx"
        assert_includes stdout, "git commit -m Update\\ catalog_head\\ to\\ AMC\\ 3.0"
        assert_includes stdout, "# push remains an explicit operator choice"
        assert_includes stdout, "After that commit is durable, resume ingestion with:"
        assert_includes stdout, "bin/af-ingest-next"
        assert_includes stdout, resume_artifact
        assert_includes git(dir, "status", "--short"), "PROJECT_STATE.yml"
        assert_includes git(dir, "status", "--short"), "5e_Adventure_Master_Catalog_3.0.xlsx"
      end
    end
  end

  def test_declining_external_adoption_changes_nothing_and_copies_nothing
    with_catalog_repo do |dir, manifest|
      Dir.mktmpdir do |external_dir|
        candidate = File.join(external_dir, "5e_Adventure_Master_Catalog_3.0.xlsx")
        write_review_workbook(candidate, [catalog_row("ADV-0001", title: "Renamed Adventure", seriousness: 4)])
        before = File.read(manifest)

        compatibility = {
          "canonical_adventure_count" => 1,
          "added_adventure_ids" => [],
          "mirror_mode" => "mirrored"
        }
        stdout = stderr = status = nil
        AfDataPipeline::AmcCompatibilityCheck.stub(:validate!, compatibility) do
          stdout, stderr, status = run_adopt(candidate, manifest, "n\n")
        end

        assert status.zero?, stderr
        assert_equal before, File.read(manifest)
        refute File.exist?(File.join(dir, "5e_Adventure_Master_Catalog_3.0.xlsx"))
        assert_includes stdout, "No changes made."
        assert_equal "", git(dir, "status", "--short")
      end
    end
  end

  def test_adopt_refuses_to_overwrite_existing_canonical_destination
    with_catalog_repo do |dir, manifest|
      Dir.mktmpdir do |external_dir|
        candidate = File.join(external_dir, "5e_Adventure_Master_Catalog_3.0.xlsx")
        write_review_workbook(candidate, [catalog_row("ADV-0001", title: "Candidate", seriousness: 4)])
        destination = File.join(dir, File.basename(candidate))
        File.write(destination, "different bytes\n")
        before = File.read(manifest)

        _stdout, stderr, status = run_adopt(candidate, manifest, "")

        refute status.zero?
        assert_includes stderr, "refusing to overwrite existing AMC artifact"
        assert_equal "different bytes\n", File.read(destination)
        assert_equal before, File.read(manifest)
      end
    end
  end

  def test_noncanonical_external_filename_requires_explicit_version
    with_catalog_repo do |_dir, manifest|
      Dir.mktmpdir do |external_dir|
        candidate = File.join(external_dir, "candidate.xlsx")
        write_review_workbook(candidate, [catalog_row("ADV-0001", title: "Candidate", seriousness: 4)])

        _stdout, stderr, status = run_adopt(candidate, manifest, "")

        refute status.zero?
        assert_includes stderr, "use --version VERSION"
      end
    end
  end

  def test_adopt_blocks_incompatible_workbook_before_copy_or_promotion
    with_catalog_repo do |dir, manifest|
      Dir.mktmpdir do |external_dir|
        candidate = File.join(external_dir, "5e_Adventure_Master_Catalog_3.0.xlsx")
        write_review_workbook(candidate, [catalog_row("ADV-0001", title: "Existing", seriousness: 3)])
        replace_zip_text(candidate, "xl/worksheets/sheet1.xml", "Exploration Emphasis", "Exploration Missing")
        before = File.read(manifest)

        _stdout, stderr, status = run_adopt(candidate, manifest, "")

        refute status.zero?
        assert_includes stderr, "AMC cross-consumer compatibility failed"
        assert_includes stderr, "Exploration Emphasis"
        assert_equal before, File.read(manifest)
        refute File.exist?(File.join(dir, "5e_Adventure_Master_Catalog_3.0.xlsx"))
      end
    end
  end

  # Verify an independent role promotion prints the operator's persistence commands.
  def test_promote_prints_repository_persistence_commands
    with_catalog_repo do |dir, manifest|
      artifact = File.join(dir, "5e_Adventure_Master_Catalog_2.0.xlsx")
      stdout = StringIO.new
      original_stdout = $stdout

      begin
        $stdout = stdout
        af_project_state_main(
          [
            "promote",
            "matcher_authorized_baseline",
            "--manifest", manifest,
            "--artifact", artifact,
            "--version", "2.0"
          ]
        )
      ensure
        $stdout = original_stdout
      end

      assert_includes stdout.string, "Promoted matcher_authorized_baseline: 2.0"
      assert_includes stdout.string, "Repository persistence required:"
      assert_includes stdout.string, "git add PROJECT_STATE.yml 5e_Adventure_Master_Catalog_2.0.xlsx"
      assert_includes stdout.string, "git commit -m Promote\\ matcher_authorized_baseline\\ to\\ AMC\\ 2.0"
      assert_includes stdout.string, "# push remains an explicit operator choice"
    end
  end

  def test_executable_wiring_reports_usage_for_missing_command
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, BIN)

    refute status.success?
    assert_includes stderr, "Usage: bin/af-project-state"
  end

  private

  def run_adopt(candidate, manifest, stdin, version: nil, resume_artifact: nil)
    argv = ["adopt", candidate, "--manifest", manifest]
    argv.concat(["--version", version]) if version
    argv.concat(["--resume-artifact", resume_artifact]) if resume_artifact
    input = StringIO.new(stdin)
    stdout = StringIO.new
    stderr = StringIO.new
    original_stdin, original_stdout, original_stderr = $stdin, $stdout, $stderr
    status = 0

    begin
      $stdin = input
      $stdout = stdout
      $stderr = stderr
      af_project_state_main(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdin = original_stdin
      $stdout = original_stdout
      $stderr = original_stderr
    end

    [stdout.string, stderr.string, status]
  end

  def with_catalog_repo
    template = catalog_repo_template
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{template}/.", dir, preserve: true)
      previous_root = ENV["AF_DATA_PIPELINE_DATA_ROOT"]
      ENV["AF_DATA_PIPELINE_DATA_ROOT"] = File.realpath(dir)
      begin
        yield dir, File.join(dir, "PROJECT_STATE.yml")
      ensure
        ENV["AF_DATA_PIPELINE_DATA_ROOT"] = previous_root
      end
    end
  end

  def catalog_repo_template
    existing = self.class.instance_variable_get(:@catalog_repo_template)
    return existing if existing

    template = Dir.mktmpdir("af-project-state-adopt-template")
    git(template, "init", "-q")
    head = write_artifact(template, "2.0", [catalog_row("ADV-0001", title: "Original Adventure", seriousness: 3)])
    baseline = write_artifact(template, "1.0", [catalog_row("ADV-0001", title: "Original Adventure", seriousness: 3)])
    File.write(
      File.join(template, "PROJECT_STATE.yml"),
      {
        "schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
        "catalog_head" => role_entry(head, "2.0"),
        "matcher_authorized_baseline" => role_entry(baseline, "1.0"),
        "production_dependency_floor" => role_entry(baseline, "1.0")
      }.to_yaml
    )
    git(template, "add", ".")
    git(template, "commit", "-qm", "initial")

    self.class.instance_variable_set(:@catalog_repo_template, template)
    Minitest.after_run do
      FileUtils.remove_entry(template) if File.exist?(template)
    end
    template
  end

  def write_artifact(dir, version, rows)
    path = File.join(dir, "5e_Adventure_Master_Catalog_#{version}.xlsx")
    write_review_workbook(path, rows)
  end

  def write_review_workbook(path, rows)
    write_compatible_amc(path, rows:)
  end

  def catalog_row(adventure_id, title:, seriousness:)
    compatible_row(
      adventure_id,
      title:,
      levels: [3, 5],
      scores: seriousness.nil? ? {} : {"Seriousness" => seriousness}
    )
  end

  def role_entry(path, version)
    {
      "version" => version,
      "filename" => File.basename(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end

  def git(dir, *args)
    stdout, stderr, status = Open3.capture3(TEST_GIT_ENV, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end
