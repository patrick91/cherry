# Cherry Agent Notes

## Terminal Architecture

- `swift run Cherry` uses the embedded Ghostty-backed terminal path:
  `TerminalSurfaceView` -> `GhosttyTerminalContainerView` -> `GhosttySessionBridge` -> `GhosttyTerminal.TerminalView`.
- `TerminalCanvasView` in `TerminalSurface.swift` is the fallback/prototype renderer and input path. Do not assume changes there affect the default running app.
- `TerminalSession` still ingests raw PTY output into `PrototypeTerminalBuffer` even when Ghostty renders the UI. Session state such as cursor visibility, mouse modes, alternate screen, enhanced keyboard protocol, and application cursor keys can live in Cherry while display/input is Ghostty-backed.

## Keyboard Input

- The embedded Ghostty in-memory backend can bypass `ghostty_surface_key` for direct hardware keys. In particular, unmodified AppKit arrows may be sent directly as bytes by `libghostty-spm` instead of going through Ghostty's encoder.
- Cherry has bridge-level overrides in `GhosttySessionBridge` for host-managed input such as Shift+Enter and unmodified arrows.
- AppKit arrow key events commonly include `.numericPad` and/or `.function`; those should not be treated as user-held modifiers. Only `.shift`, `.control`, `.option`, and `.command` should disqualify an "unmodified arrow" override.
- `git diff` typically runs through `less`, which emits `ESC[?1h ESC=` and expects application cursor keys. Down should be `ESC O B` while application cursor mode is active, not `ESC [ B`.

## Config And Commands

- Agent tool configuration is global in `AgentSettings`.
- Project commands are per project and can be stored locally or in a managed section of `cherry.toml`.
- Use `cherry.toml` for shared project command configuration.

## Tests

- Prefer `swift test --no-parallel` for a reliable full-suite run.
- Plain `swift test` has shown a parallel-only control-server empty-response flake.

