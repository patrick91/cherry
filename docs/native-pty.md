# Native-PTY migration (eliminating terminal replay)

Status: **running sessions always use Ghostty's EXEC backend**. Ghostty owns the
surface's PTY. Shell-less previews and renderer tests retain the in-memory
backend. The remaining cleanup is deleting replay-only implementation that those
tests still exercise.

Since [multiplexer-default.md](specs/multiplexer-default.md), local tabs are
persistent sessions by default: the EXEC child is the `cherry attach` adapter,
and the program itself runs in a `cherry-host` holder with its own PTY. A tab
runs its program directly on the EXEC PTY when persistent sessions are off or
the local host cannot run them. AGENTS.md › Terminal Architecture describes both
paths as they are now; this document keeps only why the migration happened and
what it left.

## Why

Cherry's terminal "replay" pain — lossy color recovery, first-mount catch-up,
resize-repaint, blank panes, the whole resident-surfaces grind — all came from
**one architectural choice**: Cherry used libghostty's **host-managed** I/O
backend. Cherry ran each PTY in its own layer (`TerminalSession` /
`ShellProcessController`) and fed bytes to the ghostty surface used as a *pure
renderer*. The surface did **not** own the terminal state, so on
mount/resize/switch Cherry had to **reconstruct** the screen from bytes — and
reconstruction is what kept going wrong.

Ghostty (and cmux, the libghostty peer) never replay because **the surface owns
the PTY + Screen**. There is nothing to reconstruct. This migration adopted that
model: let the ghostty surface own the PTY (`EXEC` backend), so replay is
**impossible by construction**.

## Remaining cleanup

1. **Delete the replay subsystem** — `renderedReplayOutput`,
   `renderedReplayCache` and the first-mount/resize replay
   (`replayCurrentFrameForMountedGrid`) that the in-memory backend still uses,
   after replacing the remaining renderer-test coverage.

## Known gaps

These hold for native and persistent tabs alike:

- **Cherry's OSC 777 marks** (`cherry-command` / `cherry-nix`, written by the
  zsh integration) are read only by Cherry's own metadata parser, which sees
  only host-managed and injected output. Ghostty has no action for them and the
  host does not report them, so these tabs track no resolved command line and
  no nix-shell environment.
- **`get_process_raw_output` returns rendered text, not raw VT bytes**: the
  screen text of the surface (or of the host, when a persistent tab's surface
  does not show its program's whole screen), without escape sequences. Fine for
  human/agent reading; not byte-exact.
