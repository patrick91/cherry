---
name: verify
description: Build, launch, and observe Cherry changes end-to-end on this machine.
---

# Verifying Cherry changes

## Launch the app with your changes

```bash
./script/build_and_run.sh verify   # builds, packages dist/CherryDev.app, opens it, pgrep-checks
```

CherryDev.app has its own bundle ID (`app.cherry.CherryDev`) and UserDefaults domain, so it
coexists with the user's production Cherry.app. The script pkills only prior CherryDev instances.

The script first runs `Scripts/build-host debug` and copies `cherry` and `cherry-host` into
`CherryDev.app/Contents/MacOS/`, so it needs Rust (`cargo`, `rustc`); the first build also
downloads Zig and fetches Ghostty. `CHERRY_SKIP_HOST=1 ./script/build_and_run.sh verify` skips
the helpers. The script starts CherryDev with `open -n`, so the app gets launchd's environment,
not your shell's: it then finds helpers only in this checkout's `Host/target/{debug,release}`
(run `Scripts/build-host debug` first) or on launchd's PATH. `CHERRY_CLI_PATH` and
`CARGO_TARGET_DIR` reach the app only when you launch `dist/CherryDev.app/Contents/MacOS/CherryDev`
directly (or with `open --env`).

## Persistent sessions in CherryDev

- **This Mac** uses the default socket `/tmp/cherry-host-$UID/host.sock`, the same daemon as the
  user's installed Cherry. Never `shutdown`, `kill` or remove sessions there, and never touch that
  directory. A running daemon keeps its old code after a rebuild, so host changes need a fresh one.
- For an isolated daemon, launch the binary directly (`open` drops exported variables) with a
  socket in a private directory:
  `dir=$(mktemp -d); chmod 700 "$dir"; CHERRY_HOST_SOCKET="$dir/host.sock" dist/CherryDev.app/Contents/MacOS/CherryDev &`
  Its state goes to `~/Library/Application Support/cherry-host/<hash>/`. When done, run
  `dist/CherryDev.app/Contents/MacOS/cherry --socket "$dir/host.sock" shutdown` after killing
  its sessions, then delete that state directory.
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

Hosted sessions: `swift test --no-parallel --filter HostedSession`. The real-host test needs
`Scripts/build-host debug` first:
`CHERRY_TEST_HOST_INTEGRATION=1 swift test --no-parallel --filter HostedSessionRealHost`.
Rust host checks are listed under Validation in `Host/README.md`.
