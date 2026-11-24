# Test Suite Contract

## Narrow public standing-release gate

`bundle exec ruby bin/af-public-standing-release-test` is a separate, focused
public-safe standing-release gate. It loads only
`test/standing_bulk_score_release_test.rb` and its synthetic DPS-03 fixtures,
uses seed 170, and accepts no selection overrides. The independently maintained
`test/public_standing_release_methods.json` declares all 18 fully qualified
required identities; it is never generated from runtime discovery. Changes to
that declaration require explicit review of the public contract.

Discovery must equal the declared identities, including multiplicity. A dedicated
Minitest reporter then checks actual completed result identities for exactly-once
execution and rejects any required skip, failure or error. A successful Minitest
summary alone cannot pass this gate. Run the gate in a fresh process; its fixed
selection neither imports nor validates the unrelated integration inventory.

`test/public_standing_release_gate_test.rb` covers contract drift and execution
accounting using disposable synthetic test methods. Those protocol regressions
are separate from the 18 real standing-release methods run by the public entry.

This narrow result does not qualify the full public fast/integration suites,
coverage, runtime, or publication. Ordinary Rake tasks, private runner selection,
skip policy, Phase A advisory results, regression cases and all existing budgets
and coverage floors retain their existing contracts.

## Historical whole-suite runtime baseline

Measured on 2026-09-25 from commit
`6e65d807eeacefa298a3a89075bd30ec1b0d6079`.

Environment:
- MacBook Pro M4 Pro, 48 GB
- Ruby 4.0.6
- 1 warm-up run discarded
- 10 measured runs
- 229 tests
- 1,770 assertions
- 1 skip

Runtime:
- min: 4.171 s
- median: 4.453 s
- mean: 4.414 s
- max: 4.620 s
- stddev: 0.152 s

## Default fast-suite runtime budget

The runtime budget is calibrated for local execution on the baseline machine:

- warning threshold: 20.0 s
- hard failure threshold: 24.0 s

These thresholds are regression tripwires, not runtime budget to consume. A warning
should prompt inspection of recent test changes and `rake test:slow`; the thresholds
should not be raised merely because the suite has grown into the available headroom.

When a parallel AdventureFinder workspace test marks the process with
`AF_TEST_CONTENDED=1`, the runtime guard automatically applies the fixed
`TEST_RUNTIME_CONTENTION_MULTIPLIER` of 1.25. That makes the contended thresholds
25.0 s warning / 30.0 s hard failure. Direct `rake` and serial workspace runs
retain the 20.0 s / 24.0 s limits. The multiplier accounts for deliberate
cross-repository resource contention; it does not redefine the isolated baseline.

`rake test:runtime` enforces the budget against the ordinary, uninstrumented suite.

## Scale-sensitive benchmark

`rake test:bench` protects Horizontal Discovery package extraction from
algorithmic-growth regressions. The adapter indexes output entries by experiment
once instead of rescanning the complete package for every scoped manifest.

The benchmark measures 25 through 200 logical results and fits a power curve to
the observed timings. It requires a usable fit (`R² >= 0.90`) and a fitted growth
exponent no greater than 1.50. This deliberately guards growth shape rather than
an absolute millisecond budget, making it less sensitive to machine speed while
still rejecting a return to quadratic package scans.

## Default safety sweep

Plain `rake` runs the fast `test:contract` safety sweep in three stages.

1. `test:runtime` runs the fast product suite by itself first. Its wall-clock
   runtime is measured with a monotonic clock so the 20.0 s warning and
   24.0 s hard ceiling are not distorted by concurrent health checks.
2. `test:bench` checks Horizontal Discovery scaling without changing the calibrated
   product-suite runtime measurement.
3. After the benchmark passes, `test:health` runs these independent checks in
   parallel:
   - `test:coverage` for fast-only coverage against the committed line/branch coverage ratchet
   - `test:deps` for fast test-file independence
   - `test:lint` for structural Minitest quality

The ordinary suite uses up to twelve isolated workers. Coverage uses up to four
isolated workers: each starts SimpleCov before loading any test or product code,
writes a uniquely named result to its own temporary directory, and runs its
assigned tests through Minitest. Only after every worker exits successfully and
its run accounting and resultset validate does the runner collate those exact
results. The collating process owns the existing HTML report, line/branch
coverage checks and committed per-file ratchet. A missing or malformed slice
fails the coverage task; earlier coverage files cannot substitute for a worker.
The four-worker cap limits simultaneous instrumented processes and can be
revisited with comparable timing and memory evidence.

The default sweep is quiet on successful secondary checks. In an interactive
terminal, a single in-place spinner indicates that the parallel health phase is
running. Successful output ends with the coverage summary, runtime result, and:

```text
test:bench: Horizontal Discovery package extraction scaling guard passed
test:lint: <N> files inspected, no offenses detected
test:deps: no broken dependencies found
```

Full captured diagnostics are printed only when a secondary health check fails.
Runtime warnings and hard-ceiling failures are deferred to the bottom of the
contract output, with a blank line before them.

The raw `rake test`, `rake test:bench`, `rake test:coverage`, `rake test:deps`,
and `rake test:lint` tasks remain available when only one check or detailed
successful output is desired.

## Fast and integration selection

`test/integration.json` is the authoritative inventory of designated slow test
files. Discovery validates it against the entire integration directory and
rejects missing, duplicate or unregistered files. Functional workers, coverage
workers and Minitest dependency checking use the same selection. Nested files
outside `test/integration/` remain in the fast suite.

The frontier residual scoring integration file preserves all original real
packet, workbook, CLI, return, replay, provenance and fail-closed workflows.
The final release package integration file preserves all original package,
Git, concurrency, stale-reference, derived-candidate and authority workflows.
Cheap population identity and catalog delta checks remain in the fast suite,
alongside direct frontier return schema, identity, source-reasoning, numeric
bounds and effective Levels sibling checks. The latter uses a small real
workbook rather than the full release fixture. Fixture/provenance performance
optimization remains separate from this execution-policy split.

`bundle exec rake test:integration` independently runs:

1. Each designated integration method once in an uninstrumented functional run.
2. Each integration file in isolation through Minitest's dependency checker.
3. `test:coverage:full`, which executes the complete fast **and** integration
   population with fresh instrumentation and enforces the full coverage ratchet.

After functional success, independence and full coverage run concurrently in
separate processes, with output captured separately to preserve accounting.
These are distinct executions; coverage and independence are not claimed as
part of the functional run. Each worker invocation prints its selected suite,
exact run/assertion/failure/error/skip totals and elapsed monotonic worker time.
The public integration gate also reports its total monotonic validation time.
Missing or invalid structured results, count mismatches and unsuccessful exits fail.
The full integration gate deliberately has no newly invented runtime ceiling.
The existing 20/24 second primary runtime budget and 1.25 contention multiplier
continue to apply to the default fast functional run without change.

## Authoritative worker terminal results

Each functional or coverage worker additionally writes one private JSON document
in its invocation's temporary directory. `bin/af_test_suite_result.rb` observes
Minitest results directly; it does not parse human output or progress telemetry.
The document uses the closed `afdp-worker-result/v1` schema:

| Fields | Contract |
| --- | --- |
| `schema` | Exactly `afdp-worker-result/v1` |
| `run_id`, `suite`, `worker` | Fresh 32-character lowercase hex invocation ID; `fast`, `integration` or `all`; one-based worker number |
| `population_sha256` | SHA-256 of the sorted JSON array of all selected fully qualified method names |
| `selection_sha256` | SHA-256 of the sorted JSON array of methods actually reported by this worker |
| `status` | `complete` only when observed methods exactly equal its assigned selection; otherwise `incomplete` |
| `tests`, `assertions`, `failures`, `errors`, `skips` | Exact nonnegative integer Minitest counters, including failed/error/skipped tests |

Fingerprints retain duplicate names. Array JSON uses Ruby `JSON.generate`
without extra whitespace. The parent retains independent expected run, suite,
worker, population, selection and test count bindings. `verify!` requires the
entire ordered worker inventory, one parseable document per unique path, exact
field sets and types, matching bindings and counts, complete selection, and
normal Minitest process termination (exit 0 or 1). Failure/error/skipped records
can be complete evidence; structural validation is not a test-success verdict.
Signals and other exit codes are rejected even if a document exists. Missing,
duplicate, corrupt, stale, wrong-population or incomplete evidence is rejected;
duplicate JSON keys are rejected as ambiguous. No timestamp substitutes for
the fresh run binding.

Worker results are the sole authority for parent test counters and worker
outcomes. Missing or invalid evidence fails the invocation even with successful
text or passing peers. A normal nonzero exit independently fails the invocation,
including Minitest policy failures without assertion failures. Progress and all
human headings, summaries and completion sentences are presentation only.
Coverage collation still requires successful workers, complete accounting and
fresh independently validated slices. Sharding, discovery, seeds, filters,
populations, runtime ceilings and diagnostic output are unchanged.

### Public result handoff

A caller may supply `AFDP_TEST_RESULT_PATH` (a nonexistent file in its own fresh
directory) and `AFDP_TEST_RESULT_RUN_ID` (32 lowercase hex characters). The direct
runner and Rake entrypoints (`rake`, `test`, `test:runtime`,
`test:coverage:full`, and `test:integration`) create exactly one JSON document at that path,
with closed schema `afdp-suite-result/v1`, the caller's `run_id`, selected `suite`
(`fast`, `integration`, or `all`), `status` (`passed` or `failed`), and integer
`tests`, `assertions`, `failures`, `errors`, `skips`. Negative counters, impossible
failure/error/skip totals, duplicate fields/documents, and a passing status with
failures/errors are invalid. Existing files are refused rather than overwritten.
The consumer must require both validated fresh evidence and a successful process
exit. Missing/incomplete worker evidence yields no public result. Valid counts
may accompany a failed status; no failure is repaired by the document.

Rake and the runner consume their outer requests before discovery or subprocess
startup, so nested workers and fixtures cannot inherit or publish those requests.
Each allocates separate fresh child channels and publishes only after the public
task ends. Later benchmark, lint, independence, coverage or runtime failures veto
`passed` even when functional counts are valid. Private worker files remain
invocation-local and are removed; external consumers never read those paths.

Public counts preserve the historically observed invocations. On success, fast
exports its functional run; integration sums its functional run and the separately
executed full coverage run. A direct coverage runner or `test:coverage:full`
exports its one selected run.
Each included invocation has a fresh validated channel; worker summaries and
aggregate summaries of the same invocation are never added twice. Quiet health,
dependency and benchmark checks retain their execution and exit gates and their
historically excluded successful counts. Failed quiet benchmarks, failed fast
coverage and failed isolated dependency files expose distinct Minitest executions;
those executions contribute their complete validated counts. Successful isolated
peers remain excluded. Standalone benchmark and per-file children consume fresh
requests before loading fixtures and publish only after their complete selected
Minitest population ran. Missing or invalid required evidence refuses the public
total; the child's actual exit/signal independently vetoes success. Later gate
failures retain complete known counts with failed status. AdventureFinder validates the public document independently; human text
and previous reports cannot supply or repair counts.

## Two-tier coverage obligation

Both tiers retain the unchanged `.simplecov_baseline.yml` per-file line and
branch floors. A fast-only pilot against the prepared source passed those
floors, so no separate lower fast floor is introduced. Default coverage reports
only fast tests; the historical full population is independently executed by
`test:coverage:full` during the integration gate. Passing fast coverage does not
establish integration coverage or readiness for final integration.

Every coverage invocation allocates new worker directories and unique command
names, validates the exact expected slice inventory, line/branch data and
invocation timestamps, and collates only those slices into a new empty report
directory. Existing reports never contribute hits. Missing, stale, corrupt,
misattributed or omitted worker results fail before collation. Reports are
published to `coverage/fast` and `coverage/full` after successful collation;
these reports may describe different executed populations and must not be
substituted for one another. Baseline initialization uses full coverage only;
this split neither regenerates nor lowers the committed baseline.

Before final integration, run both public contracts sequentially:

```sh
bundle exec rake
bundle exec rake test:integration
```

A green default rake alone is a fast safety result. TST-05B owns composing both
commands into AdventureFinder's `af-test`; this repository does not implement
that cross-repository change. Both contracts use disposable offline fixtures
and do not perform inference, load models or mutate paid resources or production
artifacts.

## Live test progress

AFDP reports discovery, functional or coverage workers, coverage slice
verification, and each captured benchmark, lint or independence check as they
start. Workers report completion immediately; their complete stdout/stderr and
original Minitest summaries remain buffered together for diagnostic readability.
The counter is **workers finished**, including failed or invalid workers. It is
not a per-test counter, percentage, ETA or acceptance result. Exit status, validated worker
accounting and coverage verification remain authoritative.

Every active phase emits a monotonic elapsed-time heartbeat approximately every
five seconds. A heartbeat proves only that its reporting parent is alive.
Observed child output and its age are shown separately; neither child output nor
silence establishes useful work or a stall. No new timeout or gate is introduced.
SimpleCov's existing `collate` subprocess combines collation, formatting and
ratchet validation, so that operation has one phase label and elapsed time. AFDP
does not manufacture separate internal milestones or percentages.

Text-mode progress uses serialized plain lines on stderr, including captured
CI logs, without escape sequences or spinner redraws. Concurrent workers emit
one completion line each, plus phase-level heartbeats. Captured health checks
relay nested progress live while retaining original diagnostic bytes and exit
status. Invalid, oversized or truncated telemetry remains diagnostic output,
with a bounded `telemetry_invalid` warning; it cannot make a test or coverage
failure pass. The quiet checks keep their existing success-summary policy and
print complete retained diagnostics on failure.

### Interactive bars and permanent completion

Interactive fast tests select `tty-progressbar` automatically. This includes
plain `rake`, `bundle exec rake`, `rake test` and the fast runtime wrapper. The
Rakefile enables uncounted benchmark/health phases automatically only within a
public fast-test invocation; unrelated standalone Rake tasks keep their existing
presentation. Integration/all suites retain explicit `AF_TEST_PROGRESS_RENDERER=tty`
activation.

| Configuration | Presentation |
| --- | --- |
| `AF_TEST_PROGRESS_FORMAT=json`, with any renderer/output | Exact existing `afdp-test-progress/v1` records |
| `AF_TEST_PROGRESS_RENDERER=text` | Existing plain lines, including on a TTY |
| No renderer setting, fast test invocation, supported stderr TTY | Animated row and permanent result |
| Explicit `AF_TEST_PROGRESS_RENDERER=tty`, supported stderr TTY | Animated row and permanent result for supported suite invocations |
| Captured output, missing gem, `TERM=dumb`/`unknown`, terminal narrower than 60 columns, or unsupported renderer setting | Safe text fallback |

Explicit configuration wins over automatic selection. Captured nested processes
still emit validated JSON, rather than detecting the outer terminal themselves.
JSON mode has no additional completion event, text marker or animation. The
schema, event names, field meanings and validation are unchanged.

The live row shows suite/phase, completed/total **workers**, and elapsed monotonic
phase time. Discovery, independence, lint, benchmarking and coverage collation
remain indeterminate. Worker counts change only on real completion records;
heartbeat redraws mean reporter activity, not useful child work. All concurrent
reporters share one row, with a worker group taking priority and `+N phases`
identifying other active phases. Failed/invalid workers and invalid telemetry
leave permanent notices. Labels are bounded ASCII, without injected control
characters or gem format tokens. Original diagnostic bytes and exit statuses
remain authoritative and retain their existing streaming/capture policies.

The final result is a separate static row, never an inferred gate pass from the
gem's `finish` method. A direct runner owns its result only after worker accounting
and any requested coverage verification/collation complete. Its worker counter
includes failed/invalid workers; a full bar can therefore end in **FAIL**. The test
count appears only when all selected-worker accounting is valid and reconciles
with the discovered population. It is an executed-test count, not bar progress.

For plain `rake`/`test:contract`, the outer Rake invocation owns completion. The
runtime wrapper retains its functional worker counts and uniquely identified,
reconciled aggregate count. The final row appears after health summaries, runtime
warnings/failures and Rake's exception diagnostics. PASS requires the complete
public task to finish and the process to exit successfully. A later benchmark,
coverage, lint, independence or runtime failure yields FAIL even if all functional
workers passed. The displayed test count is the verified fast functional population,
not the sum of functional, independence and coverage re-executions. Unknown counts
are omitted; `[ended]` is used when no reliable worker inventory is available.

The runtime wrapper owns standalone `test:runtime` completion as well. Explicit
TTY integration uses an outer contract completion without inventing functional
counts unavailable to that parent. A private per-child ownership flag suppresses
an intermediate runner completion when that outer integration owner is present.
Nested JSON capture already suppresses intermediate completion rows. Completion
is idempotent and does not introduce another authoritative Minitest summary.

Completion uses a visible cursor and clears/suspends animation before diagnostics.
It does not change worker counts, selection, seeds, test/coverage accounting,
ratchets, thresholds or gates. No dependency changes or additional UI threads are
introduced. Pseudo-terminal tests control dimensions without timing snapshots;
text-specific tests set their format explicitly so coverage's inherited JSON
setting cannot change the intended assertion. Explicit JSON failure precedence
has a separate regression test.

The existing `tty-progressbar 0.18.3` dependency and its lockfile are unchanged.
The previously accepted reporting-overhead decision remains in force; this change
does not restart performance benchmarking or relax any runtime/algorithm gate.

For the TST-06B front-door consumer, set `AF_TEST_PROGRESS_FORMAT=json`. Each
record is one newline-terminated `AFDP_TEST_PROGRESS ` prefix followed by JSON
with `schema: afdp-test-progress/v1`, `event`, `phase`, `suite`,
`elapsed_seconds`, `workers_total`, `workers_finished`, and
`child_output_age_seconds`. A `worker_finished` event also has one-based `worker`
and `outcome` (`passed`, `failed` or `invalid`). Phase events are `start`,
`heartbeat`, `telemetry_invalid`, `finished` or `failed`. `finished` means a
presentation phase ended; it does not establish a gate pass. Null counters or
ages mean unavailable data. A consumer must keep telemetry separate from
Minitest summaries, preserve missing-stream fallback and original failures, and
never count a heartbeat or worker event as an executed test. TST-06B owns making
these records visible through AdventureFinder's outer subprocess capture.

Validate presentation first with `test/test_suite_progress_test.rb` and
`test/test_suite_runner_test.rb`, using synthetic workers and disposable data.
Then preserve a complete baseline-bound patch before the existing fast and
integration contracts. The reporting overhead was previously accepted; this UX
change requires the existing validation gates, not a new benchmarking campaign.
Report unavailable gates explicitly. Runtime ceilings, coverage ratchets and
suite populations remain unchanged.
