# Agents use the `cherry` CLI

Status: plan (2026-10-19). Supersedes the 2026-10-15 decision to keep Cherry
MCP as the agents' primary interface; MCP stays as a fallback.

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
cherry todo …, cherry note …, cherry project ls|open|show
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

- The front end lives in Swift next to the catalog: `CherryMCP cli ARGS…`
  parses the verbs into a tool name and arguments and calls
  `CherryMCPSession.call(…, interface: "cli")`, so caller identity (process
  ancestry; a device tab's token), the private-socket checks, the legacy
  fallback and device scoping are the ones MCP uses today.
- The Rust `cherry` keeps the host commands and hands every other subcommand
  to the helper (`execv`: `CHERRY_MCP_HELPER`, else `CherryMCP` beside its own
  executable), so there is one `cherry` on PATH.
- `cherry skill show` prints the guide, generated from `CherryToolCatalog`
  and the worker rules, so it always matches the running build.

### PATH

Agents type `cherry`, not `"$CHERRY_CLI"`: Codex's command rules and Claude
Code's `Bash(cherry …)` rules match the command's first word, and an absolute
path matches neither. Every tab gets a directory holding only `cherry` (a link
to the bundle's) at the front of PATH: This Mac's under the identity's
Application Support, a device's in its install's build directory (prepended
in `lineSettingLoginPath`). `CHERRY_CLI` stays.

## Teaching agents: the skill

A skill named `cherry`, Rex-style: a short SKILL.md (when to use Cherry,
targeting rules: no ID means your own tab, "the focused tab" means the
selection, a name wins; workers and tasks in five lines) that ends with "run
`cherry skill show` for the full guide".

| Agent | Installed (Connect, confirmed) | One launch (agents Cherry starts) |
|---|---|---|
| Claude Code | `~/.claude/skills/cherry` (follows `CLAUDE_CONFIG_DIR`) | `--plugin-dir <bundle>/cherry-plugin` (its `skills/cherry`) |
| Codex | `~/.agents/skills/cherry` | none: `-c developer_instructions=…` (only when the user sets none) |
| Pi | `~/.agents/skills/cherry` | `--skill <bundle>/skills/cherry` |
| OpenCode | `~/.agents/skills/cherry` | `OPENCODE_CONFIG_CONTENT` `skills` (check it merges) |
| Amp | `~/.agents/skills/cherry` | none |

- `cherry skill setup|status|remove` writes, reports (`current`, `outdated`,
  `missing`, `foreign`, `unreadable`, `unsupported`) and removes only
  Cherry's own files, honours `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, `--dry-run`,
  `--project`, `--json`. A `cherry` skill Cherry did not write is `foreign`
  and left alone without `--force`.
- In the app, Connect Agents to Cherry… shows these rows and installs only
  after its confirmation, as today (Cherry writes no agent configuration
  otherwise).
- A tab of an agent Cherry starts also gets two lines at launch (Claude Code
  and Pi `--append-system-prompt`, Codex `developer_instructions`): it runs in
  Cherry, its tab's ID, and to use the `cherry` skill. No session-start hooks:
  Codex makes the user approve them (`/hooks`), Claude Code needs folder
  trust, and the launch covers Cherry's tabs.

## Sandboxes and permissions

| Agent | Socket blocked? | What Cherry does |
|---|---|---|
| Codex | yes (`workspace-write`, `read-only`) | Connect writes `~/.codex/rules/cherry.rules`: `prefix_rule(["cherry", [agent verbs]], "allow")` (an allowed command runs outside the sandbox) and `prefix_rule(["cherry","host"], "forbidden")`. Without it Codex tabs keep launch-time MCP. |
| Claude Code | only with its sandbox on (off by default) | at launch, with the sandbox on: `--settings '{"sandbox":{"network":{"allowUnixSockets":["<socket dir>"]}}}'` (check it merges with the user's) |
| Pi, OpenCode, Amp | no sandbox | nothing |

Permission prompts: Claude Code asks for each new `cherry …` command unless
allowed. Open question (below) whether Cherry passes
`--allowedTools "Bash(cherry ls *)" …` for the agent verbs at launch.

## Workers and orchestrators

- The kickoff line, `get_my_task`'s rules, the nudge and the wake lines name
  `cherry task mine`, `cherry task report <<'EOF'`, `cherry task wait`,
  `cherry events` for a tab launched with the CLI, and the MCP tools for one
  launched with MCP (`TerminalSession.lastAgentMCPLaunchOutcome` grows a
  `cli` outcome).
- Orchestrators: close workers they will not message again once their result
  is read (`cherry task cancel --close`); never by default.

## MCP

- Stays, unchanged, on the same layer: for sandboxed Codex without the rules
  file, for agents started by hand that are configured for it, and for anyone
  who prefers it.
- Launch-time MCP (`mcp.connectAgentsAtLaunch`) is off by default for agents
  that get the CLI; Settings › Agents & MCP shows which one each agent gets.

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
   `progress` in task progress.

## Open questions

1. Should Cherry allow the agent verbs without prompts in agents it starts
   (Claude Code `--allowedTools`, Codex's rules file already allows them)?
2. Codex without the rules file: keep launch-time MCP for it (as planned), or
   pass `-c sandbox_workspace_write.network_access=true` (all network)?
