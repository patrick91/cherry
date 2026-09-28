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
their screens. Sessions end when the machine restarts or you log out; their
tabs still come back, in their places, as ended tabs ("Ended when the Mac
restarted" or "Ended when you logged out") with **Restart**, which starts the
shell, command or agent again in the tab's directory, and **Close**. A notice
in each such window names them, with **Restart All**. Tabs whose sessions you
ended yourself (closed, End Sessions, Background Sessions → End) stay closed.
Several terminals can attach to one session and type into it; the shared
terminal fits the smallest one. A tab whose session another terminal shows
too says so in a slim bar at its top ("Also open in 1 other client", or
"Shown at 80×24 because another client is smaller"), with **Take Over**, and
its sidebar row shows a shared glyph. If a session's host process crashes,
its tab says "The session host crashed" (with the log to look at) instead of
an exit status, and a command is not restarted by itself.

Closing a tab (**Cmd-W**) ends its session, and asks first when that would
stop a program at work (an agent, a command, or a terminal running a job):
**Close**, **Detach Instead** or **Cancel**. **Detach Tab** (**Cmd-D**; Split
Right is **Cmd-Shift-D**) closes the tab and leaves its session running in the
background; a notice at the bottom of the window says so, with **Reopen** to
bring it back. **Cmd-Z** (Edit › Undo Close Tab or Undo Detach Tab) brings a
tab you just closed or detached back where it was, with the same session, for
as long as its notice ("Closed <name>", with **Undo**) would stay: about 6
seconds, longer while the pointer rests on it or the window is in the
background (a minute at most for a closed tab, whose program keeps running
meanwhile). A closed tab's program stops only once that has passed (or when
its window closes or Cherry quits). In a text field or the notes editor,
Cmd-Z undoes typing as usual. Quitting Cherry
or closing a project window with local sessions still running asks once:
**Keep Running** (the default) leaves them running and brings their tabs back
next time, **End Sessions** stops their programs, and **Don't ask again**
stores the answer in **When quitting or closing a window** (Ask, Keep Running
or End Sessions). Keeping sessions quits at once unless ordinary (native) tabs
have programs to stop; otherwise, and when ending sessions, Cherry's windows
disappear at once, and it stops those programs and ends the sessions before it
exits (within 10 s). A log out, restart or shut down does not ask about
sessions and ends none itself (the system then ends them), but warns about
programs still running in them, as it does for native tabs, and an update keeps them
without asking. Removing a worktree ends its sessions. A
terminal tab whose shell exits with status 0 closes by itself, and the window
closes with its last tab; turn off **Close a tab when its shell exits** to
keep such tabs. Turn off **Run local terminals as persistent sessions** to
run new tabs as ordinary native tabs. Tabs are ordinary tabs anyway while the
app runs from a disk image, has no `cherry` helper, or cannot start a
session, and in a second copy of the app that shares the first one's app
data (Settings › Sessions says why). Sessions on SSH hosts always keep running when you close a tab, close a window or quit.
A tab of an SSH host that lost its connection, or could not reach the host,
waits for it ("3 tabs waiting for my-server", with **Retry Now**) and
attaches again once the host answers: Cherry asks the host with growing
delays, and at once when the Mac wakes or a network comes back. Tabs of a
host that was unreachable when their window opened come back once it
answers.

**Settings › Sessions › Session Host** shows the local host's build, uptime
and sessions, and offers **Reveal Log**, **Copy Diagnostics** (what `cherry
status` and `cherry doctor` report, for a bug report) and **Restart Host…**
(your programs keep running). In a terminal, `cherry status` describes the
host and `cherry doctor` checks it for problems and says how to fix them.

Sessions of windows or tabs you closed that keep running are listed under
**Background sessions** in the Cherry menu bar icon: click one to show it in a
tab (its project's window opens again with its other tabs), or hover and click
**End** twice to stop it (**Remove** for one that already ended). **Cherry →
End Background Sessions…**, **End All…** in that list and **Settings ›
Sessions › Background Sessions** end them all after asking. When Cherry opens
and agents, commands or busy terminals among them still run, a notice at the
bottom of a window says so once, with **Reopen** and **End…** (its time runs
only while that window is in front); sessions you kept running when you closed
their tab or window, and idle shells, are not mentioned. Turn that off with
**Tell me about background sessions when Cherry opens**. Only Cherry's own sessions are listed there; sessions made with the
`cherry` CLI or by another app are in Persistent Sessions. A bell or
notification from a background session (an agent that finished or needs
input) shows as a Cherry notification naming the session and its project
(a shell's bell only once until you open it, and a few a minute at most);
click it to open the session, whose tab then shows it unread. **Clear
Ended** in that list removes the sessions whose programs ended, and ended
ones that no saved tab brings back are removed by themselves after they
have been listed for 10 minutes while Cherry was in use (never one you have
not seen, or one whose host crashed). Removing a project in **Settings › Projects** offers to end its
background sessions first.

Open **File → Persistent Sessions…** (`Cmd-Shift-R`) to see every session on
**This Mac** or an SSH destination, and to create, attach to, or terminate
one. Renaming a tab renames its session there and in `cherry list` (an
agent's session takes the agent's task title); Cherry's own sessions show
their kind, project and what they run, and one already open in a tab offers
**Show Tab**. A remote machine needs `cherry-host` on its SSH command `PATH`. Building
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
that connects replaces a daemon speaking an older protocol, or the same
protocol but an older build, and the sessions carry on in their holders
(each keeps the build it started with until it ends). On a remote host, put the new `cherry-host` on its
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
