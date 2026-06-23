# Cherry Roadmap

Cherry should become a native workspace for local agentic development: projects, agents, terminal sessions, and dev processes in one focused app. The goal is not to become an IDE. Cherry should make it easy to run the tools a project needs, see what is healthy, and let agents inspect or control that environment through MCP.

## Current Baseline

- Native macOS app with SwiftUI chrome and a left session sidebar.
- Live PTY-backed terminal sessions.
- Ghostty-backed terminal view is wired in through `GhosttySessionBridge`.
- Local MCP helper can list, create, select, read, search, clear, restart, close, and send input to terminal tabs.
- Basic app settings exist for terminal appearance.

## Themes

Support app-wide appearance plus Ghostty-compatible terminal themes.

- Add a persisted app appearance setting: system, light, dark.
- Use Ghostty theme names for terminal light/dark themes instead of inventing a Cherry terminal palette format.
- Resolve built-in Ghostty themes through the `GhosttyTheme` catalog.
- Later, support custom Ghostty theme/config files from the user's Ghostty config directories.
- Define theme tokens for backgrounds, sidebar material, borders, text, selection, process status, and accent color.
- Route terminal palette/background/foreground through Ghostty themes instead of hard-coded values.
- Make the translucent sidebar and floating panels adapt cleanly in light and dark mode.
- Keep the first version intentionally small: built-in Ghostty themes only, no custom theme editor yet.

## Projects

Introduce saved project workspaces so Cherry can reopen a repo with its known agents, terminals, and commands.

- Add a project model with name, root path, local settings, and process definitions.
- Add a project picker or project sidebar state for opening/reopening recent projects.
- Persist the active project and restore its layout on app launch.
- Define a repo-level `cherry.yml` for shared project commands and agents.
- Support local-only project overrides for personal commands that should not be committed.
- Add trust prompts when `cherry.yml` changes before running newly pulled commands.

## Agents And MCP

Make agents first-class project entries, not just generic terminal tabs.

- Add agent presets for Codex, Claude Code, Gemini CLI, Amp, Aider, Goose, and custom commands.
- Track each agent as a process with status, working directory, command, terminal output, and restart behavior.
- Extend MCP from terminal-tab control to project/process control:
  - list projects and active project
  - list agents and processes
  - read recent logs/output
  - search logs/output
  - send input to an agent/process
  - start, stop, and restart processes
  - report health/status
- Make agent visibility explicit: agents should be able to inspect only the selected project/process state exposed by Cherry.
- Keep MCP transport local and private by default.

## Notifications

Add native notifications for events that matter while Cherry is not frontmost.

- Notify when a process exits unexpectedly.
- Notify when an agent appears to need attention, such as a prompt, permission request, or terminal bell.
- Notify when an auto-restart fails repeatedly.
- Add notification preferences per project and per process type.
- Surface the same events in-app with status badges so notifications are not the only signal.

## Full Terminal Polish

Ghostty is already the right foundation. The work here is to make Cherry feel like a reliable daily-driver terminal around that foundation.

- Verify resize, focus, selection, copy, paste, scrollback, and alternate-screen behavior across common TUIs.
- Keep long-session and multi-window performance measurable with opt-in stress tests, app-level soak runs, and Ghostty side-by-side baselines.
- Add link detection/opening if Ghostty does not already expose enough of this through the current bridge.
- Make terminal bell, title changes, working directory updates, and process exit states feed the sidebar/project model.
- Tighten keyboard behavior for tab switching, interrupt, clear, search, paste, and focus restoration.
- Keep the fallback/custom renderer only as a debugging aid if Ghostty covers the real terminal surface.
- Update README once the Ghostty-backed terminal is the canonical path.

## Command Palette

Build this after the project/process model has enough commands to justify it.

- Add a searchable command palette for project, process, agent, terminal, theme, and settings actions.
- Include keyboard-first navigation for switching projects, jumping to agents/processes, and running commands.
- Let project commands from `cherry.yml` appear in the palette.
- Add recent commands and common actions once usage patterns are clear.

## Suggested Build Order

1. Full terminal polish and README cleanup, because this is the foundation users touch constantly.
2. Themes, since the settings surface already exists and the scope is contained.
3. Projects, including recent projects and basic project persistence.
4. Agents as named project processes.
5. MCP expansion around projects, agents, processes, logs, and status.
6. Notifications for process and agent attention states.
7. Command palette once the app has enough actions to make it valuable.
