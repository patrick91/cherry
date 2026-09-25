# Cherry

Small native macOS prototype for a `libghostty`-style shell with left-side tabs.

## Why this shape

- Uses SwiftUI for the window chrome and tab rail.
- Renders every terminal with an embedded Ghostty surface (`libghostty`), so
  TUIs such as `vim`, `top`, or `less` render as they do in Ghostty.
- Each local tab runs its program as a persistent session in `cherry-host`
  (see [Persistent Sessions](#persistent-sessions)), or on a native PTY when
  that is turned off or unavailable.

## Run

```bash
swift run Cherry
```

Run `Scripts/build-host debug` first so its tabs can be persistent sessions;
without the helpers they run natively. `swift run Cherry` shares the installed
Cherry's app data: while Cherry.app runs it is a second copy with native tabs
and no saved tabs, and otherwise it restores and saves Cherry.app's tabs. See
[Host/README.md](Host/README.md#use-in-the-mac-app) for running it apart.

Enable worktree spaces in **Cherry > Settings > General**. Cherry then discovers
every Git worktree for a project and keeps them
inside one project window. Switch with the worktree rail, an interactive
horizontal two-finger swipe over the sidebar, or `Cmd-Option-Left/Right`. The
rail's `+` and `...` buttons create, show/hide, prune, and safely remove clean
worktrees. The sliders button opens a temporary dogfooding panel for tuning the
swipe trigger distance and settle duration. Quick flicks can commit below the
distance threshold based on their velocity.

## Persistent Sessions

Local terminal, command and agent tabs run as persistent sessions by default.
A Rust host, `cherry-host`, keeps each session's program, PTY and a headless
Ghostty terminal in a holder process of its own, on this Mac or on a Mac or
Linux machine reached over SSH; the `cherry` client attaches to it, and each
tab's Ghostty surface runs that client. Quitting Cherry, a crash of Cherry, an
update, losing SSH, and a crash or restart of the host's daemon leave the
program running; each project window reopens its tabs attached to them, with
their screens. Sessions end when the machine reboots. Several terminals can
attach to one session and type into it; the shared terminal fits the smallest
one.

**Settings › Sessions** decides what closing does. By default, closing a tab
ends its session and quitting keeps the sessions for next time; **Keep running
after closing a tab** leaves a closed tab's session running (attach to it
again from Persistent Sessions), and **End sessions when quitting** ends them
when you quit or close a window. Removing a worktree ends its sessions. Turn
off **Run local terminals as persistent sessions** to run new tabs as ordinary
native tabs. Tabs are ordinary tabs anyway while the app runs from a disk
image, has no `cherry` helper, or cannot start a session, and in a second copy
of the app that shares the first one's app data (Settings › Sessions says
why). Sessions on SSH hosts always keep running when you close a tab or quit.

Open **File → Persistent Sessions…** (`Cmd-Shift-R`) to see every session on
**This Mac** or an SSH destination, and to create, attach to, or terminate
one. A remote machine needs `cherry-host` on its SSH command `PATH`. Building
the host, the `cherry` CLI, service setup, updates, the protocol, and current
limits are documented in [Host/README.md](Host/README.md).

To build a disk image for testing on this Mac:

```bash
Scripts/package-dmg
open "dist/Cherry Sessions-$(uname -m).dmg"
```

Drag **Cherry Sessions** into Applications and open it from there; while it
runs from the disk image, its local tabs are ordinary tabs and **This Mac** is
unavailable in Persistent Sessions. This test build has a distinct icon,
bundle identifier (`dev.patrick.cherry.sessions`), settings, and Application
Support folder, so it can run alongside Cherry and restores only its own tabs.
Both apps use the same local session daemon
(`/tmp/cherry-host-<uid>/host.sock`), so Persistent Sessions shows the same
sessions on **This Mac** in each. The app includes its persistent-session
helpers; no separate CLI installation is needed for **This Mac**. Open a
project, start a command or an editor in a tab, quit Cherry Sessions, and
reopen it: the tab comes back with the same process and screen. Multiple
devices can stay attached and type into one session. This is a local test
build, signed ad-hoc by default and not notarized. The disk image always
includes the helpers, so building it needs the same tools as the installer
below.

Updating the app does not end sessions. The first `cherry` of the new version
that connects replaces a daemon speaking an older protocol, and the sessions
carry on in their holders. On a remote host, put the new `cherry-host` on its
SSH command `PATH`; the next connection upgrades it the same way. A daemon
that speaks a newer protocol than the app is reported, never replaced, so
build Cherry and Cherry Sessions from the same version. A daemon from before
this protocol (4) cannot make way: finish its sessions and stop it with the
version that started it. See [the host guide](Host/README.md#updates).

Packaging verifies the copied app can open a terminal and render shell output
with access to the source checkout blocked, and that its bundled `cherry` and
`cherry-host` can start a daemon on a private socket and create, list, kill, and
remove a session. The packaged app runs with its own `CHERRY_HOST_SOCKET` and
`CHERRY_CONTROL_SOCKET` in a private (0700) fixture directory, never your
daemon, and its tabs must be persistent sessions on the bundled `cherry-host`.
Afterwards every session, the daemon, the holders and attach adapters, the
host's state directory and the smoke copy's preferences domain are removed.
This requires a logged-in macOS GUI session. To repeat the standalone check,
run `Scripts/test-packaged-app "/path/to/Cherry Sessions.app"` (add
`--skip-helpers` for an app built with `CHERRY_SKIP_HOST=1`).

## Local Install

Build and install a local `.app` copy into `~/Applications`:

```bash
Scripts/install-local-app
open ~/Applications/Cherry.app
```

The installer also builds the `cherry` and `cherry-host` helpers that
persistent sessions use and bundles them inside the app. That needs Rust
(`cargo` and `rustc`, from [rustup.rs](https://rustup.rs)) and the Xcode
command-line tools. The first build also needs network access:
`Scripts/build-host-vt` downloads a checksum-pinned Zig 0.16.0 and fetches a
pinned Ghostty revision, and Cargo fetches crates. Later builds reuse them.
The helpers are built into `CARGO_TARGET_DIR` (or `CARGO_BUILD_TARGET_DIR`)
when set, otherwise `Host/target`. To install without the helpers, and without
Rust:

```bash
CHERRY_SKIP_HOST=1 Scripts/install-local-app
```

Persistent sessions are then unavailable in that copy, and its local tabs run
natively: the default release build uses only the `cherry` bundled beside it,
never one on `PATH`. To use helpers
built elsewhere, quit the app and relaunch it with
`open --env CHERRY_CLI_PATH=/absolute/path/to/cherry ~/Applications/Cherry.app`.
That `cherry` starts the daemon from `CHERRY_HOST_PATH`, else the `cherry-host`
beside it, else one on your login shell's `PATH`. The lookup is described in
[Host/README.md](Host/README.md#use-in-the-mac-app).

Run the installer again after making changes to replace the installed copy.
You can customize the destination and name:

```bash
CHERRY_APP_NAME="Cherry Local" CHERRY_INSTALL_DIR="$HOME/Applications" Scripts/install-local-app
```

That copy keeps the default bundle identifier, so it shares the installed
Cherry's settings and data. For a separate dogfood build, also set its own
`CHERRY_BUNDLE_ID`, `CHERRY_APPLICATION_SUPPORT_NAME` (the folder in
`~/Library/Application Support`), and `CHERRY_URL_SCHEME` (its deep links and
MCP server name); the installer warns when a non-default bundle identifier
still shares Cherry's data folder or `cherry://` scheme:

```bash
CHERRY_APP_NAME="Cherry Local" CHERRY_BUNDLE_ID=com.example.cherry-local \
  CHERRY_APPLICATION_SUPPORT_NAME="Cherry Local" CHERRY_URL_SCHEME=cherry-local \
  Scripts/install-local-app
```

The installer checks these values before building and stops on an invalid
one: the bundle identifier uses letters, digits, and `-` in `.`-separated
parts; the URL scheme starts with a lowercase letter followed by lowercase
letters, digits, `+`, `.`, or `-`; the app and folder names are single names
without `/`, and the folder name has no surrounding spaces and may not differ
from `Cherry` only by case. `CHERRY_ICON_PATH` sets an `.icns` icon; a relative
path is relative to your current directory. A build whose Info.plist holds an
invalid folder name or scheme logs a warning and uses Cherry's.

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

For opt-in collection of labeled terminal-grid observations used by the local
attention-classifier experiment, see
[docs/attention-classifier.md](docs/attention-classifier.md). The interactive
scenario runner supports controlled captures across configured agent harnesses,
and `attention-web/` contains the private Astro/Cloudflare dataset viewer.

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
