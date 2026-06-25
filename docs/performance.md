# Cherry Performance Goal

Cherry should stay responsive and memory-stable during long-lived agent workspaces: many terminal tabs, multiple open windows, heavy scrollback, frequent alternate-screen redraws, and repeated detach/reattach of Ghostty-backed surfaces.

## What We Measure

- Long scrollback replay through Cherry's live terminal state tracking.
- TUI-style alternate-screen redraws that repaint the viewport many times.
- Raw PTY output retention, including the 1 MiB replay buffer used when Ghostty surfaces attach.
- Many long-lived sessions receiving small output bursts, which stresses per-session raw replay retention and object churn.
- Ghostty bridge/session churn and detached-surface release across many terminal sessions.
- Runtime counters from `CHERRY_TERMINAL_PERF=1`: PTY chunks, Ghostty feed chunks, render ticks, SwiftUI representable updates, container configures, bridge attaches, `fitToSize`, and settings reconfigures.

## Commands

Run the opt-in synthetic stress suite:

```bash
Scripts/perf-terminal-stress --standard
```

For a quick local sanity check:

```bash
Scripts/perf-terminal-stress --smoke
```

For a longer soak before perf-sensitive changes:

```bash
Scripts/perf-terminal-stress --soak
```

The script writes logs under `.build/perf/` and runs `swift test -c release --no-parallel --filter TerminalPerformanceStressTests` with `CHERRY_PERF_STRESS=1`.
It also writes a parsed JSON report beside the log.

The synthetic suite is intentionally headless. It catches parser/state-tracking,
raw-output-retention, and bridge-lifetime regressions without opening the app.

To create a local machine baseline and fail future runs that regress beyond the
default 25% tolerance, keep one baseline per scale/configuration:

```bash
Scripts/perf-terminal-report .build/perf/terminal-stress-standard-YYYYMMDD-HHMMSS.log \
  --write-baseline .build/perf/baselines/terminal-stress-standard.json

CHERRY_PERF_BASELINE=.build/perf/baselines/terminal-stress-standard.json \
  Scripts/perf-terminal-stress --standard
```

Use `CHERRY_PERF_MAX_REGRESSION_PCT=15` to tighten the tolerance for a stable
local machine or CI runner.

## App-Level Soak

Use the real app for UI/rendering work that synthetic tests cannot cover. Start
Cherry with performance counters enabled:

```bash
CHERRY_TERMINAL_PERF=1 \
CHERRY_PERF_PROJECT_ROOTS="$PWD" \
CHERRY_TRACE_PTY_DIR=/tmp/cherry-traces \
swift run Cherry
```

`CHERRY_PERF_PROJECT_ROOTS` is a colon- or newline-separated list of valid
directories. It is only honored when `CHERRY_TERMINAL_PERF=1` and does not save
those projects to app preferences.

Then drive the running app from another terminal:

```bash
Scripts/perf-app-soak --scale smoke
Scripts/perf-app-soak --scale standard
Scripts/perf-app-soak --scale soak --windows 3 --tabs 24
```

`Scripts/perf-app-soak` talks to Cherry's local control socket, opens project
windows from Cherry's configured/open project list, creates terminal tabs, sends
deterministic workloads, cycles selection through the spawned tabs so Ghostty
surfaces attach/detach, and writes a JSON report under `.build/perf/`. It
verifies each spawned workload starts producing real terminal output before the
soak window begins, so a command-submission regression fails loudly instead of
measuring idle shells. It closes only the processes it created unless
`--keep-open` is passed, then waits `--settle-after-close` seconds before the
final sample so delayed detached Ghostty surface release is not mistaken for a
leak. For multi-window runs, open or configure the target projects in Cherry
first, or pass explicit repeated `--project-root` values. Large many-session
runs can use `--spawn-interval` to pace setup while keeping the steady-state
workload unchanged. Use `--sleep-ms` with TUI workloads when you want a
frame-paced long-session soak instead of a flat-out PTY flood.

Recommended app-level shapes:

```bash
# Fast overload/flood check: intentionally writes as quickly as possible.
Scripts/perf-run-emulator-comparison \
  --cherry-only \
  --scale standard \
  --mode mixed \
  --windows 3 \
  --tabs 8 \
  --duration 180 \
  --sample-interval 30 \
  --cherry-command 'swift run -c release Cherry'

# Long-session TUI check: many fullscreen redrawers paced like real apps.
Scripts/perf-run-emulator-comparison \
  --cherry-only \
  --scale standard \
  --mode tui \
  --windows 3 \
  --tabs 8 \
  --duration 600 \
  --sleep-ms 4 \
  --sample-interval 30 \
  --cherry-command 'swift run -c release Cherry'
```

The app-soak JSON includes periodic Cherry process samples:

- `samples[].total_rss_bytes`
- `samples[].total_cpu_percent`
- `samples[].performance[].status.ghosttyLiveBridgeCount`
- `samples[].performance[].status.ghosttyInstalledOutputObserverCount`
- `samples[].performance[].status.rawOutputObserverCount`
- `samples[].performance[].status.rawOutputRetainedBytes`
- `samples[].performance[].status.terminalPerfCounters`
- `sample_summary.max_total_rss_bytes`
- `sample_summary.last_total_rss_bytes`
- `sample_summary.rss_delta_bytes`
- `sample_summary.rss_growth_mib_per_hour`
- `sample_summary.steady_state_rss_delta_bytes`
- `sample_summary.steady_state_rss_growth_mib_per_hour`
- `sample_summary.last_ghostty_live_bridge_count`
- `sample_summary.last_ghostty_output_observer_count`
- `sample_summary.last_raw_output_observer_count`
- `sample_summary.last_raw_output_retained_bytes`
- `sample_summary.last_terminal_perf_pty_chunks`
- `sample_summary.last_terminal_perf_pty_bytes`
- `sample_summary.last_terminal_perf_processor_backlog_drop_count`
- `sample_summary.last_terminal_perf_processor_backlog_dropped_bytes`
- `sample_summary.last_terminal_perf_background_output_throttle_count`
- `sample_summary.max_total_cpu_percent`

For long-session leak hunting, prefer the drift fields over peak RSS alone:
`rss_delta_bytes` shows total end-to-start RSS growth, while
`rss_growth_mib_per_hour` normalizes that drift for multi-hour soaks. The
`steady_state_*` fields measure from after all workloads have started to the
last active pre-close sample, which separates leak-like growth from the expected
memory cost of opening many sessions. The Cherry-specific fields explain what
grew: Ghostty surfaces/observers, raw replay retention, or terminal feed/render
counters. Use `--sample-interval 10` to increase or decrease sampling frequency.

To summarize an app-soak run or compare it to a local app baseline:

```bash
Scripts/perf-app-report .build/perf/app-soak-smoke-YYYYMMDD-HHMMSS.json \
  --write-baseline .build/perf/baselines/app-soak-smoke.json

Scripts/perf-app-report .build/perf/app-soak-smoke-NEW.json \
  --baseline .build/perf/baselines/app-soak-smoke.json
```

To make a long soak fail on memory drift, add either a local-baseline
comparison slack or a hard growth-rate limit:

```bash
Scripts/perf-app-report .build/perf/app-soak-soak-NEW.json \
  --baseline .build/perf/baselines/app-soak-soak.json \
  --rss-growth-slack-mib 128 \
  --cherry-count-slack 2 \
  --raw-retention-slack-mib 128

Scripts/perf-app-report .build/perf/app-soak-soak-NEW.json \
  --max-total-cpu-percent 150 \
  --max-steady-state-rss-growth-mib-per-hour 1024 \
  --max-raw-output-retained-mib 1 \
  --max-pty-chunks-per-mib 160
```

`--max-total-cpu-percent` puts a hard ceiling on the summed Cherry process CPU
seen during the run. Use a tighter value for paced TUI soaks and a higher
mode-specific value for deliberate flood/overload tests.
`--max-raw-output-retained-mib` is strict for the default close-and-settle
workflow; increase it only when using `--keep-open` or intentionally sampling
while workload tabs remain alive.
`--max-pty-chunks-per-mib` protects the PTY coalescing path. A sudden jump in
chunks per MiB usually means Cherry is back to processing tiny PTY reads one at
a time, which shows up as CPU burn during redraw storms. Use a stricter limit
for flat-out flood runs, and a looser mode-specific limit for paced TUI runs
where the workload intentionally sleeps between frames.
The processor backlog drop counters indicate that plain terminal sessions
started shedding stale Cherry-side parser backlog to preserve app responsiveness;
visible bytes are still retained for Ghostty replay through the raw output store.
The background output throttle counter indicates that hidden plain terminals
emitted enough data for Cherry to briefly pause their PTY readers. This
backpressures runaway hidden output while selected terminals, agents, and
managed commands continue reading normally.

To watch Cherry's built-in performance counters while the soak runs:

```bash
log stream --style compact --predicate 'subsystem == "Cherry" AND category == "TerminalPerf"'
```

The shared workload generator can also be run manually inside any terminal:

```bash
Scripts/perf-terminal-workload scrollback --lines 500000
Scripts/perf-terminal-workload tui --frames 10000 --rows 40 --columns 120
Scripts/perf-terminal-workload tui --duration 600 --sleep-ms 4
Scripts/perf-terminal-workload mixed --duration 300
```

Additional manual workloads:

- Open 10, 25, and 50 terminal tabs, then switch through them repeatedly.
- Run `Scripts/terminal-hell-test --no-pause` in Cherry and Ghostty side by side.
- Run long-output commands such as `yes | head -n 500000`, large `git log --stat`, and build/test loops.
- Run TUIs such as `vim`, `less`, `top` or `btop`, `lazygit`, and `claude`/`codex` sessions with active status redraws.
- Leave a multi-window workspace running for at least 2 hours, then check CPU wakeups, resident memory, bridge counts, and terminal responsiveness.

## Ghostty Comparison

Ghostty is the control. For any Cherry slowdown, run the same shell/TUI workload in Ghostty and compare:

```bash
Scripts/perf-ghostty-workload --standard --mode mixed --windows 1
Scripts/perf-ghostty-report .build/perf/ghostty-workload-standard-YYYYMMDD-HHMMSS.json
```

On macOS this launches Ghostty via `open -na Ghostty.app --args -e ...`, samples
the newly launched Ghostty PIDs, writes a JSON report under `.build/perf/`, then
terminates only the new PIDs unless `--keep-open` is passed. Use the report as a
local Ghostty control baseline:

```bash
Scripts/perf-ghostty-report .build/perf/ghostty-workload-standard-OLD.json \
  --write-baseline .build/perf/baselines/ghostty-standard.json

Scripts/perf-ghostty-report .build/perf/ghostty-workload-standard-NEW.json \
  --baseline .build/perf/baselines/ghostty-standard.json \
  --rss-growth-slack-mib 128
```

To compare Cherry directly against a Ghostty control run, match workload count
and duration, then compare the reports:

```bash
Scripts/perf-app-soak --scale smoke --windows 3 --tabs 2 --duration 60
Scripts/perf-ghostty-workload --smoke --windows 6 --duration 60

Scripts/perf-compare-emulators \
  --cherry .build/perf/app-soak-smoke-YYYYMMDD-HHMMSS.json \
  --ghostty .build/perf/ghostty-workload-smoke-YYYYMMDD-HHMMSS.json \
  --require-shape-match \
  --json-out .build/perf/compare-smoke.json
```

For a fully repeatable local run that launches Cherry with perf-only project
roots, runs a matched Ghostty control workload, compares them, and cleans up:

```bash
Scripts/perf-run-emulator-comparison \
  --scale standard \
  --mode tui \
  --windows 3 \
  --tabs 8 \
  --duration 300 \
  --sleep-ms 4 \
  --sample-interval 10
```

This writes a paired-run manifest plus the Cherry, Ghostty, and comparison
reports under `.build/perf/`.

For long leak-focused soaks where a Ghostty control would double the wall time,
use the same launcher in Cherry-only mode:

```bash
Scripts/perf-run-emulator-comparison \
  --cherry-only \
  --scale standard \
  --mode tui \
  --windows 3 \
  --tabs 8 \
  --duration 1800 \
  --sleep-ms 4 \
  --sample-interval 30 \
  --cherry-command 'swift run -c release Cherry'
```

Then gate the resulting app report with `--max-steady-state-rss-growth-mib-per-hour`.

- CPU in Activity Monitor or Instruments Time Profiler.
- Resident memory and dirty memory via `vmmap <pid>`.
- Hang samples via `sample <pid> 10`.
- The user's visible latency: input echo, scrolling, resizing, search, and alternate-screen redraws.

Cherry-specific overhead to watch:

- `TerminalSession` still stores raw PTY output and tracks session state while Ghostty renders.
- Plain terminal sessions keep only a bounded auxiliary `LiveTerminalOutputBuffer`
  scrollback for Cherry-side state; Ghostty owns the visible terminal scrollback.
- `LiveTerminalOutputBuffer` parsing may duplicate work Ghostty already performs.
- `GhosttyOutputSink` coalescing helps progress-frame storms, but should not add input latency after host input.
- Surface detach/reattach should not leak `GhosttySessionBridge` objects or raw output observers.

### Keep background surfaces warm (`CHERRY_LIVE_SURFACE_LIMIT`)

Cherry keeps the most-recently-used background Ghostty surfaces alive and fed
across tab switches (the output observer stays installed), so a switch-back is a
re-show with no rebuild and no replay — matching how Ghostty and cmux keep a live
surface per pane. This is the **default** (`GhosttySessionBridge.liveSurfaceLimit`
= `defaultLiveSurfaceLimit`, 64). The active surface is always live; the cap only
bounds how many *inactive* ones stay warm, with the oldest evicted (and fully
released) past the cap — only those evicted surfaces fall back to the
rebuild-by-replay cold path (`renderedReplayOutput`).

Measured cost is ~3 MiB per light surface and ~8-10 MiB with heavy scrollback;
the cap bounds worst-case memory (64 ≈ keep everything for realistic tab counts).
Override the cap at runtime with `CHERRY_LIVE_SURFACE_LIMIT=N`. Use
`CHERRY_LIVE_SURFACE_LIMIT=unlimited` (or a negative value) to never evict — keep
every surface alive forever, the pure-Ghostty model where memory grows with tab
count (Ghostty itself has no eviction and can balloon at high surface counts).
Disable keep-warm (old replay-on-every-switch behavior) with
`CHERRY_LIVE_SURFACE_LIMIT=0` or a `-DCHERRY_REPLAY_ON_SWITCH` build
(`CHERRY_KEEP_SURFACES_WARM=0 Scripts/install-local-app`). Use the app-soak harness to measure the per-surface
RSS/CPU cost at your real tab count; `last_ghostty_live_bridge_count` and
`last_ghostty_output_observer_count` in the report show how many stay resident.

## Tooling

Currently useful without installing anything extra:

- `/usr/bin/time -lp` for repeatable wall time and max RSS.
- `Scripts/perf-terminal-report` for parsed stress reports and local baseline comparison.
- `xctrace` / Instruments Time Profiler for CPU hot paths.
- `sample`, `spindump`, `leaks`, and `vmmap` for hangs and memory.
- macOS unified logging for `TerminalPerformanceMonitor` output.

If these stop being enough, the next useful additions would be a small automated UI driver for opening many windows/tabs and a checked-in Instruments template for Cherry-specific captures.
