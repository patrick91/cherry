# Cherry Performance Goal

Cherry should stay responsive and memory-stable during long-lived agent workspaces: many terminal tabs, multiple open windows, heavy scrollback, frequent alternate-screen redraws, and repeated detach/reattach of Ghostty-backed surfaces.

## What We Measure

In the app a tab's PTY belongs to its Ghostty surface (a native tab) or to its
session's `cherry-host hold` holder (a persistent tab, the default), not to
Cherry. Cherry's own host-managed path (`LiveTerminalOutputBuffer`, the raw
output it keeps for replay, PTY coalescing) runs only in tests, so only the
synthetic suite measures it.

- Synthetic suite (`Scripts/perf-terminal-stress`):
  - Long scrollback and TUI-style alternate-screen redraws through the
    host-managed buffer.
  - Raw output retention of host-managed sessions, also with many long-lived
    sessions receiving small output bursts.
  - Rebuilding an evicted surface from a styled replay (`renderedReplayOutput`).
  - Ghostty bridge/session churn across many sessions, and detached surfaces
    kept warm up to the live-surface cap (see below).
- App soak (`Scripts/perf-app-soak`): RSS and CPU of Cherry's processes (the
  app, its attach adapters and control helper, its session host's daemon and
  holders) under real workloads, and the runtime counters from
  `CHERRY_TERMINAL_PERF=1`: Ghostty bridges and output observers, Ghostty feed
  chunks, render ticks, SwiftUI representable updates, container configures,
  bridge attaches, `fitToSize`, and settings reconfigures. Its PTY chunk,
  processor backlog, background throttle and raw retention counters count
  only the host-managed path, so they stay at 0 in the app and the soak
  reports leave them out.

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
It also writes a parsed JSON report beside the log, also when a test fails (the
script then exits with the suite's status).

The synthetic suite is intentionally headless. It catches parser/state-tracking
and raw-output-retention regressions of the host-managed path, and
bridge-lifetime regressions, without opening the app.

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

Use the real app for UI/rendering work that synthetic tests cannot cover. The
simplest run is `Scripts/perf-run-emulator-comparison --cherry-only` (see the
shapes below): it builds Cherry, runs it from a private directory and drives it
with `Scripts/perf-app-soak`.

To drive a Cherry you start yourself, run CherryDev, not `swift run Cherry`
(which has the installed Cherry's identity: it restores, saves and ends your
own tabs and sessions on the shared session host), with a private `HOME` and
private sockets in a private (0700) directory, and performance counters
enabled:

```bash
./script/build_and_run.sh build
dir=$(mktemp -d /private/tmp/cherry-perf-XXXXXX); mkdir -m 700 "$dir/home"
HOME="$dir/home" CFFIXED_USER_HOME="$dir/home" \
CHERRY_HOST_SOCKET="$dir/host.sock" CHERRY_CONTROL_SOCKET="$dir/control.sock" \
CHERRY_TERMINAL_PERF=1 CHERRY_PERF_PROJECT_ROOTS="$PWD" \
  dist/CherryDev.app/Contents/MacOS/CherryDev -sessions.onQuit keep &
```

`CHERRY_PERF_PROJECT_ROOTS` is a colon- or newline-separated list of valid
directories. It is only honored when `CHERRY_TERMINAL_PERF=1` and does not save
those projects to app preferences.

Then drive it, with the same `$dir`:

```bash
Scripts/perf-app-soak --socket "$dir/control.sock" --scale smoke
Scripts/perf-app-soak --socket "$dir/control.sock" --scale standard
Scripts/perf-app-soak --socket "$dir/control.sock" --scale soak --windows 3 --tabs 24
```

When you are done, quit CherryDev, wait for its process to exit, and end the
run's sessions and session host and delete the directory:

```bash
python3 Scripts/cherry_private_host.py stop "$dir" --cli dist/CherryDev.app/Contents/MacOS/cherry
```

`Scripts/perf-app-soak` talks to Cherry's local control socket, opens project
windows from Cherry's configured/open project list, creates terminal tabs, sends
deterministic workloads, cycles selection through the spawned tabs so Ghostty
surfaces attach/detach, and writes a JSON report under `.build/perf/`. It
refuses a control socket outside a private run directory (0700, yours, with
`home/` in it), such as your own Cherry's, which a Cherry tab's
`CHERRY_CONTROL_SOCKET` names, unless you pass `--force`. It samples the RSS
and CPU of Cherry's processes: the app, the `cherry` helpers it runs
(persistent tabs' attach adapters, its control connection) and its session
host's daemon and holders (found by `CHERRY_HOST_SOCKET`, else the `host.sock`
beside the control socket); not the shells and programs in its tabs, since the
Ghostty control run samples only Ghostty. It verifies each spawned workload
starts producing real terminal output before the soak window begins, so a
command-submission regression fails loudly instead of measuring idle shells. It
closes only the processes it created unless `--keep-open` is passed, then waits
`--settle-after-close` seconds before the final sample so delayed detached
Ghostty surface release is not mistaken for a leak. For multi-window runs, open
or configure the target projects in Cherry first, or pass explicit repeated
`--project-root` values. Large many-session runs can use `--spawn-interval` to
pace setup while keeping the steady-state workload unchanged. Use `--sleep-ms`
with TUI workloads when you want a frame-paced long-session soak instead of a
flat-out PTY flood.

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

The app-soak JSON includes periodic samples of Cherry's processes:

- `samples[].total_rss_bytes`
- `samples[].total_cpu_percent`
- `samples[].processes[]` (`pid`, `rss_bytes`, `cpu_percent`, and `role`:
  `app`, `adapter`, `helper`, `daemon` or `holder`)
- `samples[].performance[].status.ghosttyLiveBridgeCount`
- `samples[].performance[].status.ghosttyInstalledOutputObserverCount`
- `samples[].performance[].status.rawOutputObserverCount`
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
- `sample_summary.last_terminal_perf_bridge_attaches`
- `sample_summary.last_terminal_perf_render_ticks`
- `sample_summary.max_total_cpu_percent`

For long-session leak hunting, prefer the drift fields over peak RSS alone:
`rss_delta_bytes` shows total end-to-start RSS growth, while
`rss_growth_mib_per_hour` normalizes that drift for multi-hour soaks. The
`steady_state_*` fields measure from after all workloads have started to the
last active pre-close sample, which separates leak-like growth from the expected
memory cost of opening many sessions. The Cherry-specific fields explain what
grew: which of Cherry's processes (`role`), Ghostty surfaces/observers, or
terminal feed/render counters. Use `--sample-interval 10` to increase or
decrease sampling frequency.

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
  --cherry-count-slack 2

Scripts/perf-app-report .build/perf/app-soak-soak-NEW.json \
  --max-total-cpu-percent 150 \
  --max-steady-state-rss-growth-mib-per-hour 1024
```

`--max-total-cpu-percent` puts a hard ceiling on the summed CPU of Cherry's
processes seen during the run. Use a tighter value for paced TUI soaks and a
higher mode-specific value for deliberate flood/overload tests.

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
and duration, then compare the reports (here with a Cherry run from a private
`$dir`, see App-Level Soak):

```bash
Scripts/perf-app-soak --socket "$dir/control.sock" --scale smoke --windows 3 --tabs 2 --duration 60
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

The launcher runs Cherry apart from your own copy: a private `HOME` (saved
workspaces, todos) and private control and session-host sockets
(`CHERRY_CONTROL_SOCKET`, `CHERRY_HOST_SOCKET`) in a private 0700 directory,
with a `cherry-host` of its own. By default it builds with
`swift build --product Cherry` and runs the built executable; `--cherry-command`
runs another command with the same environment. `--sessions persistent` (the
default, like the app's; it needs `Scripts/build-host debug`) runs Cherry's tabs
as persistent sessions on that private host, and `--sessions native` as native
tabs. The choice is passed to Cherry as a launch argument, whatever your own
setting, and recorded in the manifest. At the end every session there is
killed and removed, the daemon is shut down and the directory is deleted;
`--keep-cherry-open` instead prints
`python3 Scripts/cherry_private_host.py stop <dir>` for later teardown.
`Scripts/perf-app-soak` driving a Cherry you started yourself (see App-Level
Soak) measures that Cherry's own tabs, which are persistent sessions unless
Settings › Sessions turns them off.

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

- Ghostty (a native tab) or the session's holder (a persistent tab) owns the
  PTY; Cherry reads each tab's screen text from its surface, or from the host
  while a persistent tab's adapter is away, for its content model (MCP output
  and search, the sidebar).
- A persistent tab's output is parsed twice, by its holder's headless terminal
  and by its Ghostty surface, and each persistent tab has two processes of its
  own: its attach adapter (`cherry attach`) and its holder.
- The host-managed `LiveTerminalOutputBuffer`, raw output store and
  `GhosttyOutputSink` coalescing are what the synthetic suite measures; the
  app's tabs do not feed them.
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
`CHERRY_LIVE_SURFACE_LIMIT=0`. Use the app-soak harness to measure the per-surface
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

## Neovim Scrolling

Compare release builds at the same terminal grid size, font, display, and refresh
rate. Run this from the repository root in each terminal (use a different report
path for each run):

```bash
CHERRY_NVIM_SCROLL_REPORT=/tmp/cherry-nvim-scroll.json \
  nvim --clean -n -i NONE -c 'luafile Scripts/perf-nvim-scroll.lua'
```

The workload opens a generated Lua buffer with syntax highlighting, waits three
seconds, then scrolls three lines and redraws every eight milliseconds for 2,400
iterations. It exits its own fresh Neovim process and writes JSON with grid size,
Neovim version, elapsed time, redraw gap percentiles, and per-redraw timestamps.
Override `CHERRY_NVIM_SCROLL_FRAMES` or `CHERRY_NVIM_SCROLL_INTERVAL_MS` to change
the workload. It does not load the user's Neovim configuration or edit files.

These are **Neovim workload timings**, not presented frame rates or input latency:
a terminal can consume output quickly while dropping or delaying visual frames.
Compare physical trackpad and keyboard scrolling as well. For a CPU profile,
run `sample <terminal-pid> 5 -file /tmp/nvim-scroll.sample` while the workload is
active. Cherry's `renderTicks` counter measures host callbacks; native Ghostty
renders on its own thread, so this counter is not a native frame-rate meter.

The AppKit wrapper should let Ghostty's input/PTY handlers wake the renderer.
Adding an unconditional host refresh to every input event schedules unnecessary
work, even for key releases and sub-row wheel deltas. Similarly, moving the
scrollback viewport should update the renderer's origin without resizing its
terminal grid. `TerminalScrollingTests` covers both paths and checks that an
actual resize still updates the grid.
