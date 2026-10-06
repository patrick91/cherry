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
  accepted and the returned connection's `endpoint` carries its OpenSSH
  fingerprint (`SHA256:…`) for the app to show and save; a different key later
  is `.hostKeyMismatch`. The session host's identity is pinned the same way
  (`expectedHostID`, passed as `--expected-host-id`).
- **Finding cherry:** one `/bin/sh -c` prints the first executable among the
  endpoint's `cherryPath`, `~/Applications/Cherry.app` and
  `/Applications/Cherry.app` (`CherryLocator`). Commands are single-quoted
  words, so zsh, bash and fish login shells read them alike (`ShellQuote`).
- **Sessions:** a long-lived `cherry control --no-start` channel speaks the host
  protocol (`HostWire`: List, Screen, SendInput, Subscribe, Ping every 15 s).
  If no host runs, the error is `.noSessionHost`.
- **Agent state:** `CherryMCP --call list_projects`, then `list_processes` for
  each open project and loaded worktree, at most every 3 s. A process's `id` is
  its tab's id, which its host session names in the `cherry.tab` tag.
- **Terminal:** a PTY channel runs `cherry attach <id> --detach-key none
  --client-id mobile-<device id>`; `resize` is an SSH window change.

## The app

`App/project.yml` is the app's Xcode project for xcodegen (`brew install
xcodegen`); the generated `CherryMobile.xcodeproj` and `App/build/` are
git-ignored.

```bash
Mobile/Scripts/build-app        # generate, then build for the simulator, signed ad hoc
Mobile/Scripts/screenshots DIR  # build, then screenshot each screen against the Demo Mac
```

`screenshots` runs headless: it creates a private simulator named
`CherryMobile-Proto`, boots it without Simulator.app, then shuts it down and
deletes it. It touches no other simulator. To run the app yourself, open the
generated project in Xcode and pick a simulator or your device; signing
uses your team.

Screens:

- **Inbox:** every Mac's sessions. *Needs you* comes first (approvals,
  questions, errors, results), then *Working*, then the rest. Pull to
  refresh.
- **Session:** the host's screen text at the session's width, kept to the
  bottom. A menu on screen (`ScreenMenu`) becomes buttons that type the
  option's digit, as an agent takes it. Below them are a reply field (text,
  then Enter) and keys: Esc, arrows, Enter, Tab, ⌃C.
- **Terminal:** Ghostty's `UITerminalView` on an `InMemoryTerminalSession`,
  bridged to a `TerminalAttachment`.
  - *Keep Mac size* (the default) attaches at the session's grid in a
    zooming scroll view, so nothing changes on the Mac.
  - *Fit to phone* attaches at the view's grid, so the session reflows
    there and on the Mac while it is open.
- **Macs:** add, edit and remove Macs; this device's public key, with Copy;
  each Mac's status; the Demo Mac switch. A first connect shows the Mac's
  host key and pins it once you trust it.

Launch arguments open a screen against the Demo Mac, and such a run connects
nowhere else:

- `-screen inbox`
- `-screen session:demo-claude`
- `-screen terminal:demo-codex`
- `-screen terminal-fit:demo-claude`
- `-screen macs`

## Rules for tests

Tests never reach the user's real Macs, daemon or Cherry:

- SSH only to a private sshd on 127.0.0.1 (as
  `Scripts/test-remote-mac-loopback` does);
- a private `cherry-host` with its own `HOME` and sockets;
- `cherry control --no-start`;
- recorded JSON in place of the real `CherryMCP`.
