# Native-PTY migration (eliminating terminal replay)

Status: **Stages A–C done on branch `native-pty`**, behind the `CHERRY_NATIVE_PTY`
flag. `main` and the default (host-managed) path are **untouched**. What remains is
the human-reviewed cutover: flip the default and delete the replay subsystem.

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
- **Stage C — chrome + data layer + input** (`c0aa764`, `2235f73`): everything the
  host path derived from the PTY byte stream is now re-sourced from the surface, so
  native panes are usable end to end. All flag-gated; host path untouched.
  - **Chrome from ghostty actions** (`c0aa764`): new wrapper delegates +
    `handleAction` cases for `GHOSTTY_ACTION_PWD` / `DESKTOP_NOTIFICATION` /
    `SHOW_CHILD_EXITED` / `SET_TITLE`; `GhosttySessionBridge` forwards (gated on
    native) into `TerminalSession.ingestNative{Title,WorkingDirectory,Notification,
    ChildExit}`, which mirror the `ingestTerminalMetadata` cases. Child-exit closes
    Stage B's exit-detection gap.
  - **Data layer** (`2235f73`): `TerminalSurface.readText(screen:)` over
    `ghostty_surface_read_text` + `free_text`. `getProcessRawOutput` and a native
    line model behind `lineCount`/`snapshot(range:)` (→ search, getTerminalOutput,
    agent summaries) pull the surface scrollback lazily on read (throttled). A
    full-screen-hash change probe — driven by a debounced `GHOSTTY_ACTION_RENDER`
    signal (new `TerminalSurfaceRenderDelegate`) *and* on every read — advances
    `outputVersion`/`contentVersion`/`lastContentChangeAt` and the agent
    activity+summary hooks, so `waitForProcessIdle` and agent idle work.
  - **Input** (`2235f73`): `send(text:)`/`send(data:)`/`sendInterrupt` route to the
    surface under native (`shellProcess` is nil). Printable runs go through
    `ghostty_surface_text`; CR/LF and Ctrl-C become real key events
    (`sendKeyPress`) — a trailing CR via the text path does **not** submit.
  - *Verified via control socket against the native build:* getProcessRawOutput is
    live; injected input submits and runs; search finds produced output;
    `outputVersion` advances; `cd` updates the sidebar cwd (PWD action); `exit`
    flips the session to `.exited` with the right code (child-exited action).

## Remaining — the cutover (NEEDS HUMAN REVIEW)

Everything functional is done and socket-verified. What's left is the deliberate,
human-reviewed cutover — **not started**, waiting on Patrick's visual review on
real hardware:

1. **Flip the default** — make native the default backend (drop the
   `CHERRY_NATIVE_PTY` opt-in).
2. **Delete the replay subsystem** — `renderedReplayOutput`, `rawOutputStore`
   style-recovery merge, the first-mount/resize replay, and the (now-moot)
   resident-surfaces code on the shelved branch.

## Residual gaps / decisions for review

These remain under native and want a decision before/at cutover:

- **`read_text` is rendered text, not raw VT bytes** — `getProcessRawOutput` for
  native panes returns screen text without escape sequences. Fine for human/agent
  reading; a behavior change for any byte-exact consumer.
- **Lost custom OSC 777** (`cherry-command` / `cherry-nix`) — no ghostty action
  equivalent, so resolved-command-line and **nix-shell env tracking degrade** under
  native PTY. Needs an out-of-band channel or a ghostty patch.
- **foreground_pid / tty_name** absent from this binary → ServiceDetector / sidebar
  program label need an XCFramework rebuild.
- **Input edge cases** — only printable text + CR/LF + Ctrl-C are translated.
  Arbitrary control/escape sequences injected via `raw_base64` are sent as text,
  not synthesized keys.
- **Restart-on-exit** (command panes) under EXEC re-mounts the surface; now that
  exit is detected the path runs, but it's only socket-verified for plain exit, not
  visually for the restart redraw.
- **Title / desktop-notification actions** are wired identically to cwd (verified)
  but weren't separately socket-asserted.

## Rules being followed
Everything flag-gated; default/`main` untouched; verify via control socket since
screen capture is unavailable; **do not flip the default or delete replay** —
that waits for visual review.
