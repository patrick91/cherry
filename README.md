# Cherry

Small native macOS prototype for a `libghostty`-style shell with left-side tabs.

## Why this shape

- Uses SwiftUI for the window chrome and tab rail.
- Uses an AppKit-backed terminal canvas for the scrollable surface so it only draws visible rows.
- Each tab now owns a live PTY-backed shell.
- Defaults to 50,000 lines of scrollback while still rendering only visible rows.

## Current State

- Works with a real login shell and real command output.
- Supports direct typing after clicking the terminal surface.
- Does not yet implement a full VT renderer, so TUIs such as `vim`, `top`, or `less` will still render imperfectly until `libghostty` is wired in.

## Run

```bash
swift run Cherry
```

Worktree spaces are currently opt-in while the UI is being dogfooded:

```bash
CHERRY_WORKTREE_SPACES=1 swift run Cherry
```

When enabled, Cherry discovers every Git worktree for a project and keeps them
inside one project window. Switch with the worktree rail, an interactive
horizontal two-finger swipe over the sidebar, or `Cmd-Option-Left/Right`. The
rail's `+` and `...` buttons create, show/hide, prune, and safely remove clean
worktrees. The sliders button opens a temporary dogfooding panel for tuning the
swipe trigger distance and settle duration. Quick flicks can commit below the
distance threshold based on their velocity.

## Local Install

Build and install a local `.app` copy into `~/Applications`:

```bash
Scripts/install-local-app
open ~/Applications/Cherry.app
```

Run the installer again after making changes to replace the installed copy.
You can customize the destination/name if you want a separate dogfood build:

```bash
CHERRY_APP_NAME="Cherry Local" CHERRY_INSTALL_DIR="$HOME/Applications" Scripts/install-local-app
```

Installed builds keep recently-used Ghostty terminal surfaces alive across tab
switches (no per-switch replay). To build the older replay-on-switch behavior
instead, opt out:

```bash
CHERRY_KEEP_SURFACES_WARM=0 Scripts/install-local-app
```

By default the installer uses ad-hoc signing, which can make macOS privacy
permissions reset after each rebuild because the code identity changes. To keep
Desktop/Documents/etc. permissions stable, sign local builds with a persistent
certificate:

```bash
CHERRY_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Scripts/install-local-app
```

If you do not have an Apple development certificate, create a local code-signing
certificate in Keychain Access and pass its common name as `CHERRY_CODESIGN_IDENTITY`.

Inside the prototype:

- Use the left rail to switch tabs.
- Use `New Tab` or `Cmd-T` to create another shell session.
- Click inside the terminal to type directly.
- Use the `Prototype` menu commands for interrupt, restart, and clearing scrollback.

## MCP Control

Cherry installs a stdio MCP helper next to the app executable. After installing
and opening the local app, register the helper with your agent harness:

```bash
codex mcp add cherry -- "$HOME/Applications/Cherry.app/Contents/MacOS/CherryMCP"
claude mcp add --transport stdio --scope user cherry -- "$HOME/Applications/Cherry.app/Contents/MacOS/CherryMCP"
```

Run the Cherry app first. The helper forwards MCP tool calls to Cherry's
instance-scoped Unix control socket under `/tmp/cherry-$UID/`. The MCP server
exposes process-first tools for terminals, agents, configured project commands,
output reads, idle waiting, service readiness, notes, and todos. See
[docs/mcp.md](docs/mcp.md) for the tool guide and recommended agent workflows.

## Rendering Debug

Run the terminal fixture inside Cherry and Ghostty side by side:

```bash
Scripts/terminal-hell-test
```

The most useful panels for background rendering bugs are `256-color and truecolor full-row backgrounds`, `Reset boundaries and inverse video`, and `Codex-style prompt paint`.

To capture the actual PTY stream while reproducing a rendering bug:

```bash
CHERRY_TRACE_PTY_DIR=/tmp/cherry-traces swift run
```

Then inspect the latest trace for palette queries and background SGR:

```bash
Scripts/analyze-terminal-trace /tmp/cherry-traces/*.pty --show-erase
```

Raw traces can include terminal output and prompt text, so treat them like logs.

## Performance Stress

Run the opt-in terminal stress suite:

```bash
Scripts/perf-terminal-stress --standard
```

Use `--smoke` for a quick check and `--soak` before perf-sensitive changes. For
real app UI soak runs, start Cherry and run `Scripts/perf-app-soak --scale
standard`. `Scripts/perf-app-report` summarizes peak RSS, end-to-start RSS
drift, MiB/hour growth, Ghostty bridge/observer counts, and raw replay
retention, with hard gates for CPU, memory drift, retained output, and PTY
callback density so long-session leaks are visible. Use paced TUI soaks such as
`--mode tui --sleep-ms 4` for long-session stability, and keep unpaced `mixed`
runs as overload/flood stress. `Scripts/perf-ghostty-workload` and
`Scripts/perf-ghostty-report` capture the same workload in Ghostty as a control
baseline, and `Scripts/perf-compare-emulators` prints Cherry/Ghostty ratios for
matched runs. `Scripts/perf-run-emulator-comparison` performs the paired
Cherry/Ghostty run end to end. The perf report scripts compare runs against
local baselines. See
[docs/performance.md](docs/performance.md) for the full performance goal,
app-level soak plan, and Ghostty comparison workflow.
