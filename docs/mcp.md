# Cherry MCP Guide

Cherry exposes a local HTTP MCP server from the running macOS app. The MCP
surface is process-first: terminals, agents, and configured project commands are
all Cherry processes with a `process_id`.

## Setup

Start Cherry first, then register the local endpoint with your agent harness:

```bash
codex mcp add cherry --url http://127.0.0.1:61234/mcp
claude mcp add --transport http --scope user cherry http://127.0.0.1:61234/mcp
```

The endpoint is local-only at `127.0.0.1:61234/mcp`. Cherry forwards MCP calls to
its instance-scoped Unix control socket under `/tmp/cherry-$UID/`.

## Scope And Identity

- `whoami` reports the MCP session ID, active/effective project root, selected
  process, bound process, and default parent agent.
- `bind_session_process` binds the current MCP HTTP session to a process. Later
  process tools can omit `process_id` unless they pass `process_name`.
- `select_process` is the process-level UI selection tool. It is intentionally
  explicit; other process tools do not change the visible Cherry selection.

Agent creation stays nested under the current, selected, or latest root agent
unless `parent_agent_id` explicitly points somewhere else.

## Process Tools

Use process tools for new automation:

- `list_processes`, `get_process_status`
- `spawn_process`, `start_process`, `stop_process`, `restart_process`,
  `close_process`, `rename_process`, `send_process_input`
- `spawn_agent`, `send_agent_message` for agent-native launch and messaging
- `get_process_output`, `get_process_raw_output`, `search_process_output`
- `wait_for_process_idle`
- `get_process_ports`, `services_list`, `wait_for_bound_port`

The older terminal-tab MCP namespace has been removed. Use `process_id` with the
process tools instead.

## Waiting For Agent Output

Avoid fixed sleeps after sending input. Use `wait_for_process_idle`, which waits
for new output and then a quiet period:

```json
{
  "process_id": "PROCESS_UUID",
  "require_new_output": true,
  "quiet_ms": 1200,
  "timeout_ms": 120000,
  "line_limit": 200
}
```

The default `require_new_output: true` prevents a false idle result immediately
after a prompt is submitted. The result includes `reason` (`idle`, `exited`, or
`timed_out`), `observed_new_output`, `since_output_version`, `output_version`,
process status, and the rendered output tail. Timeouts return a normal result
with partial output rather than a tool error.

A typical agent-native flow:

1. `spawn_agent` with the configured agent name. Keep the returned
   `process.id`; agent sessions are not rebound by default so multi-agent
   orchestration does not accidentally message the most recently spawned agent.
   For a single-agent conversation, pass `bind_session: true`.
2. `send_agent_message` with `process_id` and `message`; no trailing newline is
   required. By default it sends the message and waits for new output plus a
   quiet period.
3. `get_process_output` if more context is needed.

The lower-level process flow is still available when you need raw terminal
control:

1. `spawn_process` to launch the agent.
2. `send_process_input` with the prompt.
3. `wait_for_process_idle` on that `process_id`.
4. `get_process_output` if more context is needed.

For `send_process_input` and `spawn_process`, `text` is typed as terminal
input. CR/LF line endings are encoded as carriage-return Enter, matching the
plain Enter key path. Use `raw_base64` when you need exact PTY bytes instead.

## Dev Server Readiness

For local services, use `services_list` or `get_process_ports` for discovery and
`wait_for_bound_port` for readiness. HTTP probing only happens when
`probe_http` is true.

```json
{
  "process_id": "PROCESS_UUID",
  "port": 5173,
  "probe_http": true,
  "path": "/",
  "timeout_ms": 60000
}
```

## Notes And Todos

Cherry also exposes project notes and todos through MCP. These tools are
project-scoped and do not change visible UI selection unless the tool name starts
with `select_`.
