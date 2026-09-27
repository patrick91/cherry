# Cherry MCP Guide

Cherry exposes MCP through a stdio helper launched inside each agent harness.
The helper talks to the running macOS app over Cherry's local control socket.
The MCP surface is process-first: terminals, agents, and configured project
commands are all Cherry processes with a `process_id`.

## Setup

Start Cherry first, then register the helper shown in Settings > MCP with your
agent harness. In a SwiftPM checkout, build the helper and install it like this:

```bash
swift build --product CherryMCP
codex mcp add cherry -- "$(swift build --show-bin-path)/CherryMCP"
claude mcp add --transport stdio --scope user cherry -- "$(swift build --show-bin-path)/CherryMCP"
```

The helper talks to Cherry through the instance-scoped Unix control socket; the
old direct HTTP MCP endpoint has been removed.

## Scope And Identity

- `whoami` reports the MCP session ID, caller process, active/effective project
  root, selected process, and bound process.
- `CHERRY_PROCESS_ID` identifies the Cherry process that launched the helper.
  `CHERRY_AGENT_ID` is still exported for agent processes as a compatibility
  alias.
- If an MCP client strips Cherry environment variables when launching the stdio
  helper, the helper falls back to matching its parent process ancestry against
  Cherry's live process list.
- `bind_session_process` binds the current MCP session to a process. Later
  process tools can omit `process_id` unless they pass `process_name`.
- `select_process` is the process-level UI selection tool. It is intentionally
  explicit; other process tools do not change the visible Cherry selection.

Agent creation stays nested under the bound caller agent when the stdio helper
is running inside a Cherry agent. If there is no bound caller, new agents are
created at the top level unless `parent_agent_id` explicitly points somewhere
else.

## Worktree Tools

- `list_projects` includes discovered worktrees, their branch/HEAD state, and
  whether each checkout is active, loaded, hidden, detached, or locked.
- `activate_worktree` focuses an existing checkout by absolute
  `project_root`.

Worktree creation, removal, fetch, and prune are intentionally not exposed to
MCP. Those lifecycle actions stay in Cherry's confirmation-based UI.

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

## Process States

Every process summary has a `state`:

- `launching`, `live`, or `exit N` (the process ended with status `N`, also
  reported as `exit_code`).
- `failed`: the launch failed, or a tab attached to a hosted session could not
  attach. `failure_message` says why.
- `disconnected`: a tab attached to a hosted session it does not own (from
  File › Persistent Sessions, or an SSH host's) whose attach client stopped
  (after `stop_process` or Disconnect, a lost connection, or another client
  taking the session over). The hosted program may still be running on its
  host, so there is no `exit_code`.

## Persistent Sessions

Local terminal, command and agent tabs are persistent sessions by default
(Settings › Sessions): their programs run in Cherry's local session host, so
they keep running when Cherry quits and come back with their tabs when it
opens again. MCP treats them like native tabs:

- `stop_process` ends the program (its session on the local host ends with
  it); the process then reports `exit 0` with `exit_code` 0, whatever signal
  ended it, and `start_process` starts it again in a new session.
- `restart_process` ends the session and starts a new one in the same process
  (same `process_id`).
- `close_process` ends the session, as the tab's close button does, without
  asking (the app asks before its own close stops a program at work).
- The process reports the program's `pid` (the host's child, never
  signalled by Cherry), port tools attribute its listeners to it, and its
  program gets `CHERRY_PROCESS_ID`, so a CherryMCP helper started inside it
  identifies its tab. A tab restored after Cherry relaunched keeps its
  `process_id`.
- While the tab's terminal is not attached yet (a restored tab in a worktree
  that is not shown, or one whose attach adapter is being launched or is
  reconnecting), output is read from the host and input is sent through the
  host. `line_count` is then the host's line count. The process stays
  `live` while its program runs.
- Input sent while the tab's session is still being created or restarted is
  queued, in order with typed keys, and the call waits until it reached the
  program. Input still queued after 16 s is dropped and reported as
  `input_not_delivered`.
- Input the host types is encoded for the program's cursor key mode, as a
  terminal would type it: unmodified arrow, Home and End sequences
  (`ESC [ A` or `ESC O A` …), `raw_base64` included, go as `ESC O x` while
  the program has application cursor keys (DECCKM) on and does not use the
  kitty keyboard protocol (its kitty flags are 0), and as `ESC [ x`
  otherwise. The session host reports the mode, so such input goes through
  it at once, without waiting for an attach adapter. A session whose
  program was started by an older build (its holder process predates
  holder link version 4) reports the mode as off for its whole life, so
  its cursor keys go as `ESC [ x` even under `less` or `vim`. With an
  older session host, which reports no mode at all, these
  sequences to a tab without a live attach adapter (a restored tab in a
  hidden worktree, or one whose adapter just launched) launch or wait for
  the adapter, up to 3 s, and go through the terminal; if no adapter
  attaches in time, the host types them as they were sent.

When persistent sessions are off or the local host cannot run them, new local
tabs run natively; MCP treats them the same way.

A tab attached to a hosted session it does not own (another machine's,
another app's, or one created with the `cherry` CLI) behaves differently.
`stop_process` only disconnects it (state `disconnected`), and `close_process`
disconnects and closes the tab; the program keeps running on its host.
`start_process` and `restart_process` reconnect its attach client, and both
fail with the error code `hosted_session_ended` when the session has ended on
its host; create a new session instead. Such a tab reports a `pid` only for a
session on This Mac while it is attached. A session on another machine never
has one, so port tools never attribute ports to it; on a remote host its
listeners are not visible. Its program did not get this tab's
`CHERRY_PROCESS_ID`.

## Process Activity Fields

Process summaries from `list_processes`, `get_process_status`, and the other
process tools include activity metadata:

- `agent_activity_state` (agent processes only): `working`, `idle`,
  `permission` (the agent is blocked waiting for an approval: its screen shows
  a permission prompt, or it sent a permission notification), `error`, or
  `unknown` when Cherry has not classified the agent yet.
- `uses_alternate_screen`: whether the process is currently showing a
  fullscreen TUI on the terminal's alternate screen.
- `last_content_change_at` / `content_version`: when and how often the rendered
  content actually changed. `output_version` advances on every redraw,
  including cosmetic churn such as spinner repaints; `content_version` only
  advances on real content changes.

Rendered output results (`get_process_output` and the `output` field of other
tools) include `screen` and `content_version`. `screen` is `"alternate"` when
you are reading a fullscreen TUI's live screen rather than scrollback, and
`"primary"` otherwise.

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
after a prompt is submitted. The result includes `reason` (`idle`, `exited`,
`disconnected`, `timed_out`, `permission`, or `agent_error`),
`observed_new_output`, `since_output_version`, `output_version`,
`agent_activity_state`, process status, and the rendered output tail. Timeouts
return a normal result with partial output rather than a tool error.

`exited` covers a process that ended and one whose state is `failed`, including
an attached hosted-session tab that could not attach. `disconnected` means a
tab attached to a hosted session it does not own lost its attach client: the
hosted program may still be running and there is no `exit_code`. Reconnect it
with `start_process` before waiting again. A local persistent tab whose
terminal reconnects to the session host stays `live`, and the wait reads its
output from the host meanwhile.

For agent processes with a known activity state, the wait is state-aware:

- `permission` returns immediately when the agent becomes blocked on an
  approval prompt (its screen shows one), so orchestrators can react instead
  of timing out.
- `agent_error` returns when the agent enters an error state.
- `idle` requires `agent_activity_state == idle` plus the usual new-output
  baseline, and the quiet window is measured against real content changes
  (`last_content_change_at`) instead of raw output. Spinner repaints do not
  starve the wait, and echoed input bytes do not satisfy it prematurely.

Non-agent processes (and agents Cherry has not classified yet) keep the
original output-quiet behavior.

A typical agent-native flow:

1. `spawn_agent` with the configured agent name. Pass `model` to override the
   configured agent's model for this launch. Codex, Claude, Gemini, OpenCode,
   and Pi support model overrides; Amp and unrecognized custom agents do not.
   Keep the returned `process.id`; agent sessions are not rebound by default so
   multi-agent orchestration does not accidentally message the most recently spawned agent.
   For a single-agent conversation, pass `bind_session: true`.
2. `send_agent_message` with `process_id` and `message`; no trailing newline is
   required. By default it sends the message and waits for new output plus a
   quiet period.
3. `get_process_output` if more context is needed.

The lower-level process flow is still available when you need terminal-shaped
control:

1. `spawn_process` to launch the agent.
2. `send_process_input` with the prompt. For agent processes, plain `text`
   input is submitted with Enter by default; pass `submit: false` to only type
   it.
3. `wait_for_process_idle` on that `process_id`.
4. `get_process_output` if more context is needed.

For `send_process_input` and `spawn_process`, `text` is typed as terminal
input. CR/LF line endings are encoded as carriage-return Enter, matching the
plain Enter key path. Use `raw_base64` for bytes without that normalization;
raw bytes are not auto-submitted unless `submit: true` is provided. Key
sequences in them may still be re-encoded for the program's key modes:
unmodified arrow, Home and End keys follow its cursor key mode, whether its
terminal or its session host types them.

## Input To Agents

Input to an agent (`send_process_input`, `send_agent_message`, the first input
of `spawn_process` and `spawn_agent`) is checked against the agent's current
screen first. The screen is read from its session host when no terminal shows
it, for example for a restored agent in a worktree that is not shown. While
the screen shows a tool-permission prompt, where Enter (or a letter such as
`y`) would approve the pending action, the input is refused with
`agent_awaiting_permission` and nothing is sent: let the user answer it, or
send the answering keys deliberately as `raw_base64` without `submit`, which
goes through. When the agent's screen cannot be read from its host, the input
fails with `input_not_delivered` and nothing is sent.

Cherry presses Enter on an agent's startup or trust prompt only for an agent
its tab just launched, never for a restored, adopted or attached agent, and
never on a permission menu. A restored agent has been running for a while;
input to it is checked as above.

## Input Errors

- `process_not_accepting_input`: the process has ended, failed to start, or
  is a disconnected attached session. Nothing was sent.
- `agent_awaiting_permission`: see above. Nothing was sent.
- `input_not_delivered`: the session host did not take the input (the
  session ended, the host could not be reached, input queued for a session
  being created was not sent within 16 s), or an agent's screen could not be
  read from its host. Nothing was sent, with one exception: when the host's
  answer to the input (at most 64 KiB, or the first 64 KiB part of longer
  input) was lost (the connection failed or timed out after it was sent),
  the error is also `input_not_delivered`, although the host may have typed
  that part. Check the program's output before sending it again.
- `input_partially_delivered`: only a first part of the input reached the
  program. Either an agent message's text was typed but the Enter that
  submits it did not reach the agent, or input longer than 64 KiB went to
  the session host in several parts and a part after the first failed. The
  message says how many bytes were typed ("Only the first N of M bytes …").
  When the host refused the part that failed, the rest was not sent. When
  that part was sent but the host's answer was lost (the connection failed
  or timed out), the message says so: those bytes, up to 64 KiB, may or may
  not have been typed, and only the bytes after them were not sent. Do not
  send all of the input again, which would type that first part twice:
  check the program's output, then send what is missing.

## Client Timeouts

The CherryMCP helper waits 10 s for Cherry's answer by default, longer for
tools that wait on purpose:

- `spawn_process`, `spawn_agent` and `send_process_input`: `wait_ms` + 20 s,
  since a persistent tab's session may still be created and an agent's first
  input waits for it to be ready. `spawn_process` with kind `command` waits
  `wait_ms` + 30 s, because it first waits up to 10 s for a restore under way
  that may bring back the command's tab.
- `start_process`, `start_all_commands` and `restart_all_commands`:
  `wait_ms` + 20 s, as they also wait up to 10 s for such a restore.
- `send_agent_message`: `timeout_ms` + 5 s, at least 20 s.
- `wait_for_process_idle` and `wait_for_bound_port`: `timeout_ms` + 5 s.

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

## Testing The Control Server

`Scripts/test-mcp-concurrency` checks that the control server stays responsive
while service detection runs. It builds Cherry with
`swift build -c release --product Cherry` and runs the binary apart from your
own Cherry: a private `HOME` and `CFFIXED_USER_HOME`, and private control and
session-host sockets (`CHERRY_CONTROL_SOCKET`, `CHERRY_HOST_SOCKET`) in a 0700
directory. Its tabs are persistent sessions on a daemon of its own, which it
tears down at the end (`Scripts/cherry_private_host.py`); it never touches your
daemon or saved workspaces. Its log is `/tmp/mcp-conc.log`.
