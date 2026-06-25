# Native-PTY migration (eliminating terminal replay)

Status: **in progress on branch `native-pty`**, behind the `CHERRY_NATIVE_PTY` flag.
`main` and the default (host-managed) path are **untouched**.

## Why

Cherry's terminal "replay" pain — lossy color recovery, first-mount catch-up,
resize-repaint, blank panes, the whole resident-surfaces grind — all comes from
**one architectural choice**: Cherry uses libghostty's **host-managed** I/O
backend. Cherry runs each PTY in its own layer (`TerminalSession` /
`ShellProcessController`) and feeds bytes to the ghostty surface used as a *pure
renderer*. The surface does **not** own the terminal state, so on
mount/resize/switch Cherry must **reconstruct** the screen from bytes — and
reconstruction is what keeps going wrong.

Ghostty (and cmux, the libghostty peer) never replay because **the surface owns
the PTY + Screen**. There is nothing to reconstruct. This migration adopts that
model: let the ghostty surface own the PTY (`EXEC` backend), so replay is
**impossible by construction**.

## Feasibility (verified)

- The vendored `libghostty-spm` 1.2.7 already ships `GHOSTTY_SURFACE_IO_BACKEND_EXEC`
  (it's even the wrapper default). Cherry was opting *out* via `.inMemory(...)`.
- Chrome hooks exist: `GHOSTTY_ACTION_PWD/_SET_TITLE/_RING_BELL/_PROGRESS_REPORT/`
  `_DESKTOP_NOTIFICATION`, `ghostty_surface_read_text` (full scrollback), childexited.
- Cherry isn't sandboxed, so an EXEC-spawned child is allowed.
- One genuine gap: `ghostty_surface_foreground_pid`/`tty_name` are absent from this
  binary (needs an XCFramework rebuild) — deferred.

## How to try it

The installed `~/Applications/Cherry.app` is currently the native build
(`CHERRY_NATIVE_PTY` baked). Or: `CHERRY_NATIVE_PTY=1 swift run -c release Cherry`.

**Revert to the stable build:** `git checkout main && Scripts/install-local-app`.

## Done

- **Spike** (`56e9e15`) — `backend: .exec`; ghostty owns the PTY. *Verified: renders + inputs, no replay.*
- **Stage A — command/env injection** (`d8e1b03`): native panes run **Cherry's
  resolved shell + environment** (login zsh + shell-integration `ZDOTDIR` +
  `CHERRY_STARTUP_COMMAND` + the ~15 env vars), not ghostty's default shell.
  - Wrapper: `TerminalSurfaceOptions.execCommand/execEnvironment`;
    `TerminalController+Surface.finalizeSurface` populates the C config
    `command`/`env_vars` with a strdup arena (correct pointer lifetime).
  - Cherry: `ShellProcessController.nativeExecLaunch` (mirrors the forkpty child
    setup), fed from the same `shellLaunchConfiguration()` the host path uses (parity).
- **Stage B — single shell** (`d8e1b03`): `TerminalSession.startShell` gates off
  the host forkpty for native panes (else **two shells per pane, two agents per
  agent pane**) and reaches `.live` so the surface mounts.
  - *Verified via control socket: spawns + selects native sessions, no crash.*

## Remaining (Stage C — exact plan)

The full implementation plan is the workflow synthesis; the key pieces:

### Known consequence to fix: the data layer goes dark
Under EXEC the forkpty `onData` never fires, so `rawOutputStore`/`outputVersion`
never advance. Everything reading them — `getProcessRawOutput`,
`searchProcessOutput`, `waitForProcessIdle`, agent-summaries — is dark for native
panes until re-sourced (verified: `contentVersion: 0`).

### C1–C3, C6 — chrome from ghostty actions (additive)
Cherry derives title/cwd/notification from PTY bytes today
(`TerminalSession.metadataEvent` ~798-851). Re-source from ghostty:
- **Title** — wrapper already forwards `GHOSTTY_ACTION_SET_TITLE` →
  `TerminalSurfaceTitleDelegate`; `GhosttySessionBridge` just needs to conform and
  route to `updateSystemTitle` (~`TerminalSession:3040`).
- **cwd** — add a delegate + `case GHOSTTY_ACTION_PWD` (`pwd.pwd`) → the
  `.workingDirectory` consumer (~`TerminalSession:3052`).
- **notification** — `case GHOSTTY_ACTION_DESKTOP_NOTIFICATION` (`title`/`body`) →
  the `.notification` consumer (~`TerminalSession:3061`).
- **exit code (closes Stage B's gap)** — `case GHOSTTY_ACTION_SHOW_CHILD_EXITED`
  (`child_exited.exit_code`) → `finishProcessExit(status:launchID:)`. (Field name
  in the header is literally `timetime_ms`.)

### C7–C9 — data layer from pull APIs
- Wrap `ghostty_surface_read_text` (SCREEN) + mandatory `ghostty_surface_free_text`
  (defer, same surface — leak risk) on `TerminalSurface`.
- Route `getProcessRawOutput`/search/agent-summary to `readText(.screen)` for
  native panes (note: rendered text, not raw VT bytes — a semantic change to flag).
- `waitForProcessIdle`: drive an `outputVersion` bump from a ghostty content-change
  signal (`GHOSTTY_ACTION_RENDER`, debounced) via `noteNativeOutputChanged()`.

### Then — flip default + delete (NEEDS HUMAN REVIEW)
Once the above is solid and visually verified: make native the default, then
delete the replay/recovery subsystem and the (now-moot) resident-surfaces code.

## Known gaps / decisions for review

- **Chrome stale + MCP/agents dark** for native panes until Stage C lands.
- **Shell exit not detected** until C6 (session stays `.live`).
- **`read_text` is rendered text, not raw VT bytes** — a behavior change for
  byte-exact MCP consumers.
- **Lost custom OSC 777** (`cherry-command`/`cherry-nix`) — no ghostty action
  equivalent; needs an out-of-band channel or a ghostty patch. Nix-shell env
  tracking degrades under native PTY.
- **foreground_pid/tty_name** absent from this binary → ServiceDetector / sidebar
  program label need an XCFramework rebuild.
- **Restart-on-exit** under EXEC re-mounts; behavior unverified.

## Rules being followed
Everything flag-gated; default/`main` untouched; verify via control socket since
screen capture is unavailable; **do not flip the default or delete replay** —
that waits for visual review.
