# Cherry Sidebar Playground

A small native SwiftUI app for designing Cherry’s sidebar, inspired by the live parameter controls in [DialKit](https://joshpuckett.me/dialkit). It has no third-party dependencies and runs on macOS 14 or later.

## Use it

Open **Cherry Sidebar Playground.app**. Move the dials on the right; the preview updates immediately.

- **Layout:** sidebar width, left inset, row height, row gap, folder gap.
- **Icons:** maximum width/height, icon column width, text gap, folder icons, chevrons, and monochrome logos. Glyphs are normalized to their visible bounds and left-aligned; alignment guides show the column edges. Glyphs preserve their proportions; the column never shrinks below the glyph size.
- **Type:** text sizes, weight, subtitles, and shortcut hints.
- **Selection:** inset, corner radius, selected opacity, and hover opacity.
- **Colors:** sidebar, content, text, and highlight color pickers, plus light/dark starting palettes.
- **Sub-agents:** choose the Sub-agents scene for Codex and Claude parents with selectable children. Click the agent count to collapse/expand, or right-click a parent to add another child. Tune child indentation, spacing, tree guide offset/opacity, and status indicators. The guide starts at the parent icon’s left edge by default. Working/starting agents display animated spinners using the sidebar text color, ready agents a dot, and completed agents a checkmark. Animation can be disabled and respects macOS Reduce Motion. Closing a sample parent also removes its children.
- **Scenes:** populated, sub-agents, no projects, empty folder, nothing selected, and long names.

The sidebar is interactive: select and close sample sessions, add folders/terminals, and expand Commands and Notes. All content is sample data. No shells, agents, servers, or repository operations run.

**Compare** (⌘B) shows the current Cherry baseline without replacing your edits. **Presets** includes Current Cherry, Compact, Airy, and your saved variations. Saving an existing variation name updates it. **Reset** restores the baseline; **Reset scene** restores sample content only.

Changes and named variations save automatically in this app’s own preferences (`dev.patrick.cherry.sidebar-playground`). They do not modify Cherry’s settings or source code.

**Export…** (⌘E) saves the current design as JSON. Send that file back to apply the design in Cherry. **Import…** (⌘O) restores an exported design, including presets exported before the sub-agent controls were added. **Copy Swift** (⇧⌘C) copies equivalent reference values for implementation; they are not an automatically applied patch.

## Build

From the Cherry repository root:

```sh
Scripts/build-sidebar-playground
```

Outputs `dist/Cherry Sidebar Playground.app` and an architecture-specific DMG. Pass `--app-only` to skip the disk image. The build is ad-hoc signed for local testing, not notarized.

For development:

```sh
swift run --package-path Design/SidebarPlayground SidebarPlayground
swift test --package-path Design/SidebarPlayground --no-parallel
```

The standalone package avoids Ghostty and the main Cherry dependency graph. The sidebar is an independent design fixture rather than a shared production component; export values for a reviewed integration.

## Logo sources

The bundled logos are copied from Cherry’s existing resources: Claude, Neovim, and Python from Simple Icons (CC0); OpenAI’s geometric mark from Wikimedia Commons. They identify the sample programs and remain subject to their respective trademarks. See the main project’s `AgentLogos/README.md` and `ProgramLogos/PROGRAM_LOGOS.md` for provenance.
