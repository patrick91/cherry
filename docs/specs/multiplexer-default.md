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
| When quitting or closing a window (*on quit*: Ask, Keep Running, End Sessions) | `sessions.onQuit` (`ask`, `keep`, `end`) | `ask` |
| Close a tab when its shell exits (*close on exit*) | `sessions.closeTabOnExit` | on |
| Tell me about background sessions when Cherry opens (*background notice*) | `sessions.backgroundNoticeAtLaunch` | on |

The boolean keys are read with `object(forKey:) as? Bool`, so a launch
argument must be a plist boolean: `-sessions.persistLocal '<false/>'` works,
`-sessions.persistLocal NO` (or `0`) is ignored. `sessions.onQuit` is a
string (`-sessions.onQuit keep`); anything else reads as `ask`.

Close intents (every path that used to call `TerminalSession.stop()` names one):

| Intent | Local hosted tab | Remote hosted tab | Native tab |
|---|---|---|---|
| `userClosedTab` (⌘W, Close Tab, the sidebar's and pane menu's Close) | terminate (in a window that stays open, once ⌘Z can no longer undo the close) | detach | stop |
| `userDetachedTab` (⌘D, Detach Tab, the sidebar's and pane menu's Detach, Detach Instead) | detach | detach | — (not offered) |
| `mcpClose` (MCP `close_process`, never asked about) | terminate | detach | stop |
| `windowClosed` (Keep Running, *on quit* = keep, or nothing asked) | detach | detach | stop |
| `windowClosedEndingSessions` (End Sessions, or *on quit* = end) | terminate | detach | stop |
| `appQuit` (Keep Running, *on quit* = keep, nothing asked, or a log out, restart, shut down or update) | detach | detach | stop |
| `appQuitEndingSessions` (End Sessions, or *on quit* = end) | terminate | detach | stop |
| `duplicateWindowTeardown` | detach | detach | stop |
| `worktreeRemoved` | terminate (confirm busy first) | detach | stop |
| `restart` (menu, MCP `restart_process`) | terminate + create with the same tab id | reconnect | restart |
| `programExited` (a terminal's shell exited with status 0) | terminate (removes the ended session) | — (attached tabs never close by themselves) | stop |

A tab attached to a session it does not own (from the Persistent Sessions
sheet: another app's or the CLI's local session, or an SSH host's) behaves
like a remote hosted tab: it detaches, and `restart` reconnects it.

Closing and detaching a tab (the menu's Close Tab and Detach Tab, which say
Pane in a split, act on the selected tab or the focused pane):

- **⌘W** (Close Tab) always ends the tab's program: a persistent tab's
  session ends, a native tab's process tree stops, and a tab attached to a
  session it does not own only disconnects (not this app's to end). There
  is no setting to keep a closed tab's session running; detach it instead.
- **⌘D** (Detach Tab; Split Right moved to **⌘⇧D**) closes the tab and
  keeps its session running in the background, where Background Sessions
  lists it (a tab attached to a session it does not own disconnects). It is
  offered for this app's own persistent tabs while their program runs and
  for attached tabs whose session has not ended
  (`SessionCloseCoordinator.canDetach`); for a native tab the menu item is
  disabled and ⌘D does nothing. An agent with sub-agents detaches just its
  own tab (the sub-agents stay, promoted). The sidebar's tab and agent rows
  and a split's pane menu offer Detach (Detach Pane) beside Close. Every
  detach, an idle shell's too, shows the window's toast ("<name> is running
  in the background", with Reopen), and the session counts as told for the
  launch notice (`SessionBackendPolicy.sessionDetached`). ⌘Z undoes it
  (below).
- Both shortcuts are taken by `AppShortcutMonitor` before the terminal sees
  them (Ghostty's own ⌘D and ⌘⇧D would split its surface); ⌘⇧D arrives with
  its characters shifted ("D"), and Caps Lock (like the keypad and function
  flags) does not count as a held modifier.
- A user's close that would stop a program at work (an agent, a running
  command, or a terminal whose host or PTY reports a job in its foreground;
  an idle shell never asks: a native terminal Ghostty cannot see at a
  prompt, as with a shell without its shell integration such as macOS's
  bash 3.2, counts as busy only while the PTY's foreground process group is
  not its shell's, `ShellProcessController.nativeShellHasForegroundJob`)
  asks one question first, a sheet on the window:
  "Close “<name>”?", "<program> is running. Closing the tab stops it."
  (the program is "This agent", a command's command line, a terminal's
  foreground job as its host reports it, or "A program"), with **Close**
  (destructive), **Detach Instead** (only for a tab that can detach) and
  **Cancel** (`TabCloseQuestion`, `ProjectWindowChromeState.pendingTabClose`,
  `TabCloseAlertPresenterView`). It is the only dialog a tab close shows:
  it replaced "Close agent?" and ⌘W's "Close window?" for a last tab, and a
  second close while it is up asks nothing more. An agent with sub-agents
  asks "Close Agent Group?" instead (Close Parent and Sub-Agents, Close
  Parent Only, and Detach Parent and Sub-Agents when they can all detach),
  and Close Split Group… asks as before, adding Detach Instead when every
  pane can detach and the close would stop one. MCP `close_process` never
  asks and ends the session.
- On a window's last tab (no other worktree of the window has tabs), ⌘W
  and ⌘D close (or detach) the tab, after its question if any, and then
  close the window, which has nothing left to ask about; they do not close
  the window with the tab in it, which would ask whether to keep its
  session. After the question, the window closes once its sheet has gone
  (`SessionCloseCoordinator.performClose`: `NSAlert` answers while the sheet
  is still attached, and AppKit ignores a close meanwhile), unless a tab
  came to it.

Undoing a close or detach (`ClosedTabHistory`):

- **⌘Z** (Edit › Undo, which then reads "Undo Close Tab" or "Undo Detach
  Tab", "Tabs" for a group) brings back what a close (⌘W, Close, a question
  answered Close or Detach Instead, Close Split Group…, "Close Agent
  Group?") or a detach (⌘D, Detach) just took out of a window that stays
  open: each tab where it was (its place in the sidebar, its pane in its
  split, which is made again when the close left one pane), with the same
  tab id, kind, title, agent and command, and the sub-agents its close
  promoted back under it. It attaches to the same session again, with no
  new Create: this app's own session becomes the tab's own again, and a
  session the tab did not own is attached again. Several closes come back
  latest first, then the one before, and so on. Redo (⌘⇧Z) is not offered.
- Each close can be undone for as long as its toast would stay: 6 s (30 s
  while VoiceOver runs), its time stopped while the pointer rests on its
  toast (then at least 2 s more) and while its window is not key in the
  active app. A close whose sessions end with it waits for its window for a
  minute at most (`ClosedTabHistory.longestUnattendedWait`), then its time
  runs anyway: its programs keep running until it ends, and nothing shows
  them meanwhile. Each keeps its own time: a newer toast replacing its toast
  leaves it as it is. Once that runs out it drops out of ⌘Z.
- A close's toast says "Closed <name>" ("Closed N tabs") with **Undo**
  (⌘Z). A detach, or a close that leaves a program at work running in a
  session the tab did not own, keeps its "is running in the background"
  toast, whose **Reopen** does what ⌘Z does while the undo lasts (and, once
  it ran out, what it did before). These toasts, like the undo, wait while
  their window is not key.
- Until then a closed persistent tab's session is not ended: ⌘W (a
  confirmed "Close “<name>”?" too, as Ghostty does) stops only the tab's
  attach adapter, and the session ends as any close ends it (Kill, then
  Remove; only Remove for a program that ended) when the undo runs out,
  and at once when its window closes or Cherry quits (a quit that keeps
  sessions then takes its slow path to end them). Meanwhile nothing else
  takes it: Background Sessions, the launch notice, orphan adoption and
  Persistent Sessions treat it as being ended (the sheet marks it "Ending"
  and does not attach it, `BackgroundSessionsModel.isEnding`); ⌘Z brings
  the tab back as its session's own even if another tab attached to it. It is recorded in
  `sessions-to-end.json` when its tab closes, and dropped once it ended or
  the close was undone, so a launch after Cherry exited without ending it
  ends it.
- Not undoable, and ending at once as before: native tabs (their program
  stops with the tab), MCP `close_process`, a clean-exit close
  (`programExited`), a worktree removal, a window close or quit, a ⌘W or
  ⌘D that closes the window with its last tab (its toast goes to another
  window, whose Reopen still brings a detached session back), and a
  persistent tab whose Create was still under way. A command tab does not
  come back once its command was started again in another tab (a command
  runs in one tab per workspace): a closed one's session then ends, and a
  detached one's stays in the background.
- ⌘Z goes to the closed tabs only while no text view has the keyboard: the
  terminal, the sidebar or any other view. In a text view (the notes
  editor, a search, name or palette field) ⌘Z and Edit › Undo are its own
  text undo, as before; closed tabs never join it. ⌘Z never reaches the
  terminal program, and with nothing to bring back it beeps.

Quit and window close ask at most one question. When local persistent tabs
(not native tabs, not tabs attached to a session they do not own) have a
running program, a Create under way included, and *on quit* is Ask, a sheet
asks "Keep N sessions running in the background?": **Keep Running** (the
default, Return) closes with `windowClosed`/`appQuit`, **End Sessions**
(destructive) with `windowClosedEndingSessions`/`appQuitEndingSessions`, and
**Cancel** closes nothing. It lists up to five of them (busy ones first,
marked "(running)", by their sidebar names and their project, or worktree
when a window has tabs in several), and names the native programs that stop
either way ("N other running processes will be stopped"), so the "Quit
Cherry?" or "Close window?" confirmation never follows it. A window's
question also says where the kept sessions are until the project opens again
("Until then, open or end them from Background Sessions in the Cherry menu
bar icon"), and those sessions are ones the user knows about: the launch
notice below never names them, nor those of a window closed while *on quit*
is Keep Running, nor a detached tab's.
**Don't ask
again** stores Keep Running or End Sessions as *on quit*; Cancel stores
nothing. With *on quit* Keep Running or End Sessions, or with no running
session, nothing is asked about sessions: "Quit Cherry?" / "Close window?"
asks only when the close stops a busy program (with End Sessions, busy
persistent tabs count). Ended persistent tabs never cause the question; they
follow *on quit* (Ask keeps them, showing their exit next time). End
Sessions also ends the sessions of the window's (or every window's) saved
tabs that no open tab shows, as a worktree removal does (below), so none is
left running unseen; so does *on quit* = End Sessions, also for a quit with
no open persistent tab (`SessionTeardownSummary.savedSessionsNotOpen`,
`SessionQuitPlan`). The quit sheet goes where "Quit Cherry?" goes, and a
window's on that window. A window closed without its confirmation
(`window.close()`) follows *on quit*, keeping when it would ask. A window
whose close is decided leaves the screen before its tabs are torn down
(`ProjectWindowCloseDelegate.takeOffScreen`: ordered out, or made
transparent while its question's sheet is still going away), so it
disappears at once. A user quit
while a window's own question ("Keep N sessions…?" or "Close window?"), or
a question of a close of its tabs ("Close “<name>”?", "Close Agent Group?"),
is up is cancelled and that window brought forward: its answer decides
those sessions, and a quit question queued behind it would list them
still.

Quits that never ask about sessions and end none themselves: a log out,
restart or shut down (the quit Apple event's `kAEQuitReason`, or a quit
Apple event without one within 5 minutes of
`NSWorkspace.willPowerOffNotification`; ⌘Q and menu quits send no event, so
an announcement never makes them count), after which the system ends the
sessions with the user's processes, so their busy programs are confirmed with
the native ones in "Quit Cherry?" (`decide(systemEndsSessions:)`; Cancel
cancels the log out); an update
(the app bundle on disk has another `CFBundleVersion` than at launch, as
`Scripts/install-local-app` and `Scripts/package-dmg` stamp every build, or
`CherryAppDelegate.terminateKeepingSessions()`); and SIGTERM, SIGKILL, Force
Quit or a crash, which run no Cherry code. A second copy of the app has no
persistent tabs to ask about. With `sessions.persistLocal` off new tabs are
native, but tabs restored as persistent sessions still ask (so *on quit*
stays editable), and a duplicate window's teardown always detaches.

With *close on exit* on, a terminal tab whose own shell exits by itself with
status 0, after running at least a second (`cleanExitMinimumRunTime`,
counted from `programStartedAt`: when its session's Create answered or it
fell back to running natively, not when the tab asked; a restored tab counts
from its restore), closes as `programExited` on
the next main-loop turn, as most terminals close it. `exit` ends a shell
with its last command's status, so after a failed command the tab stays. On
the window's last tab the window closes too, as with ⌘W, without asking
(nothing runs); with no window, while a sheet is on it, or while it shows a
note (⌘W would close the note), the tab stays.
Non-zero exits and signals, command and agent tabs, attached tabs, a stop or
restart (MCP `stop_process` included), and a shell that ended within its
first second keep the tab, showing how it ended. Native tabs follow the same
rule, but their launches go through login(1), which always exits with status
0, so a native terminal tab closes whenever its shell ends (after its first
second); Settings › Sessions says so while persistent sessions are off or
the local host cannot run them. MCP reports `terminal_not_found` for a closed
tab's `process_id`; a `wait_for_process_idle` under way returns `exited` with
the lines the tab showed last (`TerminalSession.keepContentAfterClosing`).

Background sessions: this app's own local sessions (its identity, `owner`)
that no open tab shows, running or ended. They come from a window closed
keeping its sessions, a detached tab (⌘D), a command tab
a restore set aside (another tab runs that command), a Create that answered
after a detaching close, and an orphan of a project whose window is not open.
The Cherry menu bar icon's panel lists them under **Background sessions**,
below the agents and in the same scrolling list: the command's or agent's
name (or the session's), the project, and `idle`, the foreground program of a
busy terminal, `running`, `attached` or `exit N`. Clicking a row shows it in a
tab: its project's window opens (or is focused), and that window's restore
brings a closed window's session back with its sibling tabs and layout; a
session no saved tab names is adopted into its worktree as the tab it was
started for (same tab id, kind, agent and command), or attached when another
client shows it. Hovering a row offers **End**, then **End Session** (a
second click, inline: an alert would close the panel); an ended session
offers **Remove**; the inline confirmation ignores clicks for 0.45 s, so a
double click on **End** is not a yes. A terminal whose shell exited with
status 0 is removed instead of listed while *close on exit* is on (its tab
would have closed, and its window's restore removes it too). **Cherry → End
Background Sessions…** (disabled when there are none), the panel's **End
All…** and Settings › Sessions' **Background Sessions** card end them all
after "End N background sessions?" (**End Sessions**, destructive, and
Cancel; "Remove N ended background sessions?" when none runs), shown on the
Settings window when asked there, else where the quit confirmation goes,
never on the panel; only the sessions still in the background when it is
answered end. Ownerless sessions (`cherry new`, the sheet's **Create &
Attach**), other identities' and SSH hosts' sessions are never listed or
ended there; File › Persistent Sessions keeps managing them, and marks this
app's sessions "In a tab", "In the background" or "This app". When Cherry
opens, once its windows restored their tabs, a toast at the bottom of the
first project window names the background sessions at work (an agent, a
command, or a terminal whose host reports a foreground job; never an idle
shell) that it has not told about: "3 sessions are still running in the
background", "From tabs or windows you closed (<projects>). Open or end them
from Background Sessions in the Cherry menu bar icon.", with **Reopen**
(each session back in a tab of its project's window, as Background Sessions
→ Open does), **End…** (the End Background Sessions confirmation for those
sessions only) and dismiss. Its time runs only while that window is key in
the active app, and it takes turns with a closed tab's toast: it waits for
one on screen to go, and one shown over it sets it aside until that one
goes. Sessions the user kept on purpose count as told already: a detached
tab's, a window's closed with Keep Running or while *on quit* is Keep
Running. So do those a notice
named once its toast is dismissed, runs out its time or is acted on. Those
that went to the background without a choice (orphans, a Create that
answered after its tab closed, a command a restore set aside, a window closed
without its question) are named. *background notice* turns it off.

A bell or notification of a background session is posted as the app's own
notification, naming the session and its project ("<name>", "<project> · in
the background", the program's text, "Terminal bell" for a shell's bell or
"This agent may need your attention." for an agent's), and clicking it opens
the session as **Open** does. A session's bell is posted once, then only
marks it unread until it is opened; its notifications at most every 10 s;
and at most 6 a minute are posted for all background sessions together (the
others only mark their sessions unread). One
that arrives while an open tab may still follow the session (its Create
answer or its window's restore is still to come) waits 30 s for that tab and
is posted then if none took it. The session's row shows a blue dot, and the
tab that shows it next (Open, a restore, the Persistent Sessions sheet)
comes up unread (`Workspaces/unread-sessions.json`, which also brings the
list's dots back at the next launch); a tab's unread dot is also saved with
it, so a restored or reopened tab keeps it. The panel's
**Clear Ended** removes every ended session in the list at once (nothing
asked: nothing runs). An ended session the list has shown for 10 minutes
of time Cherry was active (in front, the Mac awake: refreshes more than 5 s
apart do not count) that no state file names (any project's, open window
or closed, and set-aside `.bak` copies) is removed by itself; one a closed
window's saved tab names stays for that window's restore, which shows how
it ended. One marked unread, or whose host crashed, is never removed by
itself. Both removals are recorded as
ends on purpose, like **End**. Settings › Projects › **Remove Project** for
a project with background sessions asks "End the N background sessions of
“<project>”?" (**End Sessions**, **Keep Running**, Cancel) first. A session
belongs to the registered project its worktree's repository is, else to the
longest registered root that contains it, so a project nested in the one
removed keeps its sessions.

The name a tab has reaches its session's host (`Update`): an explicit rename
at once (clearing it sends the tab's name again), and an agent's task title
once it has not changed for a second; `cherry list`, Background Sessions and
File › Persistent Sessions show it. That sheet's rows say what each of this
app's sessions is: its kind (Terminal, Agent: <agent>, Command: <command>),
its project and what it does now (the program in a shell's foreground, else
the title its program set). For a session a tab already shows, in any
window, the sheet offers **Show Tab** instead of Attach.

A tab whose session other clients show too (a `cherry attach` in another
terminal) has a slim bar at its top: "Also open in N other clients", or,
while its adapter shows a viewport because another client is smaller,
"Shown at C×R because another client is smaller", with **Take Over**
(`reconnectHostedSession(takeover:)`: the others are disconnected and the
session follows this tab's size). Its sidebar row shows a shared glyph.

Quit/close confirmations use the host-reported foreground process for hosted
tabs (busy = foreground process group differs from the session leader's, or the
tab is a running command/agent), exactly as native tabs use their PTY today.

Relaunch: each project window restores its saved tabs (same tab UUIDs, kinds,
titles, split layout, selection). Hosted sessions that still run are reattached;
exited ones show "Session ended (exit N)" with Close/Remove, except that with
*close on exit* on, a terminal of this app whose shell exited with status 0
is not restored and its session is removed. Missing ones are dropped, except
this app's own sessions that the system ended while Cherry was closed (a
restart, shut down, crash or power loss of the Mac, or a log out): their tabs
come back in their places (order, splits, agent tree, selection) as ended
tabs with their kind, title, agent, command and last directory, saying "Ended
when the Mac restarted" or "Ended when you logged out", with **Restart** (a
new session in the tab's directory with the same launch: the shell, command
or agent started fresh; no conversation is resumed) and **Close**; the window
opens no default shell for them, and a toast in each such window says "N tabs
ended when the Mac restarted" with **Restart All**. Tabs whose sessions this
app ended on purpose stay dropped. See "Sessions the system ended" under
[App: persistence and restore](#app-persistence-and-restore) for the rule.
Native tabs are not restored (their processes are gone), except that
auto-start commands start as today. Windows that had tabs reopen even when
macOS window restoration is off.

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
after a mismatch; since protocol 7 it may add `build`, which every version
ignores), `Replace`, `Ok`, `Error{code, message}`.

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

What exists on `codex/persistent-sessions` (2026-09-27), and where it
differs from the design above.

### Host and protocol

- The daemon (`cherry-host serve`) and one holder per session
  (`cherry-host hold --socket …`, link on fd 3, never the daemon's child) are
  implemented as designed. The holder link is at `LINK_VERSION` 7, and a
  daemon speaks every version from 1. Beyond the frames listed above it has
  `Launch` and `Failed` (Create goes through the holder), `Update` (rename /
  retag kept by the holder), `Info` (title/pwd/foreground, from version 3
  `alternate_screen` and `kitty_keyboard_flags`, from version 4
  `application_cursor_keys`), `ScreenReply` (from version 3,
  `SCREEN_LINES_VERSION`, `Screen` carries `max_lines`) and `Refused` (a
  daemon that will never serve a holder, with `retry`). All of them are
  additive; version 4 adds only `application_cursor_keys` (in `Info` and
  the hello's session), and version 7 adds `bracketed_paste` there (left
  out by older holders, which the daemon then reports as unknown), the
  daemon-to-holder `ClearHistory`, and `Launch.colors`. On Linux a daemon starts holders from its own image
  (`/proc/self/exe`); on macOS from its executable's path, which after an
  app update is the new build, so `Launch` fields are additive too.
- A crashed holder reports its session exited with code 1, and says why:
  `ended_by: "holder_lost"` on `SessionInfo` and the `exited` event, with
  `holder_log` (the daemon's `host.log`, where holders' stderr goes, when
  the daemon's stderr is that file). The app shows "The session host
  crashed (see <log>)" instead of "Session ended (exit 1)", `cherry list`
  says "Exited (the session host crashed)", and a command that restarts on
  exit is not restarted by it (its bar says "…; not restarted", with
  Restart). The daemon then ends the program the holder left behind: once
  the holder process is gone (up to 2 s; one that only lost its link dials
  again and is left alone), SIGHUP to every live process in the program's
  session (it runs under `setsid`, so its jobs are included), SIGTERM after
  the kill grace, then SIGKILL, on a thread of its own; nothing is sent when
  the leader's pid now belongs to another process (its start time
  differs). A holder that panics logs one line first (the session, pid, UTC
  time and build: package, link and protocol versions and its executable),
  then the default report. Exited sessions
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
- A daemon that starts drops the manifests of holders that are gone (a
  holder that exits removes its own, so such a holder was killed: a log out
  or restart kills them all while no daemon runs) and lists their sessions in
  `Sessions.lost_sessions` (sorted, left out when empty, for the daemon's
  lifetime). A session ended on purpose (Kill, Remove, its program's exit)
  never appears there. An optional field: `PROTOCOL_VERSION` did not change,
  and an older host sends none.
- `SessionInfo` gained `alternate_screen` and `kitty_keyboard_flags` (the
  active screen's), `application_cursor_keys` (DECCKM, mode `?1`, which
  libghostty keeps terminal-wide, so a screen switch does not change it; it
  selects `ESC O x` for unmodified arrows, Home and End only in legacy key
  encoding, as the kitty encoding sends them as CSI whatever DECCKM says),
  `bracketed_paste` (protocol 7: mode 2004, `None` and left out for a
  session whose holder predates link version 7), and `request_id` (the
  Create's, from the receipt the holder keeps). The
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
- Protocol 7 (additive; the version changed so that an updated app
  replaces a daemon that does not know the new requests): `ClearHistory{id}`
  clears the history above a session's screen on its holder, as ED 3 at the
  offset read so far (`Terminal::clear_history` keeps an unfinished escape
  sequence), so `Screen` and later attachments no longer show it
  (`unsupported_operation` for a holder older than link 7); `Create.colors`
  (`#rrggbb` foreground, background and optional cursor, and `dark`), which
  the holder's terminal reports for OSC 10, 11 and 12 and `CSI ?996n`
  instead of light grey on black, dark (not part of the retry
  fingerprint); `SessionInfo.bracketed_paste`; and `Restart`, which makes
  the daemon stop as for `Replace` whatever sessions run, so `cherry restart`
  can start this build's daemon after an update of the same protocol
  replaced or removed the running one's executable.
- **Builds and diagnostics.** Every cherry and cherry-host carries a build
  id (`cherry_protocol::BUILD`, set by `crates/cherry-protocol/build.rs`):
  `CHERRY_BUILD_ID` at build time when set (Scripts/install-local-app passes
  the app's CFBundleVersion, `<YYYYMMDDHHMMSS>.<revision>`), else a
  development build, `dev-<commit time>.<revision>` (or `dev-<package
  version>` outside git). `--version` prints it (`cherry-host 0.1.0
  (build …)`; a daemon's stand-in build under `CHERRY_HOST_TEST_BUILD`). The daemon sends it in `Welcome.build` (the one field added
  to the frozen Welcome; every version ignores it), and each session
  reports its holder's in `SessionInfo.holder_build` (from the holder's
  hello and manifest; None for a holder older than the field): a holder
  keeps the code it started with when the daemon is updated. Builds order
  by their time (`build_is_newer`), and only builds given an explicit id
  have one: two builds of the same time, or a development build, are
  neither newer nor older than any other. `CHERRY_HOST_TEST_BUILD` makes a
  daemon (and the holders it starts, and its `--version`) report another
  build, and `CHERRY_TEST_BUILD` makes the CLI act as one, for tests.
- `Status` (protocol 7, additive; an older host of the same version answers
  `unsupported_operation`) answers `HostStatus`: identity, version, build,
  pid, start time and uptime (on the clock that stops while the Mac sleeps),
  socket, state directory, log path (when its stderr is `host.log`), its
  executable and whether an update replaced or removed it since it started,
  sessions (running) against `MAX_SESSIONS` (128), connections against
  `MAX_CONNECTIONS` (1024), holders registered and still expected, lost
  sessions and its descriptor limit.
- The daemon writes `host.pid` in its state directory (JSON: pid, its
  start identity (`processes::start_identity`), build, start time, socket)
  once it holds the lock, and removes it when it exits normally. Its log lines and its holders' say when, who and which build:
  `2026-09-27T10:15:00.123Z cherry-host[1234] daemon <build>: <message>`
  (`holder` for a holder); other roles (`start`, the gateway) still write
  `cherry-host: <message>` to the terminal or client that ran them, which
  the CLI's stderr relay reads. A daemon logs a startup line (protocol, pid,
  socket, state, holders expected, sessions lost, descriptor limit).
  The daemon moves `host.log` aside to `host.log.1` (replacing an older
  one) when it is over 8 MiB, only while it holds the state directory's
  lock: when it starts, and every minute while it runs
  (`CHERRY_HOST_LOG_MAX_BYTES`, `CHERRY_HOST_LOG_CHECK_MS` for tests, which
  `cherry-host start` passes on). It then writes to a new `host.log`, and so
  do its holders: a daemon or holder whose stderr is the log reopens
  `host.log` (append) before a line when the name no longer names the file
  it writes to (`reopen_if_moved`), so nothing writes to `host.log.1` once
  it has logged again, and the moved copy is not moved a second time while
  one does.
- The holder's terminal matches the tab's Ghostty: grapheme clustering
  (2027) is on by default (`GHOSTTY_TERMINAL_OPT_MODE_DEFAULT`, so RIS keeps
  it), snapshots set 2027 on or off before their content, and `modes()` and
  `refresh()` send it only when the session turned it off. The session's
  PTY has IUTF8 set.
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

- `cherry restart` (local only) first finds the cherry-host it will start
  (`CHERRY_HOST_PATH`, beside `cherry`, or on `PATH`; not a translocated or
  read-only copy) and refuses, leaving the host running, when there is
  none; then it sends `Restart` and starts that daemon, which adopts the
  running sessions from their holders.
- **Same-protocol updates hand over by build** (`cherry-cli/src/handover.rs`).
  Locally, `list`, `new` and `control` (the app's control helper), never an
  attachment, send `Restart` and start their cherry-host, once per
  connection, when all of these hold: the daemon's `Welcome.build` is
  older than this cherry's build; the cherry-host to start (as `cherry
  restart` finds it) says with `--version` a build newer than the daemon's;
  that cherry-host is the daemon's own executable (the same file as
  `HostStatus.executable`), or the daemon reports it replaced or removed;
  no systemd user service manages the daemon (Linux); and no handover
  between the same two builds came back within the last hour with a
  replacement that was not newer (another client of the old build started
  the next daemon first), which `handover.json` in the state directory
  records. So an app update gets new daemon code, sessions carry on in
  their holders (which keep their builds), a development build (CherryDev,
  `swift run Cherry`) never takes over the shared daemon, and clients of
  two builds never take turns restarting it. A refusal is reported on
  stderr and the connection goes on. The gateway does not do this for a
  remote host (see Not done yet).
- `cherry status [--json]` never starts a host. It prints the daemon's
  `Status` (a host that predates it: its identity and sessions only), this
  cherry's build, and each session with its holder's build; `--json` has
  `running`, `build`, `host` (the `HostStatus`), `sessions` (id, name,
  state, pid, exit code, clients, owner, created at, `holder_build`) and
  `client`. With no host running it prints so (JSON: `running: false`,
  `socket`, `state_dir`, `log_path`) and exits with status 3. It works with
  `--host` through `gateway --no-start`.
- `cherry doctor` (local only, never starts a host) checks this cherry and
  the cherry-host it would start (a translocated or disk image location, a
  missing one, another build), the socket directory and socket (owner,
  mode, a stale socket nothing listens on, one another account serves, a
  listener that does not answer), the daemon (protocol and build against
  this cherry's, an executable that was replaced, removed or runs from a
  disk image, its descriptor limit against its connection limit, the
  session and connection limits), the state directory, `host.pid` (stale:
  its pid gone or, by its start identity, now another process's; or
  naming another process than the one serving), the log's size (over
  64 MiB), and, with no daemon running, holders whose manifests name live
  processes (sessions with no host; a manifest whose holder is gone is only
  noted: the next daemon reports it lost). Each finding is `ok` or
  `PROBLEM` with a `fix:` line; it exits with status 1 when it found a
  problem.
- The status file's final `disconnected` or `failed` outcome says
  `"reconnectable": false` when connecting again can never resume the
  attachment (another identity, a protocol this cherry cannot use or
  replace, a session the host no longer has: the `Unresolvable` failures
  and an Attach refused with `unknown_session`); the reconnection keeps the
  error's kind so that this is known.
- A negotiated connection answers a JSON request the host cannot decode
  (an unknown `op`: `unsupported_operation`; fields it cannot take, such as
  a colour that is not ASCII `#rrggbb`: `request_failed`) with an `Error`,
  with its `req`, and carries on; before protocol 7 it closed the
  connection unanswered.
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
  bytes after them were not sent. A lost answer to input of at most 64 KiB,
  or to the first part of longer input (`HostedSessionError.transport`), is
  `input_maybe_delivered` ("… was sent, but its host's answer was lost, so it
  may or may not have reached the program"); `input_not_delivered` still
  means nothing was sent.
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
- A session's name is the tab's name at its Create, then whatever the tab
  sends with `Update` (`PersistentLocalSessions.rename`, cut to 256 bytes):
  an explicit rename (`TerminalSession.rename`) at once, and an agent's
  automatic title (`titleSource` `.automatic`) 1 s after its last change
  (`hostSessionNameDelay`); a title the program set for a shell is not sent.
  A tab bound to a session whose host name differs from the name it was
  given (renamed while its Create was under way, or while Cherry was
  closed) sends it once bound. A failed `Update` is logged; the next rename
  sends it again.

- **Session host diagnostics.** Settings › Sessions has a "Session Host"
  card (`SessionHostDiagnostics`): the local host's status from `cherry
  status --json` (running, build, uptime, sessions against the limit,
  connections, sessions whose holder runs another build, pid), read when
  the pane opens; Reveal Log (the daemon's `host.log` in the Finder); Copy
  Diagnostics (the app's version, then what `cherry status` and `cherry
  doctor` print); and Restart Host… (`cherry restart`, after an alert that
  says running programs keep running and tabs reconnect). Where local
  sessions cannot run (a disk image copy) it runs nothing and says why. The
  app's session diagnostics (the tab and session messages it wrote to
  standard error) go to the unified log (`SessionLog`: subsystem the bundle
  identifier, category "Sessions"; the `CHERRY_DEBUG_*` traces at debug
  level, and what was typed or printed in them as private data:
  `SessionLog.debugContent`).
- **SSH tabs wait for their host.** A tab attached to an SSH host's session
  whose adapter ended `disconnected` (it gave up reconnecting after its 30 s
  window) or `failed` (it could not attach: ssh could not reach the host),
  unless the status file says `"reconnectable": false`, waits for its host
  (`HostedReconnects`, the workspace policy's `hostReconnects`; workspaces
  without it, as in most tests, leave such tabs disconnected). Waiting tabs
  are grouped per host: each group is probed with one `HostControl.list()`
  (one control connection, however many tabs wait) after 0.25 s, doubling
  to 8 s (`PersistentLocalSessions.Configuration.reconnectDelay`, as local
  persistent tabs), starting over once a tab of that host attaches again,
  and at once, starting over, when the Mac wakes
  (`NSWorkspace.didWakeNotification`), when NWPathMonitor reports a
  satisfied path after it was not, or on Retry Now. Once the host answers,
  each waiting tab whose session it lists launches its adapter again
  (`reconnectHostedSession`); a tab stops waiting, with the reason as its
  status (`.failed`), when another identity answers, the host speaks a
  protocol this app cannot use, or it no longer lists the session (and
  expects no more holders). A detach, a takeover, a replacement, an exit,
  or the tab's own stop, disconnect, reconnect or close never waits or ends
  the wait. A probe that SSH could not sign in for ("Permission denied",
  "Host key verification failed", a changed host key, too many
  authentication failures: `HostedSessionError.isAuthenticationFailure`)
  stops the timer for that host (`pausedReasons`, shown on the bar's help)
  until a wake, a network change or Retry Now, which try once more: each
  probe is a login, and repeated failed logins can get the address
  blocked. The tab's connection bar says "Waiting for the host to answer…"
  (with Reconnect), and a bar over its pane says "3 tabs waiting for
  devbox" with Retry Now. The wake and network triggers also make a leased
  `HostControl` waiting to reconnect try at once (`reconnectNow`).
- A restore that cannot reach an SSH host keeps its records (as before)
  and now also restores them once that host answers during this run:
  `retryWhenAvailable` is `HostControl.availability()`, which leases the
  host's control connection (so it reconnects with its backoff, and at once
  on a wake or a network change) and fires once it is connected. A host
  that answers with another identity, or speaks a protocol this app cannot
  use, is not waited for; `availability()` completes without firing, and
  releases its lease, once the connection fails for good. A leased
  `HostControl` treats a protocol mismatch as permanent (`.failed`, no
  reconnect), and after a refused SSH login waits in
  `.waitingToReconnect` without a timer until `reconnectNow` (a wake, a
  network change).

### App: hosted-by-default tabs

- `PersistentLocalSessions` runs new local tabs in the local host when
  *Run local terminals as persistent sessions* is on and the host can run
  them. Otherwise, and for 30 s after the host could not start a session,
  tabs run natively and Settings › Sessions says why. A tab whose session is
  not created within 14 s (`creationTimeout`, longer than the host's 10 s
  wait for a new holder, so a holder that fails to start is reported by the
  host's rejection) runs natively, and a session created after that is
  ended. A tab that runs natively because the host rejected its Create (the
  128-session limit, a holder that failed to start, a daemon whose
  executable was removed) or did not answer in time says so in a bar at the
  bottom of its pane ("Not a persistent session: <reason>", with Retry;
  `PersistentSessionFallbackBar`, `TerminalSession.persistentFallbackReason`),
  and Settings › Sessions shows the latest such reason
  (`PersistentSessionsStatus.lastLaunchFailure`) until a session starts
  again. The tab keeps its host (`persistentFallbackHosting`): Restart, or a
  command's restart, runs it in the host again once the host takes new tabs,
  and Retry does at once (`retryPersistentSession`).
- A session adopted from the Persistent Sessions sheet
  (`TerminalWorkspace.attachHostedSession`, and a toast's Reopen of a
  session its tab did not own) gets the record its tags give
  (`OrphanedSessionCriteria.record`, title source `.system`) and is built by
  `makeRestoredPersistentSession`, as Background Sessions › Open and the
  orphan scan do: an agent stays an agent (MCP's permission-prompt guard
  applies) and a command keeps its command, and the next save keeps them.
- A Create carries the app's terminal theme for the appearance it shows
  (`PersistentLocalSessions.appTerminalColors`,
  `TerminalSettings.hostTerminalColors`), so a program that asks for its
  terminal's colours or appearance sees the tab's.
- ⌘V typed while a persistent tab's adapter is away is bracketed as the
  host reports the program's mode (`TerminalSession.bracketsPaste`,
  `usesBracketedPasteMode` prefers the host's `bracketed_paste` for hosted
  tabs). When the host cannot tell (a holder older than link 7), a paste
  with a line break is bracketed anyway, a trade-off: programs at a prompt
  turn the mode on, and an unbracketed paste would run there line by line,
  but a program that did not gets the markers as input (`cat > file` writes
  them, a vi-mode line editor takes the ESC as a key); a single line goes as
  it is. Pasted text never carries ESC or the other bytes Ghostty's paste
  encoder replaces with a space (NUL, BS, ENQ, EOT, DEL and the line
  discipline's control characters), so a paste cannot end its own bracket
  with `ESC [ 201 ~`. (Holding the paste for the adapter was rejected: it
  would arrive later, after whatever the user typed meanwhile, and the
  surface learns the mode only from the adapter's repaint.)
- Clear Scrollback (⌘K) and MCP `clear_output` on a persistent tab also send
  `ClearHistory`, and forget the screen read from the host; `clear_output`
  answers once the host did, so MCP output and search read after it no
  longer have the history, and neither does the next attach adapter. The
  holder answers how it went (`HistoryCleared`): `clear_output` says
  `cleared: false` with the host's reason (`hostKeptHistory`) when the
  alternate screen shows, the holder predates link 7, is not connected, or
  failed. A UTF-8 character the output left half written is never broken:
  the holder's erase then waits for the output that completes it.
- The daemon runs Creates one at a time, so a tab waits for its session
  `creationTimeout` once for itself and once for each of this app's
  Creates still ahead of it (`PersistentLocalSessions.creationDeadline`). A
  host's rejection that arrives after the tab gave up replaces the
  timeout's reason in its bar.
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
  one exits. **Reconnect Now**, a sidebar Start and MCP `start_process` on a
  tab whose adapter reports `reconnecting` keep that adapter (and its
  surface) and send it SIGUSR1 (`pokeReconnectingAdapter`), which makes
  `cherry attach` try again at once, with a new 30 s window and its backoff
  from the start; only a takeover replaces it. The signal goes to the
  process the adapter's status file names (`pid`, with its kernel start
  time `started`, checked first: `HostedAdapterProcess`), never to the
  surface's own process, login(1), which does not pass it on. When the
  status names no process, the pid now belongs to another one, or the
  signal fails, a new adapter is launched as before. The app shows the reconnect
  bar once an adapter has reported
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
  waits up to 22 s, then is reported undelivered; it goes as sent, since
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
- Close intents follow the table above. The additions: closing or
  detaching a persistent tab whose program already ended removes its
  session. A user's close asks "Close “<name>”?" only when it stops a
  program at work (`SessionCloseCoordinator.closeAsks`; attached tabs never
  ask), through the window's chrome state (without one, as in a test with
  no window, it closes at once); the answer closes, detaches instead or
  keeps the tab (`SessionCloseCoordinator.answerTabClose`), and a program
  that ended before the answer leaves nothing to ask (the tab closes). A
  detach, and a close that leaves the program running (a tab attached to a
  session it does not own: `SessionCloseCoordinator.closeEndsProgram` is
  false), ask nothing: the tab closes at once. A detach always, and such a
  close when its program was at work (a command or an agent, or a terminal
  whose host reports a foreground job), show
  a toast at the bottom of the window that says "<sidebar name> is running
  in the background" (only the name is cut short to fit) and "Open or end
  it from Background Sessions in the Cherry menu bar icon." ("Attach to it
  again from File › Persistent Sessions." for a session the tab did not
  own), with **Reopen** and a dismiss button (`ClosedTabNotice`). Any other
  close that ⌘Z can undo (an idle shell's too) shows "Closed <name>" with
  **Undo** instead (see Undo below); a native tab's close shows nothing.
  While ⌘Z can still undo it, Reopen is that undo; after that, Reopen brings a session back where its tab was: this
  app's own session the way Background Sessions → Open does
  (`ProjectWindowRegistry.showBackgroundSession`: its project's window,
  adopted with its tab id, kind, agent and command), and a session the tab
  did not own attached again in the worktree it was closed from
  (`ProjectWindowRegistry.workspaceOpeningWindow`); either opens that
  project's window again when it closed with its last tab. A session of
  This Mac that is gone brings nothing back. On a window's last tab the
  window closes too, and the toast goes on the project window that was
  active last and is on screen (not minimized), when there is one. A window
  shows one toast (`ProjectWindowToasts`; a new one replaces it, except
  that the launch notice's unprompted toast waits for the one shown to go,
  and one shown over it sets it aside, to come back with the time it had
  left once that one goes), at the
  bottom of its detail pane where the pane's bottom bars (command exited,
  reconnecting, program ended) sit, and above any of them it would cover
  (`ProjectWindowToastObstacles`). It dismisses itself after 6 s on screen
  (30 s while VoiceOver runs; the launch notice's `.long` toast 12 s, 60 s
  with VoiceOver, with its two buttons under its text), not counting the
  time the pointer rests on
  it (at least 2 s once the pointer leaves; AppKit may not say the pointer
  left, so a paused toast looks each second whether it is still there) nor,
  for the launch notice's unprompted toast (`isUnprompted`), the time its
  window is not key in the active app (`ToastAttentionProbe`: AppKit's key
  and active notifications, a look each second while paused and one more
  before its time runs out), is
  announced to VoiceOver, never takes the keyboard from the terminal, and
  slides in (only fades with Reduce Motion). The sidebar's Close and
  Detach for a terminal tab or split pane go the same way. Tabs closed or
  detached together get one toast, "N tabs are running in the background"
  when more than one runs on, whose Reopen brings each back as a tab: Close
  Split Group… (whose confirmation says which panes' programs stop and
  which keep running, and offers Detach Instead) and "Close Agent Group?"'s
  Close Parent and Sub-Agents, Close Parent Only or Detach Parent and
  Sub-Agents. MCP `stop_process` reports a clean `exit 0`. New MCP errors are
  `process_not_accepting_input`, `input_not_delivered`,
  `input_partially_delivered` and `agent_awaiting_permission`.
- **Undo** (`ClosedTabUndo.swift`). `SessionCloseCoordinator.closeTabs`
  records a user's close or detach in a window that stays open: it reads
  each tab's `ClosedTab` before the close (`TerminalWorkspace.closedTab`:
  its `WorkspaceSessionRecord`, the host session it shows, whether it owned
  it, and its `ClosedTabPlacement`), runs the close inside
  `TerminalWorkspace.deferringSessionEnds`, where a `userClosedTab` of this
  app's own persistent tab stops only the adapter (its `.terminate`, or the
  Remove of an ended session, is left out), and hands those sessions to
  `PersistentLocalSessions.deferEnd` with the tab's usual end
  (`SessionBackendPolicy.terminateHostedSession`) and the app's store
  (`sessions-to-end.json`). A deferred end counts in `isEnding` (so
  `canAdopt`, `BackgroundSessions.classify`, the orphan scan and the restore
  leave it alone) and keeps the control connection leased;
  `hasDeferredEnds` makes a quit that keeps sessions take the slow path
  (`CherryAppDelegate.confirmedQuitPlan`). The window's `ClosedTabHistory`
  (`ProjectWindowChromeState.closedTabs`, on the toasts' clock) keeps an
  entry per close with its own `ToastLifetime`, paused while its toast is
  hovered (`ProjectWindowToasts.hoverDidChange`) or its window is not key
  (`ClosedTabAttentionProbe`, in the toast overlay, which is always there;
  an entry with sessions to end, `Entry.endsSessions`, for
  `longestUnattendedWait` at most);
  its toast pauses the same way (`ProjectWindowToast.pausesWhileUnattended`).
  Running out calls `endDeferred`; `endAll` ends them all at a window close
  (`ProjectWindowCloseDelegate.closeWorkspaceIfNeeded`) and a quit
  (`ProjectWindowRegistry.tearDownForQuit`, and `QuitTeardownSteps.app`
  ends any left with `endAllDeferred` before it waits). Undo (`undoLatest`,
  and `undo(_:)` for a toast's button) calls `resumeDeferred`, then
  `TerminalWorkspace.reopenClosedTab`, which builds the tab as a restore
  builds one (`makeRestoredPersistentSession` with its adapter launch
  deferred, or `makeRestoredHostedSession`) and inserts it at its
  placement; an entry whose workspace went (a removed worktree) ends and is
  skipped. Edit › Undo: the project window's delegate answers
  `windowWillReturnUndoManager` with `ClosedTabUndoManager`, a stand-in
  whose `canUndo`, `undoMenuItemTitle` and `undo()` read the history,
  unless an `NSText` or `NSTextField` is first responder
  (`ClosedTabUndoRouting`), when it returns the window's own undo manager,
  as AppKit made one before; `AppShortcutMonitor` takes ⌘Z in the same
  case, before the terminal sees it.
- **Restart.** A tab runs one launch at a time. A stop or close during a
  restart's wait for the old program to exit starts nothing. A second restart
  waits (bounded) for the first. A session created by a Create that answers
  after its tab stopped or closed is ended, and its exit is waited for,
  before the tab's next launch.
- **Detaching close during a Create.** When a persistent tab closes with a
  detaching close action while its session's Create is under way, the
  session that Create makes is kept, not ended. Detaching actions: a quit or
  window close that keeps sessions (Keep Running, *on quit* = keep, or
  nothing asked), a detach (⌘D), and a duplicate window teardown. A quit
  leaves such a tab to the exit (`keepSessionUntilExit`), which keeps it
  the same way and does not wait for its Create. The tab's saved record names the session by its
  launch request id, and the next restore brings the tab back with it. A
  stop, a restart, or a close that terminates (a tab close, a
  worktree removal, a quit or window close answered End Sessions) still ends
  a late-created session: the answer travels in the close intent, which a
  restore finishing after the close also uses.
- **Ending a session** (close, worktree removal, restart, a quit answered
  End Sessions): a Kill or Remove that gets no definite answer is resent with
  backoff (250 ms, doubling to 4 s) for up to 60 s. Only the host saying
  `unknown_session`, or another host identity answering, stops it early.
  Quit still waits at most its own bound.
- **Quit.** Its confirmation sheet (the sessions question or "Quit
  Cherry?") goes on the key window when that is a project window, otherwise
  on the active project's window, which is unhidden, deminiaturized and
  activated; never on the menu-bar panel. With no project window it is an
  app-modal alert. Closing the sheet's window before answering cancels the
  quit. A quit that keeps sessions, has no busy native program to stop and
  no session still being ended (a tab closed just before, one ⌘Z could
  still bring back, whose session the quit ends, or one closed while its
  Create was under way, whose session is ended when the Create answers:
  `TerminalSession.hasLaunchesEndingTheirSessions`) quits at once,
  whether it asked nothing or was answered Keep Running (or "Quit Cherry?"
  for a log out's busy persistent programs; `SessionQuitPlan.confirmed`,
  which counts them when answered): it saves the windows and tabs and
  tears nothing down. Idle native shells and the attach adapters of
  persistent tabs end with the app (their terminals hang up), and the
  sessions run on in their holders. A background job of an idle native
  shell that ignores SIGHUP (`tilt up &` at the prompt) therefore outlives
  that quit, as it outlives a quit that asked nothing; a job in the
  foreground makes the tab busy, and the quit then stops its process tree. Any other confirmed quit (End
  Sessions, *on quit* = end, native programs to stop, or sessions being
  ended) first orders every window out (project windows,
  Settings, sheets, panels; not the menu bar icon's), so the app looks gone
  at once, then saves and tears down only the tabs whose close does what
  the exit does not (`CherryAppDelegate.tearDownForQuit`,
  `TerminalWorkspace.closeSessionsForQuit`): native tabs are stopped
  (HUP → TERM → KILL) and persistent tabs whose sessions the quit ends
  terminate. Tabs that only detach (persistent tabs a quit keeping sessions
  leaves running, tabs attached to sessions they do not own) are left as
  they are until the exit, which also spares stopping each adapter and
  freeing each surface (about 20 ms a tab under the fake host; 30 tabs took
  0.6 s). It then waits at most 8 s for sessions being ended and for tabs'
  launches in flight whose session will be ended (so such sessions are
  ended rather than orphaned), and, only when it stopped a native tab's
  busy program (`hasRunningProcess`, as the quit counted it; an idle
  shell's hang-up is not waited for), until 900 ms after the teardown
  (`ShellProcessController.terminationEscalationDuration`), so the
  escalation's KILL (at 700 ms) goes out before the exit. It replies to
  macOS within 10 s either way. The instance lock is marked quitting
  (`noteAppQuitting`) before the teardown, so a copy launched meanwhile
  waits for this one. That wait runs off the main thread
  (`AppInstanceLock.resolveInBackground`): at launch
  (`InstanceLockLaunchWait`) the local host's warm-up, Background Sessions
  and the first windows wait for the lock, and a small window says "Waiting
  for the previous Cherry to finish quitting…" while the previous copy
  quits. A copy whose lock is taken at once shows nothing. Pruning old
  set-aside state files runs after the wait too. While it runs, nothing on
  the main thread asks the lock: a Dock click opens no window (the launch
  opens them), ⌘Q quits at once (nothing of this copy's was opened or
  saved), and `markQuitting` does nothing.
- **MCP and agents.** MCP input to an agent is checked against its current
  screen first (read from its session host when no surface shows it). While
  the screen shows a tool-permission prompt, input is refused with
  `agent_awaiting_permission` and nothing is sent; raw keys sent without
  submit still go through. `input_not_delivered` is returned when the
  agent's screen cannot be read from its host. Cherry presses Enter on an
  agent's startup or trust prompt only for an agent its tab just launched,
  never for a restored, adopted or attached agent, or on a permission menu.
  A restored or adopted agent (one its tab did not start) whose screen or
  title shows it is at work (a working marker, a title spinner) is taken to
  be in a turn submitted before the tab followed it (`agentTurnState`
  `.active`), so its end notifies as a finished turn does.
  `wait_for_process_idle` returns `permission`, and `agent_activity_state` is
  `permission`, whenever the screen shows a permission prompt. MCP client
  timeouts: `spawn_process` with kind `command` waits `wait_ms` + 30 s,
  other `spawn_process`, `spawn_agent` and `send_process_input` `wait_ms` +
  20 s; `start_process`, `start_all_commands` and `restart_all_commands`
  `wait_ms` + 20 s (they wait up to 10 s for a restore); `send_agent_message`
  max(`timeout_ms` + 5 s, 20 s). `line_count` of a restored tab whose lines
  come from the host is the host's line count.

### App: persistence and restore

- Housekeeping: at launch, state files this version set aside
  (`<file>.<label>-<time>.bak`) older than 30 days are removed, keeping the
  newest of each (`WorkspaceStateStore.pruneSetAsideFiles`). Each launch
  spec's use of the staged Ghostty resources marks that copy used (its
  modification time), and each session's Create tags it with its copy
  (`cherry.resources`, the content hash). Once per run, from the first
  complete live list (nothing while the host cannot be listed or still
  expects holders), the copies other than this build's that no running
  session names, whoever owns it, and that were last used more than 30
  days ago are removed (`GhosttyResourceStaging.staleCopies`). While a
  running session of this app names no copy (it was created before the
  tag), nothing is removed.

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
    (`Screen` with history) is shown as plain text, without colours. With
    *close on exit* on, an owned terminal whose shell exited with status 0
    (no signal) is not restored: its record is dropped and its session
    removed (Remove only, as it is not running). A tab opened for a session
    that had already ended (a restored one, or one attached from the
    Persistent Sessions sheet) never closes by itself: it was opened to
    show that exit.
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
    reset) drops it at once. Whenever a record of This Mac would be dropped
    this way, one whose session the system ended comes back as an ended tab
    instead (next bullet).
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
- **Sessions the system ended** (`SystemEndedSessions`,
  `WorkspaceRestore.swift` and `WorkspaceStateStore.swift`). A saved tab that
  owned a session of This Mac (`mayOwnLocalSession`: bound to one it owned,
  or saved while its Create was under way) whose session a list of the same
  host identity no longer has, at the moment the record would be dropped
  (a complete list, or the second look), comes back as an ended tab
  (`TerminalWorkspace.makeSystemEndedSession`) when this app did not end it
  on purpose and one of these says the system ended it:
  1. This Mac booted after an open tab last saved the record (its own
     `savedAt`, which a record kept while its host could not be listed
     keeps when it is saved again; else the file's `savedAt`; before
     `kern.boottime`, in whole seconds): "Ended when the Mac restarted".
     This covers a crash, a power loss and a forced restart, which run no
     Cherry code.
  2. Cherry quit for a log out, restart or shut down after that:
     `CherryAppDelegate.recordSystemQuit` records such a quit in
     `Workspaces/system-quits.json` in `applicationWillTerminate`, after the
     quit's last saves (the newest 32), only when the quit Apple event
     itself names a log out, restart or shut down (`kAEQuitReason`), not
     for a quit that only came within 5 minutes of the system announcing
     one: "Ended when you logged out" (a restart also moved the boot time,
     rule 1).
  3. The host lists the session in `lost_sessions` (its holder was killed
     while no daemon ran, as a log out does even while Cherry is not
     running), now or in a list this app took earlier:
     `PersistentLocalSessions` copies every lost session it sees into
     `Workspaces/lost-sessions.json`, since a daemon forgets them when it
     restarts: "Ended when you logged out".

  Without any of them (a normal relaunch, a session that ended while the Mac
  ran) the record is dropped as before. "On purpose" is any of: its session
  is being ended now (`isEnding`); its tab was in `sessions-to-end.json` when
  the window opened or is now; or its session is in
  `Workspaces/ended-sessions.json`, where `PersistentLocalSessions.end`
  records every session this app ends (a tab's close, End Sessions on a
  window close or quit, Background Sessions → End, a removed worktree, a
  clean exit's removal, a restart's previous session) and the Persistent
  Sessions sheet records Terminate and Remove of This Mac's sessions: a
  window closed or a quit with End Sessions saved its tabs before ending
  them, and a closed window's record still names the sessions ended from
  Background Sessions. Its entries never expire: each write drops the
  entries no saved state file names any more (`lost-sessions.json` is
  pruned the same way). A file that cannot be read is moved aside and the
  list starts again with `lostBefore`: a record saved before then counts as
  ended on purpose, so the loss drops tabs rather than bringing back ones
  ended on purpose. A log out, restart or shut down while *on quit* is End
  Sessions records the sessions ⌘Q would have ended (the open windows'
  persistent tabs and their saved tabs no open tab shows,
  `ProjectWindowRegistry.localSessionsEndedByAQuit`) as ended on purpose,
  so their tabs do not come back, as after ⌘Q. Records attached to
  sessions they did not own, SSH hosts' records and native tabs are never
  brought back this way.

  A record saves its program's exit (`exitStatus`) once its host reported
  the session exited (a persistent tab's exit is saved at once). Such a
  record is never taken for a session the system ended while it ran: when
  the rule above holds, it comes back as "Session ended (exit N)" (a
  terminal whose shell exited with status 0 stays dropped while *close on
  exit* is on), is saved so, and never restarts by itself (a command whose
  auto-restart gave up stays stopped; auto-start aside) nor counts in the
  toast or Restart All.

  The ended tab is built like the tab that saved it (id, kind, title, agent,
  parent agent, command, launch settings, project) but not launched, in its
  saved place, split and agent tree; `TerminalSession.systemSessionEnd`
  says why, and `PersistentSessionEndedBar` shows "Ended when the Mac
  restarted" (or "…when you logged out") with **Restart** and **Close**, for
  commands too (instead of `CommandExitStatusBar`). It is a persistent tab
  with no session (a native one while *persistent* is off): Restart (the
  bar, the menu, MCP `restart_process` or `start_process`) creates a new
  session for the same tab id in the tab's saved directory (or where it
  started, or its project, when that is gone), with the same shell, command
  or agent command, started fresh; `claude --continue` is not used, since
  several agents may share a directory. Any start clears `systemSessionEnd`.
  Until then it is saved with `systemEnd` and no binding
  (`WorkspaceSessionRecord.systemEnd`; older builds ignore the field and
  drop the tab), and comes back ended at every launch, whatever the
  settings, until it restarts or closes, unless This Mac's host has a
  session this app started for the tab (`cherry.tab`): a Restart whose new
  binding was never saved (the app ended first) comes back as the tab's
  own session. A saved ended tab names no tab id for orphan adoption either,
  so such a session is adopted if the restore did not take it. The window opens no
  default shell for a worktree that got tabs back, as for any restored tab.
  A command with auto-start is started in its tab by auto-start, and one
  with auto-restart restarts by its policy (`showSystemSessionEnd`), as for
  a restored command whose session ended.

  The first time a window's restores bring such tabs back in a run (not tabs
  saved ended), a toast (`ProjectWindowToast.systemEndedTabs`, unprompted:
  its time runs only while its window is key) says "N tabs ended when the
  Mac restarted" (or "…when you logged out"), with **Restart All**
  (`RepositoryWorkspace.restartSystemEndedTabs`: each of those tabs still
  ended) and dismiss; tabs a later step brings back update it. It counts
  only tabs nothing starts by itself: not those auto-start started (it is
  shown after auto-start ran) or will start, not commands that restart when
  they exit, and not those showing an earlier exit.

  They are ended tabs, like "Session ended" ones: they never close by
  themselves (no program exits), never ask a question on close or quit
  (nothing runs), cannot detach, and are never background sessions (no
  session). Closing one ends nothing; it cannot be undone with ⌘Z, since
  there is no session to bring back (as for native tabs).
- **Orphan adoption.** Sessions this app created (owner) for a tab
  (`cherry.tab`) in one of the window's worktrees (`cherry.project`) that no
  saved record names are adopted as persistent tabs of that worktree, after
  the tabs already open: a tab never saved because the app crashed right
  after opening it, or a record that was lost. The session must have been
  created after the last save (to the second) and before this app run began.
  A session created before the last save and missing from it (a detached
  tab's) is left alone. While a project has no usable
  state file but one was moved aside, that file counts: its `savedAt` (or its
  modification time) is the lower bound, and the tabs it named come back
  whenever they were created, until this version saves a file for the
  project. With no file of any version ever saved, any of the project's
  sessions from before this run are adopted. Each worktree is scanned once
  per run: at window open and after discovery, again once the host is
  reachable, and after a restarted daemon's holders have registered.
  Sessions recorded to be ended (below) are never adopted. With *close on
  exit* on, a terminal (its `cherry.kind` tag) whose shell exited with status
  0 is removed instead of adopted.
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
    session keeps running, in Background Sessions and the Persistent
    Sessions sheet), so
    nothing is orphaned without a record.
- **Deviation (ended tabs).** Ended persistent terminal and agent tabs show
  "Session ended (exit N)" with **Restart** and **Close**; Close removes the
  ended session, so there is no separate Remove. A terminal whose shell
  exited with status 0 closes instead, and its session is removed, unless
  *close on exit* is off or the shell ended within its first second.
  Attached tabs whose session ended show Remove from Host and Close Tab.
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
- **Background sessions** (`BackgroundSessions.swift`). One pure classifier
  (`BackgroundSessions.classify`) serves the menu bar list, End All, the
  launch notice and the Persistent Sessions sheet's label. A session is in
  the background when this copy holds the instance lock, its `owner` is this
  app's identity, and none of these holds:
  - an open tab shows it (`PersistentLocalSessions.isShownByOpenTab`): the
    tab that owns it, a tab attached to it (`OpenHostedTabs`), an open tab
    whose id its `cherry.tab` names, or an open persistent tab whose Create or
    restart started it and has not answered (`persistentLaunchRequestID`
    against its `request_id` or `cherry.launch`);
  - it is being ended, or a search for the sessions of forgotten saved tabs
    under way names it (`isScheduledToEnd`);
  - a saved tab an open window may still restore names it (by binding,
    attached ones included, launch request id or tab id): not restored yet,
    being restored, or kept while the host could not be listed
    (`RepositoryWorkspace.savedRecordsAwaitingRestore`). Set-aside records
    do not count: their sessions run unseen until the next launch.

  `BackgroundSessionsModel` reads `HostControl.sessions` (what the control
  connection last knew) every second and on `added`, `removed`, `exited` and
  `resync` events (never `changed`, which carries agents' spinner titles),
  and publishes only a changed list; rows carry no OSC title. The app body
  observes only its `BackgroundSessionsSummary` (a count, for the Cherry
  menu). It never starts a daemon to list: it connects (a list when the
  panel opens) only in the copy that holds the lock, and only once this run
  reached the host (`connectionGeneration` > 0), while local tabs run in it
  (`sessions.persistLocal`), or while it lists sessions already. It holds a
  lease on the connection while it lists any, so the list does not go stale
  when an unused connection closes; opening the panel only lists the host
  once (nothing waits for the panel to close). With *close on exit* on it
  ends (removes) listed terminals whose shell exited with status 0, from a
  live list only. End is
  `PersistentLocalSessions.end` with `waitingForExitUpTo: endRetryWindow`:
  Kill, wait for the exit, Remove (Remove only for an ended session), sent
  again for 60 s without a definite answer; the row leaves the list at once.
  A closed window's saved record is never rewritten (its window may load it
  at any moment): its next restore lists the host completely, finds the
  session gone and drops the tab, with no "Session ended" tab. A restore or
  orphan scan that runs while the ending does treats the session as gone
  too (`isEnding`, `isScheduledToEnd`), and `canAdopt` refuses it, so a
  window reopened meanwhile builds no tab that outlives it. Quit already
  waits for ends under way. Open (`ProjectWindowRegistry.showBackgroundSession`)
  finds the window by `cherry.project` (the open window of that worktree's
  repository, else `AgentSettings.repositoryRoot(for:)` or the worktree
  itself, opened with SwiftUI's `openWindow` through `projectWindowOpener`,
  else the active window), waits (10 s at most) for that window's restores
  and orphan scan, then reveals the tab that shows the session, or else,
  unless it is being ended by then (End, or that window's restore removing
  a clean exit), adopts it through the orphan restore step (`RepositoryWorkspace.showBackgroundSession`,
  which sets a command aside when another tab runs it and shows that tab),
  or attaches it when `canAdopt` refuses (a client shows it).
  `BackgroundSessionsNotice` (installed by `startLaunchHousekeeping`) starts
  when the launch has asked for its windows: 2 s later it waits (20 s at
  most) for the reopened windows to register and for every window's restores
  and orphan scans, then, when *background notice* is on, this copy holds
  the lock and this run reached the host, takes a complete list and names
  the background sessions at work (`BackgroundSession.isAtWork`, as
  `ClosedTabNotice.programIsAtWork` counts a closed tab's program) whose ids
  are not in `sessions.backgroundNoticeToldIDs` (UserDefaults, pruned to the
  listed ids, at most 512). It shows them in a toast in the first project
  window on screen (`ProjectWindowToasts`, no alert), an unprompted toast
  (`ProjectWindowToast.isUnprompted`): its time runs only while its window
  is key in the active app, so it never runs out unseen while Cherry is in
  the background, and it takes turns with a closed tab's toast instead of
  replacing it or being replaced (see "Close intents"). Reopen runs
  `SessionCloseCoordinator.reopen` for each, one after the other; End… is
  `BackgroundSessionsModel.confirmEndAll(from:limitedTo:)` on that window.
  The toast's `onDismiss` (its dismiss button, its time running out, or
  either action; not a toast that replaces it or its window closing) adds
  them to the told ids. So do the closes that keep sessions on purpose: a
  tab detached with `userDetachedTab` whose own persistent session keeps
  running (`TerminalWorkspace.finishClosing` →
  `SessionBackendPolicy.sessionDetached`),
  and a window close that keeps its sessions after Keep Running or with *on
  quit* = Keep Running (`ProjectWindowCloseDelegate.sessionsKeptInBackground`,
  the running persistent tabs' sessions as the tabs close). A tab whose
  Create was under way has no session id yet and is not told. With no
  project window on screen it tries again shortly, then on the next window
  that registers, on the next turn of the main queue (a window registers
  from inside its SwiftUI update, which must not change the toast).

### Not done yet

- **DECCKM of older holders.** A holder older than link version 4 never
  reports DECCKM, so its session reads `application_cursor_keys` false for
  its whole life, even under an updated daemon, and the app cannot tell off
  from unknown: MCP cursor keys to it without a live adapter go through the
  host at once as `ESC [ x` instead of waiting for the adapter, and so do
  cursor keys typed while its adapter is away. An optional field, left out
  when unknown, would let the app keep the adapter fallback for such
  sessions. A daemon of this protocol is replaced by a newer build only
  when it reports its build (`Welcome.build`); one from before builds were
  reported is used as it is until it restarts (`cherry restart`, or Restart
  Host in Settings › Sessions; sessions carry on in their holders).
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
- An attached SSH tab whose host control is not connected reports alternate
  screen false and keyboard flags 0 once its adapter runs; it does not open a
  connection just to follow modes. A kept command record whose holder stays
  alive but never registers (a SIGSTOPped holder) makes auto-start wait for
  the rest of the run.
- The earlier run's sessions to end are resumed when the first project
  window opens, not at app start, and a copy that cannot reach the host
  (disk image, no helper) records them but does not look for them. The
  launch's own lock check waits off the main thread; something else that
  asks for the lock before it is resolved (a deep link opening a window
  during that wait) still waits for it on the main thread.
- **Background sessions.** A terminal in the background whose shell exits
  with status 0 while a closed window's saved tab names it stays listed as
  `exit 0` (with Remove) until that window's next restore removes it. The
  10-minute removal of ended sessions counts from when this run's list
  first showed them, not from their exit (the host does not report when a
  session exited). Notifications of background sessions are not tested
  with the system's notification center (their content, the click's Open
  and the unread marks are). After a
  relaunch, a linked worktree's repository is known only once its window
  opened (no `cherry.repository` tag): Open for such a session opens a
  window for the worktree itself. Saved tabs of a worktree an open window
  never restores (worktree spaces off) count as awaiting restore for the
  whole run, so their sessions are not listed. The menu bar panel, the
  Settings card, the Cherry menu command and the sheets are not covered by
  tests (the model, classifier, copy, Open, End and the notice are); the
  Persistent Sessions sheet's Create still makes ownerless sessions, which
  are never in the background.
- End Sessions on quit ends the sessions of saved tabs no open tab shows
  only if the host lists them before the quit's wait ends; otherwise they
  are recorded in `sessions-to-end.json` and ended when the next launch
  opens the project's window, after its restore (which may bring such a tab
  back first).
- Test gaps: bringing the quit sheet's window on screen is not unit-tested
  (it would take focus from the user's apps), nor is the quit's reply to
  AppKit after the sessions question (what it does is: `SessionQuitPlan`,
  `SessionQuitPlan.confirmed`, `SessionTeardown.intent(for:)`,
  `windowToAnswerBeforeQuitting`, and the teardown's order and waits through
  `QuitTeardownSteps`), nor ordering real windows out
  (`takeWindowsOffScreen`, the default `takeOffScreen`: tests' windows never
  come on screen), or
  presenting that question as a sheet (the window close's is tested through
  its seam); ⌘W on a last tab attached to
  someone else's session is covered only through `closeEndsProgram`. The
  tab close question is tested through its request and answer
  (`pendingTabClose`, `answerTabClose`) and its alert's buttons, not its
  sheet (`TabCloseAlertPresenterView`); ⌘D and ⌘⇧D through
  `AppShortcutMonitor.shortcutAction` and the coordinator, not the menu
  items' or context menus' enablement. ⌘Z's routing is tested through
  `ClosedTabUndoRouting`, `AppShortcutMonitor.shortcutAction`, and an
  off-screen window whose first responder changes (AppKit's own Undo
  validation and the window's undo manager), not with key events in the
  running app. The
  closed-tab toast is tested through its model (`ProjectWindowToasts`,
  `ToastLifetime`), its placement above the bottom bars
  (`ProjectWindowToastOverlay.bottomInset`) and the close flows, not its
  SwiftUI view (hover events, truncation, animation, and the key and active
  notifications `ToastAttentionProbe` reports, which tests inject through
  `setAttended` and `setAttentionProbe`), which no test puts on screen. The
  instance-lock sheet is tested only with an injected presenter (no run
  with two copies of the app), and keys typed while an adapter is away only
  against a fake host (MCP cursor keys also against a real one), not in the
  running app. The CI workflow has not run on GitHub yet. The ignored
  `ssh_host.rs` acceptance test needs a disposable real SSH host; the SSH
  reconnect paths are covered by fake-ssh tests. The GUI scripts
  (`test-packaged-app`, `test-mcp-concurrency`,
  `perf-run-emulator-comparison` with a real Cherry) were not run in this
  round.
- A tab that fell back to native (`persistentFallbackReason`) is saved as a
  native tab: its program ends with the app, and it comes back at the next
  launch only if Retry or a restart got it a session first. The colours a
  session reports are the theme's when it was created; a later change of
  appearance or theme does not reach it: the host keeps answering OSC 10,
  11 and 12 and `CSI ?996n` (with `CSI ?997;1n` or `;2n`) from the colours
  it was created with, and sends no colour-scheme change notification
  (`CSI ?997;…n` for mode 2031) of its own. `ClearHistory` clears
  nothing on the alternate screen (like ED 3 and Ghostty's own clear), and
  Clear Scrollback on a tab only attached to a session (another app's, the
  CLI's or an SSH host's) leaves that host's history alone. The helper
  replaces a daemon of the same protocol only by build (above): a daemon
  whose executable was replaced by the same build is not restarted by
  itself (Settings › Sessions offers Restart Host).
- **Sessions the system ended.** A session of this app killed outside it
  (`cherry kill`, a `kill -9` of its holder while a daemon runs, `cherry
  shutdown` removing it once ended) is not recorded as ended on purpose: if
  the Mac then restarts, its saved tab (only a closed window's, whose record
  still names it) comes back ended. A holder killed while no daemon ran,
  without a log out, reads as a log out. A save in the second of the boot
  that came before it cannot be told from one after it (whole seconds), and
  `kern.boottime` moving after the clock is set could take a save made just
  after the boot for one before it; both would only bring back an ended tab
  for a session that is gone. Closing an ended tab cannot be undone. A
  saved ended tab takes a session started for it only if the host lists it
  when the restore asks (a restarted daemon whose holders have not
  registered yet leaves the tab ended). An exit is saved with the next save
  after the host reports it; a restart within that half second loses it.
- **Diagnostics.** The build handover is local: the SSH gateway does not
  replace a remote daemon of the same protocol and an older build (`cherry
  --host H status` shows it; `ssh H cherry restart` hands it over). Holders
  keep their builds until their sessions end; nothing restarts them. The
  log is rotated only by a daemon whose stderr is `host.log` (not under a
  systemd unit, whose log is the journal), at most once a minute, keeping
  one old copy; a holder that logs nothing after a rotation, and output a
  program prints to stderr without going through `log` (none does), stay
  in `host.log.1` until its next line. `cherry doctor` is local only and reads the PID
  file and manifests without locking; it cannot tell a PID file of a
  daemon that just started from a stale one in the moment before the daemon
  binds its socket. A handover the old build won is not tried again for an
  hour, even when the old build's client is gone by then. The Settings card, its alert, and the waiting bar are
  tested through their models (`SessionHostDiagnostics`,
  `SessionHostStatus`, `HostedReconnects`, `HostedConnectionBarState`), not
  as SwiftUI views; the wake notification and NWPathMonitor are tested
  through the calls they make (`systemDidWake`, `networkBecameAvailable`).
- **SSH tabs.** A tab that waits for its host after its adapter failed
  (`failed`) for a reason other than the host (a usage error, a missing
  helper) is retried like one that could not reach its host. Tabs of one
  host are probed together but each launches its own adapter (and ssh,
  unless the app's master runs). A probe that succeeds while the adapter
  then fails again keeps the backoff growing until a tab attaches.
- Nice-to-haves (none blocks): sequence ids on bell and notification events,
  for exact deduplication; per-client sizes in `SessionInfo`.
