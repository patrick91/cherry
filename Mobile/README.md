# Cherry for iPhone and iPad (prototype)

The plan is [docs/specs/ios-app.md](../docs/specs/ios-app.md). This directory
holds its P0 prototype:

- `CherryMobileKit/`: the app's UI-free layer (Swift package, iOS and
  macOS). `MacConnection` is a Mac's host over SSH; `DemoMac` is a Mac that
  lives in the app, with agents in every state, for the demo, previews,
  screenshots and tests.
- `App/`: the iOS app (SwiftUI, with libghostty-spm's `UITerminalView` for
  the full terminal).

## Build and test

```bash
swift test --package-path Mobile/CherryMobileKit
Mobile/Scripts/test-loopback   # the SSH transport against a private sshd and host
```

`test-loopback` needs `/usr/sbin/sshd` (it runs as you) and the debug helpers
(`Scripts/build-host debug`, or `CHERRY_HOST_BIN` naming their directory).

## SSH transport

`SSHMacConnector(identity:)` reaches a Mac with Apple's swift-nio-ssh (Citadel's
current release pulls a personal fork of it):

- **Identity:** `KeychainDeviceIdentity` is an Ed25519 key in the Keychain
  (this device only, after first unlock), made on first use; `publicKey()` is
  its `authorized_keys` line, `ssh-ed25519 … cherry-ios`.
  `InMemoryDeviceIdentity` is for tests and previews.
- **Host key:** pinned on first use. With no `hostKeyFingerprint`, the key is
  accepted (only one of `pairedHostKeyFingerprints`, a pairing code's, when
  set) and the returned connection's `endpoint` carries its OpenSSH
  fingerprint (`SHA256:…`) for the app to show and save; a different key later
  is `.hostKeyMismatch`. The session host's identity is pinned the same way
  (`expectedHostID`, passed as `--expected-host-id`).
- **Finding cherry:** one `/bin/sh -c` prints the first executable among the
  endpoint's `cherryPath`, `~/Applications/Cherry.app` and
  `/Applications/Cherry.app` (`CherryLocator`). Commands are single-quoted
  words, so zsh, bash and fish login shells read them alike (`ShellQuote`).
- **Sessions:** a long-lived `cherry host control --no-start` channel speaks the
  host protocol (`HostWire`: List, Screen, SendInput, Subscribe, Ping every
  15 s). If no host runs, the error is `.noSessionHost`.
- **Agent state:** each session's program status (OSC 7501), which the host
  keeps and sends with the session (`program_status`, in the list and its
  `changed` events), so no Cherry app is involved. The program's own record
  (`SessionMapping.attention`): `blocked` with `kind=permission` is an
  approval, another `blocked` a question, `done` a result ready; `working`,
  `idle` and `error` as they are. Its message is the session's detail. Claude
  Code and Pi report it; Codex and Amp don't, so theirs is unknown (the
  session screen still turns a menu on it into buttons). The connection notes
  when a session's attention changed (`changedAt`).
- **Keys:** what the phone types follows the key modes the host reports for
  the program (`KeyModes`), as `cherry keys` types them: arrows as `ESC O x`
  under application cursor keys (not with the kitty flags), Tab as `CSI 9 u`
  when the kitty flags report every key, and a reply of several lines as one
  bracketed paste.
- **Terminal:** a PTY channel runs `cherry host attach <id> --detach-key none
  --client-id mobile-<device id>`; `resize` is an SSH window change.

## The app

`App/project.yml` is the app's Xcode project for xcodegen (`brew install
xcodegen`); the generated `CherryMobile.xcodeproj` and `App/build/` are
git-ignored.

```bash
Mobile/Scripts/build-app        # generate, then build for the simulator, signed ad hoc
Mobile/Scripts/screenshots DIR  # build, then screenshot each screen against the Demo Mac
```

On your iPhone or iPad (Developer Mode on, unlocked, connected by USB or on
the same network):

```bash
CHERRY_MOBILE_TEAM=<team id> Mobile/Scripts/install-device [DEVICE]
```

It signs with that team (one Xcode is signed in to), registering the bundle
id and the device on the first run, then installs and launches the app. A
free Personal team's build stops launching after 7 days; run it again.

To TestFlight, for internal testers, once the app's record (bundle id
`dev.patrick.cherry.mobile`) exists in App Store Connect:

```bash
CHERRY_MOBILE_TEAM=<team id> Mobile/Scripts/testflight
```

It archives a Release build for devices, signs it with the team (Xcode's
automatic signing, or an App Store Connect API key named by `ASC_KEY_PATH`,
`ASC_KEY_ID` and `ASC_ISSUER_ID`) and uploads it, marked for internal testing
only. The build number is the UTC time. Signing needs the login keychain, so
run it in your own terminal. `--export DIR` writes the `.ipa` instead of
uploading it; `--unsigned` only checks the device build, as CI does. The
privacy manifest (`App/CherryMobile/PrivacyInfo.xcprivacy`) declares the
required-reason APIs the linked binary uses: check it again when a new one
appears (`nm -u` on the app's binary).

Xcode Cloud does the same with no keychain at all (Apple signs it). Its
workflow, made in Xcode (Integrate › Create Workflow) by someone signed in to
the team, archives for iOS and hands the build to TestFlight's internal
testers. `App/ci_scripts/ci_post_clone.sh` runs after its clone: it
generates the project and gives it the kit's `Package.resolved` (Xcode Cloud
resolves no packages itself). Xcode Cloud numbers its builds itself (1, 2,
…), below `testflight`'s UTC numbers, so once a version has an upload from
one, keep using that one for it (or set Xcode Cloud's next build number in
App Store Connect).

`screenshots` runs headless: it creates a private simulator named
`CherryMobile-Proto`, boots it without Simulator.app, then shuts it down and
deletes it. It touches no other simulator. To run the app yourself, open the
generated project in Xcode and pick a simulator or your device; signing
uses your team.

Screens:

- **Inbox:** every Mac's sessions by project (`Inbox.projects`: the
  project the Mac's Cherry tagged the session with, `cherry.project`, else
  its folder; the home folder is Home). A project is a heading (with its
  Mac when there are several, and its folder's place when another of that
  Mac's projects has its name), its agents a line each: a mark for what
  they need (a dot for an approval or a question, a check for a result, a
  spinner while working), the task, and the agent with what it says; its
  commands and terminals in small type under them. Projects whose agents
  wait on you come first, then those an agent works in, each by name;
  quiet ones fold at the end and open in place. Filters keep the agents
  that need you, or those working. Pull to refresh.
- **Session:** for an agent, its conversation by default: what the Mac's
  `cherry host transcript` reads from the agent's own session (Claude Code,
  Codex, Pi, Amp; Host/README.md), followed every 2 s (5 s for Amp) from
  its cursor. Messages are Markdown (`Markdown.blocks`: paragraphs,
  headings, lists, code, tables as code, quotes); each run of tool calls is
  one group of one-line rows, a verb and what it acted on with paths
  relative to the session's folder (`ToolPresentation`, `DisplayPath`),
  the latest three shown, each opening on the start of its result; a row
  says when the agent works. A menu on the agent's screen (`ScreenMenu`: a
  permission prompt, a question, each option with the lines describing it)
  is a card under the last entry whose options type their digit, as an
  agent takes it. The toolbar switches to the screen, which every other
  session shows: the host's screen text, kept to the bottom, an agent's at
  the session's width (scrolling sideways, for its boxes), a terminal's or
  command's wrapped at the phone's (the host joins wrapped rows, so it
  reflows; the toolbar switches back to the session's width). Under either is the composer: on the screen, its menu as
  compact buttons, a reply field (text, then Enter) and, behind the
  keyboard button, keys: Esc, arrows, Enter, Tab, ⌃C. The program's status
  shows in the inbox, not here. A Mac whose `cherry` predates
  `host transcript` says to update Cherry there.
- **Terminal:** Ghostty's `UITerminalView` on an `InMemoryTerminalSession`,
  bridged to a `TerminalAttachment`.
  - *Keep Mac size* (the default) attaches at the session's grid in a
    zooming scroll view, so nothing changes on the Mac.
  - *Fit to phone* attaches at the view's grid, so the session reflows
    there and on the Mac while it is open.
- **Pairing:** Pair a Mac scans the code the Mac's Cherry shows (Settings ›
  Devices › Pair iPhone…), or the iPhone's camera opens it
  (`cherry-mobile://pair?…`, `PairingOffer`; docs/specs/mobile-pairing.md on
  main). `MacPairing` asks each of its addresses for `/hello` and keeps the
  first, in the code's order, that answers (the ones before it get a second
  more), sends this device's key with an HMAC proof of the one-time code
  over plain HTTP on Network.framework (App Transport Security would refuse
  it to `URLSession`), and waits while you allow it on the Mac, showing this
  device's key to compare. The Mac is saved at the address that answered
  with the code's host keys (`pairedHostKeyFingerprints`): its first connect
  accepts only one of them and pins it without asking. A code for another
  of the user's Macs (version 2, `isForAnotherMac`) has the listener at its
  `via` addresses (`listenerHosts`); before sending the key the phone looks
  for the first of the Mac's own addresses that takes a TCP connection on
  its SSH port (`reachableSSHHost`) and saves the Mac there, or says it
  can't reach it (`PairingError.sshUnreachable`).
- **Macs:** in the inbox's style: Pair a Mac first, then each Mac as a
  heading with its status and `user@host` (a tap edits it, where it can be
  removed; a long press too); setting one up by hand (this device's public
  key, with Copy, and Add a Mac by Hand…); the Demo Mac switch. A Mac added
  by hand shows its host key on the first connect and pins it once you
  trust it.

Launch arguments open a screen against the Demo Mac, and such a run connects
nowhere else:

- `-screen inbox`
- `-screen session:demo-claude`
- `-screen terminal:demo-codex`
- `-screen terminal-fit:demo-claude`
- `-screen macs`

`-demoDropAfter <seconds>` makes the Demo Mac drop each connection that long
after it opened, to show reconnecting. `-pairing <cherry-mobile://pair?…>`
opens that pairing code as the camera would, without iOS asking first.

## Rules for tests

Tests never reach the user's real Macs, daemon or Cherry:

- SSH only to a private sshd on 127.0.0.1 (as
  `Scripts/test-remote-mac-loopback` does);
- a private `cherry-host` with its own `HOME` and sockets;
- `cherry host control --no-start`;
- a stand-in agent that reports its status as Claude Code does.

CI (`.github/workflows/mobile.yml`) runs the kit tests, `test-loopback` and
`build-app` on macOS.
