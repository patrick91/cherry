# Agents use the `cherry` CLI

Status: built (2026-10-19), and Cherry MCP removed (2026-10-20, phase 6).
Supersedes the 2026-10-15 decision to keep Cherry MCP as the agents'
primary interface.

## Why

- Cherry MCP's tool list is about 28 KB (≈7k tokens) in every agent session
  Cherry starts, used or not, and it is at its budget: each new tool costs
  wording elsewhere. A skill costs one description line until it is used.
- Any agent with a shell can run `cherry` (Amp, OpenCode, Gemini, …): no
  registration per CLI, no version gates, no Pi extension to register a
  server, no `list_changed`.
- Per-action permissions, typed arguments and shell-less clients, MCP's other
  advantages, matter little here: agent commands are kept apart from host
  plumbing (`cherry host …`), long arguments come on standard input, and
  shell-less clients are not Cherry's audience.
- What MCP still does better is sandboxes (Codex blocks Unix sockets). That is
  handled per agent below.

Every tool already runs in the app's one layer (`CherryToolLayer`, protocol 2
`callTool`), so the CLI is a second front end on the same calls, not a second
implementation.

## Shape

One binary, `cherry`. Agent commands at the top level; the session-host
plumbing moves under `cherry host …`.

```
cherry ls [--kind agent|terminal|command]          list_processes
cherry show [ID]                                   get_process_status
cherry read [ID] [--lines N] [--from LINE]         get_process_output
cherry search ID PATTERN                           search_process_output
cherry wait [ID] [--timeout MS]                    wait_for_process_idle
cherry send ID [TEXT | -]                          send_agent_message / send_process_input
cherry keys ID KEYS…                               send_process_input raw (named keys: up, enter, esc…)
cherry answer ID CHOICE                            answer_prompt
cherry spawn agent NAME [--task - | --message -] [--label L] [--phase P]
             [--schema FILE|-] [--run RUN] [--allow-subagents]
cherry spawn terminal|command …                    spawn_process
cherry start|stop|restart|close ID                 start/stop/restart/close_process
cherry rename ID NAME, cherry select ID
cherry task mine | report [-] | progress MSG [--awaiting-approval]
cherry task get ID | list | wait RUN [--cursor C] | cancel …
cherry subscribe …, cherry events SUB [--cursor C], cherry unsubscribe SUB
cherry ports [ID], cherry services, cherry wait-port …
cherry todo ls|show|add|edit|move|rm|select|comment|comments, cherry project ls|open|add|show
cherry devices                                     list_devices (--device D on project open|add, spawn agent)
cherry commands start|stop|restart, cherry agents, cherry link LINK, cherry subscriptions
cherry whoami
cherry skill setup|status|show|remove [--agent A] [--dry-run] [--project] [--json]
cherry tool NAME [JSON | -]                        any catalog tool, as MCP calls it
cherry host start|shutdown|restart|list|new|attach|kill|remove|control|status|doctor|ports|…
```

- Output: the tool's JSON (`--json`, the default when standard output is not a
  terminal) or a short human form. Exit 1 on a tool error, with the error's
  `code` and message on standard error.
- Standard input: `-` (or no TEXT with a pipe) reads the brief, message,
  report value or schema, so heredocs carry multi-line text and JSON without
  shell quoting.
- Naming: `cherry host …` next to the global `--host <ssh-alias>` option
  (`cherry --host mini host kill ID`) is the one awkward pair; accepted.
- Old host names stay as hidden aliases where unambiguous: `attach`,
  `control`, `new`, `kill`, `remove`, `shutdown`, `doctor`, `list` (host
  sessions; agents use `ls`), and `status` (host status; agents use `show`).
  `start` and `restart` go by shape: with a process ID they are the agent
  verbs, without one (or with `--if-*`) the host's. The app and device
  installs switch to `cherry host …` in the same release; a build only ever
  runs its own `cherry`, so no older caller meets the new names.

### Implementation

- The front end lives in Swift next to the catalog, in the app: a
  `runCommand` request (control protocol 3) carries the command's words,
  and the app parses the verbs into a tool name and arguments and runs it
  as a `callTool` of the same caller (interface "cli"), so caller identity
  (process ancestry; a device tab's token) and device scoping are the
  tools'. What only the caller's Mac has (standard input, a file a flag
  names) the answer asks for, and `cherry` sends the command again with it.
- The Rust `cherry` keeps the host commands and sends every other
  subcommand to the app's control socket itself (`agent.rs`: the socket
  path, the private-socket checks, the token envelope), so there is one
  `cherry` on PATH and no helper. (Phase 1 to 6 ran a Swift helper,
  `CherryMCP cli`; phase 7 removed it.)
- `cherry skill show` prints the guide, generated from `CherryToolCatalog`
  and the worker rules, so it always matches the running build.
- As built (phase 1, Swift half): the commands' table is `CherryCLI.commands`
  (`Sources/CherryControl/CherryCLI.swift`); the catalog has no notes tools, so
  there is no `cherry note`. `cherry send` to a tab that is not an agent
  types the text as a line once the app refused `send_agent_message`
  (`not_agent_process`, nothing sent). `cherry keys` takes named keys (`up`,
  `enter`, `esc`, `shift-tab`, `ctrl-c`, F1–F4…) or single characters.

### PATH

Agents type `cherry`, not `"$CHERRY_CLI"`: Codex's command rules and Claude
Code's `Bash(cherry …)` rules match the command's first word, and an absolute
path matches neither. Every tab gets a directory holding only `cherry` (a link
to the bundle's) at the front of PATH: This Mac's under the identity's
Application Support, a device's in its install's build directory (prepended
in `lineSettingLoginPath`). `CHERRY_CLI` stays.

As built: This Mac's tabs get `CHERRY_BIN_DIR` (`TabCLIDirectory`), first on
PATH in native and hosted launches, and Cherry's zsh bootstrap puts it first
again after the user's `.zshrc` (bash and fish keep it wherever their startup
files leave it; path_helper keeps it, after the system directories). A
device's commands and agents get the install's build directory first in
`CHERRY_LOGIN_PATH`; that directory also holds the install's `cherry-host`. A device's interactive terminals have no such line and keep
`CHERRY_CLI` only.

## Teaching agents: the skill

A skill named `cherry`, Rex-style: a short SKILL.md (when to use Cherry,
targeting rules: no ID means your own tab, "the focused tab" means the
selection, a name wins; workers and tasks in five lines) that ends with "run
`cherry skill show` for the full guide".

| Agent | Installed (Connect, confirmed) | One launch (agents Cherry starts) |
|---|---|---|
| Claude Code | `~/.claude/skills/cherry` (follows `CLAUDE_CONFIG_DIR`) | `--plugin-dir <agent-skill>/cherry-plugin` (its `skills/cherry`) |
| Codex | `~/.agents/skills/cherry` | none: `-c developer_instructions=…` (only when the user sets none) |
| Pi | `~/.agents/skills/cherry` | `--skill <agent-skill>/cherry-plugin/skills/cherry` |
| OpenCode | `~/.agents/skills/cherry` | `OPENCODE_CONFIG_CONTENT` `skills` (check it merges) |
| Amp | `~/.agents/skills/cherry` | none |

- `cherry skill setup|status|remove` writes, reports (`current`, `outdated`,
  `missing`, `foreign`, `unreadable`, `unsupported`) and removes only
  Cherry's own files, honours `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, `--dry-run`,
  `--project`, `--json`. A `cherry` skill Cherry did not write is `foreign`
  and left alone without `--force`. Done (phase 2): Cherry's skill has a
  `.cherry-skill` marker with its SKILL.md's hash (an edit by hand makes it
  `foreign`); the rules file starts with `CherrySkill.rulesFirstLine`, and
  allows every agent command's first word but `start`, `restart` and
  `skill` (docs/cli.md › The `cherry` Command).
- In the app, Connect Agents to Cherry… shows these rows and installs only
  after its confirmation, as today (Cherry writes no agent configuration
  otherwise).
- A tab of an agent Cherry starts also gets one line at launch (Claude Code
  and Pi `--append-system-prompt`, Codex `developer_instructions`;
  `AgentCLILaunch.instructionLine`): it runs in a Cherry tab (its
  `CHERRY_PROCESS_ID`), `cherry` on its PATH reaches the others, and to load
  the skill or run `cherry skill show` first. Never when the command sets its
  own instructions (`--system-prompt*`, `--append-system-prompt*`, Codex's
  `developer_instructions`/`model_instructions_file` on its line or in its
  `config.toml`). No session-start hooks: Codex makes the user approve them
  (`/hooks`), Claude Code needs folder trust, and the launch covers Cherry's
  tabs.
- `<agent-skill>` is `<identity's Application Support>/agent-skill`, which
  the app writes at launch (the instance-lock holder; `AgentSkillDirectory`)
  from `CherryAgentSkill`, the text `cherry skill show --skill-md` prints. It
  is not a bundle resource: SwiftPM's `.process` flattens directories, and a
  Claude Code plugin needs `.claude-plugin/plugin.json` beside `skills/`. So
  install-local-app, package-release and the signing scripts are unchanged.
- Pi started with the CLI gets no `-e` extension (it registered Cherry MCP,
  and is gone with it); the skill and the line take its `cherry_workers`
  prompt section's place.
- Devices (phase 6, `RemoteAgentLaunch`): the install carries no skill
  files, so a device agent gets the line (`hasSkill: false`, naming `cherry
  skill show`), Claude Code also `--settings` for the forwarded socket, and
  Codex's `developer_instructions` only while a grep of its `config.toml`
  there finds none; the gated line checks the install's `cherry`.

## Sandboxes and permissions

| Agent | Socket blocked? | What Cherry does |
|---|---|---|
| Codex | yes (`workspace-write`, `read-only`; `danger-full-access` or workspace-write with `network_access = true` reach it: checked with `codex sandbox` and `nc -U` on 0.162.1) | Connect writes `~/.codex/rules/cherry.rules`: `prefix_rule(["cherry", [agent verbs]], "allow")` (an allowed command runs outside the sandbox) and `prefix_rule(["cherry","host"], "forbidden")`. See below for when a Codex tab gets the CLI. |
| Claude Code | only with its sandbox on (off by default) | every CLI launch: `--settings '{"sandbox":{"network":{"allowUnixSockets":["<control socket>"]}}}'` (array settings merge across Claude Code's scopes and `--settings` is one, so the user's own list stays; it turns no sandbox on). Not when the command has its own `--settings` (it takes one). |
| Pi, OpenCode, Amp | no sandbox | nothing |

Approvals (Settings › an agent's page › Starting …, stored per CLI as
`agents.approvals.claudeCode` / `agents.approvals.codex`, `AgentApprovals`;
applied with the CLI or Cherry MCP, before Cherry MCP's `--mcp-config`, and
only while Connect agents Cherry starts is on):
*As configured* (default) or *Auto review*: Claude Code
`--permission-mode auto` (its classifier decides each action), Codex
`--approve-for-me` (approval requests go to Codex's automatic reviewer, the
workspace-write sandbox stays). Auto review covers everything the agent does
in that tab, not only `cherry`, so it is opt-in and the page says so. It is
never added when the command already sets a mode (`--permission-mode`,
`--dangerously-skip-permissions`, `--approve-for-me`, `-a`/`--ask-for-approval`,
`--dangerously-bypass-approvals-and-sandbox`, `--full-auto`, `-s`/`--sandbox`
for Codex, or a `-c` of `approval_policy`, `approvals_reviewer`,
`sandbox_mode`; Claude Code's `--allow-dangerously-skip-permissions` and
`--permission-prompt-tool` too: `AgentApprovals.setsOwnApprovals`, from
Claude Code 2.1.303's and Codex 0.162.1's `--help`).

Phase 3 gave a Codex tab the CLI only when one of these held, else
launch-time MCP; since phase 6 every Codex tab gets the CLI, and these
decide only whether a `cherry` there runs without asking (the agent's page
says which, `AgentSettingsPage.interface`):

1. Its sandbox reaches the socket (`CodexLaunchFacts.launchReachesSockets`):
   the command's own choice (`--dangerously-bypass-approvals-and-sandbox`,
   `-s`/`--sandbox danger-full-access`, `-c sandbox_mode="danger-full-access"`,
   `-s workspace-write -c sandbox_workspace_write.network_access=true`) over
   its `config.toml`'s (`${CODEX_HOME:-~/.codex}`: top-level `sandbox_mode =
   "danger-full-access"`, or `"workspace-write"` with
   `[sandbox_workspace_write] network_access = true`). A command with
   `-p`/`--profile`, or a config that selects a `profile`, reads as one that
   does not (profiles are not read).
2. Cherry's rules file exists and starts with `# Written by Cherry: cherry's
   agent commands run outside Codex's sandbox; cherry host is forbidden.`
   (allowed `cherry` commands run outside the sandbox on the first try).
3. Approvals is Auto review: a sandboxed `cherry` fails, the model asks to run
   it outside the sandbox and the reviewer decides, so two tries per call.
   Unverified until a real Codex run, which needs the owner's OK.

Codex's files are read off the main thread (`CodexLaunchFactsCache`, again
after each launch); a launch never waits for them: before the first reading
only the command's own words count (1), and the line is left out (the config
may set instructions).

## Workers and orchestrators

- The kickoff line, `get_my_task`'s rules, the nudge and the wake lines name
  `cherry task mine`, `cherry task report <<'EOF'`, `cherry task progress
  --awaiting-approval`, `cherry task wait RUN`, `cherry task get`, `cherry
  events SUB`, `cherry send` for a tab launched with the CLI
  (`TerminalSession.launchUsesCherryCLI`: `lastAgentMCPLaunchOutcome` is
  `.cli`), and the MCP tools (with CherryMCP's `--call` fallback) otherwise.
  A task's kickoff is worded once its worker started and kept
  (`AgentTask.kickoffUsesCLI`), so the kickoff Cherry looks for on the
  screen is the one it typed. A session restored or adopted after a relaunch
  has no launch outcome, so it gets the MCP texts, whose `--call` fallback
  works in any shell.
- Orchestrators: close workers they will not message again once their result
  is read (`cherry task cancel TASK --close`); never by default (the guide
  says so).

## MCP

Removed in phase 6 (the owner's call, 2026-10-20: "we can add it back
later if the CLI is not enough"): CherryMCP's stdio server and the MCP SDK,
launch-time `--mcp-config`/`-c mcp_servers`/Pi's `-e` extension, the
Connect rows that ran `claude|codex|pi mcp add`, Connect This Agent, and
Set Up Cherry MCP on <Mac>…. The tool layer, the catalog (its fixtures and
`listTools`) and the control protocol stay: the wire is append-only, and
the CLI is a front end on the same calls. A `cherry` registration someone
made by hand now fails to start; `claude mcp remove cherry` (and Codex's,
Pi's) clears it. Connect agents Cherry starts keeps its key
(`mcp.connectAgentsAtLaunch`).

## Sidebar (with this work)

- One mark per row. For a task's worker the task's state is the mark;
  permission and question still win; working is the spinner only; reported is
  one check, bright until seen, dim after; failed and no-report keep theirs.
- A settled run's workers collapse under their orchestrator ("10 done"),
  expandable as now; an orchestrator's context menu and the Omni bar get Close
  Finished Workers.

## Phases

1. CLI front end: `CherryMCP cli`, the Rust hand-off, `cherry host …` with the
   aliases, standard input arguments, `cherry skill show`, the tab PATH; the
   app and device installs call `cherry host …`. Tests: argument parsing per
   verb, the hand-off, a CLI call end to end against a private server.
2. Skill install: `cherry skill setup|status|remove`, Connect's rows, the
   Codex rules file.
3. Launch: per agent skill and instruction flags, the Claude Code sandbox
   setting, MCP off at launch where the CLI works; worker texts per launch.
4. Sidebar: one mark, collapsed settled workers, Close Finished Workers.
5. Follow-ups: OSC 7501 child records (an agent's own subagents) and
   `progress` in task progress. A launch that also finds the skill installed
   (`cherry skill setup`) gives Claude Code two copies (`cherry` and the
   plugin's `cherry:cherry`) and Pi two skills named `cherry`: skip the
   launch-time skill when the installed one is `current`, read off the main
   thread as Codex's config is. A real Codex run of Auto review (needs the
   owner's OK).

6. Remove Cherry MCP (above); devices get the CLI's flags; every worker
   text names `cherry` commands.
7. The Rust `cherry` speaks the control protocol itself (`runCommand`,
   control protocol 3: the app parses the command, prints the guide and
   help, and places the skill's files on the caller's Mac, any Mac, through
   its `cherry`: paths described and steps taken there), and
   CherryMCP is deleted, with Help › Keyboard Diagnostics and its key echo
   (Settings › Terminal's Copy Report stays). Device installs carry no
   CherryMCP; an older install's still works (`callTool`).

## Open questions

None: approvals are the setting above; a Codex whose sandbox cannot reach
the socket, without the rules file or Auto review, keeps launch-time MCP.
