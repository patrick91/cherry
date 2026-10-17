# Cherry MCP Guide

Cherry exposes MCP through a stdio helper, CherryMCP, that each agent
harness starts. The helper talks to the running macOS app over Cherry's
local control socket, and the app runs the tools. The MCP surface is
process-first: terminals, agents, and configured project commands are all
Cherry processes with a `process_id`.

## Setup

**Agents Cherry starts need nothing registered.** An agent tab Cherry starts
with Claude Code 2.0.0 or later, Codex 0.162.0 or later, or Pi 0.99.2 or
later, gets Cherry's server on its command line for that run, on This Mac
and on your other Macs (below):

- Claude Code: `--mcp-config '{"mcpServers":{"cherry":{"args":[],"command":"<…/Contents/MacOS/CherryMCP>","type":"stdio"}}}'`.
- Codex: `-c 'mcp_servers.cherry={command="<…/CherryMCP>",args=["--client-tool-timeout","300"],env_vars=[…],startup_timeout_sec=30,tool_timeout_sec=300}'`,
  where `env_vars` names the Cherry variables the launch sets
  (`CHERRY_PROCESS_ID`, `CHERRY_AGENT_ID`, `CHERRY_PROJECT_ROOT` when the
  tab has one, `CHERRY_CONTROL_SOCKET` when the app listens,
  `CHERRY_MCP_HELPER`). Only names go on the line, never a value.
- Pi: `-e '<…/Contents/Resources/Cherry_Cherry.bundle/cherry-pi-mcp.ts>'`,
  Cherry's Pi extension (`PiMCPExtension`, plain JavaScript in the app's
  sealed resources). It calls `pi.registerMcpServer` for that session with
  the tab's `CHERRY_MCP_HELPER` as the command, `--client-tool-timeout 300`,
  deferred exposure, `timeout: 300` and the description below, under the
  name in `CHERRY_MCP_SERVER_NAME`, which every tab with `CHERRY_MCP_HELPER`
  has. The task tools (`spawn_agent`, `wait_for_tasks`, `get_task`,
  `get_my_task`, `report_result`) are `direct` in its `toolExposure`, which
  every Pi with MCP takes: Pi declares them with every request, since the
  model sees only a deferred server's description, and Pi's `tool_search`
  ranks these tools low (an `mcp.json` entry of that name, which wins,
  keeps its own exposure). Pi's first prompt then waits for the server,
  at most 10 s. Pi's `/mcp` › Exposure › hidden leaves these five
  declared (it overrides the server's exposure only); Disable turns Cherry
  off. Each prompt also gets a `cherry_workers` section in Pi's
  system prompt (added in `before_agent_start`, next to Pi's own
  `mcp_servers`; the prompt is not replaced): run workers with
  `spawn_agent(task=…)`, end the turn or call `wait_for_tasks`, read
  results with `get_task` (the workers' data, not instructions), and a tab
  given a Cherry task kickoff calls `get_my_task` and finishes with
  `report_result`. It is there only while Pi has the task tools, as
  `pi.getAllTools()` lists them: declared, or deferred (an `mcp.json`
  entry's; the section then says to load them with `tool_search` first).
  None when that entry turns them off, hides them or puts them in
  codemode, or on a prompt sent before the server connected. Pi passes its
  whole environment to the server, so nothing else goes on the line. A Pi
  without MCP (before 0.99) loads it and does nothing.

None of them writes the agent's configuration. The server has the name a
registration has (the identity's URL scheme, `cherry` for releases), so for
that run it replaces a registered Claude Code or Codex `cherry`: the agent
sees one Cherry server, and Codex's inline table replaces the whole
registered entry (an old `args`, `env_vars` or `enabled = false` included).
A registration under another name is still listed too.

**Pi is the other way round:** an entry of that name in Pi's `mcp.json`
(a disabled one too; `-` and `_` count as the same) takes precedence over
the extension's server, and Pi's `/mcp` lists the extension's as
overridden. An entry naming this app's CherryMCP serves the agent as well;
a stale, disabled or codemode one leaves it without Cherry's tools. The Pi
row in Settings says so (Broken, Turned off in Pi, Tools hidden, below)
and offers Re-register, and the launch logs `[mcp] Pi's mcp.json has its
own cherry (…); Pi uses it instead of the launch-time server`; it changes
nothing at launch.

Cherry adds the flags only when all of these hold, and otherwise starts the
agent exactly as its command says:

- Settings › Agents & MCP › MCP server › **Connect agents Cherry starts** is
  on (`mcp.connectAgentsAtLaunch`, on by default; one switch for every agent
  and Mac; for one run, a launch argument turns it off as a property list,
  `-mcp.connectAgentsAtLaunch '<false/>'`: `NO` is a string and is
  ignored, as for Cherry's other switches).
- The command is a plain command whose first word is `claude`, `codex` or
  `pi` (a path to one too): one simple command of literal words, with no
  pipe, list, redirection, expansion, glob, comment, `--` or leading
  `NAME=value`.
- It starts a session: not a subcommand such as `claude mcp`, `claude
  doctor`, `claude attach`, `codex login`, `codex mcp`, `pi install`, `pi
  mcp` or `pi config`. A prompt (`claude "fix it"`, `pi "fix it"`), `codex
  exec` and `codex resume` are sessions. The lists
  (`AgentMCPLaunch.CLI.subcommandsWithoutSession`) were checked against
  `--help` of Claude Code 2.1.299 and Codex 0.162.1 and Pi 1.3.0's argument
  parser; recheck them when a CLI adds subcommands.
- It names no MCP configuration of its own (`--mcp-config`,
  `--strict-mcp-config`, or a `-c` with `mcp_servers`), and a Pi turns off
  neither its MCP nor its extensions (`--no-mcp`, `--no-extensions`, `-ne`:
  nothing would connect the extension's server).
- It does not end in an option that takes a value (`claude --model`, `pi
  -e`; `AgentMCPLaunch.CLI.optionsTakingValue`): the option would take the
  first word Cherry adds, and Claude Code and Pi would start a turn with the
  next one as its prompt.
- For Pi, the app's extension is there (a Cherry moved while it runs has
  none, and its Pi agents start as before).
- The CLI's version is known and at least the minimum (Claude Code 2.0.0,
  checked with 2.1.299; Codex 0.162.0, checked with 0.162.1; Pi 0.99.2,
  read from Pi 1.3.0's source: an extension's server takes a `description`
  and a `timeout` from 0.99.2). On This Mac Cherry runs `<cli> --version`
  once per run for each executable (found on the login shell's PATH, off
  the main thread, at most 5 s, with no terminal; again when the file
  changes) and asks the enabled agents' CLIs as the first window opens. It
  reads the version from the standard output: Pi 0.62.0, with no terminal,
  prints its version on standard error, so it counts as unknown and its
  agents start as before (Settings reads standard error too, but only to
  say Update Pi). A launch never waits for it: an agent started
  before its version is known (usually a tab restored as Cherry starts)
  runs without the flags until it is restarted. On another Mac the agent's
  line checks the version itself.
- The helper's path has no `'`, `\` or control character and the server
  name is `[a-z0-9_-]+`, so the words read the same under sh, zsh, bash
  and fish.

The flags are decided for each launch and never saved with the tab (its
command stays as you wrote it; a restart decides again). A shell alias or
function named `claude`, `codex` or `pi` gets them too, although its
version was read from the executable on PATH: turn the switch off if that
breaks it. The session log (`SessionLog`, "[mcp]") says what was added, or
why nothing was.

**Agents you start yourself** (in a plain shell, outside Cherry, or a
command Cherry does not extend), and agents Cherry starts while the switch
is off, use what is registered with their CLI. Start Cherry first, then
connect them with Connect Agents to Cherry… (below), or register the
helper shown in Settings › Agents & MCP yourself. In a SwiftPM checkout,
build the helper and install it like this:

```bash
swift build --product CherryMCP
codex mcp add cherry -- "$(swift build --show-bin-path)/CherryMCP"
claude mcp add --transport stdio --scope user cherry -- "$(swift build --show-bin-path)/CherryMCP"
pi mcp add cherry --exposure deferred --description 'Cherry, the terminal app this Pi runs in: its tabs, agents, waits and ports. Workers: spawn_agent with task, then wait_for_tasks and get_task. Given a Cherry task: get_my_task, then report_result. Load its tools with tool_search.' -- "$(swift build --show-bin-path)/CherryMCP"
```

Pi's registration needs Pi 0.99.2 or later (MCP came in 0.99.0;
`--description`, Pi's `mcp_servers` prompt section and deferred servers that
no longer hold up the first prompt in 0.99.2), and the Pi agents Cherry
starts use it instead of the extension's server (above). An older Pi has
no `pi mcp` and takes `mcp add …` as prompts for its model, so Cherry runs
`pi mcp` only after `pi --version` shows 0.99.2 or later, here and on your
other Macs. `--exposure deferred` lets the model find Cherry's tools
through Pi's tool search when it needs them; `direct` sends all of them
with every request, and Pi's default (`codemode`) hides them behind a
script tool. The description is the line Pi's prompt shows for the server;
it names the task tools, since `pi mcp add` sets no tool's exposure of its
own (only the extension makes them `direct`).

**Connect Agents to Cherry…** (the Omni bar, or Settings › Agents & MCP ›
MCP server) shows Claude Code, Codex and Pi on this Mac: each one's
version, whether it has Cherry MCP and what that means, the exact command
that connects it (the CLI's path as found, first; only while the row has a
button that runs it, so never for a version Cherry can't read or a Pi
without MCP), and what the agents Cherry starts get. The CLIs it does not
find are listed at its end ("Not found: …"). Each agent's page in
Settings › Agents & MCP shows the same row for its CLI, from the same
model, and the command to run yourself (Pi's only on a Pi with MCP, as in
the sheet). Nothing writes an agent's settings until you confirm: every
button that would (Connect, Connect Again, Re-register, Make Deferred and
**Connect All**) first shows "Cherry will run:", the exact commands, the
file the CLI writes and what it replaces, and only its **Connect** runs
them, each as an argv with no shell in between, in your login shell's
environment (each CLI writes its own settings; Cherry never edits them).

Each CLI's state is read when a sheet or page shows and on Check Again
(never as Cherry starts), with nothing that starts a server or writes a
file:

| CLI | Read | Never run |
|---|---|---|
| Claude Code | `claude --version`, then its settings file: `.config.json` in its config directory (`CLAUDE_CONFIG_DIR`, else `~/.claude`) when that legacy file exists, else `.claude.json` in `CLAUDE_CONFIG_DIR` when it is set, else in your home folder (as Claude Code 2.1.299 writes it); its top-level `mcpServers.cherry` (`type`, `command`, `args`; not `env`) | `claude mcp list`, `claude mcp get` (both start the server, and `get` rewrites the file) |
| Codex | `codex --version`, then on Codex 0.162.0 or later `codex mcp get cherry --json` (`enabled`, `transport`; it starts no server and writes no settings), at most 10 s; an older Codex is "Not checked", with Connect still offered | `codex mcp list`; Cherry does not parse `config.toml` (profiles and project settings would be missed) |
| Pi | `pi --version`, then on Pi 0.99.2 or later its `mcp.json` (below) | `pi mcp list`, which starts every server |

Claude Code's and Codex's rows say:

| Status | When | Button |
|---|---|---|
| Not installed | not found (the login shell's PATH, then `~/.local/bin`, `~/.claude/local`, `~/.bun/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) | Check Again |
| Unknown | `--version` printed no version, or did not answer | Check Again |
| Not connected | no entry of this app's name | Connect |
| Connected | this app's CherryMCP, with no arguments | Connect Again (in `⋯`) |
| Turned off | Codex's `enabled = false` | Connect |
| Another Cherry / Broken | another CherryMCP, which runs / is gone | Re-register |
| Differs | this app's CherryMCP with arguments, or not a stdio server | Re-register |
| Can't read | the file is not a JSON object, `CLAUDE_CONFIG_DIR` is not an absolute path (Claude Code refuses one too), or Codex's own error | Check Again |
| Not checked | a Codex before 0.162.0 | Connect |

Claude Code's Connect runs `claude mcp add --transport stdio --scope user
cherry -- <CherryMCP>`; its Re-register and Connect Again run `claude mcp
remove --scope user cherry` first, since its `add` refuses a name it has
(what the remove said is shown only when the add fails). Codex's `codex
mcp add cherry -- <CherryMCP>` and Pi's command replace an entry of the
name, so theirs are one command. **Connect All** shows one confirmation
with the commands of every CLI that is not connected, turned off, has its
tools hidden (Pi) or names a CherryMCP that is gone; never one that is
connected (Pi's direct one too), another Cherry's helper that runs, or one
with other arguments: those are yours to change with their own buttons.
After a run each row is read again and shows the CLI's own output; one
that worked adds "Sessions already open read their MCP servers when they
start: restart them." (Pi: "type /reload in them, or restart the tab.").

**Connect This Agent to Cherry…** (the Omni bar, while the selected tab is
a Claude Code, Codex or Pi agent) shows that CLI's row and how this tab
started: with Cherry MCP for this session (for Claude Code and Codex their
registration is then for sessions started elsewhere; Pi's own `cherry`
entry still wins), or without it and why, with **Restart Tab** (as Restart
Active Tab) when a launch now would get it: its version is known now, or
the CLI was updated. It also says what this project's settings change, read
only and with no button: for Pi a `cherry` entry in the `.pi/mcp.json` of
the tab's directory (else its project root's) that turns it off, sets its
exposure or runs a command of its own, which Pi uses once it trusts the
project; for Claude Code, when this launch had no Cherry MCP, a local-scope
entry (`projects["<project root>"].mcpServers.cherry` in its settings file),
which it uses instead of the user one; for Codex nothing (its project
settings are not read). After a Connect there, Restart Tab is offered for a
Claude Code or Codex tab that started without Cherry MCP. For a tab on
another Mac it reads nothing of This Mac's and offers Set Up Cherry MCP on
<Mac>… (Agents On Another Mac).

A Pi row (a Pi agent's page, the sheets, and Agents & MCP's Connect other
agent CLIs) finds `pi` as above (the login shell's PATH, then the same
directories), runs `pi --version` and nothing else (never `pi mcp list`,
which starts every server), and on a Pi with MCP reads its `mcp.json`,
never writing it. Its row then says:

| Status | When | Button |
|---|---|---|
| Not installed | no `pi` found | Check Again |
| Unknown Pi | `--version` printed no version on its standard output (and no version before 0.99.2 on its standard error), or did not answer | Check Again |
| Update Pi | a Pi before 0.99.2: its standard output's version, else its standard error's (Pi 0.62.0 prints it there without a terminal) | Check Again |
| Not connected | no entry of this app's name | Connect |
| Connected | this app's CherryMCP, deferred | Connect Again (in `⋯`) |
| Connected (direct) | this app's CherryMCP, direct | Make Deferred |
| Tools hidden | this app's CherryMCP, `codemode` (also no `exposure`) or `hidden` | Make Deferred |
| Turned off in Pi | `"enabled": false` | Connect |
| Another Cherry / Broken | another CherryMCP, which runs / is gone | Re-register |
| Differs | this app's CherryMCP with arguments, deferred with another description than Cherry's (an older Cherry's, or none: Pi's prompt lists the server with it), or no command | Re-register |
| Can't read | `mcp.json` is not a JSON object | Check Again |

Connect, Make Deferred, Re-register and Connect Again all run the command
above (`pi mcp add` replaces an entry of the same name), only once you
confirm it, and only after `pi --version`, run again then, says 0.99.2 or
later (a version manager's shim stays the same file while its Pi changes;
Check Again runs it again too). On any other answer nothing runs: a Pi
before 0.99 has no `pi mcp` and would take `mcp add …` as prompts for its
model. A refused one shows Pi's own words and is never retried another
way. Only the entry's `enabled`, `command`, `args` and `exposure` are
compared (its description, `env` and `timeout` are Pi's).

**MCP server › Connect other agent CLIs** on Agents & MCP shows the three
commands (Pi's only on a Pi with MCP), with Pi's row. Every CLI runs, and
is read, in the environment of your login shell, as this run of Cherry
captured it, so a `PI_CODING_AGENT_DIR`, `CODEX_HOME` or
`CLAUDE_CONFIG_DIR` set there names the settings each uses; Set Up Cherry
MCP on another Mac passes that Mac's login-shell `PI_CODING_AGENT_DIR` to
`pi` too. The same section's **Control socket** row shows the socket this
app's tabs name (below) and whether it listens.

The helper talks to Cherry through the instance-scoped Unix control socket; the
old direct HTTP MCP endpoint has been removed.

## Versions

The app answers three requests of control protocol 2 besides the typed
requests every CherryMCP used before: `appInfo` (which app answers and its
build), `listTools` (the tools for one client) and `callTool` (one tool
run in the app as its caller). CherryMCP asks `appInfo` on its first
`tools/list` or call:

| CherryMCP | Cherry with control protocol 2 | An older Cherry (no `appInfo`) |
|---|---|---|
| this one | **pipe**: `tools/list` is the app's `listTools`, each `tools/call` one `callTool` | **legacy**: its own tool list, and it runs the tools itself over typed requests |
| an older one | typed requests, answered as before; its own compiled list | as before |

- In pipe mode every tool name goes to the app, so a tool of a newer app
  works through a helper that does not know it, and a name the app does
  not know is the app's `unknown_tool`. In legacy mode a name the helper
  does not know is `unknown_tool` before anything is sent.
- An app that cannot decode `appInfo` (`invalid_request`) makes the
  session legacy for 60 s, then it asks again (an update may replace the
  app while the agent runs). Any other failure (`cherry_unavailable`,
  `cherry_unreachable`, `unauthorized`, `socket_not_private`) is returned as
  the tool's error and never changes the mode. A `callTool` refused with
  `invalid_request` by an app that still says protocol 2 is that tool's
  error; one refused because an older app replaced it runs in the helper.
- `appInfo` waits 2 s before a `tools/list` (the app answers it, and
  `listTools`, before its task restore) and 10 s before a call. When no app
  answers a `tools/list` in time, and in legacy mode, the helper lists its
  own catalog (`CherryToolCatalog`, the same tools) as for a client it
  knows nothing of: `wait_for_events` and `wait_for_tasks` say at most
  50 s, an older app's limit, whatever the client allows (a pipe app that
  answers later sends `list_changed` with the client's own limit); when
  no app answers a call, the
  call fails as before (`cherry_unavailable`, or `cherry_unreachable` from
  another Mac), after the checks the helper can make itself (an unknown
  tool, a missing argument).
- Every `callTool` answer carries the digest of the app's list for that
  client (`toolsDigest`). When it is not the list the client was served,
  CherryMCP sends `notifications/tools/list_changed`, once per new digest
  (its `initialize` answer says `listChanged: true`).
- The server instructions are the helper's own build's, sent before the
  app is asked anything.
- `CherryMCP --version` prints
  `{"build":"<build>","controlProtocol":2,"name":"CherryMCP","version":"<build>"}`:
  the enclosing app's `CFBundleVersion`, a device install's build directory
  name, else `dev`. Its `initialize` answer names the same build as the
  server's version.
- `get_status` always runs in the helper (it reports the helper's socket)
  and asks `appInfo` again. It adds `helper_build`, and `app_build`,
  `app_control_protocol` and `mode` (`pipe` or `legacy`; absent while no
  app answers).

### What changed for agents

Against cda2728 (the last helper that ran every tool itself), on purpose:

- Shorter tool and parameter descriptions; some parameters have none. The
  52 tools' names and input schemas (property names, types, `required`)
  are unchanged.
- Every tool has annotations, `openWorldHint: false`. Read-only (24):
  every `get_`, `list_`, `search_` and `wait_` tool but
  `wait_for_bound_port`, `whoami`, `resolve_link`, `services_list` and
  `bind_session_process`: bookkeeping counts as a read (`wait_for_events`
  acknowledges events, `get_my_task` marks its task fetched,
  `bind_session_process` binds only the MCP session), so Codex's approval
  mode for writes prompts for none of them. `wait_for_bound_port` is not
  one: with `probe_http` it forwards another Mac's port to This Mac's
  loopback and sends the service a request.
  Destructive (10): `cancel_tasks`, `stop_process`, `restart_process`,
  `close_process`, `send_process_input`, `send_agent_message`,
  `stop_all_commands`, `restart_all_commands`, `delete_todo`,
  `delete_todo_comment`. The other 18 add or start something
  (`destructiveHint: false`); of them `open_project`, `unsubscribe`,
  `rename_process`, `select_process`, `select_todo`, `update_todo` and
  `update_todo_comment` are idempotent.
- `capabilities.tools.listChanged` is true, with `list_changed` as above.
- `serverInfo.version` is the build, not `0.1.0`; `--version` as above.
- `get_status`'s build and mode fields. Its `socket_path` and
  `socket_exists` are left out when the caller has no socket of its own (a
  `callTool` from another Mac, answered in the app).
- `whoami.caller_process_id`, the default `process_id`, the default
  `parent_agent_id` and `subscribe`'s subscriber come from the caller
  Cherry verified (below), else from the caller's claim. They are what the
  helper inferred whenever its inference worked; a subscriber whose
  environment says another tab than its process tree now gets its wake
  line in its own tab. A call made without an MCP session's context
  (`CherryMCPTools.call` in tests) takes the environment's
  `CHERRY_PROCESS_ID` as its claim for `whoami` and the default process
  too, where only `subscribe` did before.
- `wait_for_events` and `wait_for_tasks` accept the client's own limit
  (Client Timeouts, below); their descriptions state it. Defaults are
  unchanged.
- CherryMCP no longer lists processes at startup to find its caller (the
  app identifies it), so it starts faster; only a legacy session still
  looks, once, at its first call.
- Arguments travel as JSON: a whole number written with a zero fraction
  (`5000.0`) is honored, and a string that looks like a data URL is the
  string the client sent (the MCP SDK reads it as data, so CherryMCP keeps
  the call's arguments as written for its handler; such an argument was
  dropped before). Only `CherryMCPTools.call`, which takes the SDK's
  values (tests), passes it as a base64 data URL of the same bytes,
  `data:,hi` as `data:text/plain;base64,aGk=`.
- The composite tools (`whoami`, `bind_session_process`, `spawn_agent`'s
  parent check, `send_agent_message`) run in the app on one connection.
- The helper's socket calls run on threads of their own, so parallel
  waits no longer hold up each other.
- The server instructions no longer give `wait_for_tasks`' limit (it
  depends on the client); the rest of them is unchanged.
- The identity checks below (`socket_not_private`, other accounts refused,
  no takeover of a live socket) and the tab's `CHERRY_CONTROL_SOCKET`.
- Launch-time MCP for the Claude Code, Codex and Pi agents Cherry starts
  (Setup), and Pi's deferred registration, which Cherry runs only on Pi
  0.99.2 or later.
- Decoding errors (and requests for the removed notes) are answered before
  the app's task restore, not after it.

## Scope And Identity

- The app runs every tool (`callTool`) and identifies its caller itself:
  on This Mac by its process, the tab whose program is the CherryMCP
  process or one of its parents, as the process tree was when it
  connected; on another Mac by its tab's token (below). What the helper
  says of itself (`CHERRY_PROCESS_ID`, its bound process, its project and
  directory) only supplies defaults when Cherry verified no caller; tasks,
  wake lines, `sub_agents` and run ownership use only the verified caller.
- `whoami` reports the caller process, active/effective project root,
  selected process, and bound process.
- `CHERRY_PROCESS_ID` identifies the Cherry process that launched the helper.
  `CHERRY_AGENT_ID` is still exported for agent processes as a compatibility
  alias.
- Every tab's environment names its app: `CHERRY_CONTROL_SOCKET` is the
  socket that app's server listens on (on This Mac; a tab on another Mac
  names the forward there), and `CHERRY_CLI` is the `cherry` command-line
  tool of the Cherry build that started the tab (a device tab's names the
  install's on that Mac, when it has Cherry MCP and Ghostty's resources
  there). CherryMCP uses the tab's socket, so a helper of another build (a
  hand-registered development build) reaches the tab's own app. A tab of a
  Cherry whose server could not listen has `CHERRY_CONTROL_SOCKET` empty or
  unset, and never names the socket of a Cherry that Cherry was started
  from; whatever reads it treats an empty value as unset.
- `CHERRY_MCP_HELPER` is the absolute path of the CherryMCP of the Cherry
  that started the tab (This Mac's tabs, native and persistent, and tabs on
  another Mac alike), so `"$CHERRY_MCP_HELPER" --call TOOL '{…}'` works from
  any tab's shell whatever its PATH.
- If an MCP client strips Cherry environment variables when launching the stdio
  helper, the app still finds the caller from its process; a legacy helper
  (against an older app) matches its own parent process ancestry against
  Cherry's live process list.
- The socket is private: the app's socket directory is this account's
  (0700, `/tmp/cherry-$UID/<instance>/`, the shared `/tmp/cherry-$UID` not
  writable by others), the socket 0600. CherryMCP connects only to a socket
  this account owns, in a directory no other account may enter (a link in
  such a directory is followed: a device's forward can be one), and only
  while the process answering is this account's; otherwise it fails with
  `socket_not_private`, saying why. A missing socket is still
  `cherry_unavailable`. The app answers only this account's processes: a
  peer of another uid gets `unauthorized`, on This Mac's socket and a
  device's listener alike.
- The caller's process and its parents are pinned when it connects, each
  with when it started (root's processes too, such as a native tab's
  login(1)), so a caller that exits mid-call never lends its tab to a
  process that reuses its pid; a caller gone before it was pinned has no
  verified tab.
- A Cherry never takes over a live control socket; only a stale one,
  whose server is gone, is replaced, and a server removes only the socket
  file it bound itself. A Cherry started from a Cherry tab inherits that
  tab's `CHERRY_CONTROL_SOCKET` and uses its own default path instead. A
  second copy of the same Cherry (the same path) runs without a control
  socket and logs why (`socket_in_use`); the helpers of its tabs reach the
  first copy, which finds none of its own tabs to be the caller and
  answers unscoped requests in its active window. To tell a live socket
  from a stale one, Cherry connects, sends an empty line (an invalid
  request to every Cherry) and waits for the answer or the close, at most
  200 ms: a probe that left at once would leave the server a connection it
  cannot guard against SIGPIPE, which a Cherry from before `MSG_NOSIGNAL`
  would get answering it. The server writes its answers with
  `MSG_NOSIGNAL`, so no caller that goes away mid-answer can stop the app.
- `bind_session_process` binds the current MCP session to a process. Later
  process tools can omit `process_id` unless they pass `process_name`.
- `select_process` is the process-level UI selection tool. It is intentionally
  explicit; other process tools do not change the visible Cherry selection.
  It selects the tab in the window that has it, which it does not bring
  forward.
- A request scoped to a project (a tool call is scoped to its
  `project_root`, else the caller's `CHERRY_PROJECT_ROOT`, else the
  innermost open project of its directory) goes to the caller's own window
  when the project has several windows, else to the active window when it
  is the project's, else to the project's most recently active window.
  Listings and counts are that window's; a `process_id` finds its tab in
  any window. A project command runs in one tab across the project's
  windows: its `process_name` finds that tab in any of them, starting it
  (`start_process`, `spawn_process`, `start_all_commands`) uses that tab
  where it is, and `stop_all_commands` stops the project's commands in
  every window. The project's to-dos are one list for all its windows;
  `select_todo` selects in the request's window.

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
- Unscoped requests go to the tab's window, and a scoped one to the
  tab's window too when it is a window of that project (else to the
  project's most recently active window there). A `project_root` is an
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
  tab, installed on that Mac with `cherry` and `cherry-host`, and
  `CHERRY_CLI` that install's `cherry`.
- When Cherry cannot be reached from there (it quit, the Mac slept, the SSH
  connection is being made again), tools fail with `cherry_unreachable`:
  "Cherry on <this Mac> is not reachable". The forward is made again when
  Cherry reconnects to that Mac.
- The helper there is the install's build, older than this Cherry until
  **Update Session Host…**: an install from before control protocol 2
  sends typed requests, answered as before. A newer one is a pipe: its
  tool calls run in the app as `callTool` over the forward, each of their
  requests checked as a typed request is (the token again before each one,
  the bounds above), and its `get_status` names the forward, never a path
  of This Mac.

**Agents Cherry starts there** get Cherry MCP on their command line, as on
This Mac (Setup), with the install's CherryMCP (`<build>/CherryMCP` there)
and the same server name (the tab's `CHERRY_MCP_SERVER_NAME`); Codex's
`env_vars` also names `CHERRY_CONTROL_SOCKET`, `CHERRY_CONTROL_MACHINE`,
`CHERRY_MCP_TOKEN` and `CHERRY_CLI` when the tab has them (only names: the
token never goes on the line), and Pi gets the install's copy of Cherry's
Pi extension, `<build>/cherry-pi-mcp.ts`, which Add Mac… and Update Session
Host… copy with CherryMCP (Pi passes the token to the server with the rest
of its environment). Cherry keeps no version of that Mac's CLIs, so the
agent's line checks its CLI each time it starts:

```sh
if [ -x '<build>/CherryMCP' ] && cherry_v=$('claude' --version 2>/dev/null </dev/null) && printf '%s\n' "$cherry_v" | /usr/bin/awk '…at least 2.0.0…'; then exec claude … '--mcp-config' '{…}'; else exec claude …; fi
if [ -x '<build>/CherryMCP' ] && [ -r '<build>/cherry-pi-mcp.ts' ] && cherry_v=$('pi' --version 2>/dev/null </dev/null) && printf '%s\n' "$cherry_v" | /usr/bin/awk '…at least 0.99.2…'; then exec pi … '-e' '<build>/cherry-pi-mcp.ts'; else exec pi …; fi
```

- Only for a plain `claude`, `codex` or `pi` command (Setup's rules), only
  in a tab that has the forwarded socket and an install with CherryMCP (and,
  for Pi, one whose device record has its resources: an install made before
  Cherry had the extension fails the `-r` check and runs the line as before
  until Update Session Host…), only under an sh-family login shell there
  (zsh, bash, sh, ksh, mksh, dash, yash, oksh, loksh; fish, csh, tcsh and
  others run the line as before), and only while Connect agents Cherry
  starts is on.
- Both branches `exec`, so the session's program is the agent itself, as
  with the plain line: its ports, signals and foreground job. A `claude` or
  `codex` shell function that the login startup files there define is
  therefore not used: `exec` runs the executable on PATH. An install whose
  CherryMCP is missing, an older CLI, or one whose version cannot be read
  from its standard output (Pi 0.62.0 prints it on standard error), runs
  the line as before (so a Set Up registration, whose launcher finds
  another CherryMCP, still serves it), and a missing CLI still exits 127
  with Cherry's "not on <Mac>'s login PATH" message. An executable written
  `~user/…` fails the check and runs the line as before.
- Each launch runs `<cli> --version` there once (for a Node CLI about
  0.3–1 s before the agent starts); a `--version` that hangs delays the
  agent, as Cherry sets no time limit there.
- The log names the flags only, as on This Mac.

Agents started there by hand, and agents Cherry starts there under another
login shell or with an older CLI, read their MCP servers from their own
configuration there (a Pi's own `cherry` entry wins over the extension's
there too). **Set Up Cherry MCP on <Mac>…** (the device's menu in the
project picker, Settings › Macs, or Connect This Agent to Cherry… for an
agent tab of that Mac, which says "<agent> on <Mac> gets Cherry MCP at
launch when <Mac>'s session host is this build or newer (Update Session
Host…), with an sh-family login shell", for Pi "and Pi 0.99.2 or later")
shows these commands and runs them there only when you confirm; running it
again gives the same result, and **Remove** takes the registrations away:

```bash
# the launcher: runs $CHERRY_MCP_HELPER (else the newest installed CherryMCP,
# else that Mac's own Cherry.app's)
~/Library/Application Support/cherry-host/mcp/cherry-mcp
claude mcp add --scope user --transport stdio cherry -- "$HOME/Library/Application Support/cherry-host/mcp/cherry-mcp"
codex mcp add cherry -- "$HOME/Library/Application Support/cherry-host/mcp/cherry-mcp"
# only with Pi 0.99.2 or later: an older pi takes these words as prompts
pi mcp add cherry --exposure deferred --description '…' -- "$HOME/Library/Application Support/cherry-host/mcp/cherry-mcp"
```

Each run asks `pi --version` there first (check, Set Up and Remove alike)
and runs `pi mcp add` or `pi mcp remove` only on Pi 0.99.2 or later; any
other Pi is reported as `pi_skipped` ("Pi <version> has no MCP (needs
0.99.2 or later)"), not as a failure, and the sheet says "Pi <version>: no
MCP, update Pi there". A Pi whose `--version` printed no version on its
standard output is asked again for its standard error (`pi_version_errors`),
which only names an older one there (Pi 0.62.0 prints its version on
standard error without a terminal); for one that printed nothing else the
sheet says "its --version did not answer: no MCP".
A Mac whose only agent CLI is such a Pi has nothing to set up.

Codex passes an MCP server only a few variables of its own environment, so
Set Up also adds `env_vars = ["CHERRY_MCP_TOKEN", "CHERRY_CONTROL_SOCKET",
"CHERRY_PROCESS_ID", "CHERRY_AGENT_ID", "CHERRY_PROJECT_ROOT",
"CHERRY_MCP_HELPER", "CHERRY_CONTROL_MACHINE"]` to `[mcp_servers.cherry]`
in `~/.codex/config.toml` (or `$CODEX_HOME`) there. Cherry never changes
those configurations otherwise.

`CherryMCP --call TOOL [JSON]` runs one tool call and prints its result (exit
1 on an error), and `CherryMCP --version` says what it is; both are for
checks without an MCP client.

## Project Tools

- `list_projects` lists the saved and open projects: each one's root, name,
  whether it is active or open, and its to-dos feature.
- `open_project` focuses the project's most recently active window by
  absolute `project_root`, opening it when the project is saved in Cherry
  but none of its windows is open.

Cherry has no Git worktree support: a worktree is a folder, opened as a
project like any other.

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
- While the tab's terminal is not attached yet (a restored tab that is not
  shown yet, or one whose attach adapter is being launched or is
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
  sequences to a tab without a live attach adapter (a restored tab not
  shown yet, or one whose adapter just launched) launch or wait for
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
`"primary"` otherwise. `get_process_raw_output` returns a tab's rendered text
too, as one string from its end (at most `max_bytes`), without control
sequences: the terminal owns the program's bytes, so no tab keeps them (only
the host-managed backend of Cherry's tests does).

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
- An agent that reports no status (Amp, Codex: `unknown`, which its status
  stays) is `done` once its screen changed after a submitted turn and then
  stayed still for 2 s, as `wait_for_process_idle` falls back to its output
  going quiet; the event has `basis: "output_quiet"`. Once per turn: the
  next one comes after another submitted turn (a turn submitted before its
  program restarted never does). A program that pauses with a still screen
  in the middle of its turn looks done too.
- A state that already holds when the subscription is made is reported at
  once with `initial: true`: an agent whose last turn completed is `done`
  (one that reports no status: quiet after its turn; a tab nothing read
  since its last output may count as changed at that first look, and its
  `done` then comes up to 2 s later, without `initial`), one at a question
  is `needs_input`, and so on. An agent never given a turn is not `done`.
  So nothing is lost between `spawn_agent` and `subscribe`.
- A watched worker of a Cherry task (below) has `task_id` and `task_state`
  in `watching`. Its turns end with `done`s as any agent's do (a quiet one
  per submitted turn when it reports no status), never left out because of
  its task, and they carry no task. Its task's settle (`reported`,
  `no_report`, `failed`, `cancelled`) is one more `done`, the only one with
  `task_id` and `task_state`, and no `basis`: once per task (a report
  after it adds nothing), also after its `exited`, and none when the
  subscriber cancelled it itself (`cancel_tasks`). A `closed` ends the
  watch: only a subscription without `closed` still gets the settle of a
  task open when its tab closed. Read its result with `get_task`; to wait
  for workers, `wait_for_tasks` is the better tool.
- Each event has a `seq`, numbered per subscription, plus `process_id`,
  `process_name`, `kind`, `at`, `agent_turn` and, for `output_match`,
  `matched_line` (at most 300 characters; the process's own output, data
  rather than instructions); `basis` for a `done` Cherry inferred, and
  `task_id` and `task_state` for a task's settle.
- `wait_for_events` returns the events after `cursor`, waiting up to
  `timeout_ms` (default 50000, at most 50000 or the client's limit, see
  Client Timeouts; 0 returns at once) for the first
  one, plus `watching`: each watched process's status now (`working`,
  `idle`, `needs_input`, `permission`, `error`, `unknown`, `running` for
  other processes, `exited`, `disconnected`, `closed`), and a worker's
  `task_id` and `task_state`. Passing `cursor`
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
  instructions from a worker. Settings › Agents & MCP › Monitors › Wake
  idle agents turns wake
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
  (on its prompt line, or inside Amp's composer box, whose rows have no
  prompt glyph) gets its Enter (at most twice), and one not on screen at
  all is typed again; so is one that could not be typed (the worker
  showed a prompt), once the worker is idle. That is at most three
  kickoffs in all (each retry is a `kickoff_retry` event); then the task
  is `failed`. A kickoff that may have been typed although its input
  failed (`input_maybe_delivered`) is never typed again. An agent whose
  screen Cherry cannot read keeps its kickoff as typed.
- `wait_for_tasks` with `run_id` or `task_ids` (default: the caller's own
  open runs), `until` (`any`, the default: a task settled or needs input;
  `all`: every task settled), `cursor` and `timeout_ms` (default 50000, at
  most 50000 or the client's limit, see Client Timeouts; 0 returns at
  once). It returns `events` after `cursor`
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
  Agents & MCP › Monitors › Wake idle agents turns it off with monitors'
  wake lines.
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
whose tab is not shown yet, and when it cannot be read the input fails
with `input_not_delivered` and nothing is sent. The first input of
`spawn_process` and `spawn_agent` (a task's kickoff included) that is refused
or not delivered leaves the process running: the result has `sent_bytes` 0
and `input_error`, the error's `code` and `message` (absent when the input
arrived, and from apps that predate it).

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

CherryMCP waits for each tool call's answer as long as the call can take
(`CherryToolLayer.callTimeout`): 10 s by default, longer for tools that
wait on purpose:

- `spawn_process`, `spawn_agent` and `send_process_input`: `wait_ms` + 20 s,
  since a persistent tab's session may still be created and an agent's first
  input waits for it to be ready. `spawn_process` with kind `command` waits
  `wait_ms` + 30 s, because it first waits up to 10 s for a restore under way
  that may bring back the command's tab. A new agent (`spawn_agent`, or
  `spawn_process` with kind `agent`) waits 5 s more, for the check that
  nests it under its caller.
- `start_process`, `start_all_commands` and `restart_all_commands`:
  `wait_ms` + 20 s, as they also wait up to 10 s for such a restore.
- `send_agent_message`: `timeout_ms` (default 40 s) + 25 s: the message
  (20 s, as `send_process_input`) and then its wait, in one call.
- `wait_for_process_idle` and `wait_for_bound_port`: `timeout_ms` + 5 s
  (`wait_for_process_idle` defaults to 50 s).
- `wait_for_events` and `wait_for_tasks`: `timeout_ms` (default 50 s, at
  most the client's cap below) + 5 s.

A legacy helper (against an older Cherry) sends each of a tool's typed
requests on its own connection and waits for each as long as before
(`CherryToolLayer.clientTimeout`; `send_agent_message`'s `timeout_ms` + 5 s,
at least 20 s).

Your MCP client has its own limit per tool call, and a wait longer than it
loses its answer. `wait_for_events` and `wait_for_tasks` therefore accept
up to what the client allows, by the name its `initialize` gives
(`CherryToolCatalog.waitCap`), and say so in their descriptions:

| Client | Its limit is known from | `timeout_ms` accepted up to |
|---|---|---|
| Claude Code (`claude-code`) | `MCP_TOOL_TIMEOUT` (ms) in CherryMCP's environment, else its long default | that limit less 10 s, between 50 s and 300 s; 300 s when it declares none |
| Codex (`codex-mcp-client`) | `--client-tool-timeout <seconds>` among CherryMCP's arguments (Cherry passes 300 to the Codex it starts, with `tool_timeout_sec=300`) | that limit less 10 s, between 50 s and 300 s; 50 s when it declares none |
| Pi (`pi`) | `--client-tool-timeout <seconds>` among CherryMCP's arguments (Cherry's Pi extension passes 300, with `timeout: 300`) | that limit less 10 s, between 50 s and 300 s; 50 s when it declares none |
| any other (`--call`, unknown) | – | 50 s |

Codex's documentation gives `tool_timeout_sec` a 60 s default, while
Codex itself has defaulted to 300 s since mid-2026; a Codex you registered
yourself tells CherryMCP nothing, so it keeps 50 s. A Pi registration
(`pi mcp add` takes no timeout) allows Pi's default 60 s and tells
CherryMCP nothing, so it keeps 50 s too, also in the Pi agents Cherry
starts, which use it instead of the extension's server. Defaults stay 50 s
for every client (`send_agent_message` 40 s); `wait_for_process_idle` and
`send_agent_message` keep their 300 s maximum and `wait_for_bound_port`
its 60 s. Typed requests from an older helper keep 50 s.

## Control Socket

Each connection carries one JSON line each way: a request, then its
answer, `{"result":…}` or `{"error":{"code":…,"message":…}}` (a caller on
another Mac wraps its request in `{"cherryAuth":{"token":…,"processID":…},"request":…}`).
Besides the typed requests (`{"listTerminals":{}}` and the like, which
older helpers send and which stay as they are), control protocol 2 has
three:

| Request | Answer |
|---|---|
| `{"appInfo":{}}` | `{"result":{"appInfo":{"_0":{"build":"…","bundleIdentifier":"dev.patrick.cherry","controlProtocol":2,"urlScheme":"cherry","version":"…"}}}}` |
| `{"listTools":{"_0":{"profile":{"client":{"name":"claude-code","version":"2.1.299"}}}}}` | `{"result":{"listTools":{"_0":{"digest":"<16 hex>","instructions":"…","tools":[…]}}}}` |
| `{"callTool":{"_0":{"name":"list_processes","arguments":{"kind":"agent"},"context":{…}}}}` | `{"result":{"callTool":{"_0":{"isError":false,"structured":{…},"text":"{…}","toolsDigest":"<16 hex>"}}}}` |

- `tools` are MCP tool definitions (`name`, `description`, `inputSchema`,
  `annotations`), and `digest` the first 16 hex digits of the SHA-256 of
  their sorted-keys JSON. A profile's `toolTimeoutMilliseconds` is the
  client's limit when known.
- A call's `context` says what the caller says of itself:
  `callerProcessID` (a claim), `boundProcessID`, `bindsSession`,
  `projectRoot`, `workingDirectory`, `profile` and `interface` (`mcp`,
  `call`). The app takes its defaults from the caller it verified first.
- `text` is the tool's result as agents read it (snake_case keys, sorted),
  `structured` the same payload with camelCase keys (MCP's
  `structuredContent`), and `bindProcessID` the process an MCP session
  binds to now (`bind_session_process`, `spawn_agent` with
  `bind_session`). A tool's error is a result with `isError: true` and
  `text` `{"error":{…}}`; a top-level `error` means the request itself
  failed (`invalid_request` from an app that does not know it,
  `unauthorized`, `request_too_large`, `request_timeout`,
  `too_many_connections`, `server_unavailable`).
- The three are never scoped: one inside `scoped` is refused with
  `invalid_request` (a tool call names its project in its arguments). A
  caller on another Mac sends them in its envelope too; its listener
  answers `appInfo` and `listTools` only for a valid token, and checks the
  token again before each of a call's requests.
- `appInfo` and `listTools` are answered at once, before the app's task
  restore; `callTool` waits for it, as every typed request does.

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

## Todos

Cherry also exposes project todos through MCP. These tools are
project-scoped and do not change visible UI selection unless the tool name starts
with `select_`.

## Testing The Control Server

The MCP tools and the control socket's tool requests have a group of their
own in `Scripts/test-session-suites unit` (and CI), **ControlTool**
(`--filter ControlTool`):

- `ControlToolCatalogTests`: the 52 tools in their order, the list encoded
  byte for byte as `Fixtures/mcp-tools-list.json` (for a client Cherry
  knows nothing of) and the schemas as `Fixtures/mcp-tool-schemas.json`,
  the list's byte budget (28 000), the facts agents act on, the
  annotations, the per-client caps and the descriptions that state them.
  A deliberate change of a description or an annotation regenerates the
  list fixture; the schema fixture never changes.
- `ControlToolLayerTests`: the tool layer over a recording transport
  (argument parsing, scoping, the composite tools, timeouts, the
  encoding), and over a socket off the cooperative pool.
- `ControlToolServerTests`: `appInfo`, `listTools` and `callTool` against
  a private server, each read compared with the layer over typed requests,
  the verified caller's defaults, the cap, scoped and device refusals.
- `ControlToolIdentityTests`: the client's directory, socket and peer
  checks, the server's directories, a live socket never taken over, the
  caller chain pinned at accept, and probes and clients that leave at once
  (no SIGPIPE).
- `ControlToolPipeTests`: the real CherryMCP (`.build/debug/CherryMCP`)
  as an MCP client sees it: pipe and legacy, no app, an app replaced by an
  older one, `list_changed`, `--version`, `--call`'s exits.
- `ControlToolLaunchTests`: launch-time MCP on This Mac (detection, the
  arguments, quoting under sh, zsh, bash and fish, the version probe with
  stand-in CLIs, the switch, launches native, persistent and restored, and
  Pi's: its extension, its version gate, and the log of a Pi registration
  Pi prefers).
- `ControlToolPiExtensionTests`: Cherry's Pi extension, the bundle's own
  copy run in JavaScriptCore against a stand-in for Pi's extension API: the
  server it registers, and nothing (and no exception) without Pi's MCP, a
  usable helper or name, or a `process`.
- `ControlToolConnectTests`: Connect Agents to Cherry… and Connect This
  Agent with stand-in claude, codex and pi in a private HOME (Claude Code's
  settings file and its rules, `codex mcp get --json`'s answers, an old Pi
  asked only its version): what each row says, that nothing but
  `--version` and `codex mcp get` runs before a confirmed plan, Claude
  Code's remove-then-add, Connect All's choice, the confirmation's texts,
  Restart Tab, and the Omni bar's rows.

Tests never use the default socket (every client gets its harness's).
The ControlTool and device tests inject their environment
(`CherryMCPSession(environment:)`, `SocketToolTransport(socketURL:)`) and
never `setenv` it; the older `mcp` tests in CherryTests.swift still set
the process environment around `CherryMCPTools.call`, which reads it.
Tests never get launch-time flags or probe a CLI unless they build their
own `AgentCLIVersions` (a test workspace's policy has no `agentMCPLaunch`,
a test's `RemoteDeviceStore` connects no agents), find CLIs only on the
PATH they give (no fallback directories, which include the real
`/opt/homebrew/bin`), and never run a real `claude`, `codex` or `pi`.
`SettingsWindowMCPInstallTests` (SettingsWindow group) has Pi's row and
its gate: a stand-in old Pi that logs every call but `--version` is never
asked anything else, from This Mac or from Set Up on another Mac
(`RemoteDeviceMCPSetup…`). The device twins are in the RemoteDevice group:
`RemoteDeviceMCPCallToolTests` (every boundary case of
`RemoteDeviceMCPTests` through `callTool`) and
`RemoteDeviceMCPLaunchTests` (the device line under the real shells, Pi's
with its extension, its version check, and what never goes on the line).
The older MCP suites (`CherryTests`' `mcp`, `controlServer` and
`cherryControl` tests, `ControlAgentTask*`, `ControlAgentWait`,
`ControlAgentMonitor`, `ControlActivity`, `ControlProjectWindows`,
`CherryStdioTransportTests`) run locally with `--filter`.

`Scripts/test-mcp-concurrency` checks that the control server stays responsive
while service detection runs. It builds Cherry with
`swift build -c release --product Cherry` and runs the binary apart from your
own Cherry: a private `HOME` and `CFFIXED_USER_HOME`, and private control and
session-host sockets (`CHERRY_CONTROL_SOCKET`, `CHERRY_HOST_SOCKET`) in a 0700
directory. Its tabs are persistent sessions on a daemon of its own, which it
tears down at the end (`Scripts/cherry_private_host.py`); it never touches your
daemon or saved workspaces. Its log is `/tmp/mcp-conc.log`.
