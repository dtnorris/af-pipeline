# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

# Protocol regressions use disposable synthetic methods; the public entry itself
# runs the unchanged real standing-release tests and DPS-03 fixtures.
class PublicStandingReleaseGateTest < Minitest::Test
  ENTRY = File.expand_path("../bin/af-public-standing-release-test", __dir__)
  MANIFEST = File.expand_path("public_standing_release_methods.json", __dir__)

  # A fresh entry needs no integration inventory or private runner selection.
  def test_fresh_entry_runs_the_complete_declared_population
    with_gate do |root, _source|
      output, error, status = run_gate(root)
      assert status.success?, error + output
      assert_includes output, "18 runs, 18 assertions, 0 failures, 0 errors, 0 skips"
      assert_includes output, "Public standing-release execution: 18/18 required methods"
    end
  end

  # Same-count renaming cannot silently change the independently stored contract.
  def test_missing_extra_and_duplicate_discovery_fail
    with_gate do |root, source|
      manifest = File.binread(File.join(root, "test/public_standing_release_methods.json"))
      method = JSON.parse(manifest).first.split("#").last
      [source.sub("def #{method}", "def removed_method"),
       source.sub("def #{method}", "def test_unexpected"),
       source + "\nclass StandingBulkScoreReleaseTest\n def self.runnable_methods; super + [super.first]; end\nend\n"].each do |changed|
        File.write(File.join(root, "test/standing_bulk_score_release_test.rb"), changed)
        _output, error, status = run_gate(root)
        refute status.success?
        assert_includes error, "discovery differs"
        assert_equal manifest, File.binread(File.join(root, "test/public_standing_release_methods.json"))
      end
    end
  end

  # Required skips fail without making ordinary private Minitest skips fail.
  def test_required_skip_failure_and_error_fail
    with_gate do |root, source|
      ["skip 'required work skipped'", "flunk 'broken invariant'", "raise 'broken invariant'"].each do |body|
        File.write(File.join(root, "test/standing_bulk_score_release_test.rb"), source.sub("assert true", body))
        output, error, status = run_gate(root)
        refute status.success?, output + error
        assert_includes error, "required work failed/skipped"
      end
    end
  end

  # Execution must agree independently with discovery, including duplicates and
  # same-count substitutions; summary counts alone cannot establish success.
  def test_execution_omission_substitution_and_duplication_fail
    with_gate do |root, source|
      changes = [
        "def self.runnable_methods; @calls = (@calls || 0) + 1; @calls == 1 ? super : []; end",
        "def after_teardown; super; self.name = 'test_unexpected'; end",
        "def self.runnable_methods; @calls = (@calls || 0) + 1; @calls == 1 ? super : super + [super.first]; end"
      ]
      changes.each do |change|
        File.write(File.join(root, "test/standing_bulk_score_release_test.rb"),
          source + "\nclass StandingBulkScoreReleaseTest\n#{change}\nend\n")
        output, error, status = run_gate(root)
        refute status.success?, output + error
        assert_includes error, "executed identities differ"
      end
    end
  end

  # Invalid manifests and selection overrides must never shrink required work.
  def test_manifest_corruption_and_selection_overrides_fail
    with_gate do |root, _source|
      _output, error, status = run_gate(root, "--name", "test_nothing")
      refute status.success?
      assert_includes error, "no selection overrides"
      path = File.join(root, "test/public_standing_release_methods.json")
      required = JSON.parse(File.binread(path))
      [required.drop(1), [required.first] * 18, [nil] * 18].each do |changed|
        File.write(path, JSON.generate(changed))
        _output, error, status = run_gate(root)
        refute status.success?
        assert_includes error, "invalid required-method manifest"
      end
    end
  end

  private

  # Copies only the public entry and fixed manifest into a temporary root;
  # yields that root and synthetic source, and removes it after the assertion.
  def with_gate
    Dir.mktmpdir("public-standing-gate-") do |root|
      FileUtils.mkdir_p([File.join(root, "bin"), File.join(root, "test")])
      FileUtils.cp(ENTRY, File.join(root, "bin", File.basename(ENTRY)))
      FileUtils.cp(MANIFEST, File.join(root, "test", File.basename(MANIFEST)))
      methods = JSON.parse(File.binread(MANIFEST)).map { |name| name.split("#").last }
      source = "require 'minitest/autorun'\nclass StandingBulkScoreReleaseTest < Minitest::Test\n" +
        methods.map { |method| "def #{method}; assert true; end\n" }.join + "end\n"
      File.write(File.join(root, "test/standing_bulk_score_release_test.rb"), source)
      yield root, source
    end
  end

  # Executes a new Ruby process and returns its stdout, stderr and exit status.
  def run_gate(root, *arguments)
    Open3.capture3(RbConfig.ruby, File.join(root, "bin", File.basename(ENTRY)), *arguments, chdir: root)
  end
end
