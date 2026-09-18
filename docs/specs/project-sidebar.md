# Project sidebar exploration

## Status and scope

This is a design and implementation plan, accompanied by two interactive layouts in the portable [Cherry sidebar studies.html](../../Design/SidebarExploration/Cherry%20sidebar%20studies.html). Open that file directly in a browser; it contains its assets and needs no server or network. The editable entry point is [index.html](../../Design/SidebarExploration/index.html); the [README](../../Design/SidebarExploration/README.md) covers previewing, export, inspiration sources, and asset attribution.

The layouts use synthetic data and a shared state engine. Actions do not access project files, launch processes, or establish remote connections. Edits live in page memory and reset when changing scenario or reloading; changing layout keeps the current scenario and work. Native behavior is unchanged.

The exploration starts from `main` at `0d16c2e`, on `codex/sidebar-exploration`. Persistent-session and multiplexer work is parked on `codex/persistent-sessions` at `039f4c9`. Remote projects are a future design case, not functionality delivered by this exploration.

## Product model

A **project** is a named group of folders. A **folder** owns an ordered collection of terminals. A shell, editor, agent, and command process all appear as terminal rows under their owning folder. Program icons, activity, and titles describe what a terminal is doing; they do not create separate Agents or Terminals sections.

Commands and Notes form a separate area at the bottom of the sidebar, scoped to the active project. They are collapsed initially; headings expand their lists and plus buttons add content. The dedicated No commands and No notes scenarios expand the relevant section. Changing folders does not change their scope. Worktrees may be identified with optional folder metadata and Git actions; they do not have a primary sidebar area or determine which folders a project can contain.

| Entity | Proposed ownership and identity |
| --- | --- |
| Project | Stable ID, editable name, ordered folder IDs, appearance, project features. A future execution host belongs here. |
| Folder | Stable ID, project ID, path, optional display name, availability, optional repository/worktree metadata. |
| Terminal | Stable session ID, owning folder ID, display order or split membership, title, process/activity metadata. Current working directory can change without moving its sidebar ownership. |
| Command definition | Stable ID, project ID, explicit target folder ID, command, relative working directory, environment, launch policy, storage source. |
| Command run | A terminal under the definition's target folder, linked back to the command definition for status and restart actions. |
| Note / Todo | Project-owned content with existing IDs and metadata preserved. Folder switching does not filter it. |
| View state | Active project, expanded folders, contextual folder, and explicit detail selection: none, terminal, note, or another project tool. |

Folder ownership must remain separate from a terminal's reported working directory: `cd` should not reorganize the sidebar. Selecting a folder establishes a target for **Open terminal**; selecting a terminal establishes both its project and folder context. Folder disclosure only expands or collapses its rows, independently of selection. Selecting the folder name also expands it. Collapsing a folder does not close or stop its terminals.

## Two layouts to compare

**A — Focused project switcher, recommended.** The header selects one project, with that project's folders directly below it. Commands and Notes remain at the bottom. This keeps hierarchy shallow and makes command/note scope unambiguous. The main tradeoff is reduced visibility into activity in other projects; the switcher can summarize that activity.

**B — Project outline.** Every project appears in a tree, containing folders and terminal rows. Several projects can stay expanded independently. Selecting a project, folder, or terminal changes the active project; operating a project or folder disclosure does not. The bottom area explicitly names the active project so command and note ownership stays clear. This provides cross-project visibility at the cost of another indentation level and more scrolling.

Both layouts expose the same ten scenarios and actions. The folder/terminal area scrolls independently from the bottom project tools. Terminal content and typed input are simulated. Folder addition uses a sample-path form in place of the native folder picker; **Open terminal** offers Shell, Codex, and Claude. Removing projects/folders, reordering, splits, context menus, keyboard shortcuts, Todos placement, and native close safeguards are outside this prototype.

## States and actions

| State | Sidebar and detail | Primary action and result |
| --- | --- | --- |
| No projects | Welcoming empty detail; no fabricated project or folder. | **Create project** creates an empty named project and selects it. |
| Project without folders | Project remains visible; detail explains that folders hold terminals. Project Notes remain usable. | **Add folder** adds a folder to this project. Commands cannot run until their target exists. |
| Folder without terminals | Expanded folder with a quiet Open terminal action; no empty Agent/Terminal sections. | **Open terminal** offers a shell or agent, then creates and selects its row. |
| One folder, fresh terminal | A single selected shell with a clear prompt and folder path. | Try simulated `pwd` or `ls`, or close the terminal to return to the empty folder. |
| Everyday work | Expanded folders show their own shell, agent, and command terminal rows; selection is singular and visible. | Select a terminal, expand/collapse folders, open another terminal, or switch projects. |
| Nothing selected | Existing terminal rows remain; detail invites choosing a row or using Open terminal. | Selecting a row restores detail. Clearing selection is distinct from closing a terminal. |
| No commands | Expanded Commands section and an empty detail with a contextual action. | **Add command** collects a name, command, and target folder. Running the saved definition reveals its folder terminal. |
| No notes | Expanded Notes section and a project-scoped empty detail. | **Write a note** creates a titled note and opens its editable body. |
| Folder unavailable | Preserve folder, path, and child records; show availability status. | **Locate folder** updates the location while preserving folder identity. Block new launches in that folder until resolved. |
| Future remote project offline | Project-level offline status and preserved folder/terminal records. | **Reconnect** is a simulated prototype action. Real connection, persistence, and recovery behavior require a later design. |

Closing the last terminal leaves its folder empty. Clearing selection preserves folder availability; selecting an unavailable folder shows recovery again. In the native rollout, removing a folder must remain distinct from deleting files and use existing protections for running processes. A missing folder must never silently redirect a command to another folder or the home directory.

## Commands, Notes, and Todos

Commands remain project-level definitions even though every launch targets a particular folder, shown in the command row. Running a command creates its terminal under that target folder and reveals it; running the same definition again selects the existing terminal. The bottom row stays a reusable definition. The prototype does not implement stop/restart; native implementation must preserve those policies. Folder changes must not retarget a saved command.

Continue using `cherry.toml` for shared command configuration and local settings for local overrides. Definitions loaded from a folder's file retain that folder as their source and default target. Names alone are insufficient identity when two folders both define `dev`; preserve source/target identity and make duplicates distinguishable. Decide the portable format for cross-folder targets before writing shared configuration.

Notes belong to the project and remain available with no folder or selected terminal. Preserve note IDs, text, timestamps, feature settings, and existing links during migration. Todos are outside this layout comparison, not removed from the product: preserve their IDs, descriptions, comments, tags, ordering, status, and enabled state. Their final navigation placement remains a design decision.

## Proposed session lifetime setting

Add a global setting under Terminal: **Keep terminals running after Cherry closes**. This is a proposed opt-in mode, not a setting implemented by the HTML prototypes or native app. Keep it off initially while the hosted path is validated for everyday local use. Apply it to all newly created local terminals, including shells, agents, and command runs; avoid a separate persistent-terminal section in the sidebar.

When enabled, new processes belong to the local Cherry session host. The app renders and attaches to them. Turning off quit confirmation alone cannot provide this behavior: current local terminals are owned by the app's Ghostty PTYs, and quit/window teardown explicitly terminates their processes.

| Action | Proposed behavior in background mode |
| --- | --- |
| Quit Cherry or close a project window | Disconnect the views; keep hosted processes running. Do not warn that these processes will stop. |
| Reopen Cherry or the project | Reattach its existing terminals and restore folder ownership, ordering, splits, and selection. Do not rerun the launch command. |
| Explicitly stop a terminal | Terminate the host-owned process, retaining appropriate confirmation for running work. Stopping it also affects other attached clients. |
| Hide/disconnect a terminal view | Keep the process discoverable under its folder; distinguish this from stopping it. Final row-close affordance needs to make that distinction clear. |
| Change the setting | Affect future terminals. Existing terminals retain their actual lifetime policy; no silent restart or attempted transfer of a live app-owned PTY. |
| Host unavailable | Show a recoverable connection error; do not silently create a temporary local terminal. |

Persist project/folder IDs with host identity and host-issued session IDs. Reconcile these records with the host on return, including exited sessions, missing hosts, and uncertain creation results. Persisting a command string and launching it again is not session restoration. Project switching and reconnecting must not create duplicate sessions or resend previous keyboard input.

During a mixed session, quit/close warnings should count only processes that will actually stop. Turning the setting off must not terminate already-hosted work. A future remote project naturally uses its remote host; the local default must never change a remote terminal's lifetime.

Resolve the last-terminal shortcut explicitly: current Cmd+W delegates to window close when only one session remains. It must not accidentally change from stopping a terminal to detaching it based solely on the number of rows. The parked preview currently treats tab close as disconnect; any revised stop behavior needs its own host operation and clear labeling.

The parked host already supplies create/list/attach/terminate operations and survives client exit. Remaining integration includes routing every local launch through it, durable project/folder/session mapping, reopen recovery, lifecycle-specific teardown, accurate process/activity reporting, command restart policy, and terminal feature/performance verification. Automatic command restart while the app is absent requires host-side supervision; GUI timers do not continue after quit.

The current host preserves processes while its daemon and machine remain alive. Background mode must not promise uninterrupted work while the machine sleeps, or process survival across logout, reboot, daemon failure, or daemon upgrades. Evaluate those service and upgrade behaviors separately.

Introduce this after the project/folder identity and sidebar model are settled. It reuses the parked multiplexer without making the sidebar exploration depend on shipping it. A per-project override can be considered later if the global preference proves insufficient.

## Native migration seams

Locations below refer to baseline `main` at `0d16c2e`; symbols are the stable references as lines move.

| Existing seam | Required change |
| --- | --- |
| `Sources/Cherry/AgentSettings.swift:562`, `CherryProject` | Replace path-as-project identity with stable project identity and ordered folders. Migrate each existing project to a one-folder project; do not implicitly merge saved projects. |
| `Sources/Cherry/AgentSettings.swift:643`, `AgentSettings`; `:1066`, `loadProjects` | Version persisted data, preserve ordering/settings, and retain unavailable folders. Current loading filters out invalid local directories. Keep legacy root aliases while clients migrate. |
| `Sources/Cherry/RepositoryWorkspace.swift:25`, `RepositoryWorkspace` | Extract project/folder workspace ownership from Git worktree discovery. Retain lazy workspace creation and live session ownership; Git becomes optional metadata. |
| `Sources/Cherry/TerminalSession.swift:1061`, `TerminalWorkspace`; `:1314`, `addAgentSession`; `:1338`, `addCommandSession` | Produce one ordered folder display sequence for shells, agents, command runs, and splits. Preserve internal agent activity and relationships. Update row ordering, close behavior, and keyboard navigation together. |
| `Sources/Cherry/TerminalSession.swift:1099`, `selectedSession` | Its current nil-selection fallback returns the first session. Explicit detail selection is needed to represent “nothing selected” while sessions remain. |
| `Sources/Cherry/AgentSettings.swift:143`, `ProjectCommandDefinition`; `:714`, `projectCommands` | Add durable command/target identity; preserve local-over-file precedence and existing launch policies. Replace launch-time dependence on the currently selected root. |
| `Sources/Cherry/CherryApp.swift:541`, `ProjectWorkspaceView`; `Sources/Cherry/ProjectWindowRegistry.swift:7` | Key project windows/stores by project ID; resolve terminal actions through folder and session ownership. The current scene owns one repository and root-indexed stores. |
| `Sources/Cherry/ProjectNoteStore.swift:56`; `Sources/Cherry/ProjectTodoStore.swift:6` | Migrate root-hashed storage and root-tagged records without losing content. Preserve old files until the new version is durably written and verified. |
| `Sources/CherryControl/CherryControlProtocol.swift:1527`, `ProjectNote`; `:1685`, `ProjectTodo`; `Sources/CherryControl/CherryDeepLink.swift:4` | Maintain old root-scoped requests and hashed-root links through aliases; introduce project/folder IDs without silently changing their scope. |
| `Sources/Cherry/ContentView.swift:4986`, `SidebarTabsPage` | Replace separate agent/terminal sections with project/folder navigation, project-scoped bottom tools, and complete empty states. Reuse existing row affordances and activity presentation where useful. |

Project membership and view selection persistence are separate from process persistence. This sidebar work should not pull the parked multiplexer into the native runtime. Keep the current Ghostty/native PTY rendering path and ensure selecting projects or folders does not recreate live sessions unnecessarily.

## Native rollout

1. **Choose the interaction model.** Compare both HTML layouts through every state above. Settle selection, command target visibility, and bottom-area behavior before modifying native UI.
2. **Introduce the data model and migration.** Add project/folder identity and a versioned migration with temporary-storage tests for legacy projects, unavailable paths, commands, notes, and Todos. Preserve backward root aliases and repeatable migration behavior.
3. **Separate runtime ownership and selection.** Introduce per-folder workspaces and explicit detail selection while retaining existing PTYs, splits, agent metadata, command policies, and close protections. Verify folder/project switching and registry/control routing.
4. **Build the chosen native sidebar.** Add project creation, folder addition, unified rows, bottom tools, empty states, keyboard traversal, and accessibility. Make command launch visibly reveal the correct folder terminal.
5. **Validate and retire the old navigation.** Run appropriate targeted tests, then `swift test --no-parallel`. Manually verify the embedded Ghostty path, terminal focus, resizing, splits, close behavior, project switching, command targeting, and legacy note/todo links. Remove the old grouping only after these behaviors are covered.

## Decisions still to make

- Focused project switcher or project outline; whether native project switching restores previous detail selection. The prototype clears it when selecting a project name.
- Whether adding a folder opens a first terminal automatically. The prototype leaves it empty with a clear Open terminal action.
- Whether to retain collapsed Commands/Notes as the native default, and where existing Todos live.
- How parent/sub-agent relationships appear within generic terminal rows without recreating a separate agent section.
- Portable configuration for commands targeting sibling folders; policies for importing or combining existing projects and their content.
- Project/window ownership and future remote host configuration. This phase establishes identity and scope, not remote connection or reconnection guarantees.
