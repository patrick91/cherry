# Ghostty Lifecycle Parity

## Problem

Cherry can become laggy after a long dogfood session with many terminal tabs. The current running app showed high CPU spikes, a physical footprint around 3.4 GB, and `vmmap` attributed most of the footprint to graphics allocations, especially `IOSurface`. A `sample` of the process showed work in the Ghostty-backed Metal renderer and many retained Ghostty renderer/io/cf_release threads.

The important distinction is that high memory from many genuinely open terminal surfaces is not itself a leak. Upstream Ghostty keeps a real surface per tab/split and uses occlusion/focus to avoid unnecessary rendering. Cherry should align with that behavior rather than inventing hidden-tab replay or hibernation.

The bug class to fix is lifecycle drift: closed sessions, detached SwiftUI/AppKit views, note/todo transitions, or window detach paths must not leave extra Ghostty surfaces, bridges, callbacks, or raw-output observers alive.

## Goals

- Match upstream Ghostty's lifecycle model for macOS terminal surfaces.
- Keep a Ghostty surface alive for each terminal session that actually still owns a rendered terminal.
- Propagate focus and visibility/occlusion accurately so non-visible surfaces are not actively drawing.
- Release all Ghostty resources when a Cherry terminal session is closed or a bridge is no longer owned.
- Add developer-only counters/tests so lifecycle leaks are visible during development.
- Verify with both automated tests and macOS tools.

## Non-Goals

- Do not implement replay-based hidden-tab hibernation.
- Do not pause PTY output for hidden tabs.
- Do not reduce memory to one visible terminal surface when many terminal tabs remain open.
- Do not add user-facing resource diagnostics in this pass.
- Do not rework the fallback `TerminalCanvasView`; the running app uses the Ghostty-backed path.

## Upstream Ghostty Model

Upstream Ghostty's macOS app creates a `Ghostty.SurfaceView`, which creates one `ghostty_surface_t` during initialization and wraps it in `Ghostty.Surface`. `Ghostty.Surface.deinit` calls `ghostty_surface_free(surface)`. Closing tabs/splits removes surface views from the owning tree/window so deinit releases the surface. Window visibility is handled with `ghostty_surface_set_occlusion(surface, visible)`, not by destroying and replaying surfaces.

Core Ghostty then sends visibility changes to the renderer thread. Surface deinit stops renderer and IO threads. That is the behavior Cherry should mirror.

## Cherry Architecture Constraints

Cherry is not embedding Ghostty exactly the same way as the upstream app. Cherry owns the PTY and raw output in `TerminalSession`, and feeds Ghostty through the in-memory backend:

`TerminalSurfaceView -> GhosttyTerminalContainerView -> GhosttySessionBridge -> GhosttyTerminal.TerminalView`

`TerminalSession` also keeps ingesting PTY output into `PrototypeTerminalBuffer` for Cherry-owned session state. That must continue. Hidden tabs and agents cannot stop receiving PTY output without breaking command/agent behavior.

## Technical Design

### 1. Make Session Close Release the Ghostty Bridge

`TerminalWorkspace.close(_:)` currently removes the session and calls `session.stop()`. The close path should also release the Ghostty UI/rendering side.

Add a `TerminalSession.releaseGhosttyBridge()` or similarly named method that:

- Detaches the bridge from any active `GhosttyTerminalContainerView`.
- Uninstalls the raw-output observer.
- Frees the Ghostty surface if one exists.
- Clears callbacks such as controller wakeups.
- Sets `ghosttyBridgeStorage = nil`.

`TerminalSession.stop()` should remain process-oriented. Closing a tab should call the bridge release method; stopping/restarting the shell should not necessarily destroy the visible terminal UI unless the existing reset path explicitly requires it.

### 2. Add a Narrow Lifecycle API to `libghostty-spm`

If existing APIs are insufficient, add a small public API in the vendored wrapper rather than reaching through private internals from Cherry.

Expected shape:

```swift
public func freeSurface()
```

on `TerminalView` or equivalent, forwarding to `TerminalSurfaceCoordinator.freeSurface()`.

This should mirror upstream `ghostty_surface_free` semantics as closely as possible for the embedded wrapper: free the surface, remove retained bridges from `TerminalController`, clear callbacks, and leave the wrapper ready to rebuild if explicitly attached again.

Keep this API narrow. It should not implement replay, hibernation, or policy.

### 3. Fix AppKit/SwiftUI Detach Semantics

`TerminalSurfaceView` should implement `dismantleNSView` and explicitly detach the active session from its container.

`GhosttyTerminalContainerView.viewDidMoveToWindow()` should not call `attach` when `window == nil`. On detach from a window it should mark the active terminal surface invisible and avoid creating or reattaching surfaces.

`GhosttyTerminalContainerView` should expose a focused cleanup method, for example:

```swift
func detachActiveSession()
```

This method should detach the active bridge from the container and clear `activeSession` / `activeBridge` as appropriate. It should not close the PTY or remove the `TerminalSession` from the workspace.

### 4. Keep Hidden Tabs Alive, But Occluded

When switching from one session to another, the old surface should remain alive if the session remains open. The old surface should be detached from the visible container and set non-visible/occluded. The new surface should attach to the container, become visible, fit to size, and receive focus if appropriate.

This is Ghostty parity. It means a previously rendered hidden tab may still have a surface and associated renderer/io resources, but it should not be actively drawing just because it is hidden.

### 5. Raw Output Observer Policy

For an open session with an existing Ghostty bridge, keeping the raw-output observer installed is acceptable and matches the decision to keep hidden surfaces alive. Do not uninstall observers merely because a tab is hidden.

Observers must be uninstalled when the bridge is released due to close/deinit/reset. This is the leak boundary.

### 6. Developer-Only Diagnostics

Add debug-only counters or assertions for:

- Live `GhosttySessionBridge` count.
- Installed raw-output observer count.
- Live or currently allocated Ghostty surfaces, where testable.
- Active container attachments.

Prefer `#if DEBUG` static counters or internal test-visible counters. Do not add user-facing UI.

The counters should support assertions like:

- Closing a terminal decrements bridge/observer counts.
- Switching tabs does not increase counts beyond the number of sessions that have been rendered.
- SwiftUI dismantle removes the container attachment.

## Edge Cases

- Closing a selected tab should release its bridge and choose the next selected session.
- Closing a non-selected tab should release its bridge without disturbing the selected tab.
- Restarting a session should keep the rendered terminal view if the tab remains open, while existing reset behavior may rebuild Ghostty state.
- Clearing scrollback should still reset the Ghostty in-memory renderer as it does today.
- Showing notes/todos or other non-terminal content must detach the terminal container without closing the session.
- Window detach/re-attach during SwiftUI diffing should not accidentally create duplicate surfaces.
- App/window occlusion should propagate to all relevant surfaces for that window, matching upstream Ghostty.

## Testing Strategy

Use `swift test --no-parallel` for the full suite.

Add focused tests around lifecycle ownership:

- `TerminalWorkspace.close(_:)` releases a created `GhosttySessionBridge`.
- Closing a session removes any raw-output observer installed by its bridge.
- `TerminalSurfaceView.dismantleNSView` detaches the active session from the container.
- `GhosttyTerminalContainerView.viewDidMoveToWindow(nil)` does not reattach or create a surface.
- `TerminalSurfaceCoordinator.freeSurface()` continues to remove retained bridges from `TerminalController`.

Use existing `ThirdParty/libghostty-spm/Tests/GhosttyKitTest/TerminalLifecycleTests.swift` as the model for wrapper-level lifecycle tests.

## Manual Verification

After implementation:

1. Build/install/run Cherry.
2. Open multiple terminal tabs and switch among them.
3. Show notes/todos or any non-terminal view if available.
4. Close several terminals.
5. Use macOS tools to compare before/after behavior:

```bash
pgrep -fl Cherry
sample <pid> 5 -file /tmp/cherry.sample.txt
vmmap -summary <pid>
lsof -p <pid> | rg '/dev/ptmx|control.sock|61234'
ps -M -p <pid>
```

Expected result: closed sessions do not leave extra Ghostty renderer/io threads, raw observers, PTYs, or surfaces behind. Hidden but still-open rendered sessions may still account for resources.

## Technology Decisions

| Choice | Purpose | Status | Alternatives | Rationale |
| --- | --- | --- | --- | --- |
| Upstream Ghostty lifecycle semantics | Define expected surface/tab behavior | Local source reviewed in `/Users/patrick/github/ghostty-org/ghostty` | Cherry-specific hibernation/replay | Aligns with the source project and avoids inventing terminal-state replay. |
| Vendored `libghostty-spm` narrow lifecycle API | Expose safe surface teardown to Cherry | Existing local dependency | Private reaching or broad wrapper refactor | Keeps ownership explicit and testable without large architectural churn. |
| Developer-only counters | Detect leaks during tests/dogfooding | Built into app/test code | User-facing diagnostics | Solves the engineering problem without product UI. |

## Decisions Log

- Initial diagnosis found high CPU/Metal work and large `IOSurface` memory in the running Cherry process.
- We first considered hidden-tab hibernation, then checked upstream Ghostty before committing.
- Upstream Ghostty keeps a real surface per tab/split and uses occlusion rather than hidden-tab replay.
- Decision: align with Ghostty; do not implement replay-based hibernation.
- Decision: diagnostics are developer-only.
- Decision: allow a narrow API addition in `ThirdParty/libghostty-spm` if existing APIs cannot express proper teardown.
- Decision: acceptance is no lifecycle leaks, not memory dropping when tabs are merely hidden.
- Decision: verification requires focused tests plus macOS profiling tools.

## Implementation Order

1. Add wrapper-level surface teardown API and tests in `ThirdParty/libghostty-spm`.
2. Add `GhosttySessionBridge` release/detach methods and debug counters.
3. Add `TerminalSession` bridge release ownership and call it from terminal close paths.
4. Add SwiftUI/AppKit dismantle and `viewDidMoveToWindow(nil)` fixes.
5. Add Cherry lifecycle tests.
6. Run `swift test --no-parallel`.
7. Rebuild/run Cherry and verify with `sample`, `vmmap`, `lsof`, and thread/process counts.

## Acceptance Criteria

- A user can open several terminal tabs, switch among them, and close them without accumulating extra live bridges, raw-output observers, or Ghostty surfaces beyond the still-open sessions.
- Showing non-terminal content detaches the visible terminal container without closing the selected session or creating duplicate surfaces on return.
- Hidden open tabs continue receiving output and preserve terminal state.
- Closed tabs release their Ghostty resources.
- The full test suite passes with `swift test --no-parallel`.
- Manual macOS profiling confirms closed-session resources are reclaimed and samples no longer show work from surfaces that should have been closed.
