# frozen_string_literal: true

require "minitest/test_task"
require "open3"
require_relative "bin/af_test_suite_selection"
require_relative "bin/af_test_suite_progress"
require_relative "bin/af_test_suite_handoff"

# Consume the outer request once; nested health commands cannot overwrite it.
TEST_RESULT_REQUEST = [AfTestSuiteHandoff::PATH_KEY, AfTestSuiteHandoff::ID_KEY].to_h { |key| [key, ENV.delete(key)] }

TEST_RUNTIME_WARN_SECONDS = 20.0
TEST_RUNTIME_FAIL_SECONDS = 24.0
TEST_RUNTIME_CONTENTION_MULTIPLIER = 1.25
TEST_RUNTIME_ACTIVE_MULTIPLIER =
  ENV["AF_TEST_CONTENDED"] == "1" ? TEST_RUNTIME_CONTENTION_MULTIPLIER : 1.0
TEST_RUNTIME_ACTIVE_WARN_SECONDS = TEST_RUNTIME_WARN_SECONDS * TEST_RUNTIME_ACTIVE_MULTIPLIER
TEST_RUNTIME_ACTIVE_FAIL_SECONDS = TEST_RUNTIME_FAIL_SECONDS * TEST_RUNTIME_ACTIVE_MULTIPLIER
TEST_HEALTH_RESULTS = {}
TEST_HEALTH_ERRORS = {}
TEST_HEALTH_MUTEX = Mutex.new

# Only public fast-test invocations select animation automatically. Nested
# captured processes still use the unchanged JSON protocol.
AfTestSuiteProgress.automatic_fast =
  !(Rake.application.top_level_tasks & %w[default test:contract test:runtime test test:coverage]).empty?
TEST_PROGRESS_OWNER_TASK = Rake.application.top_level_tasks.find { |name|
  %w[default test:contract test:runtime test:integration].include?(name)
}
TEST_PROGRESS_COMPLETION = if TEST_PROGRESS_OWNER_TASK
  integration = TEST_PROGRESS_OWNER_TASK == "test:integration"
  AfTestSuiteProgress::Completion.new(suite: integration ? "integration" : "fast",
    phase: TEST_PROGRESS_OWNER_TASK == "test:runtime" ? "runtime check" : "test contract")
end

def full_test_contract?
  !(Rake.application.top_level_tasks & %w[default test:contract]).empty?
end

# Captures one observed suite invocation while preserving child return values,
# exceptions and diagnostics. Invalid evidence prevents a partial public total.
def capture_suite_result(suite, key: :functional_result)
  AfTestSuiteHandoff.channel(suite) do |environment, read_result|
    begin
      yield environment
    ensure
      child_error = $!
      begin
        TEST_HEALTH_RESULTS[key] = read_result.call
      rescue AfTestSuiteHandoff::InvalidResult => error
        TEST_HEALTH_RESULTS[:accounting_invalid] = true
        warn error.message
        raise unless child_error
      end
    end
  end
end

# Captures a quiet execution and includes its counts only when its process
# fails and the existing presentation exposes that distinct population.
# Invalid required evidence prevents every partial public total.
def capture_exposed_result(suite, key:)
  AfTestSuiteHandoff.channel(suite) do |environment, read_result|
    execution = yield environment
    unless execution.last.success?
      begin
        TEST_HEALTH_MUTEX.synchronize { TEST_HEALTH_RESULTS[key] = read_result.call }
      rescue AfTestSuiteHandoff::InvalidResult => error
        TEST_HEALTH_MUTEX.synchronize { TEST_HEALTH_RESULTS[:accounting_invalid] = true }
        warn error.message
      end
    end
    execution
  end
end

# Retains Minitest's file selection, concurrency, options, timing and diagnostics
# while assigning every isolated child its own consumed result channel. Only
# failed files are historically exposed by this task; successful peers add none.
def capture_isolated_results(test_task, suite)
  Rake::Task["#{test_task.name}:isolated"].clear_actions
  task "#{test_task.name}:isolated" do
    tests = Dir[*test_task.test_globs].uniq
    bad, good, count = {}, [], (ENV.delete("K") || 3).to_i
    file = ENV.delete("F")
    times = {}
    records = []
    started = Time.now
    count.threads_do tests.sort do |path|
      child_started = Time.now
      execution = nil
      AfTestSuiteHandoff.channel(suite) do |environment, read_result|
        execution = Open3.capture2e(environment.merge("AFDP_STANDALONE_SUITE" => suite),
          "#{Gem.ruby} -r./bin/af_test_standalone_result #{test_task.make_test_cmd(path)}")
        times[path] = Time.now - child_started
        if execution.last.success?
          $stderr.print "."
          good << path
        else
          $stderr.print "x"
          bad[path] = execution.first
          begin
            records << read_result.call
          rescue AfTestSuiteHandoff::InvalidResult => error
            TEST_HEALTH_RESULTS[:accounting_invalid] = true
            warn error.message
          end
        end
      end
    end
    totals = AfTestSuiteHandoff::COUNTERS.to_h { |key| [key, records.sum { |record| record.fetch(key) }] }
    TEST_HEALTH_RESULTS[:isolated_result] = totals.merge("suite" => suite, "status" => bad.empty? ? "passed" : "failed")
    puts "done"
    puts "Ran in %.2f seconds" % [Time.now - started]
    File.open(file, "w") { |output| output.puts JSON.pretty_generate(times) } if file
    unless good.empty?
      puts "\n# Good tests:\n\n"
      good.sort.each { |path| puts "%.2fs: %s" % [times[path], path] }
    end
    unless bad.empty?
      puts "\n# Bad tests:\n\n"
      bad.keys.sort.each { |path| puts "%.2fs: %s" % [times[path], path] }
      puts "\n# Bad Test Output:"
      bad.sort.each do |path, output|
        puts "\n# #{path}:"
        puts output
      end
      exit 1
    end
  end
end

suite_test_task = Minitest::TestTask.create do |t|
  t.test_globs = AfTestSuiteSelection.files(__dir__, "fast")
  t.test_prelude = %(require "simplecov"; SimpleCov.start) if ENV["COVERAGE"]
end

capture_isolated_results(suite_test_task, "fast")

# The generated dependency/slow tasks retain their Minitest behavior. The
# runtime gate times discovery, worker startup, and result accounting.
Rake::Task["test"].clear_actions
task "test" do
  arguments = suite_test_task.extra_args
  ruby_options = ["-I#{suite_test_task.libs.join(File::PATH_SEPARATOR)}"]
  ruby_options << "-w" if suite_test_task.warning
  capture_suite_result("fast") do |environment|
    sh environment, RbConfig.ruby, *ruby_options, "bin/af-test-suite", *arguments
  end
end

# The isolated/dependency tasks use the same public inventory as the runner.
integration_test_task = Minitest::TestTask.create "test:integration:functional" do |t|
  t.test_globs = AfTestSuiteSelection.files(__dir__, "integration")
end
capture_isolated_results(integration_test_task, "integration")
Rake::Task["test:integration:functional"].clear_actions
task "test:integration:functional" do
  environment = TEST_PROGRESS_COMPLETION&.interactive? ? {"AFDP_TEST_RESULT_OWNER" => "rake"} : {}
  capture_suite_result("integration") do |result_environment|
    sh environment.merge(result_environment), RbConfig.ruby, "-Ilib:test:.", "-w", "bin/af-test-suite", "--suite", "integration"
  end
end

desc "Run fresh coverage over the complete fast and integration population"
task "test:coverage:full" do
  capture_suite_result("all") do |environment|
    sh environment.merge("COVERAGE" => "1"), RbConfig.ruby, "-Ilib:test:.", "-w", "bin/af-test-suite", "--suite", "all"
  end
end

# These checks use independent processes and disposable fixtures. Capture each
# output separately so concurrent writes cannot corrupt public run accounting.
task "test:integration:health" do
  results = %w[test:integration:functional:deps test:coverage:full].map do |name|
    Thread.new do
      execution = if name == "test:coverage:full"
        capture_suite_result("all", key: :coverage_result) do |environment|
          AfTestSuiteProgress.capture3(environment, "bundle", "exec", "rake", name, phase: name, suite: "integration")
        end
      else
        capture_exposed_result("integration", key: :deps_result) do |environment|
          AfTestSuiteProgress.capture3(environment, "bundle", "exec", "rake", name, phase: name, suite: "integration")
        end
      end
      [name, *execution]
    end
  end.map(&:value)
  results.each do |name, stdout, stderr, _status|
    puts "#{name}:"
    $stdout.write(stdout)
    $stderr.write(stderr)
  end
  abort "integration validation health checks failed" unless results.all? { |result| result.last.success? }
end

task "test:integration:start" do
  TEST_HEALTH_RESULTS[:integration_started] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

desc "Run designated integration workflows, independence, and the full coverage ratchet"
task "test:integration" => ["test:integration:start", "test:integration:functional", "test:integration:health"] do
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - TEST_HEALTH_RESULTS.fetch(:integration_started)
  puts format("Integration validation finished in %.3fs.", elapsed)
end

desc "Check structural Minitest test quality"
task "test:lint" do
  sh "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "test"
end

desc "Run tests with line and branch coverage"
task "test:coverage" do
  sh({ "COVERAGE" => "1" }, "bundle", "exec", "rake", "test")
end

desc "Measure current coverage and initialize the committed ratchet baseline"
task "test:coverage:baseline" => "test:coverage:full" do
  sh({ "AF_COVERAGE_REPORT" => "coverage/full" }, "bundle", "exec", "simplecov", "ratchet", "--init")
end

desc "Run scale-sensitive algorithm benchmarks"
task "test:bench" do
  sh "bundle", "exec", "ruby", "-Ilib:test", "bench/horizontal_discovery_v1_benchmark.rb"
end

task "test:bench:quiet" do
  stdout, stderr, status = capture_exposed_result("fast", key: :bench_result) do |environment|
    AfTestSuiteProgress.capture3(environment.merge("AFDP_STANDALONE_SUITE" => "fast"),
      "bundle", "exec", "ruby", "-Ilib:test", "-r./bin/af_test_standalone_result",
      "bench/horizontal_discovery_v1_benchmark.rb", phase: "algorithm benchmark")
  end
  combined = [stdout, stderr].reject(&:empty?).join

  unless status.success?
    $stdout.write(combined)
    puts unless combined.empty? || combined.end_with?("\n")
    abort "scale-sensitive benchmark failed"
  end

  TEST_HEALTH_RESULTS[:bench] =
    "test:bench: Horizontal Discovery package extraction scaling guard passed"
end

desc "Run the test suite and enforce the local runtime budget"
task "test:runtime" do
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  status = nil

  progress = AfTestSuiteProgress::Reporter.new(phase: "runtime check", suite: "fast")
  interactive = progress.interactive?
  progress.start if interactive
  environment = interactive ? {"AF_TEST_PROGRESS_FORMAT" => "json"} : {}
  begin
    AfTestSuiteHandoff.channel("fast") do |result_environment, read_result|
      Open3.popen2e(environment.merge(result_environment), "bundle", "exec", "rake", "test") do |_stdin, stream, wait_thread|
        current_line = +""
        suppress_next_blank = false

        display = lambda do |chunk|
          visible = +""

          chunk.each_char do |char|
            if suppress_next_blank
              if char == "\n"
                suppress_next_blank = false
                next
              end
              suppress_next_blank = false
            end

            visible << char

            if char == "\n"
              suppress_next_blank = current_line.start_with?("Finished in ")
              current_line.clear
            else
              current_line << char
            end
          end

          if interactive
            progress.diagnostic(visible) do
              print visible
              $stdout.flush
            end
          else
            print visible
            $stdout.flush
          end
        end
        telemetry = AfTestSuiteProgress::Stream.new(progress, relay: true, diagnostic: display) if interactive
        begin
          loop do
            chunk = stream.readpartial(4096)
            interactive ? telemetry.read(chunk) : display.call(chunk)
          end
        rescue EOFError
          telemetry&.finish
        end

        status = wait_thread.value
        record = read_result.call
        TEST_HEALTH_RESULTS[:functional_result] = record
        if interactive && TEST_PROGRESS_COMPLETION
          TEST_PROGRESS_COMPLETION.record(workers: progress.worker_counts, tests: record.fetch("tests"))
        end
        abort "test suite failed before runtime could be accepted" unless record["status"] == "passed"
      end
    end
  ensure
    progress.finish(status&.success? ? "finished" : "failed") if interactive
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  abort "test suite failed before runtime could be accepted" unless status.success?

  TEST_HEALTH_RESULTS[:runtime] = format(
    "Test suite runtime %.3fs (warn %ss, fail %ss)",
    elapsed,
    TEST_RUNTIME_ACTIVE_WARN_SECONDS,
    TEST_RUNTIME_ACTIVE_FAIL_SECONDS
  )

  if elapsed >= TEST_RUNTIME_ACTIVE_FAIL_SECONDS
    failure = format(
      "FAILURE: test suite runtime %.3fs reached hard ceiling %ss",
      elapsed,
      TEST_RUNTIME_ACTIVE_FAIL_SECONDS
    )

    if full_test_contract?
      TEST_HEALTH_RESULTS[:runtime_failure] = failure
    else
      abort failure
    end
  elsif elapsed >= TEST_RUNTIME_ACTIVE_WARN_SECONDS
    warning = format(
      "WARNING: test suite runtime %.3fs reached warning threshold %ss",
      elapsed,
      TEST_RUNTIME_ACTIVE_WARN_SECONDS
    )

    if full_test_contract?
      TEST_HEALTH_RESULTS[:runtime_warning] = warning
    else
      warn warning
    end
  elsif !full_test_contract?
    puts TEST_HEALTH_RESULTS.fetch(:runtime)
  end
end

task "test:lint:quiet" do
  stdout, stderr, status = AfTestSuiteProgress.capture3(
    "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "test", phase: "test quality lint"
  )

  TEST_HEALTH_MUTEX.synchronize do
    if status.success?
      match = stdout.match(/(\d+) files inspected, no offenses detected/)
      if match
        TEST_HEALTH_RESULTS[:lint] =
          "test:lint: #{match[1]} files inspected, no offenses detected"
      else
        TEST_HEALTH_RESULTS[:lint] = "test:lint: structural quality check passed"
      end
    else
      TEST_HEALTH_ERRORS[:lint] = [stdout, stderr].reject(&:empty?).join
    end
  end
end

task "test:deps:quiet" do
  stdout, stderr, status = capture_exposed_result("fast", key: :deps_result) do |environment|
    AfTestSuiteProgress.capture3(environment, "bundle", "exec", "rake", "test:deps", phase: "test independence", suite: "fast")
  end

  TEST_HEALTH_MUTEX.synchronize do
    if status.success?
      TEST_HEALTH_RESULTS[:deps] = "test:deps: no broken dependencies found"
    else
      TEST_HEALTH_ERRORS[:deps] = [stdout, stderr].reject(&:empty?).join
    end
  end
end

task "test:coverage:quiet" do
  stdout, stderr, status = capture_exposed_result("fast", key: :quiet_coverage_result) do |environment|
    AfTestSuiteProgress.capture3(environment.merge("COVERAGE" => "1"),
      "bundle", "exec", "rake", "test", phase: "coverage check", suite: "fast")
  end
  combined = [stdout, stderr].reject(&:empty?).join

  TEST_HEALTH_MUTEX.synchronize do
    if status.success?
      coverage_lines = combined.lines.grep(
        /\A(?:Coverage report generated|Line coverage:|Branch coverage:)/
      ).map(&:chomp)

      TEST_HEALTH_RESULTS[:coverage] = coverage_lines
    else
      TEST_HEALTH_ERRORS[:coverage] = combined
    end
  end
end

desc "Run independent post-suite health checks in parallel"
multitask "test:health:parallel" => [
  "test:deps:quiet",
  "test:lint:quiet",
  "test:coverage:quiet"
]

task "test:health" do
  AfTestSuiteProgress.phase("secondary health checks") do
    Rake::Task["test:health:parallel"].invoke
  end
end

desc "Run the complete test-suite contract"
task "test:contract" => ["test:runtime", "test:bench:quiet", "test:health"] do
  TEST_HEALTH_RESULTS.fetch(:coverage, []).each { |line| puts line }
  puts TEST_HEALTH_RESULTS.fetch(:runtime)
  puts TEST_HEALTH_RESULTS.fetch(:bench)
  puts TEST_HEALTH_RESULTS[:lint] if TEST_HEALTH_RESULTS[:lint]
  puts TEST_HEALTH_RESULTS[:deps] if TEST_HEALTH_RESULTS[:deps]

  unless TEST_HEALTH_ERRORS.empty?
    puts
    TEST_HEALTH_ERRORS.each_value do |output|
      $stdout.write(output)
      puts unless output.end_with?("\n")
    end
    puts
    puts "FAILURE: secondary test-health checks failed"
    puts
    exit(false)
  end

  if (failure = TEST_HEALTH_RESULTS[:runtime_failure])
    puts
    puts failure
    puts
    exit(false)
  elsif (warning = TEST_HEALTH_RESULTS[:runtime_warning])
    puts
    puts warning
  end

  puts
end

task default: "test:contract"

# Rake prints its own exception diagnostics before exiting. The presentation
# owner runs last, after those diagnostics and all public contract summaries.
if TEST_PROGRESS_COMPLETION
  completed = false
  Rake::Task[TEST_PROGRESS_OWNER_TASK].enhance { completed = true }
  at_exit do
    error = $!
    TEST_PROGRESS_COMPLETION.finish(success: completed &&
      (error.nil? || error.is_a?(SystemExit) && error.success?))
  end
end

# Publishes once after the requested public task and all its gates have ended.
# A later runtime/health exception vetoes success without discarding valid counts.
if TEST_RESULT_REQUEST[AfTestSuiteHandoff::PATH_KEY]
  result_task = Rake.application.top_level_tasks.first || "default"
  result_completed = false
  Rake::Task.define_task(result_task).enhance { result_completed = true }
  at_exit do
    error = $!
    if (record = TEST_HEALTH_RESULTS[:functional_result] || TEST_HEALTH_RESULTS[:isolated_result]) && !TEST_HEALTH_RESULTS[:accounting_invalid]
      # Distinct executions exposed by the original task policy contribute once.
      # Quiet successes and worker/aggregate duplicate presentations add none.
      records = [record, *TEST_HEALTH_RESULTS.values_at(:coverage_result,
        :bench_result, :deps_result, :quiet_coverage_result)].compact
      totals = AfTestSuiteHandoff::COUNTERS.map { |key| records.sum { |entry| entry.fetch(key) } }
      AfTestSuiteHandoff.publish(TEST_RESULT_REQUEST, suite: record.fetch("suite"),
        totals: totals,
        success: result_completed && records.all? { |entry| entry["status"] == "passed" } &&
          (error.nil? || error.is_a?(SystemExit) && error.success?))
    end
  end
end
