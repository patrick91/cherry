# Devices: projects on your other Macs

Status: phase 0 (groundwork), phase 1 (devices and remote project
windows) and phase 2 (Add Mac… installs the session host) implemented on
`codex/persistent-sessions`; phases 3 and 4 are the plan. Phases 1 and 2 as
built, and where they differ from the plan below, are in *Phase 1 as built*
and *Phase 2 as built*. Builds on
[multiplexer-default.md](multiplexer-default.md) (persistent sessions, the
holder-per-session host, close intents, restore) and
[remote-session-host.md](remote-session-host.md) (SSH transport, gateway,
host identity). User-facing host behaviour is in
[Host/README.md](../../Host/README.md).

## Goal

The user's other Macs ("devices") appear in the title bar's project picker
(`ContentView` `TitlebarProjectPicker.presentMenu`) next to This Mac's
projects. Picking a device's project opens a project window whose terminals,
agents and commands run on that Mac, in its `cherry-host`, over SSH. The
window looks and behaves like a local one: tabs survive Cherry quitting on
either Mac, come back on relaunch, and a tab that cannot start says so
instead of running anything locally.

**Add Mac…** checks the other Mac over SSH and installs the `cherry` and
`cherry-host` that match this Cherry there (phase 2).

Cherry may run on the other Mac too. Both apps then share that Mac's daemon
(the default socket, `/tmp/cherry-host-$UID/host.sock`), so nothing here may
disturb the other app: its sessions, its daemon's protocol, its adoption
rules.

Out of scope for now: Linux devices in the picker (the host runs there, the
flow is Mac-first), editing remote files, a remote file browser beyond
choosing a project folder, remote previews without SSH port forwarding.

## Vocabulary

- **Device**: another Mac this Cherry reaches over SSH. It has a stable
  `deviceID` (a UUID this Cherry assigns), a display name, an SSH
  destination (an OpenSSH alias or `user@host`), the path of its
  `cherry-host` when it is not on the remote PATH, the host identity it
  answered with (pinned, as `HostedSessionHostStore` pins SSH hosts), its
  machine names (for OSC 7 reports), its home directory and login shell.
- **Project location** (`ProjectLocation`, `Sources/CherryControl`):
  `.local(path)` or `.remote(deviceID:path)`. Its **key** is what every
  store, registry and link keys a project on: the path itself for a local
  project (unchanged, so existing state keeps working) and
  `device:<lowercased uuid>:<absolute path>` for a remote one. A key never
  collides with a local path: local roots are absolute (`/…`).
- **Launch root**: the path on the machine that runs a window's tabs. For a
  local window it is the project root; for a remote one, the location's
  path. Only launch and remote-command code uses it.
- **Hosting** (`PersistentHostSessions`): runs one host's persistent tabs.
  `.shared` is This Mac's; each device gets its own.

## Rules every phase keeps

1. **Keys, not paths.** A remote project's root is its key everywhere a
   project is identified: `ProjectWindowRegistry`, `WorkspaceStateStore`
   (`sha256(key).json`), notes and todos (`ProjectNoteStore`,
   `ProjectTodoStore`: `sha256(key).json`), `CherryDeepLink.projectKey`
   (the SHA-256 of the key, never of a path resolved against the current
   directory), `AgentSettings` (projects, commands, overrides, hidden and
   last active worktrees). No code treats a remote key as a local path: no
   `FileManager` check, no `URL(fileURLWithPath:)` standardisation, no
   `cherry.toml` read or write, no `NSWorkspace` open.
2. **Never run a remote tab locally.** A remote hosting has
   `allowsNativeFallback = false`: a Create the host rejects, a host that
   cannot be reached, and a creation that takes longer than its deadline all
   leave the tab failed ("Couldn't start on <Mac>: <reason>", Retry), never
   a local shell. `SessionBackendPolicy.persistentHostingForNewTab` returns
   a remote hosting whatever the *persistent sessions* setting says and
   whether or not it can host now.
3. **Distinct owner.** Sessions this Cherry creates on a device carry the
   owner `<app identity>@<installation id>` (`PersistentHostSessions.remoteOwner`,
   for example `Cherry@6F1C…`), never the bare app identity. The other Mac's
   own Cherry (owner `Cherry`) therefore never adopts them: its restore,
   orphan scan, Background Sessions and `canAdopt` treat another owner as
   foreign, and its Persistent Sessions sheet shows them as another app's.
   Likewise this Cherry never adopts the other Mac's own sessions on that
   Mac: they are attached, not owned.
4. **No local process identity.** A remote session's `SessionInfo.pid` is a
   pid on another machine: `hostedProgramProcessID` stays nil
   (`isThisMac = false`), so MCP caller routing, `lsof` port detection and
   busy checks never look at a local process with that number.
5. **Remote directories are the host's.** A remote tab's working directory
   comes from `HostedSessionInfo.workingDirectory(onMachineNamed:)` with the
   device's machine names, never `localWorkingDirectory`; a new tab starts
   in the selected tab's directory or the launch root without checking that
   it exists locally (the host refuses a directory that does not exist).
6. **This Mac's evidence is not the device's.** `SystemEndedSessions`
   applies this Mac's boot time and log out/restart quits only to This Mac's
   records. A remote record whose session is gone comes back ended only when
   that host reported the session lost (`lost_sessions`, recorded in
   `Workspaces/lost-sessions.json` by host identity); otherwise it is
   dropped.
7. **Protocol compatibility on a shared daemon.** A client replaces a daemon
   speaking an older protocol (`Replace`) and never one speaking a newer
   one. On a device whose own Cherry.app runs the daemon, the `cherry-host`
   this Cherry uses there must speak the same protocol as that app, or one
   of the two apps is locked out. Phase 2 checks this before installing and
   before every connection (`cherry-host status --json`).
8. **SSH channels are limited.** sshd allows 10 sessions per connection
   (`MaxSessions`). One master connection per destination
   (`HostSSHMasterManager`) carries at most
   `Configuration.maxChannelsPerMaster` (8) adapter launches; further
   adapters use their own ssh. The CLI connects again without the
   ControlPath when a master refuses a session ("Session open refused by
   peer").

## Phase 0: groundwork (done)

No user-visible change for local tabs. What exists:

- **`ProjectLocation`** (`Sources/CherryControl/ProjectLocation.swift`): the
  key type, parsing (`init(key:)`), `isRemoteKey`, `launchPath(forKey:)`.
  `CherryDeepLink.projectKey(forProjectRoot:)` hashes a remote key as it is.
  `AgentSettings.validDirectory` accepts a remote key without touching the
  file system, and `CherryProjectFile` never reads or writes `cherry.toml`
  for one (loads are empty, writes throw). `ExternalEditorLauncher.open`
  does nothing for a remote key.
- **`TerminalWorkspace.launchRoot`** next to `projectRoot` (the key). New
  tabs, agents and commands start in the launch root; the key is kept
  unchanged (a remote key is not resolved as a local directory).
- **`PersistentHostSessions`** (was `PersistentLocalSessions`, which stays as
  a type alias for This Mac's code): a `PersistentHostProfile` says which
  host (`HostedSessionHost`), its display name, whether a failed tab may run
  natively, whether it is This Mac, and the machine names its directory
  reports use. `.shared` is This Mac's (`.thisMac` profile, owner = the app
  identity, 14 s creation timeout). `PersistentHostSessions.remote(…)` makes
  a device's: owner `remoteOwner`, `Configuration.remote` (45 s creation
  timeout), `RemoteLaunchSpec` launches, its own `PersistentSessionsStatus`,
  and a control connection from `HostControlRegistry.shared.control(for:
  .ssh(destination))`. Attachments, lost-Create cleanup, forgotten-tab
  searches and `record(_:names:…)` use the hosting's host, not `.local`.
  `PersistentHostingRegistry.shared` lists every hosting; a quit ends the
  deferred ends and waits for the pending ends of all of them
  (`QuitTeardownSteps.app`, `CherryAppDelegate.confirmedQuitPlan`).
- **Installation id** (`CherryInstallation`): `Application
  Support/<identity>/installation.json` (`{id, machine}`), written
  atomically, made or replaced only by the copy holding the instance lock
  (another copy reads it, or has none). `machine` is the SHA-256 of This
  Mac's `IOPlatformUUID`: a folder copied to another Mac (Migration
  Assistant) gets a new id there, so it never claims the first Mac's
  sessions on a shared device. Not in UserDefaults.
- **New tabs in a device window** start in the selected tab's
  host-reported directory when that tab runs on the same hosting, else in
  the launch root (rule 5); a local tab's directory never seeds them.
- **SSH master over the cap**: an adapter launched while its master has 8
  launches runs its own ssh for as long as it runs (reconnects reuse its
  arguments). Every launch registers afresh, so a relaunch (after its
  reconnect window, or Reconnect) takes a slot that freed meanwhile.
- **Tabs on a remote hosting** (`TerminalSession`): a failed launch leaves
  the tab `.failed("Couldn't start on <Mac>: <reason>")` with
  `persistentLaunchFailureReason` set and its hosting kept, so Restart (and
  `retryPersistentSession`) try the same host again; queued MCP input is
  reported undelivered. No pid is taken from the host. The creation deadline
  is the hosting's. The working directory is not checked locally.
  `reportsLocalWorkingDirectory` is false.
- **`RemoteLaunchSpec`**: a terminal's Create has argv `[]` (the host runs
  the account's `$SHELL -l`); a command or agent runs
  `[remoteShell, "-l", "-c", line]`. Environment: `TERM=xterm-256color`,
  `COLORTERM=truecolor`, the tab's identity (`CHERRY_PROCESS_ID`,
  `CHERRY_AGENT_ID`, `CHERRY_PROJECT_ROOT` = the remote path,
  `INSIDE_CHERRY`, `CHERRY_TERM_PROGRAM`, `TERM_PROGRAM`), the command's
  own variables, and `LANG`/`LC_*`; never `PATH`, `HOME`, `SHELL`, the
  control socket (`CHERRY_CONTROL_SOCKET`), Ghostty resources, the zsh
  bootstrap or anything else that names a local file. `cwd` is the remote
  path.
- **Restore rules**: `SystemEndedSessions` uses only the host's lost
  sessions for a record owned on another host (it comes back as `.logout`,
  like a local lost holder; phase 1 words it for the device: "Ended when
  <Mac> restarted or you logged out there");
  `OrphanedSessionCriteria.record(for:tabID:hostID:host:)` records the host.
  `WorkspaceSessionRecord.mayOwnSession(on:)` generalises
  `mayOwnLocalSession`.
- **CLI**: `cherry --remote-host-path PATH` (global, needs `--host`): the
  remote gateway command runs that cherry-host. `~/…` is sent as
  `"$HOME"/'…'`, which sh, bash, zsh and fish expand alike; any other path
  is single-quoted. Backslashes are refused (fish reads `\'` inside single
  quotes), and so is `!` (csh and tcsh expand history inside single
  quotes). `HostedSessionHost.arguments(sshControlPath:)` appends it from
  `HostedRemoteHostPaths.shared` (the device store sets its resolver in
  phase 1).
- **`cherry-host version --json`**: `{protocol, build, version, os, arch,
  min_macos}`. **`cherry-host status --json [--socket P]`**: `{running,
  state, protocol, build, host_id}` from one Hello (`launch::probe`); it
  never starts, replaces or changes a host. A socket it cannot check (not
  private, another account's, unreachable) is `state: "error"` with an
  `error` field; with `--json` it always prints JSON and exits 0.
- **SSH channel cap**: `HostSSHMasterManager.Configuration.maxChannelsPerMaster
  = 8`; `controlPath(forLaunch:)` returns nil when the master is full. The
  CLI retries once without its ControlPath when ssh reports "Session open
  refused by peer" before the gateway preamble.

## Phase 1 as built

What exists (`Sources/Cherry/RemoteDevices.swift`, `RemoteDeviceCheck.swift`,
`RemoteDeviceViews.swift`, `TitlebarProjectMenuModel.swift`):

- **`RemoteDeviceStore`** (not `DeviceStore`): `devices.json` in the
  identity's Application Support (`{version: 1, devices: [...]}`), written
  atomically by the instance-lock holder only. A `RemoteDevice` has `id`,
  `name`, `sshDestination`, `remoteHostPath?`, `machineNames`,
  `homeDirectory?`, `addedProjects`, `hiddenProjects`, `lastSeen`, `hostID`
  (its host's identity from `status --json`) and `createdHostEntry`
  (phase 2 adds `installedBuild` and `installedArch`; there is no
  `installedHostPath`, `remoteHostPath` is it, nor a stored `lastProbe`). Each destination
  is also a saved host of `HostedSessionHostStore`, whose trusted
  identities pin it; Remove ends nothing, and forgets that saved host and
  its pin only when Add Mac… created it (never a host the user had saved).
  Every change (add, remove, rename, hide, add project, trust) needs the
  instance lock (`canModify`); without it the picker's changing items are
  off. An alias of a Mac already added (the same host identity, recorded or
  pinned) is refused, and so is a destination containing `@-`. The store
  sets `HostedRemoteHostPaths.shared`'s resolver and makes one
  `PersistentHostSessions.remote(…)` per device, registered in
  `PersistentHostingRegistry` (all of them at launch). A device keeps one
  hosting by id across renames (the hosting takes the new name); removing
  a device whose hosting is in use (open tabs, a window whose saved tabs
  wait or are being restored, ends under way) leaves it registered, and
  adding that Mac again takes it back instead of making a second one.
- **Add Mac…** (phase 1 connects and checks only): the SSH host field
  suggests the non-wildcard `Host` aliases of `~/.ssh/config` (and the files
  it `Include`s). **Check** runs one BatchMode `ssh -a -x … HOST 'sh -s'`
  (`RemoteDeviceShell`, script on standard input so any login shell runs
  it) that reports `uname -sm`, `sw_vers`, ComputerName, host names, `$HOME`,
  `$SHELL`, the `cherry-host` it finds (`remoteHostPath`, else `PATH`, else
  the two known install places) with `version --json` and `status --json`,
  and whether a protected folder (Full Disk Access) and the login keychain
  can be read. The checklist (`RemoteDeviceChecklist`): SSH ok or why not
  (a host key → **Open in Terminal**, which runs `ssh -- '<host>'` in a tab
  of the frontmost This Mac project window; a refused login → keys and
  agent help; unknown host; unreachable), the Mac, the session host (same
  protocol, another one, a running daemon of another protocol, or missing:
  phase 2's installer is coming, with manual copy instructions), and Full
  Disk Access / keychain warnings. Then a name (default ComputerName) and
  **Add**, for exactly what was checked (editing the host or its
  cherry-host path asks for a new check). A cherry-host found in a known
  install place is kept as `remoteHostPath` (`~/…`).
- **Picker** (`TitlebarProjectMenuModel`, pure and tested by snapshot;
  `TitlebarProjectMenuController` builds the `NSMenu`): after This Mac's
  projects (remote keys never listed there), **Devices**, each Mac with a
  status dot and subtitle (`RemoteDeviceConnectionState`: not checked /
  last seen, connecting, connected · N sessions, offline, identity changed,
  login refused, another protocol) and a submenu: its projects, which are
  the `cherry.project` tags of every owner's sessions on its host (a device
  key's path, or a plain path from that Mac's own Cherry) with counts, plus
  `addedProjects`, minus `hiddenProjects` (an Option-alternate item hides
  one); **Other sessions** (untagged; the Persistent Sessions sheet on that
  host); **Open Home Folder**; **Add Project on <Mac>…** (a path, checked
  there with `test -d` and `pwd -P`; there is no remote folder browser and
  no `ListDir` request); a state row with **Reconnect** / **Trust New
  Identity…**; **Persistent Sessions on <Mac>…**; **Rename…**;
  **Remove…**. Then **Add Mac…**. The menu is built from what the hosts'
  `HostControl`s last listed and, while open, lists each host again without
  a lease (never one whose SSH login was refused, nor one another identity
  or protocol answers) and updates each device's item in place.
- **Remote windows**: `ProjectWorkspaceView` gives a `device:` key the
  device's hosting (`SessionBackendPolicy.remote`) and
  `hostedByDefault(localSessions: device hosting)`. A key of a device the
  store no longer knows gets a stand-in hosting (`isKnownDevice` false)
  whose control never runs a helper (no ssh to a made-up host) and whose
  tabs fail ("Couldn't start on an unknown Mac: …"), never local ones; its
  window keeps its saved tabs exactly as saved (no restore, no lease) until
  the device is known again. `RepositoryWorkspace` keeps the key
  (`isRemote`: no git, no worktrees, no auto-start commands; the sidebar
  hides project commands; Open in an editor is hidden), marks the hosting
  in use while open, holds a lease on the device's control connection
  while the window has tabs, and starts `HostedReconnects` wake/network
  monitoring. Title "<project> — <Mac>" with a computer glyph in the picker
  (and the window title); each tab row has a device chip. The restore
  routes records of the window's own host (`localSessions.profile.host`,
  not only `.local`) to the owning restore, so a device's tabs come back as
  its own; unbound records are looked for only on the host their `hostKey`
  names. A device window runs no orphan scan (its criteria compare
  creation times with This Mac's clock): its unshown sessions are listed
  under **Not open here**, the project's sessions on that Mac that no tab
  shows: this Cherry's own get **Reopen** (owned adoption, now for any
  hosting's host), other owners' **Attach** (attach-only; closing
  disconnects; its help says it may resize the session on that Mac while
  both show it). **Couldn't start on <Mac>: …** shows in a bar with
  **Retry** (`RemoteLaunchFailureBar`).
- **Offline**: a device tab's adapter is launched again only while its
  `HostControl` is connected (otherwise it waits for the connection, which
  its lease keeps retrying; `state` shows disconnected); once it answers,
  waiting tabs' adapters launch a batch at a time (at most the SSH master's
  channel cap, 8, then a jittered pause). The bars of its tabs and of a
  window whose saved tabs wait say what stands in the way and offer what
  helps (`RemoteDeviceAvailability`): "<Mac> is offline, reconnecting…"
  (Reconnect Now), a refused SSH login (Retry; not retried on a timer),
  another identity (Trust New Identity…), another protocol (Update…), or a
  reason nothing retries (a missing helper, an unknown device: Check
  Again). Keys typed while the adapter is away go only over the connection
  that is up (`HostControl.sendKeysOnCurrentConnection`: never a new
  connection, an answer within 3 s); when the Mac cannot be reached or a
  key fails, it is not sent, nor are the keys queued behind it, and the
  bar says so (`offlineInputRejectedAt`). A restore that cannot list the
  device keeps the records and retries through `HostControl.availability()`
  (the batch B machinery: leased backoff, wake and network triggers, a
  refused login waits); the window opens no default shell meanwhile and
  says how many tabs wait (`remoteTabsWaitingCount`). Every end of a device
  session (a close, End Sessions, a quit that ends sessions) is first
  recorded in `sessions-to-end.json` (an entry naming that host and
  identity's session, id `PersistentHostSessions.endRecordID`) and dropped
  once done. What could not be done is finished whenever Cherry next
  connects to that Mac for any reason (a window, the picker, Persistent
  Sessions; in this run or a later one): `resumeRecordedEndsOnConnection`,
  set up for every device at launch. A session whose tab's close can still
  be undone is never ended that way (its close ends it, or ⌘Z keeps it). A
  quit does not wait for an offline device's ends.
- **Restore wording**: a device session its host reports lost comes back as
  `SystemSessionEnd.hostRestart`, "Ended when <Mac> restarted" (toast "N
  tabs ended when <Mac> restarted"). This Mac's boot and quits are never
  evidence for it.
- **Records**: `WorkspaceSessionRecord.hostKey` is the device's
  `HostedSessionHost.id` for a device tab saved while its Create ran (nil
  means This Mac, as before); `mayOwnSession(on:)`, `ownsRemoteSession`,
  sessions to end and the restore use it. `wasEndedOnPurpose` and the ended
  and lost session files are keyed by host identity for every host.
- **Tests**: `RemoteDeviceTests` (store, SSH config, check parsing and
  checklist, SSH error mapping, picker snapshots per state and the live
  `NSMenu` update, discovery grouping, restore wording, reopen, records,
  offline adapter wait and keys, ends recorded offline, detach/⌘Z/quit
  count) and `RemoteDeviceRealHost*` (real helpers through
  `Scripts/fake-remote-mac`: Add Mac check and its SSH failures, a bare Mac
  without cherry-host, tabs created and typed into over the shim, discovery
  of all owners and Other sessions, owner isolation with the device's own
  "Cherry" on the same daemon both ways, Not open here / Reopen / Attach,
  restore after This Mac restarted, a device restart ending tabs as
  "Ended when Studio restarted", an offline device keeping tabs pending
  without native fallback until it answers, End Sessions while offline
  finished later). Group `RemoteDevice` in `Scripts/test-session-suites`;
  real-host mode requires a `RemoteDeviceRealHost*` pass.
  `Scripts/test-remote-mac-loopback` runs the check and `cherry --host`
  flows over real SSH to 127.0.0.1 with a private sshd (no admin rights).

Deviations from the plan below: Add Mac… (connect and check) is in phase
1; projects come from the device's session tags and added folders, not
`AgentSettings.projects`, and "Open Folder on <Mac>…" is Open Home Folder
plus Add Project on <Mac>… (no `ListDir`); sidebar path labels do not use
the device's home yet; Settings › Sessions does not list each device's
status; the quit question counts device sessions with This Mac's but does
not say "on 2 Macs"; file paste and drop into a device tab still insert
This Mac's paths (phase 3).

## Phase 2 as built

What exists (`Sources/Cherry/RemoteHostInstall.swift`, the Add Mac and
Update Session Host sheets in `RemoteDeviceViews.swift`, the probe in
`RemoteDeviceCheck.swift`, the scripts):

- **Universal helpers.** `Scripts/build-host` on macOS builds
  `aarch64-apple-darwin` and `x86_64-apple-darwin` (each with its own
  libghostty-vt, `Scripts/build-host-vt <triple>`), joins them with `lipo`
  and signs the result (ad hoc, or `CHERRY_CODESIGN_IDENTITY`), then moves
  it into place (a rename, never a write into a file that may run). A
  missing Rust target stops it with `rustup target add …`;
  `CHERRY_HOST_ARCHS=native` builds this Mac's architecture only and says so.
  `Scripts/check-helper-archs` checks `lipo -archs` lists arm64 and x86_64;
  `install-local-app` runs it (a native build is installed with a warning)
  and `package-dmg` requires it. `Scripts/package-host` names a universal
  archive `cherry-host-universal-apple-darwin.tar.gz`. CI's host toolchain
  installs both targets and caches both VT libraries.
- **This Cherry's helpers** (`RemoteHostHelpers`): the `cherry` and
  `cherry-host` it runs (`HostedSessionClient.installed()`'s directory),
  their `version --json`, the architectures both carry (read from the
  Mach-O headers, `MachOArchitectures`; no Xcode tools needed) and their
  SHA-256; read once off the main actor and again when the files change.
- **The probe** (the Add Mac check's script) also reports each build
  directory of ours (`installed=<name> <sha cherry> <sha cherry-host>`) and
  each `/Applications/Cherry.app` and `~/Applications/Cherry.app` with its
  `cherry-host version --json` (`app=`); the cherry-host it checks is looked
  for in `--remote-host-path`, `PATH`, `~/Library/Application
  Support/Cherry/bin`, the newest install of ours, then the two apps.
- **The decision** (`RemoteHostInstall.decide`, pure): from the probe, the
  helpers (or why there are none) and the daemon's `status --json`:

  | Daemon there | Decision |
  |---|---|
  | absent | install; the first tab's gateway starts ours |
  | same protocol | install ours; it relays to that daemon (a newer build of it is said to keep running) |
  | older protocol (≥ 4) | warn "Cherry on <Mac> is older; connecting updates its session host; its sessions carry on; update Cherry there too" (or, with no older Cherry.app there, that the host is replaced), then install; the gateway's `Replace` does the rest |
  | newer protocol | blocked: "… Update Cherry on this Mac, then check again." |
  | older than 4 | blocked, with the README's shutdown instructions |
  | unresponsive, or its socket could not be checked | install, with a warning |

  Also blocked: no helpers here, helpers of another protocol, an
  architecture they lack ("built for arm64 only, and Mini is an Intel Mac
  (x86_64)"; an arm64e Mac runs arm64), a macOS older than the slice's
  `min_macos`. Those four still allow a plain **Add** (`allowsPlainAdd`),
  as in phase 1: with the cherry-host already there when it speaks this
  protocol, otherwise its tabs say what is missing. A Cherry.app there
  of an older protocol is warned about (it cannot use the newer host while
  it runs), one of a newer protocol too (it will replace our host). The
  plan names the directory (`<build>`; `<build>-<first 12 of the hashes>`
  when `<build>` holds other files), whether a copy is needed (not when
  `<build>` has the same hashes), and whether it is an update (another
  build of ours, an older host or daemon there): **Install & Add**, **Update
  & Add** or **Add**; **Install**, **Update** or **Use It** in Update
  Session Host….
- **The install** (`RemoteHostInstaller`), over the check's BatchMode ssh
  with `-o ControlPath=<master>` when the device's master is up
  (`HostSSHMasterManager.controlPathIfUp`):
  1. copy: `/usr/bin/tar -cf - -C <helpers> cherry cherry-host` (extended
     attributes travel) piped into `ssh … -- HOST "/bin/sh -c '<line>'"`,
     the line being `umask 077 && mkdir -p "$HOME"/'…/<build>.partial-<uuid>'
     && /usr/bin/tar -xf - -C … && echo CHERRY-INSTALL-COPIED`: one line, no `!`,
     no backslash inside the quotes, so sh, bash, zsh, fish, csh and tcsh
     hand it to sh unchanged (tested);
  2. verify (`sh -s`): `xattr -c`, `codesign --verify --strict` of both,
     `cherry-host version --json` (exit 137 or 9: "macOS on <Mac> refused to
     run cherry-host … its code signature is not valid there"), `shasum -a
     256` of both; protocol, build and hashes must be this Cherry's. A
     failure removes the partial directory and says why;
  3. finish (`sh -s`, `RemoteHostInstaller.finishScript`): rename the
     partial directory to `<build>` with rename(2) (`/usr/bin/perl -e
     rename`, which fails when the target exists: concurrent installs of
     one build never nest); when `<build>` is there, `verify_dir` it (both
     executables, the expected hashes, both signatures, cherry-host runs):
     good, drop the partial; damaged and no process runs from it, move it
     aside and replace it; damaged and in use, leave it and place the copy
     at `<build>-<first 12 of the hashes>` (checked the same way). Partial
     copies an older installer nested inside a build are removed. Without a
     copy (the check saw the same hashes), the directory must pass
     `verify_dir`, or the install copies after all. The placed build gets
     `.installed` and this installation's `.used-by/<id>` marker. Then the
     report: `cherry status --json` and `cherry-host status --json` of the
     new build (neither starts a daemon), each directory with its install
     time and newest marker, and the processes running from the install
     root (`/bin/ps`, read into a variable first so no `grep` matches
     itself);
  4. recheck (`RemoteHostInstall.recheck`): the daemon as the new build
     sees it; a newer protocol or one before 4 is refused (the device is
     not changed), a daemon the check could not see is reported;
  5. handover, only when `RemoteHostInstall.shouldHandOver`: the daemon
     speaks this protocol, runs from one of our directories other than the
     new one (or the pre-phase-2 manual place, `~/Library/Application
     Support/Cherry/bin`), of another build that is not newer than ours:
     `<build>/cherry restart --if-pid P --if-executable E --if-build B`
     with what the report said (a new CLI option: checked on the connection
     that asks the restart; another daemon is left running, exit 4). Its
     sessions' holders keep running and register with the new daemon;
  6. collect (`RemoteHostInstall.garbage`): a build goes only when it is not
     the current one nor one of the two most recently installed others, no
     process runs from it, the daemon's executable is not there, neither the
     daemon's nor a running session's holder build names it
     (`directoriesInUse` says which of these keeps it), no `.used-by` marker
     is younger than 30 days, and it was installed more than 7 days ago;
     partial and moved-aside directories go after an hour unless in use;
     the removal re-reads the process list and keeps what runs.

  Every script runs the system tools by absolute path (`/usr/bin/stat`,
  `/usr/bin/tar`, `/usr/bin/shasum`, `/usr/bin/xattr`, `/usr/bin/codesign`,
  `/bin/ps`, `/usr/bin/perl`, `/usr/bin/touch`), so GNU coreutils first on
  PATH or a stand-in changes nothing.
- **Markers**: each connection of a device's control (at most every 6 hours
  per device, `RemoteDeviceStore.markUsedBuild`) and each Update Session
  Host… check touch `.used-by/<installation id>` in the build directory the
  device's `remoteHostPath` names, so another Mac's install never collects a
  build this one points at. A device whose cherry-host is gone anyway
  (`HostedSessionError.isRemoteHostMissing`: "No such file or directory" or
  "command not found" before the gateway started) is shown as "Its session
  host is missing" (`RemoteDeviceConnectionState.hostMissing`), with
  **Reinstall Session Host…** in its menu and **Reinstall…** on its bars.
- **Recording**: Add stores `remoteHostPath =
  ~/Library/Application Support/cherry-host/bin/<build>/cherry-host`,
  `installedBuild` and `installedArch` (the copy's `version --json` arch,
  as `arm64`/`x86_64`); Update Session Host… does the same
  (`RemoteDeviceStore.recordInstall`) and connects the device's control
  again unless it is connected (tabs and the control use the new path from
  their next connection; an older-protocol daemon is replaced by the first).
- **UI**: the Add Mac sheet's checklist gains an **Install**/**Update**/
  **Installed** row (or why not), its primary button is **Install & Add**,
  **Update & Add** or **Add** with the stage underway ("Copying cherry and
  cherry-host…", "Checking the copy there…", …) and errors in place; a
  typed cherry-host path skips the installer (phase 1 behaviour). The
  device submenu has **Update Session Host…** when the install there is an
  older build than this Cherry bundles (ordered builds only) or its host
  speaks another protocol; the **Update…** of a tab's or waiting window's
  bar (another protocol) opens the same sheet
  (`RemoteDeviceUpdatePresenter`).
- **Tests**: `RemoteDeviceInstallTests` (the decision table, the checklist,
  probe parsing, build order, Mach-O architectures,
  `Scripts/check-helper-archs` on thin and fat fixtures, the copy command
  through sh, bash, zsh, csh, tcsh and fish where installed, the scripts'
  reports, garbage collection, the handover rule, the menu, recording) and
  `RemoteDeviceRealHostInstallTests` through `Scripts/fake-remote-mac`
  (new switch: `arch`; `CHERRY_FAKE_REMOTE_HOST=link|none|newer|old-build`):
  Install & Add into a fake home, then the gateway run from the install;
  skipping an identical install; markers from the install, the check and a
  connection; a missing cherry-host shown as missing; an update from an
  older build of ours with live sessions, handed over with their holders
  running and registered again, while builds are collected by the rules
  above (young, recently marked, newest two and in use kept); a newer host,
  a missing architecture (plain Add) and an unsigned copy refused, leaving
  nothing behind; a damaged build repaired, a damaged one in use left for
  `<build>-<hash>`; three concurrent installs of one build (one placed, two
  reuse it, nothing nested) and an old nested partial removed; a handover
  naming another pid, executable or build refused; a daemon the check could
  not see reported after the install; a quarantine attribute that travelled
  with the copy cleared. Rust: `restart --if-*` unit tests and the ignored
  `restart_replaces_the_daemon_and_keeps_its_running_sessions`. `Scripts/test-remote-mac-loopback` runs the installer's
  test against its real sshd (tar, xattr, codesign), then `cherry --host`
  through the installed cherry-host.

Deviations from the plan below:

- The layout is `~/Library/Application Support/cherry-host/bin/<build>/`
  (immutable, one per build), not `Application Support/Cherry/bin/`, which is
  also the other Mac's own Cherry's data folder; the copy is a tar stream
  into a partial directory and a rename, not `cat > ….tmp && mv`.
- A device whose own Cherry.app runs a daemon of this protocol gets our
  install too (it relays to that daemon) rather than using that app's
  cherry-host: the device's path then never moves when that app updates.
- An older-protocol daemon is not refused: the gateway replaces it (its
  sessions carry on), with a warning to update Cherry there. A newer one,
  or one older than protocol 4, is refused.
- `min_macos` is checked per slice (an arm64 slice needs 11.0 at least);
  `xattr -c` runs although the files are not downloaded (it also clears
  provenance attributes).
- The first `cherry control` still pins the host identity as before;
  nothing is reinstalled by itself when this Cherry updates: the device menu
  offers Update Session Host…, and a protocol mismatch's Update… opens it.
- GC keeps more than "current plus two": builds installed within 7 days
  and builds any installation marked within 30 days stay too, so another
  Mac pointing at one keeps it.
- Builds without a time stamp (development builds) are never "older", so
  Update Session Host… is not offered for them by the menu (it is for
  another protocol); a handover from our own install of such a build to
  another is done, since it only happens when the user asked.

## Phase 1: devices and remote project windows (the plan)

No Add Mac yet: devices are added from a hidden debug menu or `defaults`
for development, with a working SSH alias and a `cherry-host` already on
the device.

1. **Device store** (`DeviceStore`, `Application Support/<app>/devices.json`,
   one writer: the instance-lock holder). Fields as in *Vocabulary*, plus
   `installedHostPath` and `lastProbe` (the phase 2 probe's result). It sets
   `HostedRemoteHostPaths.shared`'s resolver and registers one
   `PersistentHostSessions.remote(…)` per device in
   `PersistentHostingRegistry.shared` (keyed by device id; removing a device
   ends nothing on it, and unregisters its hosting once no window uses it).
   The installation id (`CherryInstallation`, done in phase 0) is kept
   next to it in `installation.json`, so the remote owner stays the same
   across launches.
2. **Picker.** `TitlebarProjectPicker.presentMenu` lists, after This Mac's
   projects, one section per device with its recent projects (their keys in
   `AgentSettings.projects`) and **Open Folder on <Mac>…**, which lists
   directories through the device's host (a new protocol request, `ListDir`,
   additive, or `cherry list-dir` over the control connection; not SFTP).
   A device that cannot be reached shows its projects disabled with the
   reason.
3. **Remote windows.** `RepositoryWorkspace` for a remote key: no git or
   worktree scan (a single worktree whose root is the key), its
   `SessionBackendPolicy.localSessions` is the device's hosting, restore
   uses `WorkspaceSessionRestorers.hostedByDefault(localSessions: device
   hosting, …)`, and the orphan scan runs against that host with the
   remote owner. `TerminalWorkspace.launchRoot` is the remote path.
   Sidebar path labels use the device's home directory
   (`SidebarTerminalPathFormatter` takes `homeDirectory`). Ghostty ignores
   an OSC 7 that names another machine, so while the adapter passes a
   remote tab's signals through, its directory still comes from the host's
   `changed` events (`hostReportedWorkingDirectory`); restoring and
   system-ended tabs (`makeSystemEndedSession`) must not check directories
   on this Mac either. Notes and todos
   work unchanged (keyed by the key). Open in editor is hidden (phase 3).
4. **Failure UI.** A failed remote tab shows a bar like
   `PersistentSessionFallbackBar`: "Couldn't start on <Mac>: <reason>" with
   **Retry** (`retryPersistentSession`), never "Not a persistent session".
   Settings › Sessions shows each device's `PersistentSessionsStatus`.
5. **Records.** `WorkspaceSessionRecord` gains `hostKey` (the
   `HostedSessionHost.id` a record without a binding was being created on),
   so a remote tab saved while its Create was under way is looked for on
   its device, not This Mac. `mayOwnLocalSession` stays This Mac's;
   `mayOwnSession(on:)` is used per hosting (forgotten tabs, quits).
6. **Close and quit.** Remote tabs are owned: ⌘W ends the session (after
   the undo window), ⌘D detaches, `restart` recreates with the same tab id.
   Quitting or closing a window keeps them by default; **End Sessions** ends
   them too (the question counts them with This Mac's, "N sessions on 2
   Macs"). A log out, restart or shut down of *this* Mac ends nothing on a
   device. `ProjectWindowRegistry.localSessionsEndedByAQuit` records every
   hosting's sessions (they are keyed by host identity already).
7. **Tests.** A `RemotePersistentHarness` (a fake SSH `HostControl`, the fake
   attach CLI) runs a remote window end to end: create, restart, restore,
   the failure bar, no local fallback, MCP input and screen through
   `SendInput`/`Screen`, and a quit that keeps and one that ends. Session
   suites are named after a group in `Scripts/test-session-suites`
   (`RemoteDevice`, added then).

## Phase 2: Add Mac…

1. **Probe** (`DeviceProbe`, all through the user's `ssh`, BatchMode first,
   then interactively in a sheet's terminal if keys are not set up):
   `uname -sm; sw_vers -productVersion; echo "$HOME"; echo "$SHELL";
   hostname`, then `command -v cherry-host`, the known install locations
   (`~/Library/Application Support/Cherry/bin/cherry-host`, and
   `/Applications/Cherry.app/Contents/MacOS/cherry-host`, the other Mac's
   own Cherry), each with `cherry-host version --json`, and
   `cherry-host status --json` for the daemon on the default socket.
2. **Decide.**
   - The device's own Cherry.app runs a daemon of this protocol: use that
     app's `cherry-host` (same protocol; builds may differ, and neither app
     hands the daemon over to the other's build: handover is local-only).
   - It runs a daemon of another protocol: refuse, and say which Cherry to
     update ("Update Cherry on <Mac> (protocol 6) or here (protocol 7)").
     Never install a newer `cherry-host` that would `Replace` the other
     app's daemon from under it.
   - No daemon and no Cherry.app, or only an older install of ours:
     install.
3. **Install.** Copy this app's `cherry` and `cherry-host`
   (`Contents/MacOS`) for the device's architecture (universal builds, or
   refuse on a mismatch; `min_macos` from `version --json` checked against
   `sw_vers`) to `~/Library/Application Support/Cherry/bin/` through
   `ssh … 'umask 077; mkdir -p …; cat > ….tmp && mv ….tmp …'`, verify with
   `version --json` (protocol and build must match), `xattr -d
   com.apple.quarantine` is not needed (not downloaded). Record the path
   (`~/…` form) as the device's host path. No `sudo`, no PATH edits, no
   launchd agent.
4. **Pin.** The first `cherry control` pins the host identity
   (`HostedSessionHostStore`); a later identity change is refused as for
   any SSH host.
5. **Updates.** When this Cherry updates and its protocol changes, a device
   whose own Cherry.app is older is marked out of date (not replaced); one
   with only our install is reinstalled on next use, after its sessions are
   checked (the new daemon adopts holders: sessions survive).

## Phase 3: remote project parity

Host services over the control connection (additive protocol requests):
`cherry.toml` read and write, git status and worktrees, process metadata
and listening ports, service discovery, file and image paste (transfer then
insert the remote path). MCP for remote agents: forward the app's control
socket with `ssh -R` to a per-session socket and set `CHERRY_CONTROL_SOCKET`
to it (never the local path). Previews through SSH local forwards the app
manages. Open in editor through the editor's remote support (Zed, VS Code
Remote SSH) when installed.

## Phase 4: attention and background

Bells, notifications and agent activity from device sessions in the menu
bar and Background Sessions (per device), unread marks across launches,
and the launch notice naming devices' background sessions. The host keeps
signals while no app is connected (already so), so a device's agents report
even after this Mac slept.

## Testing and safety

- Tests never reach a real SSH host: the fake `ssh` scripts in
  `Host/crates/cherry-cli/tests/client.rs` and the fake `cherry control`
  (`FakeControlHelper`) stand in. The ignored `ssh_host` suite and
  `Scripts/test-host-ssh` exercise real SSH against disposable hosts only.
- Every test daemon runs on a private socket with a private `HOME`; nothing
  touches the user's daemon at `/tmp/cherry-host-$UID`.
- The phase 0 tests: `ProjectLocationTests` (key round trip, no collision
  with the same local path, deep link keys), `HostControlSSHMasterTests`
  (remote host path arguments, the channel cap, a relaunch taking a freed
  slot), `AppIdentityInstallationTests` (the installation id's file, the
  instance lock, another Mac), `PersistentLocalSessionRemoteTests` (no
  native fallback, no pid, distinct owner, deadline message, new tabs'
  directory), `HostedLaunchSpecTests` (`RemoteLaunchSpec`
  carries no local `PATH`, `HOME` or control socket),
  `WorkspaceRestoreTests` (remote records ignore this Mac's boot), and the
  Rust `remote_gateway_command`, `remote_host_path`, mux refusal, `version`
  and `status --json` (including a socket it cannot trust) tests, and the
  quoting run through sh, bash, zsh, csh, tcsh and fish where installed.
