---
name: verify
description: Build, launch, and observe Cherry changes end-to-end on this machine.
---

# Verifying Cherry changes

## Launch the app with your changes

```bash
./script/build_and_run.sh verify   # builds, packages dist/CherryDev.app, opens it, pgrep-checks
```

CherryDev.app has its own bundle ID (`app.cherry.CherryDev`), UserDefaults domain, Application
Support folder (`~/Library/Application Support/CherryDev`: saved tabs, notes, shell integration)
and URL scheme (`cherry-dev`), so it coexists with the user's production Cherry.app. Its
persistent sessions are owned by `CherryDev`. The script pkills only prior CherryDev instances.

The script first runs `Scripts/build-host debug` and copies `cherry` and `cherry-host` into
`CherryDev.app/Contents/MacOS/`, so it needs Rust (`cargo`, `rustc`); the first build also
downloads Zig and fetches Ghostty. `CHERRY_SKIP_HOST=1 ./script/build_and_run.sh verify` skips
the helpers. The script starts CherryDev with `open -n`, so the app gets launchd's environment,
not your shell's: it then finds helpers only in this checkout's `Host/target/{debug,release}`
(run `Scripts/build-host debug` first) or on launchd's PATH. `CHERRY_CLI_PATH` and
`CARGO_TARGET_DIR` reach the app only when you launch `dist/CherryDev.app/Contents/MacOS/CherryDev`
directly (or with `open --env`).

## Persistent sessions in CherryDev

- CherryDev's local tabs are persistent sessions by default (Settings › Sessions). **This Mac**
  uses the default socket `/tmp/cherry-host-$UID/host.sock`, the same daemon as the user's
  installed Cherry. Never `shutdown`, `kill` or remove sessions there, and never touch that
  directory. A rebuilt CherryDev whose helpers speak a newer protocol replaces that daemon (the
  user's sessions carry on, but the user's older Cherry can then no longer use it), and one of the
  same protocol keeps the old daemon's code, so test host changes on a private daemon. The helpers
  `build-host` makes without `CHERRY_BUILD_ID` report a development build (`dev-<commit
  time>.<rev>`), which never counts as newer than another: CherryDev and `swift run Cherry` never
  hand the shared daemon over to their own cherry-host (only `list`, `new` and `control` of an
  explicitly numbered build do, and only to the daemon's own executable updated in place), so
  removing `dist/CherryDev.app` never removes the running daemon's executable. Never set
  `CHERRY_BUILD_ID` (or the test-only `CHERRY_TEST_BUILD`) for a run that uses the default socket.
- For an isolated daemon, launch the binary directly (`open` drops exported variables) with a
  private `HOME` and sockets in a private directory:
  `dir=$(mktemp -d); chmod 700 "$dir"; mkdir "$dir/home"; HOME="$dir/home" CFFIXED_USER_HOME="$dir/home" CHERRY_HOST_SOCKET="$dir/host.sock" CHERRY_CONTROL_SOCKET="$dir/control.sock" dist/CherryDev.app/Contents/MacOS/CherryDev &`
  The daemon's state then goes under that `HOME`, and so do CherryDev's saved tabs. When done,
  quit CherryDev, wait for its process to exit (a quit that ends sessions or stops native
  programs hides the windows at once but runs up to 10 s more; `while kill -0 <pid>; do sleep
  0.2; done`), and run
  `python3 Scripts/cherry_private_host.py stop "$dir" --cli dist/CherryDev.app/Contents/MacOS/cherry`,
  which kills and
  removes every session there, shuts the daemon down, kills leftover holders and adapters, and
  deletes the directory. Its sessions' holders outlive a killed daemon, so never just kill it.
- Quitting CherryDev (⌘Q, `osascript -e 'quit app "CherryDev"'`) or closing a project window
  while persistent tabs run asks "Keep N sessions running in the background?" and waits for an
  answer. For scripted runs, launch with `-sessions.onQuit keep` (or `end`) so it asks nothing:
  `dist/CherryDev.app/Contents/MacOS/CherryDev -sessions.onQuit keep &` (or
  `open -n dist/CherryDev.app --args -sessions.onQuit keep`). SIGTERM (`kill <pid>`) also quits
  without asking and keeps the sessions.
- ⌘W on a tab whose program is at work (an agent, a command, a busy terminal) asks "Close
  “<name>”?" (Close, Detach Instead, Cancel) and waits; MCP `close_process` never asks. ⌘D
  detaches the tab (its session keeps running in the background, with a toast); ⌘⇧D is Split
  Right. After ⌘W a persistent tab's session is killed only ~6 s later (while its "Closed <name>"
  toast would stay; paused while CherryDev's window is not key, for a minute at most), or when the window closes or
  CherryDev quits: check the host's list after that, not at once. ⌘Z (with the terminal or the
  sidebar focused, not a text field) brings the tab back with the same session.
- When CherryDev opens while agents, commands or busy terminals of its closed windows or tabs still
  run on its daemon (not ones kept on purpose, never idle shells), a toast at the bottom of its first
  project window says so once ("N sessions are still running in the background"; it asks nothing).
  Launch with `-sessions.backgroundNoticeAtLaunch '<false/>'` to skip it; the menu bar icon's
  Background sessions list and Cherry › End Background Sessions… show and end them.
- The CLI can be driven headlessly the same way (`cherry --socket "$dir/host.sock" new|list|attach|kill`);
  `attach --status-file PATH` records how an attachment ended. Also give a headless daemon a private
  `HOME` (`mkdir "$dir/home"; HOME="$dir/home" cherry --socket "$dir/host.sock" …`): the daemon keeps
  its state under `HOME`, so nothing lands in `~/Library/Application Support/cherry-host/` (its
  sessions see that `HOME` too, and `~` in `--cwd` expands to it).

## Known environment limits (as of 2026-07)

- `osascript` keystrokes → **denied** (host app lacks Accessibility TCC). Cannot drive the GUI.
- `screencapture` → **denied** (no Screen Recording TCC). Cannot capture pixels.
- So palette/UI interactions need the user's eyes; leave CherryDev running and hand them a checklist.

## What you CAN observe at runtime

- Compile a standalone harness against real source files that only import AppKit
  (e.g. `swiftc -swift-version 5 Sources/Cherry/ExternalEditors.swift main.swift`) and exercise
  them on the real system. Top-level code isn't MainActor under `-swift-version 5`; wrap calls in
  `MainActor.assumeIsolated { ... }`.
- External-app side effects: Zed records opened workspaces in
  `~/Library/Application Support/Zed/db/0-stable/db.sqlite-wal` (check with `strings | grep <path>`).
- App health: `log show --last 3m --predicate 'process == "CherryDev"'`.

## Tests

`swift test --filter <prefix>` only — full suite has ~94 PTY-environment noise failures.
Prefer `--no-parallel` for full-suite runs (AGENTS.md).

Hosted and persistent sessions, as CI runs them: `Scripts/test-session-suites unit` (each
group — PersistentLocal, PersistentTab, WorkspacePersistence, WorkspaceRestore, HostControl,
HostedSession, HostedLaunchSpec, NativeSurfaceRelaunch, MultiplexerSafety, AgentInputSafety,
SessionCloseFlow, AppIdentity — on its own) and `Scripts/test-session-suites real-host` (every
`*RealHost*` test, each on its own daemon with a private socket and `HOME`; needs
`Scripts/build-host debug`, sets `CHERRY_TEST_HOST_INTEGRATION=1`, fails on any skip). A new
session suite must be named after a group in that script. Swift Testing's `--filter` matches
source file names as well as test names. Rust host checks are listed under Validation in
`Host/README.md`.
