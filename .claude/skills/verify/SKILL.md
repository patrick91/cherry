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
