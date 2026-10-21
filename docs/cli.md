# The `cherry` Command

Agents drive Cherry with the `cherry` command on their PATH: `cherry ls`,
`cherry send ID <<'EOF'`, `cherry task report`, … Each command is one of
Cherry's tools (`CherryToolCatalog`), which the running macOS app runs
over its local control socket. The surface is process-first: terminals,
agents, and configured project commands are all Cherry processes with a
`process_id`. Cherry MCP, the stdio server agents used before
(docs/specs/agent-cli.md), is gone; the tools, their names and arguments
are the ones it served.

## Setup

**Agents Cherry starts need nothing set up.** Every tab has `cherry` first
on its PATH, and an agent tab Cherry starts with Claude Code 2.1.0 or
later, Codex 0.162.0 or later, or Pi 0.99.2 or later is told about it on
its command line for that run, on This Mac and on your other Macs (Agents
On Another Mac):

- Claude Code: `--plugin-dir <agent-skill>/cherry-plugin` (the `cherry`
  skill, which the app writes into `<Application Support>/agent-skill` from
  `CherryAgentSkill`, `AgentSkillDirectory`), `--append-system-prompt` with
  one line naming its tab (`AgentCLILaunch.instructionLine`), and
  `--settings '{"sandbox":{"network":{"allowUnixSockets":["<control socket>"]}}}'`,
  so its sandbox, when you turned it on, reaches the socket (array settings
  merge across Claude Code's scopes; a command with its own `--settings`
  keeps it).
- Pi: `--skill <agent-skill>/cherry-plugin/skills/cherry` and the same line.
- Codex: `-c developer_instructions=<the line>`, which names `cherry skill
  show`, unless its `config.toml` (`${CODEX_HOME:-~/.codex}`) sets
  `developer_instructions` or `model_instructions_file` (read off the main
  thread, `CodexLaunchFactsCache`; before the first reading it gets
  nothing). Codex's `workspace-write` and `read-only` sandboxes refuse the
  socket's connect, so a sandboxed `cherry` fails and Codex asks you to run
  it outside the sandbox, unless Cherry's rules file is installed (allowed
  `cherry` commands then run outside it: `cherry skill setup`, or Connect
  Agents to Cherry…) or Approvals is Auto review (Codex's reviewer decides).
  `danger-full-access`, and `workspace-write` with
  `sandbox_workspace_write.network_access = true`, reach it. The agent's
  page says which applies (Starting Codex › Interface).
- Approvals (an agent's page › Starting …; `AgentApprovals`,
  `agents.approvals.claudeCode`, `agents.approvals.codex`): As configured,
  or Auto review (`--permission-mode auto`, `--approve-for-me`, first),
  never over a mode the command sets.

None of them writes the agent's configuration. Cherry adds the flags only
when all of these hold, and otherwise starts the agent exactly as its
command says:

- Settings › Agents › The cherry command › **Connect agents Cherry
  starts** is on (`mcp.connectAgentsAtLaunch`, on by default; one switch
  for every agent and Mac; for one run, a launch argument turns it off as a
  property list, `-mcp.connectAgentsAtLaunch '<false/>'`: `NO` is a string
  and is ignored, as for Cherry's other switches).
- The command is a plain command whose first word is `claude`, `codex` or
  `pi` (a path to one too): one simple command of literal words, with no
  pipe, list, redirection, expansion, glob, comment, `--` or leading
  `NAME=value`.
- It starts a session: not a subcommand such as `claude mcp`, `claude
  doctor`, `claude attach`, `codex login`, `codex mcp`, `pi install` or `pi
  config`. A prompt (`claude "fix it"`, `pi "fix it"`), `codex exec` and
  `codex resume` are sessions. The lists
  (`AgentLaunch.CLI.subcommandsWithoutSession`) were checked against
  `--help` of Claude Code 2.1.299 and Codex 0.162.1 and Pi 1.3.0's argument
  parser; recheck them when a CLI adds subcommands.
- It does not end in an option that takes a value (`claude --model`, `pi
  -e`; `AgentLaunch.CLI.optionsTakingValue`): the option would take the
  first word Cherry adds, and Claude Code and Pi would start a turn with the
  next one as its prompt.
- For Claude Code and Pi, the skill's files are there.
- The CLI's version is known and at least the minimum. On This Mac Cherry
  runs `<cli> --version` once per run for each executable (found on the
  login shell's PATH, off the main thread, at most 5 s, with no terminal;
  again when the file changes) and asks the enabled agents' CLIs as the
  first window opens. It reads the version from the standard output. A
  launch never waits for it: an agent started before its version is known
  (usually a tab restored as Cherry starts) runs without the flags until it
  is restarted. On another Mac the agent's line checks the version itself.
- The paths have no `'`, `\` or control character, so the words read the
  same under sh, zsh, bash and fish.

The flags are decided for each launch and never saved with the tab (its
command stays as you wrote it; a restart decides again). A shell alias or
function named `claude`, `codex` or `pi` gets them too, although its
version was read from the executable on PATH: turn the switch off if that
breaks it. The session log (`SessionLog`, "[agent]") says what was added,
or why nothing was. The kickoff, the rules `cherry task mine` returns, the
nudge and the wake lines Cherry types into a tab name `cherry` commands.

**Agents you start yourself** in a Cherry tab have `cherry` on their PATH
too; to teach them it, install the skill: `cherry skill setup`, or
**Connect Agents to Cherry…** (the Omni bar, or Settings › Agents › The
cherry command), which shows the skill's items with Install or Update and
writes only after its confirmation (every file's path and contents). Each
agent's page shows its CLI's items too.

## The `cherry` Command

The Rust `cherry` sends each command line that is not a session-host
command to the app as one `runCommand` request (Versions), and prints what
the app answers. The app parses it (`CherryCLI`) into one catalog tool and
runs it as a `callTool` of the same caller (interface `cli`): the app
identifies, scopes and refuses the caller (Scope And Identity).

- A command's words and positional arguments are in `CherryCLI.commands`
  (`Sources/CherryControl/CherryCLI.swift`); every other `--flag` is the tool's
  parameter in kebab case, typed by its schema (`--no-x` sets a boolean
  false, a list is `a,b`, an object is JSON, a file or `-`).
  `cherry tool NAME [JSON | -]` calls any tool with its JSON arguments.
- Long text (a brief, a message, a report, a schema) comes on standard
  input: `-`, or nothing when standard input is a pipe or a file (never a
  terminal or `/dev/null`). The app asks `cherry` for it, and for a file a
  flag names (`--schema schema.json`, read relative to `cherry`'s
  directory), only once the command needs it; `cherry` sends the command
  again with them (`needsStandardInput`, `needsFiles`; `cherry skill` also
  `needsPaths` and `operations`, below).
- `cherry send` to a tab that is not an agent types the text as a line
  (`send_process_input` with submit), after the app refused
  `send_agent_message` without sending anything.
- Output is the tool's JSON when standard output is not a terminal (or with
  `--json`), else a short form for `ls`, `show`, `read` and `task mine|list`.
  A tool's error exits 1 with `code: message` (and its details as JSON) on
  standard error; a usage error exits 2.
- `cherry skill show` prints the guide (`CherryCLIGuide.guide`, from the
  commands' table), `--skill-md` the `cherry` skill's SKILL.md.
- `cherry skill setup|status|remove [--agent A]… [--dry-run] [--project]
  [--force] [--json]` (`CherrySkillInstaller`, Sources/CherryControl; run by
  the app with the caller's HOME, PATH and agent folders, its file work done
  by the calling `cherry` on its own Mac, This Mac or another: the app asks
  what is at the skill's paths, `needsPaths`, and answers the steps to take,
  `operations`, which `cherry` takes and reports; `skill_unavailable`
  without an absolute HOME) writes, reports and removes the skill: `$CLAUDE_CONFIG_DIR` (else `~/.claude`)
  `/skills/cherry` for Claude Code, `~/.agents/skills/cherry` for Codex, Pi,
  OpenCode and Amp, and Codex's `${CODEX_HOME:-~/.codex}/rules/cherry.rules`;
  with `--project` the repository's `.claude`, `.agents` and `.codex`.
  A skill is Cherry's when a `.cherry-skill` file beside its SKILL.md
  (`{"by":"Cherry","sha256":…}`) has its SKILL.md's hash, the rules file
  when its first line is `CherrySkill.rulesFirstLine`. Status per item:
  `current`, `outdated` (another build's), `missing`, `foreign` (not
  Cherry's, or edited since; setup leaves it without `--force`, remove
  always), `unreadable` (a link, a file where a folder goes, a relative
  override; never written through) or `unsupported` (none of its agents
  found: their settings folder or the program on PATH; `--agent` names one
  anyway). Remove keeps `~/.agents/skills/cherry` while an agent found that
  `--agent` did not name reads it, and a skill folder that holds other
  files.
- The rules file allows `cherry` with every agent command's first word but
  `start`/`restart` (the host's without an ID) and `skill` (its setup writes
  agent settings), so those run outside Codex's sandbox and reach the
  socket, and forbids `cherry host` and the host commands' old names.
- Connect Agents to Cherry… lists the skill's items (with Install or
  Update) and each agent's page its own (`CherrySkillsModel.shared`, read
  when they show, never at launch); Install opens `CherrySkillConfirmation`
  with every file's path and contents, and only its Install writes. A
  `CherrySkillsModel` made without an installer (tests) reads nothing.
- Every This Mac tab has `cherry` first on its PATH: `CHERRY_BIN_DIR`, a
  directory holding only a link to the app's `cherry` (`TabCLIDirectory`,
  `<Application Support>/bin`, made by the instance-lock holder), which
  Cherry's zsh bootstrap puts first again after the user's `.zshrc`. A
  device's commands and agents get their install's directory first on the
  login PATH their line sets, and its terminals get it first once their
  startup files ran (`CHERRY_BIN_DIR` there, `RemoteShellBootstrap`: zsh,
  a bash Ghostty integrates and fish, with Ghostty's integration there; a
  file in front of Ghostty's, which the launch writes into
  `~/Library/Application Support/cherry-host/shell/<digest>/`). Apple's
  /bin/bash and other shells keep that Mac's PATH, and `CHERRY_CLI`.

## Versions

The app answers four requests besides the typed requests older helpers
send: `appInfo` (which app answers, its control protocol and build),
`listTools` (the tools for one client) and `callTool` (one tool run in the
app as its caller), of control protocol 2, and `runCommand` (one `cherry`
command line run in the app as its caller), of control protocol 3.

- `runCommand` carries the command's words, what the caller says of itself
  (`CHERRY_PROCESS_ID`, `CHERRY_PROJECT_ROOT`, its directory), whether its
  standard output is a terminal and its standard input a pipe or a file,
  `HOME`, `PATH` and the agents' folder variables (for `cherry skill`), and
  `cherry`'s build; from another Mac it comes in the tab's token envelope.
  The answer is what to print and the exit status, or what to send the
  command again with (standard input, files), at most four times.
- `cherry` waits up to 340 s for the answer (the longest wait a command can
  ask for, 300 s, and its margins). With no answer the command fails
  (`cherry_unavailable`, or `cherry_unreachable` from another Mac); an app
  that cannot decode `runCommand` (`invalid_request`) is
  `cherry_outdated: … update Cherry.`
- An older install's `cherry` runs its CherryMCP, which sends `appInfo` and
  `callTool` (or typed requests): the app still answers them.
- `get_status` adds `cli_build` (the `cherry` that asked), `app_build` and
  `app_control_protocol`. Its `socket_path` and `socket_exists` are left
  out for a caller on another Mac (it has no socket of This Mac's).
- Every tool has annotations, `openWorldHint: false`: 24 read-only, 11
  destructive, and the other 18 add or start something.

## Scope And Identity

- The app runs every tool (`callTool`) and identifies its caller itself:
  on This Mac by its process, the tab whose program is the `cherry`
  process or one of its parents, as the process tree was when it
  connected; on another Mac by its tab's token (below). What `cherry`
  says of itself (`CHERRY_PROCESS_ID`, its project and directory) only
  supplies defaults when Cherry verified no caller; tasks,
  wake lines, `sub_agents` and run ownership use only the verified caller.
- `whoami` reports the caller process, active/effective project root,
  selected process, and bound process.
- `CHERRY_PROCESS_ID` identifies the Cherry tab the command runs in.
  `CHERRY_AGENT_ID` is still exported for agent processes as a compatibility
  alias.
- Every tab's environment names its app: `CHERRY_CONTROL_SOCKET` is the
  socket that app's server listens on (on This Mac; a tab on another Mac
  names the forward there), and `CHERRY_CLI` is the `cherry` command-line
  tool of the Cherry build that started the tab (a device tab's names the
  install's on that Mac, when it has Ghostty's resources there). `cherry` uses the tab's socket, so one of another build reaches
  the tab's own app. A tab of a
  Cherry whose server could not listen has `CHERRY_CONTROL_SOCKET` empty or
  unset, and never names the socket of a Cherry that Cherry was started
  from; whatever reads it treats an empty value as unset.
- No tab has `CHERRY_MCP_HELPER` or `CHERRY_MCP_SERVER_NAME` any more
  (they named CherryMCP, which `cherry` ran); one Cherry inherited is
  dropped.
- A command whose environment lost Cherry's variables is still identified
  by its process.
- The socket is private: the app's socket directory is this account's
  (0700, `/tmp/cherry-$UID/<instance>/`, the shared `/tmp/cherry-$UID` not
  writable by others), the socket 0600. `cherry` connects only to a socket
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
  socket and logs why (`socket_in_use`); the `cherry` of its tabs reaches
  the first copy, which finds none of its own tabs to be the caller and
  answers unscoped requests in its active window. To tell a live socket
  from a stale one, Cherry connects, sends an empty line (an invalid
  request to every Cherry) and waits for the answer or the close, at most
  200 ms: a probe that left at once would leave the server a connection it
  cannot guard against SIGPIPE, which a Cherry from before `MSG_NOSIGNAL`
  would get answering it. The server writes its answers with
  `MSG_NOSIGNAL`, so no caller that goes away mid-answer can stop the app.
- `bind_session_process` binds a caller that keeps a session to a process
  (a single `cherry` command keeps none).
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

Agent creation stays nested under the calling agent when `cherry` runs
inside a Cherry agent. If there is no bound caller, new agents are
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
  `AllowTcpForwarding` yes, the defaults); the log says when it refused.
- Each tab gets its own capability token, `CHERRY_MCP_TOKEN` (256 bits),
  next to `CHERRY_PROCESS_ID`. `cherry` sends both with every request;
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
- `CHERRY_CLI` is the `cherry` of the Cherry build that started the tab,
  installed on that Mac with `cherry-host`, and first on the PATH of the
  commands and agents Cherry starts there.
- When Cherry cannot be reached from there (it quit, the Mac slept, the SSH
  connection is being made again), commands fail with `cherry_unreachable`:
  "Cherry on <this Mac> is not reachable". The forward is made again when
  Cherry reconnects to that Mac.
- The `cherry` there is the install's build, older than this Cherry until
  **Update Session Host…**: an install from before control protocol 3 runs
  its CherryMCP, which sends `callTool` (or, before control protocol 2,
  typed requests), answered as before. A newer one sends `runCommand`,
  run in the app as that tab, each of its tool's requests checked as a
  typed request is (the token again before each one, the bounds above);
  `cherry skill setup|status|remove` places the skill on that Mac, through
  its `cherry` (The `cherry` Command), and `get_status` names no path of
  This Mac.

**Agents Cherry starts there** are told about `cherry` on their command
line, as on This Mac (Setup), without a skill (that Mac has no skill
files, so the line says to run `cherry skill show`): Claude Code gets
`--append-system-prompt` and `--settings` for the forwarded socket, Pi
`--append-system-prompt`, Codex `-c developer_instructions=…` while its
`config.toml` there sets no instructions. Cherry keeps no version of that
Mac's CLIs, so the agent's line checks its CLI each time it starts
(`RemoteAgentLaunch`):

```sh
if [ -x '<build>/cherry' ] && cherry_v=$('claude' --version 2>/dev/null </dev/null) && printf '%s\n' "$cherry_v" | /usr/bin/awk '…at least 2.1.0…'; then exec claude … '--append-system-prompt' '…' '--settings' '{…}'; else exec claude …; fi
if [ -x '<build>/cherry' ] && ! /usr/bin/grep -qsE '^[[:space:]]*(developer_instructions|model_instructions_file)[[:space:]]*=' "${CODEX_HOME:-$HOME/.codex}/config.toml" && cherry_v=$('codex' --version …) && …; then exec codex … '-c' 'developer_instructions="…"'; else exec codex …; fi
```

- Only for a plain `claude`, `codex` or `pi` command (Setup's rules), only
  in a tab that has the forwarded socket and an install with `cherry`,
  only under an sh-family login shell there (zsh, bash, sh, ksh,
  mksh, dash, yash, oksh, loksh; fish, csh, tcsh and others run the line as
  before), and only while Connect agents Cherry starts is on.
- Both branches `exec`, so the session's program is the agent itself, as
  with the plain line: its ports, signals and foreground job. A `claude` or
  `codex` shell function that the login startup files there define is
  therefore not used: `exec` runs the executable on PATH. An older CLI, or
  one whose version cannot be read from its standard output, runs the line
  as before, and a missing CLI still exits 127 with Cherry's "not on
  <Mac>'s login PATH" message. An executable written `~user/…` fails the
  check and runs the line as before.
- Each launch runs `<cli> --version` there once (for a Node CLI about
  0.3–1 s before the agent starts); a `--version` that hangs delays the
  agent, as Cherry sets no time limit there.
- The token never goes on the line, and the log names the flags only, as
  on This Mac.

`cherry skill setup` there installs the skill for agents started there by
hand, as on This Mac.

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
- `spawn_agent`, `send_agent_message` for agent-native launch and messaging,
  `answer_prompt` for an agent's permission or question menu (below)
- `get_process_output`, `get_process_raw_output`, `search_process_output`
- `wait_for_process_idle`
- `subscribe`, `wait_for_events`, `unsubscribe`, `list_subscriptions`
  (monitors, below)
- `get_my_task`, `report_result`, `report_progress` (a worker's side) and
  `wait_for_tasks`, `get_task`, `list_tasks`, `cancel_tasks` (an
  orchestrator's), with `spawn_agent`'s `task` (tasks and results, below)
- `get_process_ports`, `services_list`, `wait_for_bound_port`

The older terminal-tab tools have been removed. Use `process_id` with the
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
opens again. The tools treat them like native tabs:

- `stop_process` ends the program (its session on the local host ends with
  it); the process then reports `exit 0` with `exit_code` 0, whatever signal
  ended it, and `start_process` starts it again in a new session.
- `restart_process` ends the session and starts a new one in the same process
  (same `process_id`).
- `close_process` ends the session, as the tab's close button does, without
  asking (the app asks before its own close stops a program at work).
- The process reports the program's `pid` (the host's child, never
  signalled by Cherry), port tools attribute its listeners to it, and its
  program gets `CHERRY_PROCESS_ID`, so a `cherry` started inside it
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
tabs run natively; the tools treat them the same way.

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
  Enter typed into it or sent by a tool, a monitor's wake line included) and the
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

`timeout_ms` defaults to 50000 (max 300000): an agent's shell tool may give
a command a minute or two, so keep waits at 50 s or less and call again on
`timed_out`, or subscribe (below) and end your turn.

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
plain Enter key path, except in text for an agent: text of several lines
(trailing newlines aside), for `send_agent_message`, `send_process_input`
and the first input of `spawn_process` and `spawn_agent`, is one message,
pasted as one bracketed paste with its newlines (LF between the lines when
the agent's host reports bracketed paste off), then one Enter on its own
after the paste (a trailing newline counts as `submit`), so the agent does
not take each line as a message of its own. Use `raw_base64` for bytes without that normalization;
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
  above; a turn it began and finished between two looks counts too; one
  `done` per turn: its last frame noticed after its report is the same
  turn, not another),
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
  subscriber cancelled it itself (`cancel_tasks`). Once its task settled
  and that settle was told, only the turns submitted to it are news: a
  turn it begins by itself (it reports more turns than were submitted,
  none submitted since its last `done`: a finished tab's background work)
  is no `done`, and a message submitted to it makes its next turn's end
  one again. A `closed` ends the
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
- **Wake lines.** When `subscribe` runs in a Cherry agent tab and Cherry
  confirms that tab is the caller (its program is an ancestor of the
  `cherry` process, or, on another Mac, the tab its token names), that tab
  is the subscriber. Once events it has not read are ready and the subscriber is
  idle, Cherry types one line into its tab and submits it:

  ```text
  [cherry] Monitor mon-…: 2 events ready (1 done, 1 needs_input). Run cherry events mon-… to read them.
  ```

  Idle means its agent reports it is idle (`agent_activity_state` idle, not
  `permission` or `needs_input`; for an agent that reports nothing, its
  output went quiet), its screen has been still for 2 s, nobody typed into
  it for 10 s, and it is not in a `wait_for_events` call. Cherry never types
  the line while the subscriber works or is blocked on the user, and
  types it at most once per batch of events and once every 5 s. The line
  names only the subscription and event counts, never text a watched
  process controls (names, titles or output), so it cannot carry
  instructions from a worker. Settings › Agents › Monitors › Wake
  idle agents turns wake
  lines off; `wake: false` turns them off for one subscription. The result's
  `wake` and `wake_unavailable_reason` say whether this subscription gets
  them. A subscriber Cherry cannot confirm (a declared
  `subscriber_process_id` that is not the caller, or a `cherry` that does
  not run under its tab) only polls.
- The wake line is typed input, which every agent CLI takes.
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
them. Any agent CLI with a shell can orchestrate or work: Claude Code,
Codex, Pi and others.

**Orchestrator side**

- `spawn_agent` with `task` (the worker's brief, instead of `message`; at
  most 64,000 characters and 256 KiB), and optionally `label` (shown in the
  sidebar; defaults to `title`, else the brief's first words; cut at 80
  characters and 320 bytes), `phase` (60 characters, 240 bytes), `run_id`
  and `result_schema`, and `allow_subagents` (default false: the worker's
  rules tell it not to hand parts of the brief to other agents; true says
  it may use its own CLI's subagents in its tab, never `spawn_agent` with
  a task, which stays `nested_task`). The
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
  You are Cherry task task-…: run cherry task mine for your brief, do it, then report with cherry task report (a JSON object {"value":…,"status":"ok","summary":"…"} on standard input, in a heredoc).
  ```

  The brief itself is never typed. Into a CLI Cherry knows, the first
  kickoff waits for its composer on a screen still for a second. Typed is
  not sent: an agent CLI can show its composer before it takes input
  (Claude Code while it loads) and drop the text or its
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
  open runs), `until` (`any`, the default: a task settled, needs input or
  awaits approval; `all`: every task settled), `cursor` and `timeout_ms`
  (default 50000, at most 50000 or the client's limit, see Client
  Timeouts; 0 returns at once). It returns `events` after `cursor`
  (`queued`, `started`, `progress`, `needs_input`, `awaiting_approval`, `resumed`,
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
  [cherry] Run run-…: 3 tasks settled (2 reported, 1 failed). Run cherry task wait run-… to read them, and cherry task get for each result.
  ```

  A run with a task awaiting approval (below) that the orchestrator has
  not read with `wait_for_tasks` gets one line of its own, by the same
  rules, once per new request:

  ```text
  [cherry] Run run-…: 1 task awaits your approval. Run cherry task wait run-… to read the questions, and answer each worker with cherry send.
  ```

  Both carry the run id and counts only, never a worker's text. Settings ›
  Agents › Monitors › Wake idle agents turns it off with monitors'
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
an ancestor of the `cherry` process, or, on another Mac, the tab its token
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
  `retry_after_milliseconds` otherwise); the answer has the task's `state`.
- **Approval checkpoints.** A worker that needs its orchestrator's
  approval or an answer before it goes on (a plan to approve, a question)
  calls `report_progress` with `awaiting_approval: true` and its question
  as `message` (never dropped by the 5 s limit), then ends its turn. Its
  open task is `awaiting_approval` (the sidebar's "awaits approval"; an
  `awaiting_approval` event with the question; `counts.awaiting_approval`):
  not settled, never nudged and never `no_report`, and the run does not
  settle. `wait_for_tasks` (`until: any`) returns for it, and the
  orchestrator's wake line says so. The task is back at `working` (a
  `resumed` event) once a message is submitted to the worker (the
  orchestrator's `send_agent_message` or `send_process_input`, or the user
  typing in its tab; Cherry's own lines are no answer), with a
  `report_progress` without the flag, or settles with `report_result`.
  Its next turn that ends without a report is asked once again. On a task
  that already settled, the flag is ignored (a plain progress message).
  `get_my_task`'s rules say all this, in place of the earlier "report
  failed rather than waiting for an answer".

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
- It asked its orchestrator for approval (above): the task waits, with no
  nudge, until it is answered.
- It finished its turn (idle at its composer after working, as a monitor's
  `done`) without reporting: Cherry types "Please run cherry task report with
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

**The sidebar.** A worker's row shows its label and one mark: its
task's state (queued, needs you, awaits approval, reported, no report,
failed, cancelled; working is the spinner alone), unless its agent asks
for permission or a question, which wins. A report is bright until its
tab is seen, dim after; hovering shows the result's summary. While one of
its runs is open, the orchestrator's row shows how many of its tasks
settled ("3/5"). When the last of its workers' tasks settles, the sidebar
folds the workers under it and the row reads what they came to ("10
done", "8 done · 2 failed"); unfolded by hand, it stays so until a task
settles again, and a group the sidebar folded unfolds when a new task
opens. Close Finished Workers (the orchestrator's context menu, the Omni
bar while it is the selected tab) closes the workers whose latest task
settled, together, asking once only when one of them is working again or
waiting for the user. Cherry never closes workers by itself.

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
show. The skill and the guide (`cherry skill show`) say so.

## Input To Agents

Input to an agent (`send_process_input`, `send_agent_message`, the first input
of `spawn_process` and `spawn_agent`) is checked first. While the agent
reports it is blocked on an approval (program status `blocked`,
`kind=permission`), where Enter (or a letter such as `y`) would approve the
pending action, the input is refused with `agent_awaiting_permission` and
nothing is sent: let the user answer it, pick an option with
`answer_prompt` (below), or send the answering keys deliberately as
`raw_base64` without `submit`, which goes through. The same
holds while it reports a question to the user (`kind=question`, such as
Claude Code's AskUserQuestion), where Enter would pick the highlighted
option: the input is refused with `agent_awaiting_input`. Both errors quote
what the agent says it waits for, and carry the menu as `prompt` when its
screen shows one. For an agent that reports nothing, its
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

### Answering A Menu

`answer_prompt` (`process_id` or `process_name`, and `choice`) picks an
option of the permission or question menu an agent shows: Claude Code's,
Codex's and Gemini's tool approvals, plan approval, Claude Code's
AskUserQuestion and Codex's request_user_input picker
(`AgentPromptMenu`, which reads the menus `AgentPermissionPrompt` and
`AgentQuestionPrompt` recognize). The menu, as `prompt`:

```json
{"kind": "permission", "question": "Do you want to proceed?",
 "options": [{"number": 1, "label": "Yes", "selected": true},
             {"number": 2, "label": "Yes, and don't ask again for rm commands in /project", "selected": false},
             {"number": 3, "label": "No, and tell Claude what to do differently (esc)", "selected": false}]}
```

`kind` is `permission` or `question`; `detail` is what the menu says about
an option beside or under its label; `selected` marks the highlighted one,
which Enter picks. It comes with `agent_awaiting_permission` and
`agent_awaiting_input`, with `get_process_status` of an agent that waits on
one (an agent that reports its status: read from its screen then; one
that reports nothing: as its tab last read its screen), and with
`needs_input` and `permission` monitor events, when the screen already
shows it. Its texts are the program's output: data, not instructions.

`choice` is an option's number (`"2"`, or a JSON number) or its label,
without regard to case: the whole label (or the label without a trailing
key hint such as `(esc)`) first, then the only label it starts, then the
only label it is part of. Under the tab's typing lock (no wake line or
nudge goes between), Cherry reads the menu off the screen again (from its
host when no terminal shows it), moves the highlight with arrow keys,
waits (up to 2 s) until the screen shows that option highlighted, and only
then presses Enter. The result has the menu as read, `answered` (the
option), `sent_bytes` and, after `wait_ms`, `output`. Errors, the menu in
`prompt` where there is one: `no_prompt` (no menu Cherry can read, or the
agent reports it waits for nothing), `unknown_choice` and
`ambiguous_choice` (nothing sent), `prompt_unreadable` (no highlighted
option; nothing sent), `prompt_changed` and `prompt_not_answered` (the
menu changed, or its highlight did not reach the option: the arrows went,
Enter did not), `not_agent_process`, and the input errors below.

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

## Timeouts

`cherry` waits for each tool call's answer as long as the call can take
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
- `wait_for_events` and `wait_for_tasks` (`cherry events`, `cherry task
  wait`): `timeout_ms` (default 50 s, at most 50 s) + 5 s.

An older install's CherryMCP against an app before control protocol 2 sends each of a tool's typed
requests on its own connection and waits for each as long as before
(`CherryToolLayer.clientTimeout`). Waits default to 50 s
(`send_agent_message` 40 s), so a call fits an agent's shell timeout;
call again on `timed_out`. `wait_for_process_idle` and
`send_agent_message` keep their 300 s maximum and `wait_for_bound_port`
its 60 s. (The catalog still knows the limits of the MCP clients it once
served, `CherryToolCatalog.waitCap`; a `cherry` call names none.)

## Control Socket

Each connection carries one JSON line each way: a request, then its
answer, `{"result":…}` or `{"error":{"code":…,"message":…}}` (a caller on
another Mac wraps its request in `{"cherryAuth":{"token":…,"processID":…},"request":…}`).
Besides the typed requests (`{"listTerminals":{}}` and the like, which
older helpers send and which stay as they are; the wire is append-only),
control protocols 2 and 3 have four:

| Request | Answer |
|---|---|
| `{"appInfo":{}}` | `{"result":{"appInfo":{"_0":{"build":"…","bundleIdentifier":"dev.patrick.cherry","controlProtocol":3,"urlScheme":"cherry","version":"…"}}}}` |
| `{"listTools":{"_0":{"profile":{"client":{"name":"claude-code","version":"2.1.299"}}}}}` | `{"result":{"listTools":{"_0":{"digest":"<16 hex>","instructions":"…","tools":[…]}}}}` |
| `{"callTool":{"_0":{"name":"list_processes","arguments":{"kind":"agent"},"context":{…}}}}` | `{"result":{"callTool":{"_0":{"isError":false,"structured":{…},"text":"{…}","toolsDigest":"<16 hex>"}}}}` |
| `{"runCommand":{"_0":{"arguments":["send","dev","-"],"context":{…},"standardInputIsPiped":true,"standardOutputIsTerminal":false,"cliBuild":"…"}}}` | `{"result":{"runCommand":{"_0":{"exitCode":0,"needsStandardInput":true,"standardError":"","standardOutput":""}}}}`, then, sent again with `"standardInput":"…"`, `{"result":{"runCommand":{"_0":{"exitCode":0,"standardError":"","standardOutput":"{…}\n"}}}}` |

- `tools` are tool definitions (`name`, `description`, `inputSchema`,
  `annotations`, as MCP defined them), and `digest` the first 16 hex digits of the SHA-256 of
  their sorted-keys JSON. A profile's `toolTimeoutMilliseconds` is the
  client's limit when known.
- A call's `context` says what the caller says of itself:
  `callerProcessID` (a claim), `boundProcessID`, `bindsSession`,
  `projectRoot`, `workingDirectory`, `profile` and `interface` (`cli`;
  older helpers sent `mcp` and `call`). The app takes its defaults from the caller it verified first.
- `text` is the tool's result as agents read it (snake_case keys, sorted),
  `structured` the same payload with camelCase keys, and `bindProcessID`
  the process a session binds to now (`bind_session_process`, `spawn_agent` with
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

Cherry also exposes project todos (`cherry todo …`). These tools are
project-scoped and do not change visible UI selection unless the tool name starts
with `select_`.

## Testing The Control Server

The tools, the control socket's tool requests and the `cherry` command
have a group of their own in `Scripts/test-session-suites unit` (and CI),
**ControlTool** (`--filter ControlTool`):

- `ControlToolCatalogTests`: the 53 tools in their order, the list encoded
  byte for byte as `Fixtures/mcp-tools-list.json` (for a client Cherry
  knows nothing of) and the schemas as `Fixtures/mcp-tool-schemas.json`,
  the list's byte budget (28 000), the facts agents act on, the
  annotations, the per-client caps and the descriptions that state them.
  A deliberate change of a description or an annotation regenerates the
  list fixture; the schema fixture changes only by an added optional
  property or a new tool's entry, never a removed, renamed or newly
  required one.
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
- `ControlToolCLITests`: the commands' parsing, standard input, output and
  exits, `runCommand` (standard input and files asked for, `get_status`'s
  builds, the caller's skill folders), and commands end to end through the
  built Rust `cherry` against a private server (the Rust side's own tests,
  against a fake app socket, are `Host/crates/cherry-cli/tests/agent_commands.rs`).
- `ControlToolLaunchTests`: the launch flags on This Mac (detection,
  quoting under sh, zsh, bash and fish, the version probe with stand-in
  CLIs, the switch, launches native, persistent and restored, Pi's).
- `ControlToolLaunchCLITests`: each CLI's words, Codex's instructions and
  sandbox facts, Approvals, the skill's files, the worker texts, a tab's
  outcome, the agent page's Interface line.
- `ControlToolSkillInstallTests`: `cherry skill setup|status|remove` and
  Connect's rows, in a temporary home.

Tests never use the default socket (every client gets its harness's).
The ControlTool and device tests inject their socket
(`ToolCalls.call(…socketURL:)`, `SocketToolTransport(socketURL:)`) and
never `setenv` it; the older `mcp` tests in CherryTests.swift still set
the process environment around `ToolCalls.call` (Tests/CherryTests/ToolCallClient.swift), which reads it, so
run them without a Cherry tab's variables (a tab on another Mac has a
`CHERRY_MCP_TOKEN` the test server refuses). Tests never get launch flags
or probe a CLI unless they build their own `AgentCLIVersions` (a test
workspace's policy has no `agentLaunch`, a test's `RemoteDeviceStore`
connects no agents), find CLIs only on the PATH they give, and never run a
real `claude`, `codex` or `pi`. The device twins are in the RemoteDevice
group: `RemoteDeviceMCPCallToolTests` (every boundary case of
`RemoteDeviceMCPTests` through `callTool`) and `RemoteDeviceMCPLaunchTests`
(the device line under the real shells, its version check, and what never
goes on the line). The older suites (`CherryTests`' `mcp`,
`controlServer` and `cherryControl` tests, `ControlAgentTask*`,
`ControlAgentWait`, `ControlAgentMonitor`, `ControlActivity`,
`ControlProjectWindows`) run locally with `--filter`.

`Scripts/test-mcp-concurrency` checks that the control server stays responsive
while service detection runs. It builds Cherry with
`swift build -c release --product Cherry` and runs the binary apart from your
own Cherry: a private `HOME` and `CFFIXED_USER_HOME`, and private control and
session-host sockets (`CHERRY_CONTROL_SOCKET`, `CHERRY_HOST_SOCKET`) in a 0700
directory. Its tabs are persistent sessions on a daemon of its own, which it
tears down at the end (`Scripts/cherry_private_host.py`); it never touches your
daemon or saved workspaces. Its log is `/tmp/mcp-conc.log`.
