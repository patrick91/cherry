# Cherry sidebar studies

Two interactive directions, sharing the same project/folder/terminal model:

- **A — Focused project:** a project switcher above the active project's folders.
- **B — Project outline:** independently expandable projects; selecting work changes the scope of the bottom tools.

Open **[Cherry sidebar studies.html](Cherry%20sidebar%20studies.html)** directly in a browser. This export contains its own font, images, styles, and script, requires no server, and makes no network requests. It can be copied to another Mac as a single file.

For editing, run this from the repository root:

```sh
python3 -m http.server 8766 --bind 127.0.0.1 --directory Design/SidebarExploration
```

Then open <http://127.0.0.1:8766>. The `layout` and `state` URL parameters select the initial view. Rebuild the portable export with:

```sh
python3 Design/SidebarExploration/export.py
```

## What to try

- Change **Explore a state** through all ten scenarios in both layouts.
- Start at **No projects** and create a project, add a sample folder, and open a shell or agent.
- Close the last terminal; its folder remains, with an action to open another terminal.
- Expand **Commands**, run Start website twice, and observe its one terminal under website.
- Expand **Notes** and edit Sidebar ideas; switching folders keeps project-wide notes available.
- In B, expand a second project without changing selection; select work there to change the bottom tool scope.
- Clear selection in **Folder unavailable**, then select docs to find the recovery action again.
- Resize to a narrow window and use the sidebar menu.

Commands, folder selection, terminal input, and remote reconnection are simulated. No project files are accessed and no processes are started. Edits live only in page memory; changing scenario or reloading resets them. The “Future” state explores the shape of a remote project without committing to its implementation.

Commands and Notes are collapsed initially to keep folders in view. Their headings expand them; their plus buttons create definitions or notes. Folder and project disclosure controls only expand/collapse; selecting their name changes context. Removing folders/projects, reordering, splits, context menus, keyboard shortcuts, Todos placement, and native close safeguards are intentionally outside this prototype.

## Plan and references

See [the model, state table, and native migration plan](../../docs/specs/project-sidebar.md).

Inspiration reviewed on 18 September 2026:

- [Unpeel website](https://unpeel.com): restrained folder/session hierarchy and activity indicators.
- [Unpeel native sidebar](https://github.com/unpeel-com/unpeel/blob/7f2f5a33a26a26f133f52e88dd3047049088a3c2/clients/native/UnpeelNative/Sources/UnpeelNative/Views/SidebarView.swift): contextual empty project/session actions.
- [Unpeel terminal area](https://github.com/unpeel-com/unpeel/blob/7f2f5a33a26a26f133f52e88dd3047049088a3c2/clients/native/UnpeelNative/Sources/UnpeelNative/Views/TerminalArea.swift): distinct “nothing selected” state.

The multi-folder project model, copy, composition, and bottom project tools here are Cherry's proposed design. No Unpeel branding, mascot, or source was copied.

Assets: Cherry's existing icon; [Heroicons Micro v2.2.0](https://github.com/tailwindlabs/heroicons/tree/v2.2.0/optimized/16/solid) (MIT); [Inter Variable](https://github.com/rsms/inter) (SIL OFL). Licenses are in `assets/`.

## Verification

Checked in the browser on 18 September 2026:

- All ten scenarios in both directions, with no browser errors.
- Create project → add folder → open shell → simulated `pwd` → close final terminal.
- Command targeting and repeated launch reuse.
- Notes and tool scope across project switching, independent disclosure, and cancelled launch.
- Missing-folder recovery after clearing selection; offline status and disabled launch controls.
- Narrow 390px layout, sidebar opening/closing, and no horizontal page overflow.

JavaScript syntax and the portable export's embedded resources were also checked. The browser automation policy does not allow direct `file:` navigation, so visual/interaction verification used the localhost preview; direct file opening is for manual review. No native Swift code changed, so the native suite was not rerun.
