# frozen_string_literal: true

require "json"
require "open3"

# AFDP-only presentation. Test summaries and subprocess exit status remain the
# authority. Nested capture forwards only complete, validated progress records.
module AfTestSuiteProgress
  PREFIX = "AFDP_TEST_PROGRESS "
  SCHEMA = "afdp-test-progress/v1"
  OUTPUT_MUTEX = Mutex.new
  EVENTS = %w[start heartbeat worker_finished telemetry_invalid finished failed].freeze

  # Automatic selection is limited to fast-suite callers or the public fast
  # Rake contract. An explicit setting (including text) always wins.
  class << self
    attr_accessor :automatic_fast
  end

  def self.renderer(suite)
    return ENV["AF_TEST_PROGRESS_RENDERER"] if ENV.key?("AF_TEST_PROGRESS_RENDERER")

    "tty" if suite == "fast" || automatic_fast
  end

  class Reporter
    attr_reader :worker_counts
    def initialize(phase:, suite: nil, workers: nil, output: $stderr,
                   format: ENV.fetch("AF_TEST_PROGRESS_FORMAT", "text"),
                   renderer: AfTestSuiteProgress.renderer(suite),
                   interval: 5.0, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @phase, @suite, @workers = phase, suite, workers
      @output, @format, @interval, @clock = output, format, interval, clock
      @text_interval = interval
      @terminal = AfTestSuiteProgress.terminal(output, format: format, renderer: renderer)
      @interval = [interval, 0.2].min if @terminal
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @finished_workers = {}
      @last_output = nil
      @stopped = false
    end

    def interactive?
      !!@terminal
    end

    # The runtime wrapper streams original diagnostics while the bar is active.
    # Serialize both streams; never redraw across an unfinished diagnostic line.
    def diagnostic(text)
      OUTPUT_MUTEX.synchronize do
        @terminal&.diagnostic(text)
        yield
      end
    end

    def start(threaded: true)
      @mutex.synchronize do
        @started = @clock.call
        emit_locked("start")
      end
      if threaded
        @ticker = Thread.new do
          @mutex.synchronize do
            until @stopped
              @condition.wait(@mutex, @interval)
              emit_locked("heartbeat") unless @stopped
            end
          end
        end
      end
      self
    end

    def activity
      @mutex.synchronize { @last_output = @clock.call }
    end

    def heartbeat
      @mutex.synchronize { emit_locked("heartbeat") }
    end

    def worker_finished(worker, outcome)
      @mutex.synchronize do
        @finished_workers[worker] = outcome
        emit_locked("worker_finished", "worker" => worker, "outcome" => outcome)
      end
    end

    def invalid_progress
      @mutex.synchronize { emit_locked("telemetry_invalid") }
    end

    def forward(event)
      write(event)
    end

    def finish(outcome = "finished")
      @mutex.synchronize do
        @stopped = true
        @condition.broadcast
        emit_locked(outcome)
      end
      @ticker&.join
      OUTPUT_MUTEX.synchronize { @terminal&.close(self) }
    end

    private

    def emit_locked(event, extra = {})
      now = @clock.call
      data = {"schema" => SCHEMA, "event" => event, "phase" => @phase,
              "suite" => @suite, "elapsed_seconds" => (now - @started).round(3),
              "workers_total" => @workers, "workers_finished" => @finished_workers.length,
              "child_output_age_seconds" => @last_output && (now - @last_output).round(3)}
      write(data.merge(extra))
    end

    def write(event)
      OUTPUT_MUTEX.synchronize do
        @worker_counts = event.values_at("workers_finished", "workers_total") if event["workers_total"]
        if @format == "json"
          @output.puts(PREFIX + JSON.generate(event))
        elsif @terminal && @terminal.write(event, self)
          # Presentation only: no event or result accounting changes.
        else
          if @terminal
            @terminal.close(self)
            @terminal = nil
            @interval = @text_interval
          end
          label = [event["suite"], event.fetch("phase")].compact.join(" / ")
          message = "[AFDP progress] #{label}: #{event.fetch('event')}; elapsed #{format('%.1f', event.fetch('elapsed_seconds'))}s"
          if event["workers_total"]
            message += "; workers finished #{event.fetch('workers_finished')}/#{event.fetch('workers_total')}"
          end
          message += "; worker #{event['worker']} #{event['outcome']}" if event["worker"]
          if event["event"] == "heartbeat"
            age = event["child_output_age_seconds"]
            message += age ? "; child output #{format('%.1f', age)}s ago" : "; no child output observed"
            message += "; parent alive, useful child work unknown"
          end
          @output.puts(message)
        end
        @output.flush
      end
    end
  end

  # One shared row per output stream, including nested captured reporters.
  # Only completed workers advance a determinate bar. Tickers redraw elapsed
  # time (or the unknown marker), without changing worker counts.
  class Terminal
    def initialize(output)
      @output = output
      @phases = {}
      @disabled = false
      @partial_diagnostic = false
      @notices = []
    end

    def write(event, owner)
      return false if @disabled

      key = [owner, event["suite"], event["phase"]]
      previous = @phases[key]
      state = {event: event, observed: monotonic, bad: previous ? previous[:bad] : {}}
      if event["event"] == "worker_finished" && event["outcome"] != "passed"
        state[:bad][event["worker"]] = event["outcome"]
        notice("#{label(event)}: worker #{event['worker']} #{event['outcome']}")
      elsif %w[failed telemetry_invalid].include?(event["event"])
        notice("#{label(event)}: #{event['event']}")
      end
      if %w[finished failed].include?(event["event"])
        @phases.delete(key)
      else
        @phases[key] = state
      end
      unless @announced
        notice("animation = reporter alive; useful child work unknown; counts = workers finished")
        @announced = true
      end
      draw(force: event["event"] != "heartbeat")
      true
    rescue StandardError
      # Unsupported rendering cannot override subprocess results or exceptions.
      @disabled = true
      clear rescue nil
      false
    end

    def diagnostic(text)
      clear
      @partial_diagnostic = !text.end_with?("\n") unless text.empty?
    rescue StandardError
      @disabled = true
    end

    def close(owner)
      @phases.delete_if { |key, _| key.first.equal?(owner) }
      draw unless @disabled
    rescue StandardError
      @disabled = true
      clear rescue nil
    end

    # A caller supplies the authoritative result after all its diagnostics and
    # gates. This static row is deliberately independent of ProgressBar#finish.
    def complete(suite:, phase:, success:, elapsed:, workers:, tests:)
      return if @disabled

      @phases.clear
      clear
      # Separate the permanent record from live cursor-control bytes.
      @output.puts
      @partial_diagnostic = false
      count = workers ? " #{workers[0]}/#{workers[1]} workers" : ""
      bar = if workers
        filled = 12 * workers[0] / workers[1]
        "[#{'#' * filled}#{' ' * (12 - filled)}]"
      else
        "[ended]"
      end
      suffix = " #{bar}#{count} | #{success ? 'PASS' : 'FAIL'}"
      suffix += " | #{tests} tests" unless tests.nil?
      suffix += " | #{format('%.1f', elapsed)}s"
      columns = @output.winsize.last
      columns = 80 if columns.zero?
      title = label("suite" => suite, "phase" => phase)[0, [columns - suffix.length - 1, 8].max]
      @output.puts(title + suffix)
      @output.flush
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def label(event)
      [event["suite"], event["phase"]].compact.join(" / ")
        .encode("US-ASCII", invalid: :replace, undef: :replace, replace: "?")
        .gsub(/[^a-zA-Z0-9 \/_.-]/, "?")
    end

    def clear
      return unless @bar

      @bar.stop
      @bar = @key = @last_draw = nil
      @output.print("\r\e[2K")
      @output.flush
    end

    def notice(message)
      @notices << message
    end

    def draw(force: true)
      return if @partial_diagnostic
      return if !force && @last_draw && monotonic - @last_draw < 0.19

      @last_draw = monotonic

      unless @notices.empty?
        clear
        @notices.each { |message| @output.puts("[AFDP progress] #{message}") }
        @notices.clear
      end

      # Keep a measurable worker group selected while concurrent checks run.
      # Other phases occupy the same row when no worker group is active.
      key, state = @phases.find { |_, value| value[:event]["workers_total"] } || @phases.to_a.last
      unless state
        clear
        return
      end
      event = state[:event]
      total, completed = event.values_at("workers_total", "workers_finished")
      clear if @key != key
      @key = key
      elapsed = event["elapsed_seconds"] + monotonic - state[:observed]
      count = total ? "workers #{completed}/#{total}" : "indeterminate"
      others = @phases.length > 1 ? " +#{@phases.length - 1} phases" : ""
      bad = state[:bad].empty? ? "" : " !#{state[:bad].length}"
      # Bound the entire ASCII row so labels cannot wrap or contain gem tokens.
      columns = @output.winsize.last
      columns = 80 if columns.zero?
      suffix = " #{count} #{format('%.1f', elapsed)}s#{bad}#{others}"
      bar_width = [14, columns - suffix.length - 12].min
      raise ArgumentError, "terminal too narrow" if bar_width < 3

      available = columns - suffix.length - bar_width - 4
      title = label(event)[0, available]
      @bar ||= TTY::ProgressBar.new("[:bar]", total: total, width: bar_width,
        output: @output, clear: true, hide_cursor: false)
      @bar.width = bar_width
      @bar.format = "#{title} [:bar]#{suffix}"
      # finish is never called to imply success. The gem completes only when
      # the actual worker count reaches its total, including failed workers.
      @bar.advance(total ? completed - @bar.current : 0)
      if total && completed == total
        @phases.delete(key)
        @bar = @key = nil
        @output.print("\r")
      end
      @output.flush
    end
  end

  def self.terminal(output, format:, renderer:)
    return unless format != "json" && renderer == "tty" && output.respond_to?(:tty?) && output.tty?
    return if %w[dumb unknown].include?(ENV["TERM"])

    OUTPUT_MUTEX.synchronize do
      require "tty-progressbar"
      require "io/console"
      return unless output.respond_to?(:winsize) && (output.winsize.last.zero? || output.winsize.last >= 60)

      @terminals ||= {}
      @terminals[output] ||= Terminal.new(output)
    end
  rescue LoadError, StandardError
    nil
  end

  # One completion owner per invocation. Progress events supply display-only
  # worker counts; the runner/Rake gate supplies acceptance independently.
  class Completion
    def initialize(suite:, phase:, output: $stderr)
      @suite, @phase, @output = suite, phase, output
      @terminal = AfTestSuiteProgress.terminal(output,
        format: ENV.fetch("AF_TEST_PROGRESS_FORMAT", "text"), renderer: AfTestSuiteProgress.renderer(suite))
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def interactive?
      !!@terminal
    end

    def record(workers:, tests:)
      if workers && workers.length == 2 && workers.all? { |n| n.is_a?(Integer) } &&
          workers[1].positive? && workers[0].between?(0, workers[1])
        @workers = workers
      end
      @tests = tests if tests.is_a?(Integer) && tests >= 0
    end

    def finish(success:)
      return unless @terminal && !@finished

      @finished = true
      $stdout.flush
      OUTPUT_MUTEX.synchronize do
        @terminal.complete(suite: @suite, phase: @phase, success: success,
          elapsed: Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started,
          workers: @workers, tests: @tests)
      end
    rescue StandardError
      # A missing/unsupported display cannot affect the authoritative result.
      nil
    end
  end

  def self.phase(name, suite: nil, workers: nil, **options)
    reporter = Reporter.new(phase: name, suite: suite, workers: workers, **options).start
    outcome = "failed"
    begin
      result = yield reporter
      outcome = result.respond_to?(:last) && result.last.respond_to?(:success?) && !result.last.success? ? "failed" : "finished"
      result
    ensure
      reporter.finish(outcome)
    end
  end

  def self.decode(line)
    return unless line.start_with?(PREFIX) && line.end_with?("\n") && line.bytesize <= 4096

    data = JSON.parse(line.delete_prefix(PREFIX))
    return unless data.is_a?(Hash) && data["schema"] == SCHEMA && EVENTS.include?(data["event"])
    required = %w[schema event phase suite elapsed_seconds workers_total workers_finished child_output_age_seconds]
    extra = data["event"] == "worker_finished" ? %w[worker outcome] : []
    return unless data.keys.sort == (required + extra).sort
    return unless data["phase"].is_a?(String) && data["phase"].match?(/\A[^\r\n\e]{1,100}\z/)
    return unless data["suite"].nil? || %w[fast integration all].include?(data["suite"])
    return unless data["elapsed_seconds"].is_a?(Numeric) && data["elapsed_seconds"].finite? && data["elapsed_seconds"] >= 0
    return unless data["workers_finished"].is_a?(Integer) && data["workers_finished"] >= 0
    total = data["workers_total"]
    return unless total.nil? ? data["workers_finished"].zero? : total.is_a?(Integer) && total.positive? && total >= data["workers_finished"]
    age = data["child_output_age_seconds"]
    return unless age.nil? || age.is_a?(Numeric) && age.finite? && age >= 0
    if data["event"] == "worker_finished"
      return unless total && data["workers_finished"].positive? && data["worker"].is_a?(Integer) && data["worker"].between?(1, total)
      return unless %w[passed failed invalid].include?(data["outcome"])
    end
    data
  rescue JSON::ParserError
    nil
  end

  # Retain arbitrary diagnostic bytes, including malformed/truncated records.
  # A long ordinary line is drained without waiting for a newline or growing a
  # second unbounded line buffer. No progress record is an execution summary.
  class Stream
    def initialize(reporter, relay:, diagnostic: nil)
      @reporter, @relay, @diagnostic = reporter, relay, diagnostic
      @pending = +""
      @output = +""
      @passthrough = false
      @invalid_reported = false
    end

    def read(chunk)
      @reporter.activity
      unless @relay
        @output << chunk
        return
      end
      @pending << chunk
      while (index = @pending.index("\n"))
        line = @pending.slice!(0, index + 1)
        event = !@passthrough && AfTestSuiteProgress.decode(line)
        if event
          @reporter.forward(event)
        else
          invalid(line) unless @passthrough
          retain(line)
        end
        @passthrough = false
      end
      if @pending.bytesize > 4096
        invalid(@pending) unless @passthrough
        retain(@pending)
        @pending.clear
        @passthrough = true
      end
    end

    def finish
      invalid(@pending) unless @passthrough
      retain(@pending)
      @output
    end

    private

    def retain(text)
      @diagnostic ? @diagnostic.call(text) : @output << text
    end

    def invalid(line)
      return unless line.start_with?(PREFIX) && !@invalid_reported

      @invalid_reported = true
      @reporter.invalid_progress
    end
  end

  def self.capture3(*arguments, phase: nil, suite: nil, reporter: nil, relay: true, **options)
    unless reporter
      return self.phase(phase, suite: suite) do |progress|
        capture3(*arguments, reporter: progress, relay: relay, **options)
      end
    end

    environment = arguments.first.is_a?(Hash) ? arguments.shift.dup : {}
    environment["AF_TEST_PROGRESS_FORMAT"] = "json" if relay
    Open3.popen3(environment, *arguments, **options) do |stdin, stdout, stderr, wait|
      stdin.close
      streams = {stdout => Stream.new(reporter, relay: relay), stderr => Stream.new(reporter, relay: relay)}
      active = streams.keys
      until active.empty?
        IO.select(active).first.each do |io|
          begin
            streams.fetch(io).read(io.readpartial(4096))
          rescue EOFError
            active.delete(io)
          end
        end
      end
      [streams.fetch(stdout).finish, streams.fetch(stderr).finish, wait.value]
    end
  end
end
