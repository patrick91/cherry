# Cherry for iPhone and iPad

Status: plan, with a prototype (P0) in `Mobile/`.

## What it is for

Your agents and sessions run on your Macs. Away from them, you want to know
which agent needs you, see what it shows, and answer it: approve a menu,
type a reply, or open the full terminal for a minute. The iOS app is that,
for every Mac you have. It is not a general SSH client and it runs nothing
on the phone.

## Principles

- **The Macs stay the source of truth.** Sessions live in `cherry-host` on
  each Mac, as they do today. The phone is one more client of it, the way
  This Mac is a client of patstudio's host.
- **No Cherry cloud for v1.** The phone reaches each Mac directly over SSH,
  on the LAN or over Tailscale. A relay is only considered for
  notifications (P3).
- **Looking never changes a Mac.** Listing and reading use
  `cherry host control --no-start`: the phone never starts or replaces a
  daemon just to look, as the Mac app's device peeks don't.
- **No surprise resizes.** Attaching from the phone resizes a session only
  when the user asked for it (see Size below).
- **The phone's key stays on the phone.** An Ed25519 key made on the device,
  kept in its Keychain; each Mac's host key is pinned on first connect.

## What we build on

- **Rendering.** The GhosttyKit xcframework Cherry already uses ships
  `ios-arm64`, simulator, Catalyst and visionOS slices, and its C API has
  `GHOSTTY_PLATFORM_IOS`. The vendored `ThirdParty/libghostty-spm` has a
  UIKit terminal view (`UITerminalView`: keyboard accessory bar with Esc,
  Ctrl, arrows; pinch zoom; `UITextInput`) and an in-memory backend
  (`InMemoryTerminalSession`: the app feeds output bytes in and gets typed
  bytes out), which is what a terminal over SSH needs.
- **Sessions.** `cherry host control` relays the host protocol's frames
  over standard input and output (List, Screen, SendInput, events), and
  `cherry host attach ID --detach-key none --client-id ID` is a terminal
  client that repaints from the host. Both run on the Mac, so the phone only
  needs to run commands over SSH.
- **Agent state.** Agents report what they are doing with program status
  (OSC 7501), and each session's host keeps the records and sends them with
  the session (`SessionInfo.program_status`, in List and its `changed`
  events). That is the Mac app's only source of an agent's state too.

## Architecture

```
iPhone app (SwiftUI)
  └─ CherryMobileKit: MacConnection per Mac
       └─ SSH (swift-nio-ssh, through Citadel), one connection per Mac
            ├─ exec  cherry host control --no-start        host frames: sessions with their
            │                                               program status, screens, input, events
            └─ pty   cherry host attach ID --detach-key none   the full terminal
```

### Transport

One SSH connection per Mac, with channels multiplexed on it:

- a long-lived `cherry host control --no-start` exec channel;
- one PTY channel per open terminal.

A non-interactive SSH command does not get the Mac's login PATH, so the
`cherry` helper is found by absolute path: the endpoint's `cherryPath`, else
`~/Applications/Cherry.app/Contents/MacOS/cherry`, else
`/Applications/Cherry.app/Contents/MacOS/cherry`. The search is one
`sh -c` that prints the first one that exists.

The Mac needs Remote Login on (System Settings › General › Sharing). With
Tailscale on both devices the Mac's tailnet name or `100.x` address works
from anywhere.

### Sessions and screens

`cherry host control --no-start` starts with the host's `Welcome`. The phone then
sends `List` and `Screen` requests and reads `sessions_changed`, `exited` and
output events. The frames are those `Sources/Cherry/HostControlProtocol.swift`
encodes for the Mac app. The prototype keeps its own copy of the few it
needs. Sharing the encoder is the first step of the shared core (below).

The inbox shows the screen text the host keeps (`Screen`), which costs
nothing on the Mac and never resizes anything. It is shown at the Mac's
width in a horizontally scrollable monospaced view.

### Conversations

An agent's session opens on its conversation, read from the agent's own
session on the Mac: `cherry host transcript <session>` (Host/README.md) runs
over the SSH connection, finds the agent from the session's processes
(Claude Code's `sessions/<pid>.json`, the Codex rollout or Pi session file
its process started in the session's folder, the Amp thread whose log names
it) and prints trimmed entries: messages, tool calls with a one-line summary
and the start of their result, notes. The phone keeps them in a
`Conversation` (an entry with an id it has replaces it, a `tool_result`
finishes its tool) and reads what came after its cursor every 2 s, 5 s for
Amp, whose conversation comes from its server. Claude Code's transcripts run
to tens of megabytes, which is why the Mac reads and trims them, not the
phone. Only agents running in a session count, and the same lookup gives the
agent's own session id, with which the Mac app can later resume an agent
after a reboot.

The phone shows them in a `UICollectionView` laid out by
[ChatLayout](https://github.com/ekazaev/ChatLayout) (`ConversationList`),
each row SwiftUI, because SwiftUI's scroll views can't keep their place while
rows change or scroll exactly to a row they haven't laid out. It opens at
the end, follows the end as entries come, change or the keyboard opens while
the end is on screen, leaves what's on screen still while the person reads
further up, and goes to the end when they send a reply.

### Agent state (attention)

The phone reads each session's program status from the host, as the Mac
app does, so it needs neither a running Cherry on that Mac nor its control
socket. The program's own record (id empty; children such as a build's
steps don't count) maps as follows:

- `blocked` with `kind=permission` → *approval*;
- `blocked` with another kind (`question`, `auth`) or none → *question*;
- `done` → *result ready*;
- `working`, `idle` and `error` as they are.

Its message ("Approve Bash: npm test", "Tests pass") is the session's
detail, shown as text and never acted on. A program that reports nothing
(Codex and Amp today, or an older version) is *unknown*: it still lists,
and the session screen still turns a numbered menu on its screen into
buttons. The host has no time for a record, so the connection notes when a
session's attention changed.

### Typing

The host types what it is sent, so the phone encodes keys for the modes the
host reports for the program (`kitty_keyboard_flags`,
`application_cursor_keys`, `bracketed_paste`), as `cherry keys` does on the
Mac: arrows as `ESC O x` under application cursor keys unless the kitty
flags are on, Tab as `CSI 9 u` when they report every key, and a reply of
several lines as one bracketed paste, unless the program turned bracketed
paste off. A reply is its text, then Enter on its own 150 ms later
(`MacConnection.submit`), as the Mac's Cherry submits a message: an agent
such as Claude Code takes text and an Enter that arrive together as a paste,
and the Enter only starts a new line in its composer.

### Full terminal

A PTY channel runs `cherry host attach ID --detach-key none --client-id
mobile-<device id>`, so a dropped connection's attachment is replaced, not
doubled. Its bytes feed a `UITerminalView` through `InMemoryTerminalSession`,
and typed bytes (including the accessory bar's keys) go back on the channel.

### Size

The host shares one grid among a session's clients and uses the smallest
(Host/README.md, "Multiple terminals"). So a phone attaching at 45 columns
would reflow an agent on the Mac too. The terminal view has two modes:

- **Keep the Mac's size** (the default): the phone asks for the session's
  current grid (`SessionInfo` columns and rows) as its PTY size, and shows
  it zoomed to fit the width, with pinch zoom and pan. Nothing changes on
  the Mac.
- **Fit to phone:** the phone asks for its own grid. The session reflows
  while the phone is attached and grows back when it detaches. This is
  shown as a toggle, with what it does.

P2 adds a size-neutral attach to the protocol, a client that follows the
shared grid and never sets it. "Keep the Mac's size" then needs no PTY size
trick.

### Identity and pairing

- **P0:** the app makes its key and shows its OpenSSH public key with a Copy
  button. You add it to `~/.ssh/authorized_keys` on the Mac yourself. The
  host key is pinned on first connect, after the app shows its fingerprint.
- **P1 (built):** pairing from the Mac app (docs/specs/mobile-pairing.md).
  Settings › Devices › Pair iPhone… shows a QR code with the Mac's
  addresses, user, host key fingerprints and a one-time code. The phone
  scans it (or the camera opens it) and sends its public key to the Mac's
  short-lived pairing listener with an HMAC proof of the code. The Mac app
  asks before adding it to `~/.ssh/authorized_keys`, and the phone's first
  connect accepts only a host key the code listed.
- **Built (main):** the key is added as a
  `restrict,pty,command="'<cherry>' host mobile-gateway"` line, which
  reaches only Cherry: no port forwarding, no other commands, the gateway
  allowing `host control` (the phone's requests only), `host attach` and
  `host transcript`. A session is a shell, so this narrows the surface, not
  what an attached user can do.
- **Built:** pairing with another of the user's Macs from the Mac at hand
  (that Mac's card in Settings › Devices › Pair iPhone…): a version 2 code
  whose `via` addresses reach the listener on the Mac showing it and whose
  `host`s are the other Mac's. The phone keeps the first of those that
  takes a connection on the SSH port, and connects there directly from
  then on (mobile-pairing.md › Another Mac).

### Notifications (P3)

iOS will not keep an SSH connection open in the background, so "an agent
needs you" needs Apple's push service (APNs). Options:

1. **The Mac app sends pushes itself.** It uses APNs token auth: a `.p8`
   key on the Mac, and the phone's device token handed over at pairing.
   There is no server. This needs a paid Apple Developer team for the push
   entitlement, and the push stops when the Mac sleeps.
2. **A small relay** the Macs post to, which pushes. It works while the
   Mac sleeps if a host-side agent posts, but it is a service to run.
3. **Interim, no entitlement:** the Mac app posts to an ntfy topic you
   choose, and the ntfy app shows it.

Recommendation: start with option 1 once there is a paid team, and keep
option 3 as the zero-setup fallback. A push carries no screen text, only
"Claude in cherry needs you", with the session as a deep link.

### Reconnects

A connection is checked as well as used: `cherry host control` must answer a
`Ping` every 15 s within 15 s, or the app ends the connection ("The Mac
stopped answering."), its terminals with it. A network that went away (other
Wi-Fi, a NAT entry dropped while the phone slept) only shows as silence.

A dropped connection, or a connect that failed for a reason that can clear
up (an unreachable Mac, no session host yet, a broken channel), is tried
again by itself after 1, 2, 4, … s, at most 30 s (`ReconnectPolicy`), while
the app is in front and the network is up. A refused key, a changed host
key, a missing `cherry` or another protocol version wait for the user. The
Mac shows *Reconnecting…* with the last reason, its sessions stay listed (the
session screen keeps its last text, with a note), and an open terminal
attaches again once the new connection is up.

In the background every connection closes after 20 s, inside a background
task, so a Mac never keeps an attachment, and a Fit to phone grid, for a
phone iOS suspended. Back in front, or when the network comes back or
changes interface (`NWPathMonitor`), every open connection must answer a
ping within 3 s and every Mac waiting to reconnect tries at once. The app
logs this under subsystem `dev.patrick.cherry.mobile`, category
"Connections".

### Background refresh

While the app is open it keeps its connections and listens to events; 20 s
after it goes to the background it closes them (Reconnects). Backgrounded,
it refreshes through `BGAppRefreshTask` (best effort, minutes apart). That
makes notifications (P3), not polling, the real signal.

### Code sharing (with issue #7)

Issue #7 proposes a UI-free `CherryCore` for an AppKit window and a Linux
version. The phone needs the same layers:

- the host protocol's frames (`HostControlProtocol.swift`);
- session models;
- the key encoding for the host's key modes.

The first extraction is a `CherryHostWire` target, Foundation only, that
both the Mac app and `CherryMobileKit` import. The prototype copies what it
needs instead, so the Mac app is untouched until that extraction.

## Phases

| Phase | What | Done when |
| --- | --- | --- |
| P0 prototype | `Mobile/`: `CherryMobileKit` (SSH, host frames, agent state, a demo Mac) and the app (Macs, inbox, screen with quick replies, full terminal) | It builds for the simulator, its kit tests pass, it talks to a private host over a loopback sshd in tests, and the demo Mac runs in the simulator |
| P1 daily use | Your phone: install with Apple Development signing, pairing from the Mac app, reconnects, host-key UI, Tailscale names | You use it for a week to answer agents |
| P2 size and menus | Size-neutral attach; menus read as the Mac reads them (`AgentPromptMenu`, which `cherry answer` uses) | The phone never resizes a session, and answers a menu as `cherry answer` does |
| P3 notifications | APNs from the Mac app (or a relay), the ntfy fallback | "Needs you" reaches a locked phone within seconds |
| P4 iPad and polish | Hardware keyboard, split view with inbox and terminal, several terminals, widgets | |

## Open questions

- **Signing:** a free Apple Development team re-signs every 7 days, while
  TestFlight and push need the paid program. Which do we have?
- **Push provider:** the Mac app directly (P3 option 1) or a relay?
- **Shared core:** extract `CherryHostWire` from the Mac app before P1 so
  the frames are never copied twice, or after?
- **Phone-only actions:** should the phone start new agents (`Create`
  through `cherry host control`, without `--no-start`)? P0 only looks, types and
  attaches.

## Prototype (P0)

See `Mobile/README.md` for the layout, how to build and test it, and what
it does and does not do yet.
