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
pi mcp add cherry --exposure direct -- "$(swift build --show-bin-path)/CherryMCP"
```

Pi needs `--exposure direct`: its default (`codemode`) hides an MCP
server's tools behind a script tool. Settings › MCP shows the three
commands; its **Add to Pi** button runs Pi's (only when clicked: Pi writes
its own `mcp.json`, which Cherry only reads to say whether Cherry is
registered there). Both use the environment of your login shell, as this
run of Cherry captured it, so a `PI_CODING_AGENT_DIR` set there names the
`mcp.json` Pi uses; Set Up Cherry MCP on another Mac passes that Mac's
login-shell `PI_CODING_AGENT_DIR` to `pi` too.

The helper talks to Cherry through the instance-scoped Unix control socket; the
old direct HTTP MCP endpoint has been removed.

## Scope And Identity

- `whoami` reports the MCP session ID, caller process, active/effective project
  root, selected process, and bound process.
- `CHERRY_PROCESS_ID` identifies the Cherry process that launched the helper.
  `CHERRY_AGENT_ID` is still exported for agent processes as a compatibility
  alias.
- `CHERRY_MCP_HELPER` is the absolute path of the CherryMCP of the Cherry
  that started the tab (This Mac's tabs, native and persistent, and tabs on
  another Mac alike), so `"$CHERRY_MCP_HELPER" --call TOOL '{…}'` works from
  any tab's shell whatever its PATH.
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

## Agents On Another Mac

An agent running in a tab of a project on another Mac (a device, see
[docs/specs/remote-devices.md](specs/remote-devices.md), phase 4b) uses the
same tools as a local agent in that window, bounded to that Mac:

- Cherry forwards its control socket to that Mac over the device's SSH
  connection (`ssh -O forward -R`), and the tab's environment names it:
  `CHERRY_CONTROL_SOCKET=<its per-user temporary directory>/cherry-mcp-<hash>/control.sock`
  there (`getconf DARWIN_USER_TEMP_DIR`, never the shared `/tmp`). That
  Mac's sshd must allow remote forwards (`AllowStreamLocalForwarding` and
  `AllowTcpForwarding` yes, the defaults); Set Up Cherry MCP says when it
  refused.
- Each tab gets its own capability token, `CHERRY_MCP_TOKEN` (256 bits),
  next to `CHERRY_PROCESS_ID`. CherryMCP sends both with every request;
  the forwarded socket refuses a request without a valid token
  (`unauthorized`). A token is valid only while its tab is open in a window
  of that Mac's project (closing the tab revokes it) and until the tab's
  program restarts (each launch gets a new one); it keeps working after
  Cherry relaunches and restores the tab. This Mac's own callers are
  still identified by their process.
- Unscoped requests go to the tab's window. A `project_root` is an
  absolute path on that Mac (`CHERRY_PROJECT_ROOT` is the path there) or a
  `device:` key of that Mac; one with `.` or `..` components is refused
  (`invalid_project_root`), another Mac's key too (`outside_caller_mac`).
  Everything such an agent reaches is on that Mac: `process_id`s of other
  windows (This Mac's, another Mac's) are `terminal_not_found`, links to
  them are not found, `list_projects` lists that Mac's projects, and a
  scoped request inside another is refused. A tab of its window that runs
  somewhere else (a This Mac or SSH host session attached there) is not
  listed and not found either. Ports come only from that Mac:
  `include_unattributed` is refused (`unattributed_not_available`), and
  `probe_http` probes only through the port's forward. Requests are at
  most 8 MiB, must arrive within 15 s, and at most 16 run at once
  (`request_too_large`, `request_timeout`, `too_many_connections`).
- `CHERRY_MCP_HELPER` is the CherryMCP of the Cherry build that started the
  tab, installed on that Mac with `cherry` and `cherry-host`.
- When Cherry cannot be reached from there (it quit, the Mac slept, the SSH
  connection is being made again), tools fail with `cherry_unreachable`:
  "Cherry on <this Mac> is not reachable". The forward is made again when
  Cherry reconnects to that Mac.

Claude Code, Codex and Pi on that Mac read their MCP servers from their own
configuration there. **Set Up Cherry MCP on <Mac>…** (the device's menu in
the project picker, or Settings › Sessions › Other Macs) shows these
commands and runs them there only when you confirm; running it again gives
the same result, and **Remove** takes the registrations away:

```bash
# the launcher: runs $CHERRY_MCP_HELPER (else the newest installed CherryMCP,
# else that Mac's own Cherry.app's)
~/Library/Application Support/cherry-host/mcp/cherry-mcp
claude mcp add --scope user --transport stdio cherry -- "$HOME/Library/Application Support/cherry-host/mcp/cherry-mcp"
codex mcp add cherry -- "$HOME/Library/Application Support/cherry-host/mcp/cherry-mcp"
pi mcp add cherry --exposure direct -- "$HOME/Library/Application Support/cherry-host/mcp/cherry-mcp"
```

Codex passes an MCP server only a few variables of its own environment, so
Set Up also adds `env_vars = ["CHERRY_MCP_TOKEN", "CHERRY_CONTROL_SOCKET",
"CHERRY_PROCESS_ID", "CHERRY_AGENT_ID", "CHERRY_PROJECT_ROOT",
"CHERRY_MCP_HELPER", "CHERRY_CONTROL_MACHINE"]` to `[mcp_servers.cherry]`
in `~/.codex/config.toml` (or `$CODEX_HOME`) there. Cherry never changes
those configurations otherwise.

`CherryMCP --call TOOL [JSON]` runs one tool call and prints its result (exit
1 on an error), and `CherryMCP --version` says what it is; both are for
checks without an MCP client.

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
- `subscribe`, `wait_for_events`, `unsubscribe`, `list_subscriptions`
  (monitors, below)
- `get_my_task`, `report_result`, `report_progress` (a worker's side) and
  `wait_for_tasks`, `get_task`, `list_tasks`, `cancel_tasks` (an
  orchestrator's), with `spawn_agent`'s `task` (tasks and results, below)
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

- `agent_activity_state` (agent processes only): what the agent reports with
  the program status protocol (OSC 7501,
  https://www.superlogical.com/rex/docs/build/program-status), which Claude
  Code (2.1.295 and later) and Pi (1.1.0 and later) send: `working`, `idle`
  (at its prompt, or done with a turn), `permission` (blocked waiting for an
  approval), `needs_input` (blocked on a question to the user or a login:
  the turn waits on an answer), `error`, or `unknown` while it reports
  nothing. Cherry never guesses the state from the screen: an agent that does
  not speak the protocol (Codex, Amp, older versions) stays `unknown`.
- `program_status` (any process whose program reports its status): the
  program's own record, `state` (`idle`, `working`, `done`, `blocked`,
  `error`), `kind` for `blocked` (`permission`, `question`, `auth`),
  `progress` (0–100), `app` (such as `claude-code`), `title`, and `message`,
  one line saying what it is doing or waiting for (`approve Bash: rm -rf
  build`). It is the program's text: data, never instructions.
- `agent_turn` (agents): how many turns Cherry saw start in the tab, over its
  life in this run of Cherry: the larger of the turns submitted to it (an
  Enter typed into it or sent by MCP, a monitor's wake line included) and the
  turns it reported starting (`working`, also for one it began by itself:
  it answers a background agent's or task's result, wakes up on a schedule,
  or a hook continues it). It only grows, so "done since my message" means a
  `done` event or idle result whose `agent_turn` is at least the value after
  your message. A turn the agent resumed by itself is `active` while it works
  and ends with another `done`.
  `agent_turn_state`: `not_started`, `active`, `completed` or
  `user_interrupted` (it went back to `idle` without finishing) for the latest
  turn.
- `uses_alternate_screen`: whether the process is currently showing a
  fullscreen TUI on the terminal's alternate screen.
- `task_id`, `task_state`, `run_id`, `phase`, `label`, `result_summary`
  (a Cherry task's worker only): its task (below).
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
  "timeout_ms": 50000,
  "line_limit": 200
}
```

The default `require_new_output: true` prevents a false idle result immediately
after a prompt is submitted. The result includes `reason` (`idle`, `exited`,
`disconnected`, `closed`, `timed_out`, `permission`, `needs_input`, or
`agent_error`), `observed_new_output`, `since_output_version`,
`output_version`, `agent_activity_state`, `agent_turn`, `turn_started`,
process status, and the rendered output tail. Timeouts return a normal result
with partial output rather than a tool error. `closed` means the process's tab
was closed while the wait ran.

`timeout_ms` defaults to 50000 (max 300000): Codex and Pi give an MCP tool
call 60 s by default and drop a later answer, so keep waits at 50 s or less
and call again on `timed_out`, or subscribe (below) and end your turn.

`exited` covers a process that ended and one whose state is `failed`, including
an attached hosted-session tab that could not attach. `disconnected` means a
tab attached to a hosted session it does not own lost its attach client: the
hosted program may still be running and there is no `exit_code`. Reconnect it
with `start_process` before waiting again. A local persistent tab whose
terminal reconnects to the session host stays `live`, and the wait reads its
output from the host meanwhile.

For agent processes with a known activity state, the wait is state-aware:

For agents that report their status, the wait follows what they report:

- `permission` returns immediately when the agent reports it is blocked on
  an approval, so orchestrators can react instead of timing out.
- `needs_input` returns immediately when the agent reports it is blocked on
  a question or a login. Its turn cannot end before someone answers.
- `agent_error` returns when the agent reports an error.
- `idle` requires `agent_activity_state == idle` plus the usual new-output
  baseline, and the quiet window is measured against real content changes
  (`last_content_change_at`) instead of raw output, so its last frame is
  drawn. A reported `working` never ends the wait, however quiet its screen.
- After a message, an agent reports `working` a moment later. `idle`
  therefore also needs the submitted turn to have started: the agent
  reported `working` after the message, or was already working when it was
  sent (the CLI queued the message behind that turn). An agent that never
  reports working (it answered at once) counts as idle 4 s after the
  message. `turn_started` says which.

Non-agent processes, and agents that report nothing (`turn_started` is
absent), keep the original output-quiet behavior.

A typical agent-native flow:

1. `spawn_agent` with the configured agent name. Pass `model` to override the
   configured agent's model for this launch. Codex, Claude, Gemini, OpenCode,
   and Pi support model overrides; Amp and unrecognized custom agents do not.
   Pass `effort` (a level such as `low`, `medium` or `high`) to set the
   reasoning effort or thinking level for this launch: Claude gets
   `--effort`, Pi `--thinking`, Codex `-c model_reasoning_effort="…"`; other
   agents answer `unsupported_effort_override`, and each CLI checks its own
   levels. For example, a cheap Codex worker: `model: "gpt-6-luna"`,
   `effort: "low"`.
   Keep the returned `process.id`; agent sessions are not rebound by default so
   multi-agent orchestration does not accidentally message the most recently spawned agent.
   For a single-agent conversation, pass `bind_session: true`.
2. `send_agent_message` with `process_id` and `message`; no trailing newline is
   required. By default it sends the message and waits (up to 40 s) for new
   output plus a quiet period. For work that takes longer, pass
   `wait_for_idle: false`, `subscribe` to the agent and end your turn.
3. `get_process_output` if more context is needed.

The lower-level process flow is still available when you need terminal-shaped
control:

1. `spawn_process` to launch the agent.
2. `send_process_input` with the prompt. For agent processes, plain `text`
   input is submitted with Enter by default; pass `submit: false` to only type
   it. For other processes `submit` defaults to false: end the text with a
   newline, or pass `submit: true`. A submit's Enter is sent on its own after
   the text, so a program that tells typing from pasting (Claude Code run in
   a terminal tab, a shell that brackets pastes) runs it.
3. `wait_for_process_idle` on that `process_id`.
4. `get_process_output` if more context is needed.

For `send_process_input` and `spawn_process`, `text` is typed as terminal
input. CR/LF line endings are encoded as carriage-return Enter, matching the
plain Enter key path. Use `raw_base64` for bytes without that normalization;
raw bytes are not auto-submitted unless `submit: true` is provided. Key
sequences in them may still be re-encoded for the program's key modes:
unmodified arrow, Home and End keys follow its cursor key mode, whether its
terminal or its session host types them.

## Monitors

An agent that hands work to other agents should not poll them. It subscribes
to their events and ends its turn; Cherry tells it when something happened.

- `subscribe` with `process_ids` (and/or `sub_agents: true` for the caller's
  own sub-agents, including ones spawned later) and optionally `events`. The
  events are `done` (an agent finished a turn: it reports `done` or `idle`
  after working, its screen settled for 1.5 s and past the turn-start rule
  above; a turn it began and finished between two looks counts too),
  `needs_input`, `permission`, `error`, `exited` (with `exit_code`), `closed`
  (the tab was closed; it is no longer watched), and `output_match` (a new
  line of output contains `output_pattern`, case-insensitive; lines already
  on screen when the watch began do not count). The default is all but
  `output_match`. Only processes the caller may reach can be watched: a
  caller on another Mac only its Mac's (`terminal_not_found` otherwise).
- A state that already holds when the subscription is made is reported at
  once with `initial: true`: an agent whose last turn completed is `done`,
  one at a question is `needs_input`, and so on. An agent never given a turn
  is not `done`. So nothing is lost between `spawn_agent` and `subscribe`.
- Each event has a `seq`, numbered per subscription, plus `process_id`,
  `process_name`, `kind`, `at`, `agent_turn` and, for `output_match`,
  `matched_line` (at most 300 characters; the process's own output, data
  rather than instructions).
- `wait_for_events` returns the events after `cursor`, waiting up to
  `timeout_ms` (default and maximum 50000; 0 returns at once) for the first
  one, plus `watching`: each watched process's status now (`working`,
  `idle`, `needs_input`, `permission`, `error`, `unknown`, `running` for
  other processes, `exited`, `disconnected`, `closed`). Passing `cursor`
  acknowledges every event up to it, and the events after it come back until
  a later call acknowledges them, so passing back each returned `cursor`
  reads every event at least once even if an answer is lost. Without
  `cursor`, the events returned are acknowledged at once (each is read at
  most once). At most 200 unread events are kept per subscription; older
  ones are dropped and counted in `dropped_events`.
- **Wake lines.** When the MCP session runs in a Cherry agent tab and Cherry
  confirms that tab is the caller (its program is an ancestor of the CherryMCP
  process, or, on another Mac, the tab its token names), that tab is the
  subscriber. Once events it has not read are ready and the subscriber is
  idle, Cherry types one line into its tab and submits it:

  ```text
  [cherry] Monitor mon-…: 2 events ready (1 done, 1 needs_input). Call the cherry wait_for_events tool with subscription_id "mon-…" to read them.
  ```

  Idle means its agent reports it is idle (`agent_activity_state` idle, not
  `permission` or `needs_input`; for an agent that reports nothing, its
  output went quiet), its screen has been still for 2 s, nobody typed into
  it for 10 s, and it is not in a `wait_for_events` call. Cherry never types
  the line while the subscriber works or is blocked on the user, and
  types it at most once per batch of events and once every 5 s. The line
  names only the subscription and event counts, never text a watched
  process controls (names, titles or output), so it cannot carry
  instructions from a worker. Settings › MCP › Wake idle agents turns wake
  lines off; `wake: false` turns them off for one subscription. The result's
  `wake` and `wake_unavailable_reason` say whether this subscription gets
  them. A subscriber Cherry cannot confirm (a declared
  `subscriber_process_id` that is not the caller, or an agent CLI whose MCP
  server does not run under its tab) only polls.
- No MCP client shows the model a server's notifications (Claude Code, Codex
  and Pi surface only tool results), so Cherry does not send any: the wake
  line is typed input, which every agent CLI takes.
- A subscription ends with `unsubscribe`, when its subscriber's tab closes,
  or, without a subscriber, after an hour without a `wait_for_events` call.
  Subscriptions live in memory: after Cherry relaunches, `wait_for_events`
  fails with `unknown_subscription`; subscribe again (process ids and
  `agent_turn` values stay valid, though `agent_turn` restarts from 0 for a
  restored tab). A caller has at most 32 subscriptions, each watching at
  most 64 processes. `list_subscriptions` lists the caller's own.

A typical orchestration:

1. `spawn_agent` for each worker, with its `message`.
2. `subscribe` with their `process_ids` (or `sub_agents: true`).
3. End the turn. When the wake line arrives, `wait_for_events`, then read
   the workers' output with `get_process_output`.
4. Clients that cannot be woken (wake unavailable) loop on `wait_for_events`
   with the returned `cursor`.

## Tasks And Results

An agent can hand work to other agents as tasks and get a structured
result back from each. Workers are ordinary, visible agent tabs nested
under the orchestrator (one level deep), so the user can watch and steer
them. Any agent CLI that has Cherry MCP can orchestrate or work: Claude
Code, Codex and Pi.

**Orchestrator side**

- `spawn_agent` with `task` (the worker's brief, instead of `message`; at
  most 64,000 characters and 256 KiB), and optionally `label` (shown in the
  sidebar; defaults to `title`, else the brief's first words; cut at 80
  characters and 320 bytes), `phase` (60 characters, 240 bytes), `run_id`
  and `result_schema`. The
  agent is the configured `name` with its usual command and options. The
  result has `task_id` and `run_id` (and `task`). Without `run_id` the task
  joins the caller's current run: one per orchestrator, a new one once all
  of its tasks settled. Refused before anything is spawned: `task` with
  `message` (`invalid_process_request`), a schema Cherry cannot check
  (`invalid_result_schema`, with `details`), a run the caller cannot use
  (`unknown_run`), and a worker of an open task handing out tasks itself
  (`nested_task`).
- Once the worker is ready, Cherry types one line into it:

  ```text
  You are Cherry task task-…: call get_my_task (Cherry MCP) for your brief, do it, then call report_result. Without Cherry MCP tools, run "$CHERRY_MCP_HELPER" --call get_my_task, then "$CHERRY_MCP_HELPER" --call report_result '{"value":…,"status":"ok","summary":"…"}'.
  ```

  The brief itself is never typed. Into a CLI Cherry knows, the first
  kickoff waits for its composer on a screen still for a second. Typed is
  not sent: an agent CLI can show its composer before it takes input
  (Claude Code while its MCP servers load) and drop the text or its
  Enter. Until the worker's turn starts, it calls `get_my_task`, or the
  kickoff shows among its sent messages, Cherry looks at its screen once
  it has been still for a second: a kickoff left unsent in the composer
  gets its Enter (at most twice), and one not on screen at all is typed
  again; so is one that could not be typed (the worker showed a prompt),
  once the worker is idle. That is at most three kickoffs in all (each
  retry is a `kickoff_retry` event); then the task is `failed`. A kickoff
  that may have been typed although its input failed
  (`input_maybe_delivered`) is never typed again. An agent whose screen
  Cherry cannot read keeps its kickoff as typed.
- `wait_for_tasks` with `run_id` or `task_ids` (default: the caller's own
  open runs), `until` (`any`, the default: a task settled or needs input;
  `all`: every task settled), `cursor` and `timeout_ms` (at most and by
  default 50000; 0 returns at once). It returns `events` after `cursor`
  (`queued`, `started`, `progress`, `needs_input`, `resumed`,
  `kickoff_retry`, `nudged`, `reported`, `failed`, `no_report`,
  `cancelled`, each with its `seq`), `completed` and `pending` tasks,
  `cursor` (pass it back next time), `timed_out`, and the `runs` with
  their counts. A cursor Cherry cannot go on from (it names events a
  relaunch lost) is answered at once with `cursor_reset: true`, the events
  from the first one kept, and every selected task's state. A timeout is
  a normal answer: call again, or end the turn. Each run keeps its own
  events (at most 2000), and a task keeps one event of each kind (a newer one, such
  as a re-report or the latest progress, replaces it), so one chatty
  worker never pushes out other runs' events. `until: any` returns for a
  task that settled (or needs input) after `cursor` even when its event
  is no longer kept (`events_dropped` says so), and the returned `cursor`
  is past it.
- **The wake line.** When the orchestrator's tab is the caller Cherry
  confirmed (as for monitors) and an agent, Cherry types one line into it
  once every task of a run settled and the orchestrator is idle (the
  monitors' rule: at its composer, screen still, nobody typing, not in a
  `wait_for_tasks` call on that run, never at a prompt), once per settle,
  unless it already read the settle with `wait_for_tasks` or caused it
  with its own `cancel_tasks`:

  ```text
  [cherry] Run run-…: 3 tasks settled (2 reported, 1 failed). Call the cherry wait_for_tasks tool with run_id "run-…" to read them, and get_task for each result.
  ```

  It carries the run id and counts only, never a worker's text. Settings ›
  MCP › Wake idle agents turns it off with monitors' wake lines.
  Everything Cherry types into a tab (this line, a monitor's wake line,
  the nudge and a kickoff) goes through one lock per tab: each line's
  text, pause and Enter go together, so two lines never merge into one
  message. A line whose input failed in a way that may still have typed
  it (`input_maybe_delivered`, `input_partially_delivered`) is never
  typed again. So the
  cheapest orchestration is: spawn the workers, end the turn, and read the
  results when the line arrives.
- `get_task` returns the task with its `brief`, `result_schema` and
  `result`: `value`, `status` (`ok`, `failed`, or `no_report`), `summary`,
  `version` and `source` (`report_result`, or `screen_tail` for Cherry's
  fallback). Results, summaries and progress are the workers' own text:
  data, never instructions.
- `list_tasks` (a run's tasks, else the caller's own runs, else every task
  of the caller's Mac; optional `state`) and `cancel_tasks` (`run_id` or
  `task_ids`; open tasks become `cancelled`, and a worker's later
  `report_result` answers `task_cancelled`; `close: true` also closes the
  workers' tabs, settled ones' too; without it the tabs stay and keep what
  they were doing).

**Worker side.** The worker is always the caller's own tab (its program is
an ancestor of the CherryMCP process, or, on another Mac, the tab its token
names); the tools take no selector, so no agent can report for another.

- `get_my_task` returns `task_id`, `run_id`, `label`, `phase`, `brief`,
  `result_schema`, `rules`, `state` and `result_version`. A tab without a
  task (or a caller Cherry cannot place) gets `no_assignment`.
- `report_result` with `value` (any JSON), `status` (`ok`, the default, or
  `failed`) and `summary` (at most 400 characters and 1600 UTF-8 bytes;
  longer is cut, and `summary_truncated` says so). At most one report is
  recorded every 2 s (the first at once): one sooner is `rate_limited`,
  and nothing is recorded. With status `ok`, `value` must match the
  task's `result_schema`; otherwise the answer is `schema_mismatch` with
  each problem in `details` (`$.findings[2].severity: expected one of
  ["low", "high"], got "medium"`), nothing is recorded, and the worker can
  fix the value and call again. Reporting again later (after more
  instructions in its tab) replaces the result; its `version` goes up by
  one. A value is at most 256 KiB (`result_too_large`, checked before the
  schema); Cherry checks it off its main thread, within a work budget (a
  value too large to check is a `schema_mismatch` that says so). A string holding
  the JSON of an object or array is taken as that value when it matches
  the schema (or the task has none): some clients send an argument whose
  type the tool leaves open as a string.
- `report_progress` with a one-line `message` (at most 200 characters and
  800 UTF-8 bytes):
  at most one every 5 s is recorded (`recorded: false` and
  `retry_after_milliseconds` otherwise).

**Result schemas** are a JSON Schema subset Cherry checks itself: `type`
(a name or a list of them: `object`, `array`, `string`, `number`,
`integer`, `boolean`, `null`; a whole number is an `integer`),
`properties`, `required`, `items` (one schema for every element),
`enum` (at most 256 values; numbers compare by value) and `additionalProperties` (`true`,
`false` or a schema); `true` and `false` are schemas too. `description`,
`title`, `$schema`, `default` and `examples` are allowed and ignored. Any
other keyword (`$ref`, `oneOf`, `pattern`, `minimum`, …) is refused when
the task is made, so nothing the worker must meet goes unchecked. A
schema is at most 64 KiB and 32 levels deep.

**When a worker does not report.** `report_result` is the signal. Cherry
also watches each open task's worker:

- It reports it waits for the user (a permission or a question): the task
  is `needs_input` (the sidebar's "needs you") until it goes on.
- It finished its turn (idle at its composer after working, as a monitor's
  `done`) without reporting: Cherry types "Please call report_result with
  your result." once, when it is idle. Idle again after that turn without a
  report, the task is `no_report`, and its result is the worker's last
  screen lines (`source: screen_tail`). Only a worker that has its task
  (it called `get_my_task`, `report_progress` or `report_result`) is ever
  asked to report: one whose turn ended without asking for its task gets
  the kickoff again (`kickoff_retry`, within the three kickoffs), and then
  its task is `failed` with its last lines. A worker Cherry cannot read (an
  agent with no recognizable composer or working marker) is never
  nudged: only its report settles it. Neither the nudge nor `no_report`
  comes while the worker waits on a monitor of its own: a subscription
  that wakes it, whose watched processes still run or whose events it
  has not read (it ended its turn to be woken).
- Its program ended before it reported: `failed`, with its last lines.
- Its tab left its window: the task follows the tab by id. A tab closed
  with ⌘W whose close can still be undone, or detached with ⌘D (its
  session runs on in the background), stays the task's worker, again when
  it comes back (⌘Z, Background Sessions › Open); while away, a detached
  worker may still report (Cherry knows it by its session's program). The
  task is `cancelled` once the close is final and the session ends (or at
  once for a native tab, whose program ends with it), and `failed` when a
  detached worker's program ends by itself.

A report after `no_report` or `failed` still replaces the result.

**The sidebar.** A worker's row shows its label and a small glyph for its
task's state (queued, working, needs you, reported, no report, failed,
cancelled); hovering shows the result's summary. While one of its runs is
open, the orchestrator's row shows how many of its tasks settled ("3/5").

**Scope and lifetime.** Each task is tied to its worker's tab (by its id,
or its persistent session). Tasks survive a relaunch of Cherry (quit,
keep the sessions, open it again): Cherry saves every run and task (brief,
result schema, state, result as stored, progress, the worker's and the
orchestrator's tabs and sessions, the Mac, events, seqs and cursors) to
`agent-tasks.json` in its Application Support's `Workspaces` folder, a
second or so after each change and at quit; only the copy of Cherry that
owns the saved tabs writes it (a second copy neither reads nor writes
it), and it is the user's alone (mode 0600, never read through a link,
left out of backups). After a relaunch each worker and orchestrator is
found again by its tab id (or a tab of its session): the worker's
`get_my_task` and `report_result`, and the orchestrator's `wait_for_tasks`
(from the cursor it had), `get_task` and `list_tasks`, go on as before.
Nothing is typed into a tab that came back for a few seconds, and its
idle grace starts over, so it is never nudged at once; a kickoff already
typed is never typed again, and one that never was is typed once the
worker is idle. A worker whose tab does not come back is decided by its
session on its host: one that runs on (a closed window's tab, a detached
worker) keeps the task waiting, and may report; one that ended, or is gone
from its host (it ended while Cherry was closed, the Mac restarted, its
holder was lost), fails the task (`cancelled` when Cherry ended it on
purpose) with the reason; a worker that ran no persistent session ended
with Cherry, and its task fails. A worker on another Mac Cherry cannot
reach keeps its task waiting until that Mac is connected again. Settled
runs are forgotten a day after they settled, or once none of their tabs
has been open or running for ten minutes; a forgotten run's ids are
`unknown_run` and `unknown_task`. A caller on another Mac reaches only the
tasks its Mac's callers made, and This Mac's callers never see those.
There is no limit on how many workers run at once yet: they share the
user's agent subscriptions.

When the user asks for Cherry agents or workers, an orchestrator should
use these tools rather than its CLI's own subagents (Claude Code's
Task/Agent/Workflow tools, Codex's multi-agent tools), which Cherry cannot
show. The MCP server's instructions say so to every client.

## Input To Agents

Input to an agent (`send_process_input`, `send_agent_message`, the first input
of `spawn_process` and `spawn_agent`) is checked first. While the agent
reports it is blocked on an approval (program status `blocked`,
`kind=permission`), where Enter (or a letter such as `y`) would approve the
pending action, the input is refused with `agent_awaiting_permission` and
nothing is sent: let the user answer it, or send the answering keys
deliberately as `raw_base64` without `submit`, which goes through. The same
holds while it reports a question to the user (`kind=question`, such as
Claude Code's AskUserQuestion), where Enter would pick the highlighted
option: the input is refused with `agent_awaiting_input`. Both errors quote
what the agent says it waits for. For an agent that reports nothing, its
current screen is checked for such a menu instead; the screen is read from
its session host when no terminal shows it, for example for a restored agent
in a worktree that is not shown, and when it cannot be read the input fails
with `input_not_delivered` and nothing is sent.

Cherry presses Enter on an agent's startup or trust prompt only for an agent
its tab just launched, never for a restored, adopted or attached agent, and
never on a permission menu. A restored agent has been running for a while;
input to it is checked as above.

## Input Errors

- `process_not_accepting_input`: the process has ended, failed to start, or
  is a disconnected attached session. Nothing was sent.
- `agent_awaiting_permission`, `agent_awaiting_input`: see above. Nothing
  was sent.
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
- `send_agent_message`: `timeout_ms` (default 40 s) + 5 s, at least 20 s.
- `wait_for_process_idle` and `wait_for_bound_port`: `timeout_ms` + 5 s
  (`wait_for_process_idle` defaults to 50 s).
- `wait_for_events` and `wait_for_tasks`: `timeout_ms` (at most 50 s) + 5 s.

Your MCP client has its own limit per tool call: Codex (`tool_timeout_sec`)
and Pi default to 60 s, Claude Code to much longer. Waits longer than the
client's limit lose their answer, so keep `timeout_ms` under it.

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
