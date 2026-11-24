# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "timeout"
require "pty"
require "io/console"
require "rbconfig"
require_relative "../bin/af_test_suite_progress"

class TestSuiteProgressTest < Minitest::Test
  HELPER = File.expand_path("../bin/af_test_suite_progress.rb", __dir__)

  class QueueOutput < StringIO
    attr_reader :events

    def initialize
      super
      @events = Queue.new
    end

    def puts(line)
      super
      @events << JSON.parse(line.delete_prefix(AfTestSuiteProgress::PREFIX))
    end
  end

  def test_heartbeat_distinguishes_output_from_completed_workers
    now = 0.0
    output = StringIO.new
    progress = AfTestSuiteProgress::Reporter.new(phase: "functional tests", suite: "fast",
      workers: 12, output: output, format: "json", clock: -> { now }).start(threaded: false)
    now = 5.0
    progress.heartbeat
    progress.activity
    now = 10.0
    progress.heartbeat
    progress.worker_finished(1, "failed")
    progress.finish
    events = records(output.string)
    assert_equal [0, 0, 0, 1, 1], events.map { |event| event.fetch("workers_finished") }
    assert_nil events[1].fetch("child_output_age_seconds")
    assert_equal 5.0, events[2].fetch("child_output_age_seconds")
    assert_equal 10.0, events[2].fetch("elapsed_seconds")
    assert_equal "failed", events[3].fetch("outcome")
  end

  def test_twelve_concurrent_completion_events_have_bounded_atomic_output
    output = StringIO.new
    progress = AfTestSuiteProgress::Reporter.new(phase: "functional tests", workers: 12,
      output: output, format: "json").start(threaded: false)
    threads = (1..12).map { |worker| Thread.new { progress.worker_finished(worker, "passed") } }
    threads.each(&:join)
    progress.finish
    events = records(output.string)
    assert_equal 14, events.length
    assert_equal (1..12).to_a, events.select { |event| event["worker"] }.map { |event| event.fetch("worker") }.sort
    assert_equal (1..12).to_a, events.select { |event| event["worker"] }.map { |event| event.fetch("workers_finished") }
    assert_equal 12, events.last.fetch("workers_finished")
  end

  def test_text_output_is_plain_and_does_not_claim_heartbeat_means_useful_work
    output = StringIO.new
    progress = AfTestSuiteProgress::Reporter.new(phase: "coverage tests", suite: "all",
      output: output, format: "text").start(threaded: false)
    progress.heartbeat
    progress.finish
    assert_includes output.string, "parent alive, useful child work unknown"
    assert_includes output.string, "no child output observed"
    refute_match(/[\e\r]/, output.string)
    refute_match(/\d+ runs, \d+ assertions/, output.string)
    assert_equal 3, output.string.lines.length
  end

  def test_split_records_relay_without_contaminating_diagnostics
    output = StringIO.new
    progress = AfTestSuiteProgress::Reporter.new(phase: "coverage check", output: output,
      format: "json").start(threaded: false)
    stream = AfTestSuiteProgress::Stream.new(progress, relay: true)
    wire = event_line
    stream.read("original diagnostics\n" + wire[0, 11])
    stream.read(wire[11..] + "1 runs, 2 assertions, 0 failures, 0 errors, 0 skips\n")
    assert_equal "original diagnostics\n1 runs, 2 assertions, 0 failures, 0 errors, 0 skips\n", stream.finish
    assert_equal "child phase", records(output.string).last.fetch("phase")
  ensure
    progress&.finish
  end

  def test_malformed_truncated_and_oversized_records_remain_diagnostics
    output = StringIO.new
    progress = AfTestSuiteProgress::Reporter.new(phase: "coverage check", output: output,
      format: "json").start(threaded: false)
    bad = AfTestSuiteProgress::PREFIX + "{broken}\n"
    long = "x" * 10_000 + "\n"
    truncated = event_line.chomp
    stream = AfTestSuiteProgress::Stream.new(progress, relay: true)
    stream.read(bad + long)
    stream.read(truncated)
    assert_equal bad + long + truncated, stream.finish
    assert_equal 1, records(output.string).count { |event| event["event"] == "telemetry_invalid" }
    refute AfTestSuiteProgress.decode(event_line.sub('"elapsed_seconds":0.0', '"elapsed_seconds":-1'))
    refute AfTestSuiteProgress.decode(event_line.sub('"schema":"afdp-test-progress/v1"', '"schema":"unknown"'))
    refute AfTestSuiteProgress.decode(AfTestSuiteProgress::PREFIX + JSON.generate(event_data.merge("worker" => 99)) + "\n")
    refute AfTestSuiteProgress.decode(AfTestSuiteProgress::PREFIX + "x" * 5000 + "\n")
  ensure
    progress&.finish
  end

  def test_phase_failure_and_ticker_cleanup_preserve_original_exception
    output = StringIO.new
    assert_raises(ArgumentError) do
      AfTestSuiteProgress.phase("coverage slice verification", output: output, format: "json") do
        raise ArgumentError, "original failure"
      end
    end
    assert_equal "failed", records(output.string).last.fetch("event")
    progress = AfTestSuiteProgress::Reporter.new(phase: "test independence", output: output, format: "json").start
    Timeout.timeout(2) { progress.finish }
    assert_equal "finished", records(output.string).last.fetch("event")
  end

  def test_real_capture_forwards_child_progress_before_exit_and_retains_failures
    output = QueueOutput.new
    progress = AfTestSuiteProgress::Reporter.new(phase: "coverage check", output: output,
      format: "json").start(threaded: false)
    reader, writer = IO.pipe
    script = <<~'RUBY'
      require ARGV.fetch(0)
      p = AfTestSuiteProgress::Reporter.new(phase: "child phase", format: "json", output: $stdout).start(threaded: false)
      IO.for_fd(Integer(ENV.fetch("GATE_FD"))).read(1)
      puts "original stdout"
      warn "original failing diagnostic"
      p.finish
      exit 7
    RUBY
    descriptors = {reader.fileno => reader}
    thread = Thread.new do
      AfTestSuiteProgress.capture3({"GATE_FD" => reader.fileno.to_s}, RbConfig.ruby,
        "-e", script, HELPER, reporter: progress, **descriptors)
    end
    child_event = Timeout.timeout(3) do
      loop do
        event = output.events.pop
        break event if event["phase"] == "child phase"
      end
    end
    assert_equal "start", child_event.fetch("event")
    assert thread.alive?, "child must still be awaiting release"
    writer.write(".")
    stdout, stderr, status = Timeout.timeout(3) { thread.value }
    assert_equal "original stdout\n", stdout
    assert_equal "original failing diagnostic\n", stderr
    assert_equal 7, status.exitstatus
    refute status.success?
  ensure
    writer&.close
    thread&.join(3)
    reader&.close
    progress&.finish
  end

  def test_silent_live_child_retains_unknown_work_empty_output_and_zero_exit
    output = StringIO.new
    progress = AfTestSuiteProgress::Reporter.new(phase: "test independence", output: output,
      format: "json").start(threaded: false)
    reader, writer = IO.pipe
    ready_reader, ready_writer = IO.pipe
    descriptors = {reader.fileno => reader, ready_writer.fileno => ready_writer}
    script = 'IO.for_fd(Integer(ENV.fetch("READY_FD"))).syswrite("."); IO.for_fd(Integer(ENV.fetch("GATE_FD"))).read(1)'
    thread = Thread.new do
      AfTestSuiteProgress.capture3({"GATE_FD" => reader.fileno.to_s, "READY_FD" => ready_writer.fileno.to_s},
        RbConfig.ruby, "-e", script, reporter: progress, **descriptors)
    end
    assert_equal ".", Timeout.timeout(3) { ready_reader.read(1) }
    progress.heartbeat
    assert thread.alive?, "silent child must still be awaiting release"
    assert_nil records(output.string).last.fetch("child_output_age_seconds")
    assert_equal 0, records(output.string).last.fetch("workers_finished")
    writer.write(".")
    stdout, stderr, status = Timeout.timeout(3) { thread.value }
    assert_equal "", stdout
    assert_equal "", stderr
    assert status.success?
  ensure
    writer&.close
    thread&.join(3)
    reader&.close
    ready_reader&.close
    ready_writer&.close
    progress&.finish
  end

  def test_tty_opt_in_worker_counts_elapsed_time_and_cleanup
    with_terminal do |output|
      now = 0.0
      progress = tty_reporter(output, phase: "functional tests", suite: "fast", workers: 12,
        clock: -> { now }).start(threaded: false)
      assert progress.interactive?
      now = 5.0
      progress.heartbeat
      (1..8).each { |worker| progress.worker_finished(worker, "passed") }
      text = terminal_text
      assert_includes text, "fast / functional tests"
      assert_includes text, "workers 0/12"
      assert_includes text, "workers 8/12"
      assert_includes text, "5.0s"
      assert_includes text, "useful child work unknown"
      refute_match(/percent|ETA|coverage:|\d+ runs, \d+ assertions/, text)
      progress.finish
      assert_match(/\e\[2K\z/, terminal_text)
      output.puts "final diagnostics"
      assert_equal "final diagnostics\n", terminal_text
    end
  end

  def test_default_tty_non_tty_and_json_precedence
    with_terminal do |output|
      progress = tty_reporter(output, renderer: nil).start(threaded: false)
      refute progress.interactive?
      progress.finish
      refute_match(/\e/, terminal_text)
      progress = tty_reporter(output, format: "json").start(threaded: false)
      refute progress.interactive?
      progress.worker_finished(1, "failed")
      progress.finish
      text = terminal_text
      refute_match(/\e/, text)
      events = records(text)
      assert_equal %w[start worker_finished finished], events.map { |event| event["event"] }
      assert_equal "failed", events[1]["outcome"]
      assert events.all? { |event| AfTestSuiteProgress.decode(AfTestSuiteProgress::PREFIX + JSON.generate(event) + "\n") }
    end
    output = StringIO.new
    progress = tty_reporter(output).start(threaded: false)
    refute progress.interactive?
    progress.heartbeat
    progress.finish
    assert_equal 3, output.string.lines.length
    refute_match(/[\e\r]/, output.string)
  end

  def test_indeterminate_concurrent_phases_share_a_row_and_keep_worker_group_visible
    with_terminal do |output|
      lint = tty_reporter(output, phase: "test quality lint", workers: nil).start(threaded: false)
      deps = tty_reporter(output, phase: "test independence", workers: nil).start(threaded: false)
      lint.heartbeat
      text = terminal_text
      assert_includes text, "indeterminate"
      assert_includes text, "<=>"
      assert_includes text, "+1 phases"
      workers = tty_reporter(output, phase: "coverage tests", suite: "all", workers: 4).start(threaded: false)
      workers.worker_finished(1, "passed")
      lint.heartbeat
      text = terminal_text
      assert_includes text, "all / coverage tests"
      assert_includes text, "workers 1/4"
      assert_includes text, "+2 phases"
      refute_match(/\e\[\d+[AB]/, text) # No multi-row cursor movement.
      threads = (2..4).map { |worker| Thread.new { workers.worker_finished(worker, "passed") } }
      threads.each(&:join)
      assert_includes terminal_text, "workers 4/4"
      workers.finish
      deps.finish
      lint.finish
      assert_match(/\e\[2K\z/, terminal_text)
    end
  end

  def test_failed_and_invalid_workers_have_permanent_notices_and_completed_counts
    with_terminal do |output|
      progress = tty_reporter(output, workers: 3).start(threaded: false)
      progress.worker_finished(1, "failed")
      progress.worker_finished(2, "invalid")
      progress.worker_finished(3, "passed")
      progress.finish("failed")
      text = terminal_text
      assert_includes text, "worker 1 failed\n"
      assert_includes text, "worker 2 invalid\n"
      assert_includes text, "workers 3/3"
      assert_includes text, "!2"
      assert_includes text, "functional tests: failed\n"
      refute_includes text, "success"
    end
  end

  def test_tty_nested_records_validate_and_sanitize_labels_without_losing_diagnostics
    with_terminal do |output|
      progress = tty_reporter(output, workers: nil).start(threaded: false)
      stream = AfTestSuiteProgress::Stream.new(progress, relay: true)
      malicious = event_data.merge("phase" => "child\a\t:percent\0")
      wire = AfTestSuiteProgress::PREFIX + JSON.generate(malicious) + "\n"
      bad = AfTestSuiteProgress::PREFIX + "{broken}\n"
      truncated = event_line.chomp
      stream.read(wire[0, 11])
      stream.read(wire[11..] + bad + "original warning\n" + truncated)
      assert_equal bad + "original warning\n" + truncated, stream.finish
      progress.finish
      text = terminal_text
      assert_includes text, "telemetry_invalid"
      refute_match(/[\a\t\0]/, text)
      refute_includes text, ":percent"
      refute_match(/\d+%/, text)
    end
  end

  def test_terminal_failure_missing_gem_and_unsupported_terminal_fall_back
    with_terminal do |output|
      AfTestSuiteProgress.stub(:require, ->(*) { raise LoadError, "synthetic unavailable gem" }) do
        progress = tty_reporter(output).start(threaded: false)
        refute progress.interactive?
        progress.finish
      end
      refute_match(/\e/, terminal_text)
      output.winsize = [24, 40]
      progress = tty_reporter(output).start(threaded: false)
      refute progress.interactive?
      progress.finish
      refute_match(/\e/, terminal_text)
      output.winsize = [24, 140]
      progress = tty_reporter(output)
      TTY::ProgressBar.stub(:new, ->(*) { raise ArgumentError, "synthetic rendering failure" }) do
        progress.start(threaded: false)
        progress.worker_finished(1, "failed")
        progress.finish("failed")
      end
      text = terminal_text
      assert_includes text, "worker 1 failed"
      assert_includes text, "failed; elapsed"
    end
  end

  def test_partial_diagnostics_are_not_erased_or_overwritten_by_heartbeats
    with_terminal do |output|
      progress = tty_reporter(output).start(threaded: false)
      terminal_text
      progress.diagnostic("original ") { output.print "original " }
      progress.heartbeat
      text = terminal_text
      assert text.end_with?("original ")
      progress.diagnostic("warning\n") { output.print "warning\n" }
      progress.heartbeat
      text = terminal_text
      assert text.start_with?("warning\n")
      assert_includes text, "workers 0/2"
      progress.finish
    end
  end

  def test_tty_phase_exception_still_preserves_original_failure
    with_terminal do |output|
      error = assert_raises(ArgumentError) do
        AfTestSuiteProgress.phase("coverage slice verification", output: output, renderer: "tty", format: "text") do
          raise ArgumentError, "original failure"
        end
      end
      assert_equal "original failure", error.message
      assert_includes terminal_text, "coverage slice verification: failed"
    end
  end

  def test_default_fast_tty_renderer_and_explicit_overrides_are_isolated
    with_terminal do |output|
      with_progress_environment("AF_TEST_PROGRESS_RENDERER" => nil, "AF_TEST_PROGRESS_FORMAT" => nil) do
        progress = AfTestSuiteProgress::Reporter.new(phase: "functional tests", suite: "fast", output: output).start(threaded: false)
        assert progress.interactive?
        progress.finish
        assert_includes terminal_text, "indeterminate"
        ENV["AF_TEST_PROGRESS_RENDERER"] = "text"
        progress = AfTestSuiteProgress::Reporter.new(phase: "functional tests", suite: "fast", output: output).start(threaded: false)
        refute progress.interactive?
        progress.finish
        refute_match(/\e/, terminal_text)
        ENV.delete("AF_TEST_PROGRESS_RENDERER")
        ENV["AF_TEST_PROGRESS_FORMAT"] = "json"
        progress = AfTestSuiteProgress::Reporter.new(phase: "functional tests", suite: "fast", output: output).start(threaded: false)
        refute progress.interactive?
        progress.finish("failed")
        events = records(terminal_text)
        assert_equal %w[start failed], events.map { |event| event["event"] }
        ENV.delete("AF_TEST_PROGRESS_FORMAT")
        progress = AfTestSuiteProgress::Reporter.new(phase: "functional tests", suite: "integration", output: output).start(threaded: false)
        refute progress.interactive?
        progress.finish
        refute_match(/\e/, terminal_text)
      end
    end
    with_progress_environment("AF_TEST_PROGRESS_RENDERER" => nil, "AF_TEST_PROGRESS_FORMAT" => nil) do
      output = StringIO.new
      progress = AfTestSuiteProgress::Reporter.new(phase: "functional tests", suite: "fast", output: output).start(threaded: false)
      refute progress.interactive?
      progress.finish
      refute_match(/[\e\r]/, output.string)
    end
  end

  def test_explicit_json_failure_precedence_over_tty_preserves_protocol
    with_terminal do |output|
      error = assert_raises(ArgumentError) do
        AfTestSuiteProgress.phase("coverage slice verification", output: output, renderer: "tty", format: "json") do
          raise ArgumentError, "original JSON failure"
        end
      end
      assert_equal "original JSON failure", error.message
      text = terminal_text
      refute_match(/\e|\| PASS|\| FAIL/, text)
      events = records(text)
      assert_equal %w[start failed], events.map { |event| event["event"] }
      assert events.all? { |event| AfTestSuiteProgress.decode(AfTestSuiteProgress::PREFIX + JSON.generate(event) + "\n") }
    end
  end

  private

  def with_progress_environment(values)
    previous = values.to_h { |key, _| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def tty_reporter(output, **options)
    AfTestSuiteProgress::Reporter.new(phase: "functional tests", workers: 2,
      output: output, renderer: "tty", format: "text", **options)
  end

  def with_terminal
    original_term = ENV["TERM"]
    ENV["TERM"] = "xterm"
    PTY.open do |reader, output|
      output.winsize = [24, 140]
      @terminal_reader = reader
      yield output
    ensure
      @terminal_reader = nil
    end
  ensure
    ENV["TERM"] = original_term
  end

  def terminal_text
    text = +""
    loop { text << @terminal_reader.read_nonblock(4096) }
  rescue IO::WaitReadable
    text.gsub("\r\n", "\n")
  end

  def event_data
    {"schema" => AfTestSuiteProgress::SCHEMA, "event" => "start", "phase" => "child phase",
     "suite" => nil, "elapsed_seconds" => 0.0, "workers_total" => nil,
     "workers_finished" => 0, "child_output_age_seconds" => nil}
  end

  def event_line
    AfTestSuiteProgress::PREFIX + JSON.generate(event_data) + "\n"
  end

  def records(text)
    text.lines.map { |line| JSON.parse(line.delete_prefix(AfTestSuiteProgress::PREFIX)) }
  end
end
