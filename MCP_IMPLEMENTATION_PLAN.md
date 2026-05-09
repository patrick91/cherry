# Cherry MCP Implementation Plan

Last updated: 2026-05-09

This plan tracks what Cherry's MCP layer already supports and what remains to make it more useful for agent-driven project work.

Guiding rule: MCP tools should mutate project/process state only when the tool name clearly says so, and should not change the visible Cherry UI selection unless explicitly requested.

## Current Status

Cherry now has a useful local MCP surface for project work:

- The MCP helper can report app/socket reachability with `get_status`.
- Socket reads and writes have timeouts, so calls return tool errors instead of hanging indefinitely.
- Notes, todos, terminal tabs, agents, and project commands avoid UI selection side effects by default.
- Explicit UI selection remains available through `select_terminal`, `select_note`, and `select_todo`.
- Terminals, agents, and project commands are exposed through a process-oriented layer on top of `TerminalWorkspace`.
- Process summaries expose PID, timestamps, structured exit code, input readiness, output activity, and restart policy.
- Cherry can detect localhost TCP services for Cherry-managed process trees and wait for bound ports through MCP.
- Project command execution is limited to trusted configured commands from Cherry settings or `cherry.toml`.
- Backwards-compatible terminal tools still exist.

## Implemented Tools

### Status And Projects

- `get_status`
- `list_projects`
- `get_project_status`

### Process Read APIs

- `list_processes`
- `get_process_status`
- `get_process_output`
- `get_process_raw_output`
- `search_process_output`
- `get_process_ports`
- `services_list`
- `wait_for_bound_port`

### Process Lifecycle APIs

- `spawn_process`
- `start_process`
- `stop_process`
- `restart_process`
- `close_process`
- `rename_process`
- `send_process_input`
- `start_all_commands`
- `stop_all_commands`
- `restart_all_commands`

### Notes

- `list_notes`
- `create_note`
- `get_note`
- `update_note`
- `append_note`
- `rename_note`
- `search_notes`
- `delete_note`
- `select_note`

### Todos

- `list_todos`
- `create_todo`
- `get_todo`
- `update_todo`
- `move_todo`
- `delete_todo`
- `select_todo`
- `add_todo_comment`
- `list_todo_comments`
- `update_todo_comment`
- `delete_todo_comment`

### Backwards-Compatible Terminal/Agent Tools

- `list_terminals`
- `list_agents`
- `create_terminal`
- `run_agent`
- `rename_terminal`
- `press_enter`
- `select_terminal`
- `send_input`
- `get_terminal_output`
- `get_terminal_raw_output`
- `search_output`
- `clear_output`
- `restart_terminal`
- `close_terminal`

## Implemented Test Coverage

- Protocol round trips for process, note, todo, terminal, and agent requests.
- Non-focusing behavior for note/todo create defaults.
- Process layer listing, project status, command start/stop, process input, output capture, and selection preservation.
- Service detector parsing, process-tree attribution, real local listening socket detection, service list responses, wait responses, and ambiguous service errors.
- Socket timeout behavior.
- Todo comment persistence, update, and deletion.
- Existing full-suite coverage remains passing with `swift test --no-parallel`.

## Missing Next

### 1. Process Identity Hardening

Current process IDs are terminal UUIDs. That is acceptable for this implementation, but they are session-scoped and not database-backed.

Needed decisions:

- Keep terminal UUIDs as the public `process_id` long term, or introduce stable per-project process IDs.
- Decide whether closed process IDs should remain queryable for history.
- Decide whether command processes should expose configured command IDs separately from session IDs.

Recommended next step:

- Keep current UUIDs for now.
- Add explicit documentation in tool descriptions that `process_id` is stable for the lifetime of the Cherry session.

### 2. Service Detection Hardening

Service readiness is implemented for MCP with a portable detector abstraction and a macOS `lsof` implementation.

Remaining hardening:

- Decide whether wildcard listeners such as `0.0.0.0:3000` should remain eligible. They are locally reachable, but not localhost-only in the strict network sense.
- Consider exposing process groups if descendant attribution via `ps` parent traversal misses shell-launched daemons.
- Add a stable process-tree integration test only if it proves non-flaky.
- Decide whether HTTP probe failures should expose status/error detail beyond `http_failed`.
- Consider caching detection results briefly if repeated `services_list` calls become expensive.

### 3. Richer Process State

Most useful process state is now exposed through `ProcessSummary`.

Implemented:

- `exit_code`
- `started_at`
- `exited_at`
- `last_output_at`
- `accepts_input`
- `pid`
- `restart_policy` for command processes

Still missing:

- `process_group_id`
- structured state enum alongside the existing state label
- closed process history after sessions are removed

### 4. Timers And Idle Checks

Timers remain unimplemented.

Potential tools:

- `timer_set`
- `timer_list`
- `timer_cancel`
- `timer_pause`
- `timer_resume`
- `timer_fire_when_idle`

Recommended scope:

- Start in-memory.
- Scope timers to project/process/todo IDs.
- Do not automatically send terminal input or restart processes.
- Return timers through MCP and optionally surface a Cherry notification.

Open decision:

- Should timers survive app restart?

### 5. Todo Coordination Metadata

The todo system is still intentionally minimal.

Deferred features:

- priority
- tags
- blockers/dependencies
- assignee/claim metadata
- todo transfer between projects
- todo locks or leases

Recommended next step:

- Add a small `claimed_by`, `claim_expires_at`, or object-specific lease only if multiple agents start duplicating todo work.
- Avoid a generic lock API until there is a concrete contention problem.

### 6. Note Organization

Notes now cover scratchpad basics, including append and search.

Deferred features:

- archive state
- tags
- note list filters
- note locks or edit leases

Recommended next step:

- Only expose archive/tags through MCP after the app UI has visible archive/tag concepts.

### 7. MCP Tool Contract Cleanup

The helper now has both old terminal tools and new process tools.

Needed decisions:

- Keep both namespaces permanently, or steer agents toward process tools.
- Decide whether `get_process_output` should eventually replace `get_terminal_output` in documentation.
- Decide whether `run_agent` should be marked legacy after `spawn_process(kind: "agent")` is stable.

Recommended next step:

- Keep backwards compatibility.
- Update install/help text and examples to prefer process tools.

## Suggested Next Build Order

1. Harden service detection based on dogfood usage: wildcard listener policy, HTTP probe detail, and optional short-lived caching.
2. Decide process identity/history semantics: terminal UUIDs only, or durable per-project process records.
3. Add `process_group_id` if descendant attribution misses real dev server launch patterns.
4. Prototype in-memory timers using `last_output_at` for idle detection.
5. Update README/install help to prefer process/service MCP tools over legacy terminal tools.
6. Revisit todo/note locks only after real multi-agent usage shows contention.

## Non-Goals For Now

- No arbitrary filesystem browsing through MCP.
- No remote/network MCP transport.
- No automatic UI focus or pane switching from create/update/lifecycle tools.
- No arbitrary untrusted shell command execution through `spawn_process`.
- No generic lock system until a concrete conflict pattern appears.

## Open Questions

- Should process IDs remain terminal UUIDs, or should Cherry introduce stable per-project process records?
- Should closed process history remain queryable?
- Should `spawn_process` ever allow arbitrary commands, or only configured commands and agents?
- Should timers persist across app restart?
- Should note tags/archive become app-visible before MCP exposes them?
