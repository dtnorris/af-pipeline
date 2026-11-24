# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../bin/af_test_suite_result"
require_relative "../bin/af_test_suite_handoff"

# Protocol-only subprocess fixtures need no product, workbook or catalog data.
class TestSuiteResultTest < Minitest::Test
  RUNNER = File.expand_path("../bin/af-test-suite", __dir__)
  PASS_SELECTION = ["TerminalFixtureTest#test_pass"].freeze
  MIXED_SELECTION = %w[TerminalFixtureTest#test_error TerminalFixtureTest#test_failure
                       TerminalFixtureTest#test_pass TerminalFixtureTest#test_skip].freeze
  # Fixed independently from the producer: SHA-256 of each sorted JSON array.
  PASS_FINGERPRINT = "6367e649733426ecff267d25fdf7793c94d0f8e31cc1ed3fbcbdb9abfd858746"
  MIXED_FINGERPRINT = "21a490676fca1f0ea0f54d511f707a3217031523dc3bd9af80fa154a1cd1d7f3"
  PASS_SOURCE = <<~'RUBY'
    require "minitest/autorun"
    class TerminalFixtureTest < Minitest::Test
      def test_pass
        assert true
      end
    end
  RUBY
  MIXED_SOURCE = PASS_SOURCE + <<~'RUBY'
    class TerminalFixtureTest
      def test_failure
        assert_equal 1, 2
      end
      def test_error
        raise "fixture error"
      end
      def test_skip
        skip "fixture skip"
      end
    end
  RUBY

  # Verifies fixed counters in every suite, including failed/error/skipped runs,
  # and proves explicitly installed reporting survives --no-plugins.
  def test_workers_emit_one_bound_result_with_exact_minitest_counters
    %w[fast integration all].each do |suite|
      with_worker(selection: MIXED_SELECTION, suite: suite, source: MIXED_SOURCE) do |worker|
        assert_equal 1, worker.fetch(:status).exitstatus
        records = verify(worker)
        assert_equal 1, records.length
        record = records.first
        assert_equal [4, 2, 1, 1, 1], record.values_at(*AfTestSuiteResult::COUNTERS)
        assert_equal "complete", record.fetch("status")
        assert_equal MIXED_FINGERPRINT, record.fetch("selection_sha256")
        assert_includes worker.fetch(:stdout), "4 runs, 2 assertions, 1 failures, 1 errors, 1 skips"
        assert_includes worker.fetch(:stdout), "--seed 170"
        assert_includes worker.fetch(:stdout), "fixture error"
        assert_includes worker.fetch(:stdout), "fixture skip"
      end
    end
  end

  # Closed-schema mutations must fail without consulting telemetry or stdout.
  # A second JSON document and duplicate JSON keys are both ambiguous evidence.
  def test_validator_rejects_missing_duplicate_malformed_stale_and_mismatched_results
    with_worker do |worker|
      path = worker.fetch(:path)
      original = File.binread(path)
      record = JSON.parse(original)
      assert_equal [1, 1, 0, 0, 0], verify(worker).first.values_at(*AfTestSuiteResult::COUNTERS)
      changes = [
        {"schema" => "afdp-worker-result/v2"}, {"run_id" => "b" * 32},
        {"suite" => "integration"}, {"worker" => 2}, {"worker" => 1.0},
        {"population_sha256" => "0" * 64}, {"selection_sha256" => MIXED_FINGERPRINT},
        {"status" => "incomplete"}, {"tests" => 0}, {"assertions" => -1},
        {"errors" => "0"}, {"failures" => true}, {"skips" => nil},
        {"tests" => 1, "failures" => 1, "errors" => 1}, {"unexpected" => 1}
      ]
      malformed = ["{", "[]", "null", original + original,
                   original.sub('"tests":1', '"tests":0,"tests":1'),
                   JSON.generate(record.reject { |key, _value| key == "assertions" })]
      (changes.map { |change| JSON.generate(record.merge(change)) } + malformed).each do |bytes|
        File.binwrite(path, bytes)
        assert_raises(AfTestSuiteResult::InvalidResult) { verify(worker) }
      end
      File.binwrite(path, original)
      assert_raises(AfTestSuiteResult::InvalidResult) do
        AfTestSuiteResult.verify!([path, path], expected: [worker.fetch(:expected)] * 2,
          statuses: [worker.fetch(:status)] * 2)
      end
      assert_raises(AfTestSuiteResult::InvalidResult) do
        AfTestSuiteResult.verify!([], expected: [], statuses: [])
      end
      assert_raises(AfTestSuiteResult::InvalidResult) do
        AfTestSuiteResult.verify!([path], expected: [], statuses: [worker.fetch(:status)])
      end
      assert_raises(AfTestSuiteResult::InvalidResult) do
        AfTestSuiteResult.verify!([path], expected: [worker.fetch(:expected)], statuses: [nil])
      end
      File.unlink(path)
      assert_raises(AfTestSuiteResult::InvalidResult) { verify(worker) }
    end
  end

  # Completion records fingerprint observed names, not merely assigned names.
  # Substituting a different method with the same count cannot validate.
  def test_wrong_executed_population_and_duplicate_emission_are_rejected
    replacement = PASS_SOURCE + <<~'RUBY'
      class TerminalFixtureTest
        def after_teardown
          super
          self.name = "test_other"
        end
      end
    RUBY
    with_worker(source: replacement) do |worker|
      assert worker.fetch(:status).success?, worker.fetch(:stderr)
      record = JSON.parse(File.binread(worker.fetch(:path)))
      assert_equal 1, record.fetch("tests")
      assert_equal "incomplete", record.fetch("status")
      refute_equal PASS_FINGERPRINT, record.fetch("selection_sha256")
      assert_raises(AfTestSuiteResult::InvalidResult) { verify(worker) }
    end
    with_fixture do |root|
      # Emit a second document after Minitest's normal reporter dispatch.
      source = PASS_SOURCE + <<~'RUBY'
        Minitest.after_run do
          AfTestSuiteResult.instance_variable_get(:@worker_reporter).report
        end
      RUBY
      run_worker(root, source: source) do |worker|
        assert worker.fetch(:status).success?, worker.fetch(:stderr)
        assert_raises(AfTestSuiteResult::InvalidResult) { verify(worker) }
      end
    end
  end

  # Interrupts and crashes target only the isolated worker itself. Even forged
  # success text or a complete record before a fatal signal cannot validate.
  def test_interrupted_crashed_and_signaled_workers_never_supply_complete_evidence
    ["raise Interrupt", "puts '1 runs, 1 assertions, 0 failures, 0 errors, 0 skips'; exit! 19",
     "Process.kill('TERM', Process.pid)"].each do |body|
      with_worker(source: PASS_SOURCE.sub("assert true", body)) do |worker|
        refute worker.fetch(:status).success?
        assert_raises(AfTestSuiteResult::InvalidResult) { verify(worker) }
      end
    end
    ["Process.kill('TERM', Process.pid)", "exit! 19"].each do |body|
      source = PASS_SOURCE + "\nMinitest.after_run { #{body} }\n"
      with_worker(source: source) do |worker|
        refute worker.fetch(:status).success?
        assert_equal "complete", JSON.parse(File.binread(worker.fetch(:path))).fetch("status")
        assert_raises(AfTestSuiteResult::InvalidResult) { verify(worker) }
      end
    end
  end

  # Missing evidence fails despite passing text; cosmetic duplicate summaries
  # cannot invalidate independently verified results.
  def test_structured_results_are_the_only_accounting_authority
    with_fixture do |root|
      helper = File.join(root, "bin", "af_test_suite_result.rb")
      source = File.binread(helper)
      emission = 'File.open(@path, "ab") { |file| file.write(JSON.generate(record) + "\n") }'
      assert_includes source, emission
      File.binwrite(helper, source.sub(emission, 'raise IOError, "fixture emission failure"'))
      stdout, stderr, status = run_suite(root)
      refute status.success?, stderr + stdout
      assert_includes stdout, "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
      assert_includes stderr, "Worker terminal result unavailable"
      assert_includes stderr, "Worker terminal results invalid"
    end
    extra = PASS_SOURCE + "\nMinitest.after_run { puts '1 runs, 1 assertions, 0 failures, 0 errors, 0 skips' }\n"
    with_fixture(source: extra) do |root|
      stdout, stderr, status = run_suite(root)
      assert status.success?, stderr + stdout
      assert_includes stdout, "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
      refute_includes stderr, "Worker terminal results invalid"
    end
  end

  # Real parent dispatch must retain each shard's distinct identity, even when
  # several worker threads are launched before the earlier children finish.
  def test_parent_validates_every_selected_worker_without_binding_collisions
    source = PASS_SOURCE + <<~'RUBY'
      class TerminalFixtureTest
        def test_second
          assert true
        end
        def test_third
          assert true
        end
      end
    RUBY
    with_fixture(source: source) do |root|
      stdout, stderr, status = run_suite(root)
      assert status.success?, stderr + stdout
      assert_includes stdout, "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips"
      refute_includes stderr, "Worker terminal results invalid"
    end
  end

  # Real parents reject each invalid worker even with a passing peer and forged
  # success text. Mutations affect only a disposable reporter after execution.
  def test_parent_refuses_invalid_evidence_with_passing_peers
    mutations = [
      'File.unlink(@path)',
      'File.write(@path, "{")',
      'File.open(@path, "a") { |file| file.write(JSON.generate(record)) }',
      'File.write(@path, JSON.generate(record.merge("run_id" => "b" * 32)))',
      'File.write(@path, JSON.generate(record.merge("selection_sha256" => "0" * 64)))',
      'File.write(@path, JSON.generate(record.merge("status" => "incomplete")))',
      'File.write(@path, JSON.generate(record.reject { |key, _| key == "assertions" }))',
      "Minitest.after_run { Process.kill('TERM', Process.pid) }", 'exit! 19'
    ]
    source = PASS_SOURCE + <<~'RUBY'
      class TerminalFixtureTest
        def test_peer
          assert true
        end
      end
      Minitest.after_run { puts '1 runs, 1 assertions, 0 failures, 0 errors, 0 skips' }
    RUBY
    mutations.each do |mutation|
      with_fixture(source: source) do |root|
        path = File.join(root, "bin", "af_test_suite_result.rb")
        helper = File.binread(path)
        # Match the producer line without depending on its indentation.
        emission = helper.lines.find { |line| line.include?('File.open(@path, "ab")') }.strip
        File.binwrite(path, helper.sub(emission, emission + "\n      #{mutation} if @identity[\"worker\"] == 1"))
        stdout, stderr, status = run_suite(root)
        refute status.success?, mutation + stdout + stderr
        assert_includes stderr, "Worker terminal results invalid", mutation
        assert_includes stdout, "0 failures, 0 errors, 0 skips", mutation
      end
    end
  end

  # Fixed counters survive absent worker summaries, failures/errors/skips,
  # filtering, and empty selections. The caller validates the public result.
  def test_public_result_equivalence_without_cosmetic_summaries
    source = MIXED_SOURCE + <<~'RUBY'
      class Minitest::SummaryReporter
        def report
          puts "cosmetic summary omitted"
        end
      end
    RUBY
    [[[], [4, 2, 1, 1, 1], false],
     [["--name", "test_pass"], [1, 1, 0, 0, 0], true],
     [["--name", "test_failure"], [1, 1, 1, 0, 0], false],
     [["--name", "test_error"], [1, 0, 0, 1, 0], false],
     [["--name", "test_skip"], [1, 0, 0, 0, 1], true],
     [["--name", "test_missing"], [0, 0, 0, 0, 0], false]].each do |arguments, totals, passed|
      with_fixture(source: source) do |root|
        AfTestSuiteHandoff.channel("fast") do |environment, read_result|
          stdout, stderr, status = run_suite(root, *arguments, environment: environment)
          assert_equal passed, status.success?, stdout + stderr
          record = read_result.call
          assert_equal totals, record.values_at(*AfTestSuiteHandoff::COUNTERS)
          assert_equal passed ? "passed" : "failed", record.fetch("status")
        end
      end
    end
  end

  # A genuinely empty inventory retains the existing filtered-worker nonzero
  # exit, with a valid zero-count result rather than invented success.
  def test_empty_population_has_exact_zero_counters_and_failed_status
    with_fixture(source: 'require "minitest/autorun"') do |root|
      AfTestSuiteHandoff.channel("fast") do |environment, read_result|
        stdout, stderr, status = run_suite(root, environment: environment)
        refute status.success?, stdout + stderr
        record = read_result.call
        assert_equal [0, 0, 0, 0, 0], record.values_at(*AfTestSuiteHandoff::COUNTERS)
        assert_equal "failed", record.fetch("status")
      end
    end
  end

  # Public consumers reject corrupt/ambiguous documents independently, and a
  # producer cannot overwrite a stale artifact even with identical counters.
  def test_public_handoff_rejects_invalid_documents_and_existing_paths
    AfTestSuiteHandoff.channel("fast") do |environment, read_result|
      AfTestSuiteHandoff.publish(environment, suite: "fast", totals: [1, 1, 0, 0, 0], success: true)
      path = environment.fetch(AfTestSuiteHandoff::PATH_KEY)
      original = File.binread(path)
      assert_equal "passed", read_result.call.fetch("status")
      assert_raises(Errno::EEXIST) do
        AfTestSuiteHandoff.publish(environment, suite: "fast", totals: [1, 1, 0, 0, 0], success: true)
      end
      record = JSON.parse(original)
      mutations = [{"schema" => "unknown"}, {"run_id" => "b" * 32}, {"suite" => "integration"},
        {"status" => "incomplete"}, {"tests" => 1.0}, {"assertions" => -1}, {"skips" => 2},
        {"errors" => 1}, {"failures" => true}, {"extra" => 0}]
      bytes = mutations.map { |change| JSON.generate(record.merge(change)) } +
        ["{", "[]", "null", original + original, original.sub('"tests":1', '"tests":0,"tests":1')]
      bytes.each do |document|
        File.binwrite(path, document)
        assert_raises(AfTestSuiteHandoff::InvalidResult) { read_result.call }
      end
      File.unlink(path)
      assert_raises(AfTestSuiteHandoff::InvalidResult) { read_result.call }
    end
  end

  private

  # Validates one actual child against separately fixed fixture expectations;
  # returns its parsed records or raises the production InvalidResult exception.
  def verify(worker)
    AfTestSuiteResult.verify!([worker.fetch(:path)], expected: [worker.fetch(:expected)],
      statuses: [worker.fetch(:status)])
  end

  # Creates a disposable runner and yields its root. Copies only test harness
  # collaborators, then removes all fixture files when the block finishes.
  def with_fixture(source: PASS_SOURCE, suite: "fast")
    Dir.mktmpdir("terminal-result-test-") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      Dir[File.join(File.dirname(RUNNER), "af_test_suite_*.rb")].each do |path|
        FileUtils.cp(path, File.join(root, "bin", File.basename(path)))
      end
      FileUtils.cp(RUNNER, File.join(root, "bin", "af-test-suite"))
      relative = suite == "integration" ? "test/integration/synthetic_test.rb" : "test/synthetic_test.rb"
      FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
      File.binwrite(File.join(root, relative), source)
      inventory = suite == "integration" ? [relative] : []
      File.write(File.join(root, "test", "integration.json"), JSON.generate(inventory))
      yield root
    end
  end

  # Runs an isolated worker and yields its process output and expected binding.
  # Defaults to one passing method; mixed results use their own fixed digest.
  def with_worker(selection: PASS_SELECTION, suite: "fast", source: PASS_SOURCE, &block)
    with_fixture(source: source, suite: suite) do |root|
      run_worker(root, selection: selection, suite: suite, &block)
    end
  end

  # Executes the real private worker entrypoint at seed 170 without auto-loaded
  # plugins. Yields OS status, captured diagnostics and independent expectations.
  def run_worker(root, selection: PASS_SELECTION, suite: "fast", source: nil)
    File.binwrite(File.join(root, "test", "synthetic_test.rb"), source) if source
    selection_path = File.join(root, "selection.json")
    path = File.join(root, "terminal.json")
    File.write(selection_path, JSON.generate(selection))
    identity = {"run_id" => "a" * 32, "suite" => suite, "worker" => 1,
                "population_sha256" => MIXED_FINGERPRINT,
                "selection_sha256" => selection == PASS_SELECTION ? PASS_FINGERPRINT : MIXED_FINGERPRINT}
    stdout, stderr, status = Open3.capture3({"COVERAGE" => nil}, RbConfig.ruby,
      File.join(root, "bin", "af-test-suite"), "--worker", selection_path, path,
      JSON.generate(identity), "--suite", suite, "--seed", "170", "--verbose", "--no-plugins", chdir: root)
    yield(path: path, expected: identity.merge("tests" => selection.length),
      stdout: stdout, stderr: stderr, status: status)
  end

  # Runs the public functional runner on the one-method fixture with captured
  # plain output, returning stdout, stderr and the unmodified process status.
  def run_suite(root, *arguments, environment: {})
    Open3.capture3({"COVERAGE" => nil, "AF_TEST_PROGRESS_FORMAT" => "text",
                   "AF_TEST_PROGRESS_RENDERER" => "text"}.merge(environment), RbConfig.ruby,
      File.join(root, "bin", "af-test-suite"), "--seed", "170", *arguments, chdir: root)
  end
end
