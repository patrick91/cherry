# Multiplexer by default

Status: implemented on `codex/persistent-sessions` (2026-09-25): protocol v4
and the holder split, the CLI (with the attach adapter reconnecting by
itself), the Swift control plane, hosted-by-default local tabs with close
intents, settings and feature parity, restore through the control plane, and
the fixes of the stage 4 integration and the stage 5 adversarial review. What
is still open is under [Not done yet](#not-done-yet); see
[Implementation notes](#implementation-notes) for what differs from this
design. Builds on [remote-session-host.md](remote-session-host.md) and the
current `Host/` workspace; user-facing behaviour is in
[Host/README.md](../../Host/README.md).

## Goal

Every local terminal, command and agent tab in Cherry runs as a persistent
session in `cherry-host`. Tabs survive Cherry quitting, crashing or updating and
come back on relaunch. Hosted tabs keep every Cherry feature native tabs have.
The host survives its own crash and upgrades without killing sessions.

Out of scope: remote project parity (cherry.toml commands, worktrees, port
forwarding on SSH hosts), a Linux desktop UI, feeding Ghostty without the attach
adapter.

## Behaviour

Settings (Settings → Sessions, stored in `TerminalSettings`, never rebuild
Ghostty config when they change):

| Setting (as Settings › Sessions labels it) | Key | Default |
|---|---|---|
| Run local terminals as persistent sessions | `sessions.persistLocal` | on |
| Keep running after closing a tab (*keep after tab close*) | `sessions.keepAfterTabClose` | off |
| End sessions when quitting (*end on quit*) | `sessions.endOnQuit` | off |

The keys are read with `object(forKey:) as? Bool`, so a launch argument must
be a plist boolean: `-sessions.persistLocal '<false/>'` works,
`-sessions.persistLocal NO` (or `0`) is ignored.

Close intents (every path that used to call `TerminalSession.stop()` names one):

| Intent | Local hosted tab | Remote hosted tab | Native tab |
|---|---|---|---|
| `userClosedTab` (tab close, ⌘W, sidebar close, MCP `close_process`) | terminate, unless *keep after tab close* | detach | stop |
| `windowClosed` | follows *end on quit* | detach | stop |
| `appQuit` | detach (terminate if *end on quit*) | detach | stop |
| `duplicateWindowTeardown` | detach | detach | stop |
| `worktreeRemoved` | terminate (confirm busy first) | detach | stop |
| `restart` (menu, MCP `restart_process`) | terminate + create with the same tab id | reconnect | restart |

A tab attached to a session it does not own (from the Persistent Sessions
sheet: another app's or the CLI's local session, or an SSH host's) behaves
like a remote hosted tab: it detaches, and `restart` reconnects it. ⌘W or File › Close Tab on a window's
last tab (no other worktree of the window has tabs) closes that tab as
`userClosedTab` and then closes the window; it does not close the window with
`windowClosed`, which would detach and restore the tab.

Quit/close confirmations use the host-reported foreground process for hosted
tabs (busy = foreground process group differs from the session leader's, or the
tab is a running command/agent), exactly as native tabs use their PTY today.

Relaunch: each project window restores its saved tabs (same tab UUIDs, kinds,
titles, split layout, selection). Hosted sessions that still run are reattached;
exited ones show "Session ended (exit N)" with Close/Remove; missing ones are
dropped. Native tabs are not restored (their processes are gone), except that
auto-start commands start as today. Windows that had tabs reopen even when macOS
window restoration is off.

Fallback: when the local host cannot run (disk image, App Translocation, helper
missing, daemon start failure, or another copy of the app with the same app
identity owns the sessions), new tabs silently use the native backend and the
Sessions settings page explains why.

## Host architecture

```
 clients ──► cherry-host daemon (registry, auth, client multiplexer, events)
                 │  one holder link per session (Unix socket, versioned)
                 ▼
            cherry-host hold (one process per session)
               PTY master · child (parent + reaper) · kill escalation
               libghostty-vt Terminal · DisplayStream · input queue
               title / pwd / bell / notification / foreground extraction
```

### Holder (`cherry-host hold`)

One process per session, started by the daemon (double fork, `setsid`, so it is
never the daemon's child and survives the daemon). It owns everything that must
outlive the daemon: the PTY master, the child (it spawns and reaps it — PID-reuse
safety stays intact), the kill escalation, the headless Terminal and the
DisplayStream (so terminal state stays exact and terminal queries keep being
answered while no daemon runs), pending input, the output offset, and session
metadata (title, pwd, foreground process, exit status). A libghostty-vt abort
kills only its own session.

The holder dials the daemon socket and registers (`HolderHello`). When the link
drops it keeps running the session and redials with backoff (250 ms → 2 s). It
exits after the session has exited *and* the daemon told it to remove the
session (retained exited sessions stay inspectable across daemon restarts).
While no daemon is connected it buffers bounded events (bell and notification
counts, the latest title/pwd/foreground are state) for delivery on reconnect.

A manifest per holder (`<state dir>/sessions/<id>.json`: id, holder pid, created
at, link version) lets a restarting daemon know which holders to expect; `List`
waits briefly (≤ 1 s) for expected holders to re-register.

### Holder link (the only cross-version interface)

Holders keep running old code after an upgrade, so the daemon must speak every
holder link version that may still be alive. Rules: every frame carries the link
version; unknown message kinds and fields are ignored; new behaviour is additive
and gated by the version the holder registered with. Framing: 4-byte length,
1-byte kind, then JSON (control) or raw bytes (output/input) — no base64 on the
hot path.

Holder → daemon (ordered stream): `HolderHello{link_version, session info,
offset, pending events}`, `Output{offset, bytes}`, `Query{bytes}`,
`SnapshotReply{req, kind, offset, bytes}`, `ScreenReply{req, …}`,
`InputAck{lease, bytes}`, `DetachDone{req}`, `Info{changed fields}`,
`Event{bell|notification|progress}`, `Exited{exit_code, signal}`.
Daemon → holder: `Input{lease, bytes}`, `DiscardLease{lease}`, `Detach{req,
lease}`, `Resize{cols, rows}`, `Snapshot{req, kind: full|limited(max)|refresh}`,
`Screen{req, scrollback}`, `Kill`, `Remove`.

Because the holder serializes output and snapshot replies on one stream, a
`SnapshotReply` carries exactly the offset its bytes represent; the daemon never
needs to buffer output to splice a snapshot.

### Daemon

Registry and authentication (unchanged trust rules), per-client attachments,
outboxes, lag handling, resize coalescing and the refresh-vs-full decision,
query responder choice, input backpressure (from `InputAck`), event fan-out,
receipts, Create (spawns the holder, which spawns the child). It keeps no
session state that cannot be rebuilt from holders.

- Daemon crash: holders keep sessions alive; clients see a disconnect; the next
  client start (or systemd `Restart=on-failure`) brings a daemon back and
  holders re-register. Attachments reconnect and get fresh snapshots.
- Upgrade: a client or gateway whose `Hello` meets a daemon with a *lower*
  protocol version sends `Replace`; the old daemon stops accepting, removes its
  socket, releases its lock and exits; the new daemon starts; holders
  re-register. A daemon with a *higher* version is reported, never replaced.
  A daemon whose identity is not the one the client expects is neither
  replaced nor reported, so an upgrade only replaces the intended host.

## Protocol v4 (client ↔ daemon)

Exact version match for normal operation (the bundled CLI, app and host ship
together). Frozen forever: `Hello{version}`, `Welcome{version, host_id}` (sent
for every Hello, even across versions — only `Replace` and disconnect are allowed
after a mismatch), `Replace`, `Ok`, `Error{code, message}`.

- Request ids: any request may carry `"req": <u64>`; its reply echoes it. Events
  and attachment traffic carry none. One connection can have several requests in
  flight.
- `Subscribe` → `Ok`, then `Event{event}` pushed: `added{session}`,
  `changed{session}`, `removed{id}`, `bell{id}`, `notification{id, title, body}`,
  `progress{id, state, value}`, `exited{id, exit_code, signal}`, `resync` (the
  subscriber fell behind; re-`List`). Per-subscriber queues are bounded and
  coalesce `changed` per session. A subscribed connection is exempt from the
  idle limit but must `Ping` every `HEARTBEAT_INTERVAL`.
- `Create` gains `owner: Option<String>` (the creating app variant), `tags:
  map<string,string>` (Cherry stores tab id, kind, agent, command there so a lost
  state file can still be reconciled), and accepts any environment variable with
  a valid name from same-uid clients (the host no longer forces `TERM`,
  `TERM_PROGRAM` or `SSH_AUTH_SOCK` when the client sets them). The host sets
  `PWD` to the requested directory when it resolves to the canonical cwd.
- `SendInput{id, data}`: control-plane input without an attachment (MCP input to
  a background tab).
- `Screen{id, scrollback}` → `ScreenText{id, text, cursor_row, cursor_col,
  alternate_screen}`.
- `Update{id, name?, tags?}`: rename / retag a session.
- `SessionInfo` gains `title`, `pwd`, `foreground{pid, name}`, `clients`
  (attached count), `owner`, `tags`, `created_at`.

## CLI

- `cherry control`: after the usual verified connect (local auto-start, SSH +
  gateway preamble, agent lending, auto-upgrade via `Replace`), relays protocol
  frames between stdin/stdout and the daemon until either side closes. Nothing
  else is written to stdout. This is how the app gets one control connection per
  host without reimplementing socket trust, SSH handling or agent lending in
  Swift.
- `--ssh-control-path PATH` (global): passes `-o ControlPath=PATH` (with `%`
  escaped) next to `-o ControlMaster=no`, so every attach adapter and the control
  helper share the app's master connection when one is running and connect
  directly otherwise.
- `new` gains repeatable `--env KEY=VALUE`, `--owner`, and repeatable
  `--tag KEY=VALUE`.
- Auto-upgrade: `list`, `new`, `attach`, `control` and the gateway (without
  `--no-start`) replace a lower-version daemon as described above. `kill`,
  `remove`, `shutdown` (remotely `gateway --no-start`), `cherry start` and
  `cherry-host start` never replace one.

## App

- **Control plane.** `HostControl` (one per host id) runs `cherry [--host H]
  [--ssh-control-path P] control` as a long-lived helper with the login
  environment, speaks protocol v4 frames over its pipes with request ids,
  subscribes to events, pings, and reconnects with backoff. All list / create /
  kill / remove / send-input / screen / update calls go through it. The attach
  adapter per tab stays (`cherry attach … --detach-key none --status-file`).
- **SSH master.** One app-managed `ssh -M -N` per remote destination (BatchMode;
  when it cannot authenticate non-interactively, adapters fall back to their own
  ssh and can still prompt in the tab).
- **Identity.** `TerminalSession.id` is injectable and persisted. The session's
  host tags record it.
- **Launch parity.** A launch-spec builder produces argv/env/cwd equivalent to
  `ShellProcessController.nativeExecLaunch` (login wrapper, shell integration,
  `CHERRY_*`, `TERM=xterm-ghostty`, `TERM_PROGRAM=Ghostty`, startup command,
  cherry.toml command environment). Ghostty resources the environment points at
  (terminfo, shell integration) are copied to a stable Application Support
  location, because sessions outlive the app bundle's path. Local sessions get
  the login environment's `SSH_AUTH_SOCK` directly.
- **Feature parity.** Local hosted tabs set their process id from
  `SessionInfo.pid` for MCP caller routing and port detection (never used by
  `stop()`); title, pwd, bell, notifications, progress and exit come from events
  (and the adapter's passthrough while attached); cwd tracking and splits work
  for local hosted tabs; commands and agents run hosted with their real kind;
  command auto-restart runs on real host exits; MCP input to unattached tabs uses
  `SendInput`, output uses `Screen` when no surface is live.
- **Persistence.** A `WorkspaceStateStore` keeps one JSON file per project
  (repository root) under `Application Support/<app>/Workspaces/`, with per-
  worktree session records, display items, splits and selection. It saves on
  every structural or identity change (debounced) and never during teardown;
  quit flushes it before closing tabs.
- **Scoping.** Sessions carry `owner` = the app identity. Restore adopts only the
  sessions its own state file names (and, since the review, this app's
  sessions that a crash left unnamed; see
  [Orphan adoption](#app-persistence-and-restore)); the Persistent Sessions
  sheet still shows everything and can attach to other owners' sessions
  explicitly. One running copy per app identity owns them.

## Delivery

1. Protocol v4 contract in `cherry-protocol`, holder link, VT event API.
2. In parallel: holder split + v4 daemon; CLI (`control`, SSH control path,
   `new` extensions, auto-upgrade); Swift control plane + SSH master; Swift
   identity, persistence and restore.
3. Swift hosted-by-default backend, close intents, settings, parity.
4. Integration: full matrix, Docker/SSH, real-host Swift tests, CherryDev run.
5. Adversarial review, fixes, docs.

## Implementation notes

What exists on `codex/persistent-sessions` (2026-09-25), and where it
differs from the design above.

### Host and protocol

- The daemon (`cherry-host serve`) and one holder per session
  (`cherry-host hold --socket …`, link on fd 3, never the daemon's child) are
  implemented as designed. The holder link is at `LINK_VERSION` 4, and a
  daemon speaks every version from 1. Beyond the frames listed above it has
  `Launch` and `Failed` (Create goes through the holder), `Update` (rename /
  retag kept by the holder), `Info` (title/pwd/foreground, from version 3
  `alternate_screen` and `kitty_keyboard_flags`, from version 4
  `application_cursor_keys`), `ScreenReply` (from version 3,
  `SCREEN_LINES_VERSION`, `Screen` carries `max_lines`) and `Refused` (a
  daemon that will never serve a holder, with `retry`). All of them are
  additive; version 4 adds only `application_cursor_keys` (in `Info` and
  the hello's session). On Linux a daemon starts holders from its own image
  (`/proc/self/exe`); on macOS from its executable's path, which after an
  app update is the new build, so `Launch` fields are additive too.
- A crashed holder reports its session exited with code 1. Exited sessions
  survive daemon restarts until Remove. `Shutdown` still refuses while
  sessions run, and ends the holders of exited ones. `Replace` from a newer
  client always hands every session to the successor; the replaced daemon
  exits with status 0.
- Holders: a stopped session leader (`kill -STOP`, a debugger, a job-control
  stop) is not taken for an exited one, on macOS too. The session keeps
  serving snapshots, screen text and input while stopped, and `Kill` still
  ends it: SIGHUP and SIGTERM are each followed by SIGCONT, then SIGKILL. The
  holder never blocks in `waitpid`. A holder redials the daemon socket at
  once when an entry appears in the socket's directory, otherwise with
  backoff (250 ms to 2 s; up to 30 s while it watches the directory, and at
  most 2 s apart when the directory cannot be watched, for example after it
  was removed).
- A daemon that starts reads the holder manifests and makes `List`, and
  requests that name a session, wait for the holders it expects, at most
  1 s (`CHERRY_HOST_HOLDER_WAIT_MS`, for tests). `Sessions.pending_holders`
  counts the expected holders whose process still runs and that have not
  registered (a SIGSTOPped holder counts until it continues); a session is
  always listed, counted, or both. A host that knows `pending_holders` always
  sends it, even when 0, and it is also the sign that the host knows
  `Screen.max_lines`: a stage-3 host at the same protocol version ignores
  `max_lines`.
- `SessionInfo` gained `alternate_screen` and `kitty_keyboard_flags` (the
  active screen's), `application_cursor_keys` (DECCKM, mode `?1`, which
  libghostty keeps terminal-wide, so a screen switch does not change it; it
  selects `ESC O x` for unmodified arrows, Home and End only in legacy key
  encoding, as the kitty encoding sends them as CSI whatever DECCKM says),
  and `request_id` (the Create's, from the receipt the holder keeps). The
  holder hello carries all of them, so they survive daemon crashes,
  restarts and Replace, and they are kept after exit; a `changed` event
  follows every change of a mode, including a DECCKM-only one. A holder
  older than link version 4 never reports DECCKM, so its session reads
  `application_cursor_keys` false for its whole life. `Screen{max_lines}`
  returns the last `max_lines` lines and counts `cursor_row` from the first
  of them (exact, including trimmed blank lines at the end of the history).
  At most 8 kinds of `Screen` request wait on one holder, with at most 64
  callers each; beyond that the answer is `request_failed` at once ("the
  session's holder is not answering").
- An attach or resync whose snapshot the holder answered after the grid
  changed (it shows the old size) is followed at once by an
  `Attached{reason: resize}` at the current grid, so clients can see
  `attach` at the old size and then `resize`.
- Events follow the design. Details the app relies on: `changed` and
  `progress` are coalesced per session, and `resync` is followed by each
  session's latest queued progress. Bell, notification and progress events
  sent while no client was subscribed are kept (at most 64, for 30 s) for the
  next subscriber, including those a holder kept while no daemon ran.
- Create environment: every variable that execve accepts, at most 1024
  entries and 256 KiB. The host sets its defaults first, then the client's
  variables win, and `CHERRY_SESSION_ID` and `PWD` are set last.
- Auto-upgrade through the gateway: without `--no-start`, `cherry-host
  gateway` that finds an older daemon (protocol 4 or later, which answers
  with a lower `Welcome` version) asks it to make way (`Hello`, then
  `Replace`), waits for `Ok` or the connection closing, starts its own daemon
  and relays; the sessions carry on in their holders. So `cherry --host H
  list/new/attach/control` and the app's control helper upgrade a remote host
  once cherry-host is updated there. The CLI passes the identity it expects
  (`--expected-host-id`, or the one an attachment reconnects to) as
  `env CHERRY_EXPECTED_HOST_ID='<id>' cherry-host gateway …`; the gateway
  neither replaces nor reports a host of another version whose identity
  differs, but relays it, and the CLI fails with
  `host identity changed (expected X, received Y)`, as locally, so the app's
  identity classification (`HostControl.failureBeforeWelcome`) applies to
  remote upgrades too. An older or newer remote cherry-host ignores the
  variable and reports its version through its preamble. An SSH key forced
  to `cherry-host gateway` (`command=` in authorized_keys, `ForceCommand`)
  drops the variable, and the gateway then replaces without the identity
  check.
- Reports of a daemon of another version that is not replaced all start with
  `a cherry-host speaking `, which the CLI relies on: a newer one (`…; it is
  newer than this cherry-host (protocol M), which never replaces it: install
  the cherry-host (and Cherry) that speaks protocol N`), one older than
  protocol 4, which refuses a `Hello` of another version (``… finish its
  sessions and stop it (`cherry shutdown` from the matching version)``), one
  that refused `Replace` (`… and refused to make way for this one …`), and,
  for the commands that never replace (`kill`, `remove`, `shutdown` over SSH,
  `cherry start`, `cherry-host start`), an older one (``…; `cherry list`,
  `new`, `attach` and `control` replace it with this version, and its
  sessions carry on``).
- systemd: a daemon replaced this way exits with status 0, so
  `Restart=on-failure` does not restart it; the gateway (or a local client on
  Linux) then runs `systemctl --user start cherry-host.service`, so the
  unit's `ExecStart` must point at the updated binary. When it still runs an
  older one, the client fails with ``a cherry-host speaking protocol N is
  running at P: the systemd user service cherry-host.service started it, and
  its ExecStart runs that older cherry-host (<path>); install this version
  (protocol M, <exe>) in its place, or point the unit's ExecStart at this
  one (`systemctl --user edit --full cherry-host.service`), then try again``.

### CLI

- `cherry control`, `--ssh-control-path`, `new --env/--owner/--tag` and
  auto-upgrade through `Replace` are implemented. One 30 s deadline covers
  connecting (which includes starting a local host and a Replace). The app
  classifies failures by the stable stderr substrings (`host identity`,
  `host rejected request`, `protocol version mismatch`, `could not replace`,
  `was asked to make way`, `connection lost`, `appears to be dead`,
  `detached while reconnecting`).
- **The attach adapter reconnects by itself.** After a lost connection
  (including a daemon crash, restart or Replace) it keeps its terminal and
  connects again for 30 s from the loss (`CHERRY_CLI_RECONNECT_WINDOW_MS`, 0
  never reconnects): at once, then 250 ms doubling to 2 s. A reattachment
  lost again within 10 s (`CHERRY_CLI_RECONNECT_HEALTHY_MS`) continues the
  same window and backoff. Each attempt may take 5 s to connect locally and
  15 s over ssh (`CHERRY_CLI_RECONNECT_ATTEMPT_MS`), then as long for each
  answer, and runs off the terminal thread. Reattaching never takes over;
  over SSH it runs `BatchMode=yes`, `ConnectTimeout=10`, without `-a`. It
  stops at once (`disconnected`) when retrying cannot help: another
  `host_id` answers, the host's protocol is newer, older than 4, or refused
  `Replace`, the remote gateway reports a host of another version it did not
  replace, the gateway's preamble is another version, or the session is gone
  (`unknown_session`, not listed, `pending_holders` 0). Terminal input typed
  while reconnecting is discarded with a one-line notice; input queued on the
  lost connection is dropped, never resent; non-terminal stdin pauses, or
  ends the attachment when some of it went to the lost connection. After a
  reattach, the rest of a bracketed paste the terminal began before the
  attachment was back is discarded until its end marker, or 1 s without
  terminal input (`CHERRY_CLI_PASTE_TAIL_WAIT_MS`); only then, and only when
  the paste's start marker was written to the lost connection and the
  session still has mode 2004 on, is `ESC[201~` sent. Nothing ssh prints
  reaches the terminal once the first snapshot is painted.
- The status file holds a live
  `{"outcome":"attached","viewport":…,"reconnecting":…,…}` once the first
  snapshot is painted and whenever either flag changes; final outcomes keep
  the old four-field shape. A SIGKILLed adapter leaves `attached`, so the
  app also uses the process exit. `list --json` has `pending_holders`.

### App: control plane and launch

- `HostControl` (one per host, `HostControlRegistry`) and the app-managed SSH
  master are implemented as designed. For an SSH host,
  `--expected-host-id` is passed only when the trusted identity is a UUID
  (attach adapters always pass the identity their session was listed with).
  The app also checks the Welcome's `host_id` itself.
- The session list `HostControl` keeps never lets a reply snapshot (`Created`,
  a list) overwrite an event that reached the app after the request was
  sent: an exited session never turns back to running, and a session removed
  (by an event or the app's own Remove) is not brought back by an older list.
  It keeps running sessions that an incomplete list (`pending_holders` > 0)
  lacks, without a `removed` event, and lists again every 500 ms (20 times),
  then every 5 s, until a list is complete. `holdersRegistered()` fires once
  a list reports none pending.
- When a Create's first answer is lost, any failure of its retry is reported
  as `.transport` (the session may have been created), so the lost-create
  cleanup always runs. Working directories the app passes to Create are sent
  exactly as given (a trailing space is kept); only text typed in the
  Persistent Sessions sheet is trimmed. Empty still means `~`, and relative
  paths are refused.
- `SendInput` longer than 64 KiB goes in several requests. When one after
  the first fails, `HostInputPartiallyDelivered` says how many bytes were
  typed, and how many more may have been (`unconfirmedBytes`: the part
  that failed, when its answer was lost; 0 when the host refused it). MCP
  reports it as `input_partially_delivered` ("Only the first N of M bytes
  …"): when the host refused the part, the rest was not sent; when its
  answer was lost, those bytes may or may not have been typed and only the
  bytes after them were not sent. A lost answer to the first part is still
  `input_not_delivered` (see [Not done yet](#not-done-yet)).
- SSH master: one that dies within 60 s of coming up is restarted after a
  delay that doubles each time (1 s up to 60 s); one that stayed up at least
  60 s starts over at 1 s. Masters are signalled only while not yet reaped.
  Masters left by a crashed app are stopped at every app launch
  (`CherryAppDelegate.startLaunchHousekeeping`), in the background, whether
  or not any SSH host or persistent session is used.
- **Deviation (launch parity).** Hosted sessions run
  `/bin/bash --noprofile --norc -c 'exec -l <shell command>'`, or
  `/bin/sh -c <command>` when the account is unknown. They do not use the
  `/usr/bin/login` wrapper, because login(1) always exits with status 0.
  Without it, "Session ended (exit N)", the agent error state and command
  auto-restart see the real status. `SessionInfo.pid` is the login shell, and
  "busy = foreground group ≠ pid" is correct for an idle shell. The rest of the
  environment (shell integration, `CHERRY_*`, `TERM=xterm-ghostty`, staged
  Ghostty resources under `Application Support/<app>/GhosttyResources/<hash>`)
  matches `nativeExecLaunch`. The known differences are: no
  `GHOSTTY_SURFACE_ID`, `XPC_*` or `NO_COLOR`; stable staged paths; and the
  host adds `CHERRY_SESSION_ID`.
- Create tags: `cherry.tab`, `cherry.kind`, `cherry.agent`, `cherry.command`,
  `cherry.project` and `cherry.launch` (the Create request id). The app uses
  the session's `request_id` (or else `cherry.launch`) to end a session whose
  Create answer was lost, and to find the session of a record saved before
  its Create answered. The owner is `CherryAppIdentity.applicationSupportName`.

### App: hosted-by-default tabs

- `PersistentLocalSessions` runs new local tabs in the local host when
  *Run local terminals as persistent sessions* is on and the host can run
  them. Otherwise, and for 30 s after the host could not start a session,
  tabs run natively and Settings › Sessions says why. A tab whose session is
  not created within 8 s runs natively, and a session created after that is
  ended.
- **Scoping, one copy per identity.** The first copy of the app takes
  `Application Support/<identity>/instance.lock` (`flock`, released by the
  kernel when it exits) for its whole run. A second copy with the same
  identity (`swift run Cherry`, `open -n`, a second bundle with the default
  support name) does not reopen or restore windows, save tabs, or create,
  adopt or end local persistent sessions; its new tabs run natively, and
  Settings › Sessions says "Another copy of <identity> (process N) is running
  with the same app data …". It does not try again during its run. It also
  says so once, in an informational sheet on its first project window
  ("Persistent sessions are off in this copy", that reason, and "New tabs
  in this copy run as ordinary tabs: their programs end when it quits.";
  `InstanceLockNotice`), which holds up only that window; whether it is
  needed is found out off the main thread. A copy that holds the lock, or
  where the lock is not enforced, shows nothing. A copy launched while the
  holder is quitting (the holder writes `quitting` as the
  lock file's third line when its windows tear down for quit) waits for it,
  up to 12 s, and then owns the sessions and saved tabs; a copy that finds
  the holder not quitting gives up at once. On a file system without `flock`
  support (ENOTSUP, EOPNOTSUPP, ENOLCK) the lock is not enforced: the copy
  keeps persistent sessions and saved tabs and logs a warning; other lock
  errors turn them off.
- A persistent tab's surface runs its attach adapter, which reconnects by
  itself; the app launches a new adapter (backoff 0.25 s to 8 s) only when
  one exits, and shows the reconnect bar once an adapter has reported
  `reconnecting` for 2 s. The adapter's live status file alone (read through
  kqueue on the launch's private directory) says whether it is attached,
  paints a viewport, or reconnects: only `attached` resets the reconnect
  failure count or brings a `.disconnected` tab back to `.live`. There is no
  `clients > 1` guess and no settle interval. While the adapter is not
  attached and following the program, the tab gets title, pwd, bells,
  notifications and progress from host events, and its lines from `Screen`
  (the last 600 lines, at most once per second in watch loops); a reply with
  fewer lines than asked is the whole history. The program's pid
  (`hostedProgramProcessID`) is used for MCP routing and port detection, and
  is never signalled. Host-reported alternate screen, kitty flags and
  application cursor keys arrive through `changed` events
  (`TerminalSession.usesApplicationCursorKeys` prefers the host's report,
  true only while DECCKM is on and the kitty flags are 0); an attached
  (non-owned) tab takes them only while its launch is deferred or its host
  control is connected and subscribed.
- **Input while there is no program or no adapter.** Keys typed or pasted
  while a persistent tab's session is being created or restarted are queued,
  in order with MCP input and up to 64 KiB, and sent once the session
  exists; a restart shows an in-memory surface, which takes the keys, until
  the new adapter launches. Keys typed while the adapter is away (it ended
  and is relaunched with backoff, or it reports that it reconnects) are sent
  through the host (`SendInput`), and the surface keeps showing the last
  screen. `HostRoutedKeyEncoder` types what a legacy (xterm) terminal
  types: text; Return, Tab, Backspace, Escape, Forward Delete, arrows,
  Home/End, Page Up/Down and F1–F12, with Shift, Control and Option as
  xterm's modifier parameter (`CSI 1;m X`, `CSI n;m ~`); unmodified arrows,
  Home and End in the program's cursor key mode (`usesApplicationCursorKeys`);
  Control with a letter or symbol as its C0 byte (Control+/ is 0x1F,
  Control+? and Control+8 DEL; on a non-Latin layout, by key position),
  and Control with a key that has none as the key; Control+Backspace as
  ^H; Option as Alt per Ghostty's `macos-option-as-alt` (Cherry's default
  is true), ESC plus the key (Control+Option: ESC plus the Control byte);
  Cherry's own Shift and Option encodings; and ⌘V paste. So Option+letter
  types ESC and the letter, as the native surface does; the composed
  character only with `macos-option-as-alt` false. Option+digit still
  types the layout's character (Cherry's own encoding). While the
  program's kitty flags are not 0, the keys the protocol's disambiguate
  flag (1) encodes differently go as Ghostty's surface types them: Escape
  `CSI 27 u`; Control or Alt with a character key `CSI <unshifted
  code>;m u` (Control+letter `CSI <code>;5 u`, Option as Alt with a letter
  `CSI <code>;3 u`); modified Return, Tab and Backspace `CSI 13/9/127;m u`;
  F1, F2 and F4 `CSI P/Q/S` and F3 `CSI 13 ~`. Input-method composition,
  F13 and above and ⌘ shortcuts are not sent (see
  [Not done yet](#not-done-yet)). MCP input to a session being created
  waits up to 16 s, then is reported undelivered; it goes as sent, since
  the program has set no key mode yet.
- MCP input the host types (a persistent tab without a live adapter, or an
  attached tab whose adapter has not launched or reconnects) has its
  unmodified arrow, Home and End sequences, `raw_base64` included,
  rewritten for the program's cursor key mode as the host reports it
  (`hostTypedInputData`, `TerminalInputNormalizer.encodingCursorKeys`):
  `ESC O x` while DECCKM is on and the kitty flags are 0, else `ESC [ x`.
  It goes through `SendInput` at once. Only when the host does not report
  the mode (an older host) do such sequences to a persistent tab, or to an
  attached tab whose adapter has not launched, launch or wait for the
  adapter, up to 3 s (`modeDependentInputAdapterWait`), and go through the
  surface; if no adapter attaches in time, the host types them as sent. A
  Tab sent while a program has kitty flag 8 reaches the surface as a Tab;
  the `CSI 9 u` form is used only for host `SendInput`.
- A bell or notification the host kept while its daemon was down (holder,
  then new daemon) is shown even when the adapter reattached before the
  app's control connection resubscribed: for 30 s after the adapter
  attaches, host signals arriving on a newer control connection are shown
  unless the surface already showed a matching one. Otherwise bells and
  notifications from host and surface are shown once (deduplicated within
  1 s and 3 s).
- Close intents follow the table above. The additions: closing a persistent
  tab whose program already ended removes its session whatever the
  settings. ⌘W on a window's last tab asks "Close window?" only when the
  close actually stops a busy program (attached tabs never ask); a running
  agent uses the agent confirmation. A running agent's close confirmation is
  "Close agent tab?" / "This agent keeps running in the background after its
  tab closes. Attach to it again from File › Persistent Sessions." /
  **Close Tab** whenever closing the tab does not stop the agent (a
  persistent agent with *keep after tab close* on, or a tab attached to a
  session it does not own), and "Close agent?" / **Stop and close**
  otherwise. MCP `stop_process` reports a clean `exit 0`. New MCP errors are
  `process_not_accepting_input`, `input_not_delivered`,
  `input_partially_delivered` and `agent_awaiting_permission`.
- **Restart.** A tab runs one launch at a time. A stop or close during a
  restart's wait for the old program to exit starts nothing. A second restart
  waits (bounded) for the first. A session created by a Create that answers
  after its tab stopped or closed is ended, and its exit is waited for,
  before the tab's next launch.
- **Detaching close during a Create.** When a persistent tab closes with a
  detaching close action while its session's Create is under way, the
  session that Create makes is kept, not ended. Detaching actions: quit or
  window close with *end on quit* off (the default), a tab close with *keep
  after tab close* on, and a duplicate window teardown. The tab's saved
  record names the session by its launch request id, and the next restore
  brings the tab back with it. A stop, a restart, or a close that terminates
  (a tab close by default, a worktree removal, quit with *end on quit* on)
  still ends a late-created session.
- **Ending a session** (close, worktree removal, restart, quit with *end on
  quit*): a Kill or Remove that gets no definite answer is resent with
  backoff (250 ms, doubling to 4 s) for up to 60 s. Only the host saying
  `unknown_session`, or another host identity answering, stops it early.
  Quit still waits at most its own bound.
- **Quit** waits at most 8 s (and at least 900 ms) for sessions being ended
  and for tabs' launches in flight whose session will be ended (so such
  sessions are ended rather than orphaned), and replies to macOS within
  10 s either way. Its confirmation sheet goes on the key window when that
  is a project window, otherwise on the active project's window, which is
  unhidden, deminiaturized and activated; never on the menu-bar panel. With
  no project window it is an app-modal alert. Closing the sheet's window
  before answering cancels the quit.
- **MCP and agents.** MCP input to an agent is checked against its current
  screen first (read from its session host when no surface shows it). While
  the screen shows a tool-permission prompt, input is refused with
  `agent_awaiting_permission` and nothing is sent; raw keys sent without
  submit still go through. `input_not_delivered` is returned when the
  agent's screen cannot be read from its host. Cherry presses Enter on an
  agent's startup or trust prompt only for an agent its tab just launched,
  never for a restored, adopted or attached agent, or on a permission menu.
  `wait_for_process_idle` returns `permission`, and `agent_activity_state` is
  `permission`, whenever the screen shows a permission prompt. MCP client
  timeouts: `spawn_process` with kind `command` waits `wait_ms` + 30 s,
  other `spawn_process`, `spawn_agent` and `send_process_input` `wait_ms` +
  20 s; `start_process`, `start_all_commands` and `restart_all_commands`
  `wait_ms` + 20 s (they wait up to 10 s for a restore); `send_agent_message`
  max(`timeout_ms` + 5 s, 20 s). `line_count` of a restored tab whose lines
  come from the host is the host's line count.

### App: persistence and restore

- `WorkspaceStateStore` keeps one JSON file per repository (version 1). It
  saves 500 ms after changes, except that a newly opened persistent tab is
  saved at once (its record carries the Create's request id,
  `launchRequestID`); it never saves during teardown, and quit flushes it
  first. Records gained optional `owned` and `launchRequestID` fields (older
  builds ignore them). A state file (or `open-windows.json`) of another
  version, one that does not decode, or one for another root is moved aside
  as `<file>.<vN|unreadable|other-root>-<UTC yyyyMMddTHHmmssZ>.bak` in the
  same `Workspaces` directory before anything is written, never overwritten;
  if it cannot be moved, that file is not written during the run.
- The app's restorer is `WorkspaceSessionRestorers.hostedByDefault`
  (`WorkspaceRestore.swift`). For each worktree it lists every host named by
  a saved record through that host's `HostControl`, all hosts at the same
  time, and handles each record as follows:
  - Matched first by its launch request id (the session's `request_id`, or
    else its `cherry.launch` tag, for a session of this app's owner), then by
    its binding (host identity and session id). A local record whose session
    is gone falls back to a session of this app tagged with its tab id
    (`cherry.tab`), for example after a restart whose new binding was never
    saved. Running sessions win over ended ones, then the newest.
  - Running: the tab comes back with its id, kind, agent, parent agent,
    command, launch settings, project, title and directory. The attach
    adapter is launched later (see below).
  - Ended: "Session ended (exit N)". No adapter runs; the host's final screen
    (`Screen` with history) is shown as plain text, without colours.
  - Missing on a host that answered: a daemon that just restarted lists a
    session only once its holder registered again. While the host reports
    `pending_holders` > 0 it is listed again every 250 ms, for up to 10 s,
    and the record is kept if holders are still pending then; kept records
    are restored again once the host expects none
    (`HostControl.holdersRegistered()`), or at the next launch. A complete
    list (`pending_holders` 0) drops the record at once. A host without
    `pending_holders` (an older one) is listed once more after
    `disappearanceConfirmationDelay` (2 s); still missing, the record is
    dropped. A local host that now has another identity (its state was
    reset) drops it at once.
  - Unreachable, an SSH host that answers with an identity other than the
    trusted one, or this app cannot run local sessions: the record stays
    saved, and so does a record saved while its Create had not answered
    (`launchRequestID`, no binding); other records without a binding were
    never restorable and are dropped as native tabs are. A failed local list also marks the local host unavailable, so
    new tabs (the default shell first) start natively at once instead of
    waiting for a Create; the next successful list clears that. Local
    records are restored again, into the open workspace and keeping its
    selection, when the local host can be listed again during this run: at
    once if a connection came up since the list failed (even before the
    restore listened for it), or after `restoreRetryDelay` (10 s) when the
    list failed on a connection that stayed up. SSH records wait for the
    next launch.
- **Orphan adoption.** Sessions this app created (owner) for a tab
  (`cherry.tab`) in one of the window's worktrees (`cherry.project`) that no
  saved record names are adopted as persistent tabs of that worktree, after
  the tabs already open: a tab never saved because the app crashed right
  after opening it, or a record that was lost. The session must have been
  created after the last save (to the second) and before this app run began.
  A session created before the last save and missing from it (a tab closed
  with *keep after tab close*) is left alone. While a project has no usable
  state file but one was moved aside, that file counts: its `savedAt` (or its
  modification time) is the lower bound, and the tabs it named come back
  whenever they were created, until this version saves a file for the
  project. With no file of any version ever saved, any of the project's
  sessions from before this run are adopted. Each worktree is scanned once
  per run: at window open and after discovery, again once the host is
  reachable, and after a restarted daemon's holders have registered.
  Sessions recorded to be ended (below) are never adopted.
- **Hosts that answer late.** The restore adds what the hosts that answered
  within 1.5 s brought back; the others (and the second look for missing
  sessions) finish in the background (`WorkspaceRestoreResult.remainder`),
  so one slow or unreachable SSH host (or a local host that hangs) never
  holds up the other tabs, auto-start or MCP. Records still in flight stay
  saved. Their tabs come after the tabs already open (the order saves use
  while they are in flight), and take the saved selection if nobody changed
  the selection meanwhile. The window's default shell opens only once
  nothing more is coming and no terminal or agent came back (auto-started
  commands do not count). A split whose panes are on hosts that answered at
  different times comes back as separate tabs. A restore still under way
  when its window closes (or its worktree is forgotten) builds no more tabs:
  it keeps those records saved and ends the tabs it built but had not handed
  back yet with the window's close intent, so a reopened window's restore
  owns the sessions again.
- **Deviation (tab types).** A local session that this app created, for a tab
  that owned it (`owned`, or for older records the `cherry.tab` tag), comes
  back as a persistent tab (`makeRestoredPersistentSession`). Every other
  session comes back as an attached tab (`makeRestoredHostedSession`) with
  the same full metadata: SSH sessions, other owners' sessions, and tabs that
  were only viewers. So a restored agent or command is an agent or command
  again even when attached.
- **Scoping.** "Adopt" means "own". Restore only owns sessions whose `owner`
  is this app. A viewer record comes back attached whatever the owner (sheet
  sessions have no owner). A session is owned by at most one tab. A record
  that would own a session another open tab owns (any window or worktree) is
  dropped, not attached. Records naming the same session in one restore give
  one tab. A record whose tab id is already open is dropped.
- **Staggered attach.** Restored tabs follow their host at once. Persistent
  tabs are bound: exit, title, pwd, bells, notifications, progress, input and
  screen work as while an adapter reconnects. Attached tabs keep a lease on
  their host's control connection and get title, bells, notifications and
  exit from its events; MCP input to them goes through `SendInput`, also
  while their adapter reports it reconnects (a failure is
  `input_not_delivered`). `RestoredTabLaunchQueue` launches adapters one per
  main run-loop turn, the selected tab and the other panes of its split
  first, then the other tabs of the worktree shown. The pause between
  launches is 50 ms or as long as the last launch took, whichever is longer
  (each builds a surface on the main thread). Tabs of worktrees not shown
  launch their adapters when their worktree is activated, and showing any
  tab launches its adapter at once.
- Agent trees come back with parents before children. A child whose parent
  did not come back is shown as a root and keeps its parent id. Collapsed
  groups, split groups (with their weights), display order and selection are
  restored. Kept tabs that come back later (the retry) are added after the
  tabs opened meanwhile, as saves order them.
- **Commands.** A command has one tab per workspace.
  - Auto-start runs after the restore of its worktree. It never adds a
    second tab for a command a restored tab runs (running or ended). An
    auto-start command whose tab is still being restored (a host that
    answers late) or was kept because the local host was unreachable (or its
    holders were pending) waits for that tab to come back during this run.
    Until then it does not start at all, which avoids two copies of a
    server.
  - Auto-start also restarts a restored auto-start command whose session
    ended while Cherry was closed, whatever its auto-restart setting (as
    auto-start starts a stopped command when its window opens). A restored
    ended command with auto-restart restarts in its own tab through its
    restart policy (new session, the ended one removed).
  - Sidebar starts and MCP `spawn_process`, `start_process`,
    `start_all_commands` and `restart_all_commands` wait (at most 10 s) for
    a restore under way that may bring back the command's tab, then use that
    tab instead of starting a second copy.
  - If a command tab was opened anyway (the wait ran out, or while the local
    host was unreachable), the tab whose program runs keeps the command: a
    restored tab whose program runs replaces an open tab whose program ended
    (closed as a user close would); otherwise the restored tab is detached,
    and if its program runs, its record is set aside and stays saved (its
    session keeps running and shows in the Persistent Sessions sheet), so
    nothing is orphaned without a record.
- **Deviation (ended tabs).** Ended persistent terminal and agent tabs show
  "Session ended (exit N)" with **Restart** and **Close**; Close removes the
  ended session, so there is no separate Remove. Attached tabs whose session
  ended show Remove from Host and Close Tab.
- **Worktrees.** Removing a worktree, or its disappearing from discovery,
  ends the local sessions owned by its saved tabs that are not open tabs:
  not restored yet, still being restored, kept while the host was
  unreachable, or set aside. Records that were only attached are never
  ended. A removal's confirmation counts all of these as running processes.
  Those tabs (an owned local binding, or a Create under way) are recorded in
  `Workspaces/sessions-to-end.json` before the next save drops them. They are
  ended as soon as the host can be listed (asked again for up to 5 minutes
  while it cannot); an entry is removed once a complete list shows none of
  its sessions left. Whatever this run could not end (the host stayed
  unreachable, or the app quit first) is ended when the next launch opens
  its first project window. Entries expire after 14 days.

### Not done yet

- **MCP input whose first answer was lost.** When the host's answer to
  input of at most 64 KiB, or to the first 64 KiB part of longer input, is
  lost (a transport failure after it was sent), MCP answers
  `input_not_delivered` ("nothing was sent"), although the host may have
  typed that part (`PersistentLocalSessions.sendInput` says so). Fixing it
  needs a decision on what `input_not_delivered` promises, or a new error
  code.
- **DECCKM of older holders.** A holder older than link version 4 never
  reports DECCKM, so its session reads `application_cursor_keys` false for
  its whole life, even under an updated daemon, and the app cannot tell off
  from unknown: MCP cursor keys to it without a live adapter go through the
  host at once as `ESC [ x` instead of waiting for the adapter, and so do
  cursor keys typed while its adapter is away. An optional field, left out
  when unknown, would let the app keep the adapter fallback for such
  sessions. On a machine that ran an earlier build of this branch, the
  protocol-4 daemon still running is not replaced (the field did not change
  `PROTOCOL_VERSION`) and leaves the field out, so the app takes the mode as
  unknown until that daemon restarts (`cherry shutdown` when idle, or kill
  its `cherry-host serve`; sessions carry on in their holders).
- Keys typed while an adapter is away that `HostRoutedKeyEncoder` does not
  send (input-method composition, F13 and above, Option dead keys when
  Option does not act as Alt) still reach the dead surface and are lost.
  Under the kitty keyboard protocol it covers only what the disambiguate
  flag changes: plain text keys still go as text under report-all-keys
  (flag 8; only a lone Tab becomes `CSI 9 u`), and alternate keys (flag 4),
  associated text (flag 16) and Caps Lock or Num Lock in the modifier value
  are not encoded.
- systemd churn: while the unit's `ExecStart` runs an older cherry-host,
  every connection of the new version replaces the old daemon, which the
  unit then starts again (the gateway cannot know the protocol of the unit's
  binary without running it). Sessions carry on in their holders, clients of
  the old version cannot reach the host anyway, and every attempt fails at
  once with the message above.
- Permission-prompt detection recognizes phrases from numbered menus only,
  so unnumbered prompt formats are not caught.
- An explicit **Reconnect Now**, MCP `start_process` or a sidebar Start on a
  persistent tab shown `.disconnected` still launches a new adapter (a new
  surface), even while the old one reconnects by itself.
- An attached SSH tab whose host control is not connected reports alternate
  screen false and keyboard flags 0 once its adapter runs; it does not open a
  connection just to follow modes. A kept command record whose holder stays
  alive but never registers (a SIGSTOPped holder) makes auto-start wait for
  the rest of the run.
- The earlier run's sessions to end are resumed when the first project
  window opens, not at app start, and a copy that cannot reach the host
  (disk image, no helper) records them but does not look for them. A copy
  launched while the lock's holder quits blocks its main thread at the
  first lock check for up to 12 s (the launch's warm-up of the local host
  checks the lock on the main thread).
- Test gaps: bringing the quit sheet's window on screen is not unit-tested
  (it would take focus from the user's apps); ⌘W on a last tab attached to
  someone else's session is covered only through `closeEndsProgram`. The
  instance-lock sheet is tested only with an injected presenter (no run
  with two copies of the app), and keys typed while an adapter is away only
  against a fake host (MCP cursor keys also against a real one), not in the
  running app. The CI workflow has not run on GitHub yet. The ignored
  `ssh_host.rs` acceptance test needs a disposable real SSH host; the SSH
  reconnect paths are covered by fake-ssh tests. The GUI scripts
  (`test-packaged-app`, `test-mcp-concurrency`,
  `perf-run-emulator-comparison` with a real Cherry) were not run in this
  round.
- Nice-to-haves (none blocks): sequence ids on bell and notification events,
  for exact deduplication; per-client sizes in `SessionInfo`.
