# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "pty"
require "io/console"
require "timeout"
require "etc"
require_relative "../bin/af_test_suite_coverage"
require_relative "../bin/af_test_suite_selection"
require_relative "../bin/af_test_suite_progress"
require_relative "../bin/af_test_suite_handoff"

# Exercises public runner selection, accounting, progress and coverage with
# disposable subprocess fixtures; no production worker or catalog is involved.
class TestSuiteRunnerTest < Minitest::Test
  RUNNER = File.expand_path("../bin/af-test-suite", __dir__)

  # Verifies each selected method executes once at the requested seed, with
  # validated structured results and unchanged Minitest presentation.
  def test_all_methods_run_exactly_once_with_the_requested_seed
    with_runner do |root|
      stdout, stderr, status = run_suite(root, "--seed", "170", "--verbose")
      assert status.success?, stderr + stdout
      refute_includes stderr, "Worker terminal results invalid"
      assert_includes stdout, "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips"
      assert_includes stdout, "seed 170"
      assert_equal %w[AlphaTest#test_alpha AlphaTest#test_beta BetaTest#test_alpha], executed(root)
    end
  end

  def test_exact_name_regex_and_exclusion_filters_preserve_selection
    with_runner do |root|
      stdout, stderr, status = run_suite(root, "--name", "test_alpha")
      assert status.success?, stderr + stdout
      assert_includes stdout, "2 runs, 2 assertions, 0 failures, 0 errors, 0 skips"
      assert_equal %w[AlphaTest#test_alpha BetaTest#test_alpha], executed(root)
      Dir[File.join(root, "records", "*")].each { |path| File.unlink(path) }
      stdout, stderr, status = run_suite(root, "--name", "/AlphaTest/", "--exclude", "test_beta", "--no-plugins")
      assert status.success?, stderr + stdout
      assert_includes stdout, "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
      assert_equal ["AlphaTest#test_alpha"], executed(root)
      Dir[File.join(root, "records", "*")].each { |path| File.unlink(path) }
      stdout, stderr, status = run_suite(root, "--name", "prefix/AlphaTest/suffix")
      assert status.success?, stderr + stdout
      assert_includes stdout, "2 runs, 2 assertions, 0 failures, 0 errors, 0 skips"
      assert_equal %w[AlphaTest#test_alpha AlphaTest#test_beta], executed(root)
    end
  end

  def test_failure_and_worker_exit_cannot_be_reported_as_success
    with_runner do |root|
      path = File.join(root, "test", "synthetic_test.rb")
      original = File.binread(path)
      File.binwrite(path, original.sub("assert true", "flunk 'synthetic failure'"))
      stdout, _stderr, status = run_suite(root)
      refute status.success?
      assert_includes stdout, "3 runs, 3 assertions, 1 failures, 0 errors, 0 skips"
      File.binwrite(path, original.sub("assert true", "exit! 19"))
      _stdout, stderr, status = run_suite(root)
      refute status.success?
      assert_includes stderr, "test accounting differs"
    end
  end

  def test_progress_records_report_real_worker_outcomes_without_duplicate_summaries
    with_runner do |root|
      stdout, stderr, status = run_suite(root, environment: {"AF_TEST_PROGRESS_FORMAT" => "json"})
      assert status.success?, stderr + stdout
      records = stderr.lines.filter_map { |line| AfTestSuiteProgress.decode(line) }
      completed = records.select { |event| event["event"] == "worker_finished" }
      assert_equal completed.length, completed.last.fetch("workers_finished")
      assert_equal completed.length, completed.last.fetch("workers_total")
      assert completed.all? { |event| event["outcome"] == "passed" }
      assert_includes stdout, "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips"
      refute_match(/\d+ runs, \d+ assertions/, records.map { |event| JSON.generate(event) }.join)
      path = File.join(root, "test", "synthetic_test.rb")
      File.binwrite(path, File.binread(path) + "\nMinitest.after_run { puts '1 runs, 1 assertions, 0 failures, 0 errors, 0 skips' }\n")
      stdout, stderr, status = run_suite(root, environment: {"AF_TEST_PROGRESS_FORMAT" => "json"})
      assert status.success?, stderr + stdout
      assert_includes stdout, "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
      assert stderr.lines.filter_map { |line| AfTestSuiteProgress.decode(line) }.all? { |event|
        event["event"] != "worker_finished" || event["outcome"] == "passed"
      }
    end
  end

  def test_empty_filter_runs_no_unselected_tests
    with_runner do |root|
      stdout, stderr, status = run_suite(root, "--name", "/does_not_exist/")
      refute status.success?
      assert_includes stderr, "Nothing ran for filter"
      assert_includes stdout, "0 runs, 0 assertions, 0 failures, 0 errors, 0 skips"
      assert_empty executed(root)
    end
  end

  def test_coverage_slices_collate_the_same_line_and_branch_decisions_as_serial
    with_runner do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, ".simplecov"), <<~'RUBY')
        SimpleCov.configure do
          cover "lib/**/*.rb"
          enable_coverage :branch
        end
      RUBY
      File.write(File.join(root, "lib", "synthetic.rb"), <<~'RUBY')
        module Synthetic
          def self.flag(value)
            if value
              true
            else
              false
            end
          end
        end
      RUBY
      File.write(File.join(root, "test", "synthetic_test.rb"), <<~'RUBY')
        require "minitest/autorun"
        require_relative "../lib/synthetic"
        class AlphaTest < Minitest::Test
          def test_true
            assert Synthetic.flag(true)
          end
        end
        class BetaTest < Minitest::Test
          def test_false
            refute Synthetic.flag(false)
          end
        end
      RUBY

      serial = 'SimpleCov.command_name = "serial-fixture"; SimpleCov.start; Dir["test/**/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
      _out, err, status = Open3.capture3(RbConfig.ruby, "-r", "simplecov", "-e", serial, chdir: root)
      assert status.success?, err
      path = File.join(root, "coverage", ".resultset.json")
      serial_coverage = JSON.parse(File.binread(path)).fetch("serial-fixture").fetch("coverage")

      out = err = status = nil
      AfTestSuiteHandoff.channel("fast") do |environment, read_result|
        out, err, status = run_suite(root, "--seed", "170", environment: environment.merge("COVERAGE" => "1", "AF_TEST_PROGRESS_RENDERER" => "tty"))
        assert status.success?, err + out
        assert_equal [2, 2, 0, 0, 0], read_result.call.values_at(*AfTestSuiteHandoff::COUNTERS)
      end
      assert_includes out, "2 runs, 2 assertions, 0 failures, 0 errors, 0 skips"
      assert_includes err, "Line coverage:"
      assert_includes err, "Branch coverage:"
      combined = JSON.parse(File.binread(File.join(root, "coverage", "fast", ".resultset.json")))
      assert_equal 1, combined.length
      refute_includes combined.keys.join, "serial-fixture"
      parallel_coverage = combined.values.first.fetch("coverage")
      assert_equal covered_decisions(serial_coverage), covered_decisions(parallel_coverage)

      install_integration(root)
      File.write(File.join(root, ".simplecov_baseline.yml"), YAML.dump(
        "lib/synthetic.rb" => {"lines" => {"percent" => 100.0, "missed" => 0},
                               "branches" => {"percent" => 100.0, "missed" => 0}}
      ))
      out, err, status = run_suite(root, "--suite", "all", "--seed", "170", environment: {"COVERAGE" => "1"})
      assert status.success?, err + out
      assert_includes out, "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips"
      complete = JSON.parse(File.binread(File.join(root, "coverage", "full", ".resultset.json")))
      assert_equal 1, complete.length
      assert_equal covered_decisions(serial_coverage), covered_decisions(complete.values.first.fetch("coverage"))
      # An integration-only slice cannot borrow the earlier fast report's hits.
      _out, _err, status = run_suite(root, "--suite", "integration", environment: {"COVERAGE" => "1"})
      refute status.success?
    end
  end

  def test_coverage_rejects_missing_corrupt_misattributed_and_partial_workers
    Dir.mktmpdir("coverage-result-test-") do |root|
      first = File.join(root, "first.json")
      second = File.join(root, "second.json")
      entry = { "timestamp" => Time.now.to_i, "coverage" => {
        "/lib/synthetic.rb" => { "lines" => [1, nil, 0], "branches" => { "decision" => { "then" => 1, "else" => 0 } } }
      } }
      File.write(first, JSON.generate("af-test-suite-worker-0" => entry))
      assert_raises(AfTestSuiteCoverage::InvalidResult) do
        AfTestSuiteCoverage.verify!([first, second])
      end
      File.write(second, "{")
      assert_raises(AfTestSuiteCoverage::InvalidResult) do
        AfTestSuiteCoverage.verify!([first, second])
      end
      File.write(second, JSON.generate("af-test-suite-worker-0" => entry))
      assert_raises(AfTestSuiteCoverage::InvalidResult) do
        AfTestSuiteCoverage.verify!([first, second])
      end
      File.write(second, JSON.generate("af-test-suite-worker-1" => entry.merge("coverage" => {})))
      assert_raises(AfTestSuiteCoverage::InvalidResult) do
        AfTestSuiteCoverage.verify!([first, second])
      end
      malformed = { "/lib/synthetic.rb" => { "lines" => [1], "branches" => { "decision" => { "then" => "hit" } } } }
      File.write(second, JSON.generate("af-test-suite-worker-1" => entry.merge("coverage" => malformed)))
      assert_raises(AfTestSuiteCoverage::InvalidResult) do
        AfTestSuiteCoverage.verify!([first, second])
      end
      File.write(second, JSON.generate("af-test-suite-worker-1" => entry,
        "unselected-worker" => entry))
      assert_raises(AfTestSuiteCoverage::InvalidResult) do
        AfTestSuiteCoverage.verify!([first, second])
      end
      File.write(second, JSON.generate("af-test-suite-worker-1" => entry))
      assert AfTestSuiteCoverage.verify!([first, second])
    end
  end

  def test_fast_integration_and_full_discovery_partition_nested_files_exactly_once
    with_runner do |root|
      install_integration(root)
      fast = AfTestSuiteSelection.files(root, "fast")
      integration = AfTestSuiteSelection.files(root, "integration")
      assert_empty fast & integration
      assert_equal AfTestSuiteSelection.files(root, "all"), (fast + integration).sort
      {"fast" => 3, "integration" => 1, "all" => 4}.each do |mode, count|
        Dir[File.join(root, "records", "*")].each { |path| File.unlink(path) }
        stdout, stderr, status = run_suite(root, "--suite", mode)
        assert status.success?, stderr + stdout
        assert_includes stdout, "#{count} runs, #{count} assertions, 0 failures, 0 errors, 0 skips"
        assert_equal count, executed(root).length
        assert_equal mode != "fast", executed(root).include?("IntegrationTest#test_integration")
      end
    end
  end

  def test_inventory_refuses_missing_unregistered_and_duplicate_integration_files
    with_runner do |root|
      path = install_integration(root)
      manifest = File.join(root, "test", "integration.json")
      File.write(manifest, JSON.generate([path, path]))
      assert_raises(ArgumentError) { AfTestSuiteSelection.files(root, "fast") }
      File.write(manifest, "[]")
      assert_raises(ArgumentError) { AfTestSuiteSelection.files(root, "fast") }
      File.write(manifest, JSON.generate([path]))
      File.unlink(File.join(root, path))
      %w[fast integration all].each do |mode|
        _out, _err, status = run_suite(root, "--suite", mode)
        refute status.success?
      end
    end
  end

  def test_integration_errors_missing_fixtures_and_malformed_summaries_fail_closed
    with_runner do |root|
      path = File.join(root, install_integration(root))
      original = File.binread(path)
      ["raise 'integration error'", "File.binread('missing-fixture')", "exit! 19"].each do |failure|
        File.binwrite(path, original.sub("assert true", failure))
        _out, _err, status = run_suite(root, "--suite", "integration")
        refute status.success?
      end
      File.binwrite(path, original + "\nMinitest.after_run { puts '1 runs, 1 assertions, 0 failures, 0 errors, 0 skips' }\n")
      out, err, status = run_suite(root, "--suite", "integration")
      assert status.success?, err + out
    end
  end

  def test_coverage_rejects_stale_results_and_omitted_workers
    Dir.mktmpdir("coverage-freshness-") do |root|
      path = File.join(root, "worker.json")
      entry = {"timestamp" => Time.now.to_i - 60, "coverage" => {
        "/lib/synthetic.rb" => {"lines" => [1], "branches" => {}}
      }}
      File.write(path, JSON.generate("selected-run" => entry))
      assert_raises(AfTestSuiteCoverage::InvalidResult) do
        AfTestSuiteCoverage.verify!([path], names: ["selected-run"], started_at: Time.now.to_i)
      end
      assert_raises(AfTestSuiteCoverage::InvalidResult) do
        AfTestSuiteCoverage.verify!([path], names: %w[selected-run omitted-integration-worker])
      end
      assert_raises(AfTestSuiteCoverage::InvalidResult) { AfTestSuiteCoverage.verify!([]) }
    end
  end

  def test_tty_runner_preserves_selection_summary_failure_and_invalid_worker_status
    with_runner do |root|
      out, err, status = run_tty(root, RbConfig.ruby, File.join(root, "bin", "af-test-suite"), "--seed", "170")
      assert status.success?, err + out
      assert_includes err, "workers #{[Etc.nprocessors, 3].min}/#{[Etc.nprocessors, 3].min}"
      assert_equal 1, out.lines.count { |line| line == "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n" }
      assert_equal 3, executed(root).length
      assert_equal 1, completion_lines(err).length
      assert_includes completion_lines(err).first, "| PASS | 3 tests |"
      path = File.join(root, "test", "synthetic_test.rb")
      original = File.binread(path)
      File.binwrite(path, original.sub("assert true", "flunk 'original failure'"))
      out, err, status = run_tty(root, RbConfig.ruby, File.join(root, "bin", "af-test-suite"))
      refute status.success?
      assert_includes out, "original failure"
      assert_includes err, "failed"
      assert_includes out, "3 runs, 3 assertions, 1 failures, 0 errors, 0 skips"
      assert_equal 1, completion_lines(err).length
      assert_includes completion_lines(err).first, "| FAIL | 3 tests |"
      File.binwrite(path, original.sub("assert true", "exit! 19"))
      _out, err, status = run_tty(root, RbConfig.ruby, File.join(root, "bin", "af-test-suite"))
      refute status.success?
      assert_includes err, "invalid"
      assert_includes err, "test accounting differs"
      assert_equal 1, completion_lines(err).length
      assert_includes completion_lines(err).first, "| FAIL |"
      refute_match(/\| \d+ tests \|/, completion_lines(err).first)
    end
  end

  def test_rake_runtime_tty_relay_preserves_diagnostics_accounting_and_failure
    with_runner do |root|
      FileUtils.cp(File.expand_path("../Rakefile", __dir__), File.join(root, "Rakefile"))
      out, err, status = run_tty(root, "bundle", "exec", "rake", "test:runtime")
      assert status.success?, err + out
      assert_includes err, "fast / functional tests"
      assert_includes err, "workers #{[Etc.nprocessors, 3].min}/#{[Etc.nprocessors, 3].min}"
      assert_equal 1, out.lines.count { |line| line == "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n" }
      refute_includes out, AfTestSuiteProgress::PREFIX
      assert_equal 3, executed(root).length
      path = File.join(root, "test", "synthetic_test.rb")
      File.binwrite(path, File.binread(path).sub("assert true", "warn 'original warning'; flunk 'original failure'"))
      out, err, status = run_tty(root, "bundle", "exec", "rake", "test:runtime")
      refute status.success?
      assert_includes out, "original failure"
      assert_includes out, "original warning"
      assert_includes err, "test suite failed before runtime could be accepted"
    end
  end

  def test_plain_rake_default_animation_and_final_contract_acceptance
    with_runner do |root|
      install_contract(root)
      text, _err, status = run_tty(root, "rake", combined: true,
        environment: {"AF_TEST_PROGRESS_RENDERER" => nil, "AF_TEST_PROGRESS_FORMAT" => nil})
      assert_includes text, "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips"
      assert_includes text, "Line coverage:"
      assert_includes text, "Branch coverage:"
      assert_includes text, "test:bench: Horizontal Discovery package extraction scaling guard passed"
      assert_includes text, "fast / functional tests"
      assert_includes text, "workers 0/"
      assert_includes text, "test:lint: 2 files inspected, no offenses detected"
      assert_includes text, "test:deps: no broken dependencies found"
      lines = completion_lines(text)
      assert_equal 1, lines.length
      assert_equal lines.first, text.lines.last
      assert_includes lines.first, "test contract"
      if status.success?
        assert_includes lines.first, "| PASS | 3 tests |"
      else
        # The runtime ceiling is host-calibrated. Verify its real failure rather
        # than altering clocks/thresholds to manufacture a successful contract.
        assert_includes text, "reached hard ceiling 24.0s"
        assert_includes lines.first, "| FAIL | 3 tests |"
      end
      assert_includes lines.first, "#{[Etc.nprocessors, 3].min}/#{[Etc.nprocessors, 3].min} workers"
      assert_equal 3, executed(root).length
    end
  end

  def test_plain_rake_later_benchmark_failure_has_no_overall_pass
    with_runner do |root|
      install_contract(root)
      text, _err, status = run_tty(root, "rake", combined: true,
        environment: {"AF_TEST_PROGRESS_RENDERER" => nil, "AF_TEST_PROGRESS_FORMAT" => nil, "FIXTURE_BENCH_FAILURE" => "1"})
      refute status.success?
      assert_includes text, "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips"
      assert_includes text, "synthetic benchmark failure"
      assert_includes text, "scale-sensitive benchmark failed"
      lines = completion_lines(text)
      assert_equal 1, lines.length
      assert_equal lines.first, text.lines.last
      assert_includes lines.first, "| FAIL | 3 tests |"
      refute_includes lines.first, "PASS"
    end
  end

  def test_rake_test_default_text_and_json_comparisons_preserve_exit_status
    with_runner do |root|
      FileUtils.cp(File.expand_path("../Rakefile", __dir__), File.join(root, "Rakefile"))
      text, _err, status = run_tty(root, "rake", "test", combined: true,
        environment: {"AF_TEST_PROGRESS_RENDERER" => nil, "AF_TEST_PROGRESS_FORMAT" => nil})
      assert status.success?, text
      assert_equal 1, completion_lines(text).length
      assert_includes completion_lines(text).first, "| PASS | 3 tests |"
      text, _err, status = run_tty(root, "rake", "test", combined: true,
        environment: {"AF_TEST_PROGRESS_RENDERER" => "text"})
      assert status.success?, text
      refute_match(/\e/, text)
      assert_empty completion_lines(text)
      text, _err, status = run_tty(root, "rake", "test", combined: true,
        environment: {"AF_TEST_PROGRESS_RENDERER" => "tty", "AF_TEST_PROGRESS_FORMAT" => "json"})
      assert status.success?, text
      refute_match(/\e/, text)
      assert_empty completion_lines(text)
      records = text.lines.filter_map { |line| AfTestSuiteProgress.decode(line) }
      assert_equal [Etc.nprocessors, 3].min, records.count { |event| event["event"] == "worker_finished" }
      assert_includes text, "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips"
    end
  end

  # The real public Rake task exports the observed fast count only after
  # all gates end. Later failures veto the public result despite successful tests.
  def test_public_rake_handoff_preserves_counts_and_late_failure
    with_runner do |root|
      install_contract(root)
      [false, true].each do |fail_benchmark|
        AfTestSuiteHandoff.channel("fast") do |environment, read_result|
          stdout, stderr, status = Open3.capture3(environment.merge(
            "COVERAGE" => nil, "FIXTURE_BENCH_FAILURE" => fail_benchmark ? "1" : nil),
            "bundle", "exec", "rake", chdir: root)
          record = read_result.call
          expected = fail_benchmark ? [4, 4, 1, 0, 0] : [3, 3, 0, 0, 0]
          assert_equal expected, record.values_at(*AfTestSuiteHandoff::COUNTERS)
          assert_equal status.success? ? "passed" : "failed", record.fetch("status")
          if fail_benchmark
            refute status.success?, stdout + stderr
            assert_includes stdout + stderr, "synthetic benchmark failure"
          elsif !status.success?
            # Retain the real calibrated runtime veto on a heavily loaded host.
            assert_includes stdout + stderr, "reached hard ceiling 24.0s"
          end
        end
      end
    end
  end

  # Runner and Rake handoffs retain fresh instrumented accounting; full coverage
  # contributes its own observed invocation, never an earlier fast result.
  def test_public_integration_handoff_survives_changed_presentation
    with_runner do |root|
      install_contract(root)
      install_integration(root)
      runner = File.join(root, "bin", "af-test-suite")
      source = File.read(runner).sub('puts "Worker #{index + 1}:"', 'puts "Shard #{index + 1}:"')
      source = source.sub('puts "%d runs, %d assertions, %d failures, %d errors, %d skips" % totals',
        'puts "cosmetic aggregate omitted"')
      File.write(runner, source)
      rakefile = File.join(root, "Rakefile")
      File.write(rakefile, File.read(rakefile).sub('Integration validation finished in %.3fs.', 'Integration complete in %.3f seconds.'))
      AfTestSuiteHandoff.channel("integration") do |environment, read_result|
        stdout, stderr, status = Open3.capture3(environment.merge("COVERAGE" => nil),
          "bundle", "exec", "rake", "test:integration", chdir: root)
        assert status.success?, stdout + stderr
        assert_equal [5, 5, 0, 0, 0], read_result.call.values_at(*AfTestSuiteHandoff::COUNTERS)
        assert_includes stdout, "cosmetic aggregate omitted"
        assert_includes stdout + stderr, "Line coverage:"
        assert File.file?(File.join(root, "coverage/full/.resultset.json"))
      end
    end
  end

  private

  def completion_lines(text)
    text.lines.grep(/\A(?:fast|integration|all) \/.* \| (?:PASS|FAIL) \|/)
  end

  def install_contract(root)
    FileUtils.cp(File.expand_path("../Rakefile", __dir__), File.join(root, "Rakefile"))
    FileUtils.cp(File.expand_path("../.rubocop.yml", __dir__), File.join(root, ".rubocop.yml"))
    FileUtils.mkdir_p(File.join(root, "lib"))
    FileUtils.mkdir_p(File.join(root, "bench"))
    File.write(File.join(root, "test", "companion_test.rb"), 'require "minitest/autorun"' + "\n")
    File.write(File.join(root, "lib", "synthetic.rb"), <<~'RUBY')
      module Synthetic
        def self.flag(value)
          if value
            true
          else
            false
          end
        end
      end
    RUBY
    path = File.join(root, "test", "synthetic_test.rb")
    source = File.read(path).sub('require "minitest/autorun"', 'require "minitest/autorun"' + "\nrequire_relative '../lib/synthetic'")
    source = source.sub("assert true", "assert Synthetic.flag(true)")
    source = source.sub("assert true", "assert Synthetic.flag(true)")
    File.write(path, source.sub("assert true", "refute Synthetic.flag(false)"))
    File.write(File.join(root, ".simplecov"), <<~'RUBY')
      SimpleCov.configure do
        cover "lib/**/*.rb"
        enable_coverage :branch
      end
    RUBY
    File.write(File.join(root, "bench", "horizontal_discovery_v1_benchmark.rb"), <<~'RUBY')
      require "minitest/autorun"
      class SyntheticBenchmark < Minitest::Test
        def test_fixture_check
          refute ENV["FIXTURE_BENCH_FAILURE"], "synthetic benchmark failure"
        end
      end
    RUBY
  end

  def install_integration(root)
    relative = "test/integration/synthetic_test.rb"
    FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
    File.write(File.join(root, "test/integration.json"), JSON.generate([relative]))
    File.write(File.join(root, relative), <<~'RUBY')
      require "minitest/autorun"
      class IntegrationTest < Minitest::Test
        def test_integration
          File.write(File.expand_path("../../records/IntegrationTest#test_integration", __dir__), "executed")
          assert true
        end
      end
    RUBY
    relative
  end

  def run_suite(root, *arguments, environment: {})
    Open3.capture3({ "COVERAGE" => nil, "AFDP_TEST_RESULT_OWNER" => nil }.merge(environment), RbConfig.ruby, File.join(root, "bin", "af-test-suite"), *arguments, chdir: root)
  end

  def run_tty(root, *arguments, environment: {}, combined: false)
    PTY.open do |reader, output|
      output.winsize = [24, 140]
      drain = Thread.new do
        text = +""
        begin
          loop { text << reader.readpartial(4096) }
        rescue EOFError, Errno::EIO
          text.gsub("\r\n", "\n")
        end
      end
      settings = {"COVERAGE" => nil, "AFDP_TEST_RESULT_OWNER" => nil, "AF_TEST_PROGRESS_RENDERER" => "tty",
        "AF_TEST_PROGRESS_FORMAT" => "text", "TERM" => "xterm", "COLUMNS" => "140"}.merge(environment)
      if combined
        pid = Process.spawn(settings, *arguments, chdir: root, in: File::NULL, out: output, err: output)
        _pid, status = Process.wait2(pid)
        stdout = nil
      else
        stdout, status = Open3.capture2(settings, *arguments, chdir: root, err: output)
      end
      output.close
      terminal = Timeout.timeout(5) { drain.value }
      [stdout || terminal, terminal, status]
    ensure
      output.close unless output.closed?
      drain&.join(5)
    end
  end

  def covered_decisions(coverage)
    coverage.transform_values do |data|
      branches = data.fetch("branches").transform_values { |arms| arms.transform_values(&:positive?) }
      {
        "lines" => data.fetch("lines").map { |hit| hit && hit.positive? },
        "branches" => branches
      }
    end
  end

  def executed(root)
    Dir[File.join(root, "records", "*")].map { |path| File.basename(path) }.sort
  end

  # Yields a disposable runner root with all required collaborators and three
  # synthetic methods. Temporary files are removed when the block returns.
  def with_runner
    Dir.mktmpdir("suite-runner-test-") do |root|
      %w[bin test records].each { |name| FileUtils.mkdir_p(File.join(root, name)) }
      FileUtils.cp(RUNNER, File.join(root, "bin", "af-test-suite"))
      FileUtils.cp(File.expand_path("../bin/af_test_suite_coverage.rb", __dir__),
        File.join(root, "bin", "af_test_suite_coverage.rb"))
      FileUtils.cp(File.expand_path("../bin/af_test_suite_selection.rb", __dir__),
        File.join(root, "bin", "af_test_suite_selection.rb"))
      FileUtils.cp(File.expand_path("../bin/af_test_suite_progress.rb", __dir__),
        File.join(root, "bin", "af_test_suite_progress.rb"))
      FileUtils.cp(File.expand_path("../bin/af_test_suite_result.rb", __dir__),
        File.join(root, "bin", "af_test_suite_result.rb"))
      FileUtils.cp(File.expand_path("../bin/af_test_suite_handoff.rb", __dir__),
        File.join(root, "bin", "af_test_suite_handoff.rb"))
      FileUtils.cp(File.expand_path("../bin/af_test_standalone_result.rb", __dir__),
        File.join(root, "bin", "af_test_standalone_result.rb"))
      File.write(File.join(root, "test", "integration.json"), "[]\n")
      File.write(File.join(root, "test", "synthetic_test.rb"), <<~'RUBY')
        require "minitest/autorun"
        class AlphaTest < Minitest::Test
          def test_alpha
            File.write(File.expand_path("../records/AlphaTest#test_alpha", __dir__), "executed")
            assert true
          end
          def test_beta
            File.write(File.expand_path("../records/AlphaTest#test_beta", __dir__), "executed")
            assert true
          end
        end
        class BetaTest < Minitest::Test
          def test_alpha
            File.write(File.expand_path("../records/BetaTest#test_alpha", __dir__), "executed")
            assert true
          end
        end
      RUBY
      yield root
    end
  end
end
