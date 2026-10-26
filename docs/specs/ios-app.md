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
  `cherry control --no-start`: the phone never starts or replaces a daemon
  just to look, as the Mac app's device peeks don't.
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
- **Sessions.** `cherry control` relays the host protocol's frames over
  standard input and output (List, Screen, SendInput, events), and
  `cherry attach ID --detach-key none --client-id ID` is a terminal client
  that repaints from the host. Both run on the Mac, so the phone only needs
  to run commands over SSH.
- **Agent state.** Cherry's MCP helper on the Mac,
  `Cherry.app/Contents/MacOS/CherryMCP --call list_processes`, reports each
  agent's `agent_activity_state` (`working`, `idle`, `permission`,
  `needs_input`, `error`), its turn state and its Cherry task.

## Architecture

```
iPhone app (SwiftUI)
  └─ CherryMobileKit: MacConnection per Mac
       └─ SSH (swift-nio-ssh, through Citadel), one connection per Mac
            ├─ exec  cherry control --no-start        host frames: list, screen, input, events
            ├─ pty   cherry attach ID --detach-key none   the full terminal
            └─ exec  CherryMCP --call list_processes   agent state (P0/P1)
```

### Transport

One SSH connection per Mac, with channels multiplexed on it:

- a long-lived `cherry control --no-start` exec channel;
- one PTY channel per open terminal;
- short exec channels for agent state.

A non-interactive SSH command does not get the Mac's login PATH, so the
`cherry` helper is found by absolute path: the endpoint's `cherryPath`, else
`~/Applications/Cherry.app/Contents/MacOS/cherry`, else
`/Applications/Cherry.app/Contents/MacOS/cherry`. The search is one
`sh -c` that prints the first one that exists.

The Mac needs Remote Login on (System Settings › General › Sharing). With
Tailscale on both devices the Mac's tailnet name or `100.x` address works
from anywhere.

### Sessions and screens

`cherry control --no-start` starts with the host's `Welcome`. The phone then
sends `List` and `Screen` requests and reads `sessions_changed`, `exited` and
output events. The frames are those `Sources/Cherry/HostControlProtocol.swift`
encodes for the Mac app. The prototype keeps its own copy of the few it
needs. Sharing the encoder is the first step of the shared core (below).

The inbox shows the screen text the host keeps (`Screen`), which costs
nothing on the Mac and never resizes anything. It is shown at the Mac's
width in a horizontally scrollable monospaced view.

### Agent state (attention)

- **P0/P1:** the phone runs `CherryMCP --call list_processes` on the Mac and
  matches processes to host sessions. Mapping:
  - `permission` → *approval*;
  - `needs_input` → *question*;
  - `idle` after a completed turn (`agent_turn_state` `completed`) →
    *result ready*;
  - `working`, `idle` and `error` as they are.

  Without a running Cherry on that Mac, agents show as *unknown*. Sessions
  still list.
- **P2:** the Mac app publishes each tab's verdict into its host session
  (`Update` with a `cherry.attention` tag, as it already syncs names). Then
  `cherry control` alone carries it, events included, and the phone needs
  neither the MCP helper nor the Mac app's control socket.

### Full terminal

A PTY channel runs `cherry attach ID --detach-key none --client-id
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
- **P1:** pairing from the Mac app. Settings › Mobile shows a QR code with
  the Mac's addresses, user, host key fingerprint and a one-time code. The
  phone scans it and sends its public key over a pairing endpoint. The Mac
  app asks before adding it, with
  `restrict,pty,command="…/cherry mobile-gateway"`, so the phone's key can
  only reach Cherry: no port forwarding, no arbitrary commands. The gateway
  allows `control`, `attach` and the MCP helper's read tools. A session is
  a shell, so this narrows the surface, not what an attached user can do.

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

### Background refresh

While the app is open it keeps its connections and listens to events.
Backgrounded, it refreshes through `BGAppRefreshTask` (best effort, minutes
apart). That makes notifications (P3), not polling, the real signal.

### Code sharing (with issue #7)

Issue #7 proposes a UI-free `CherryCore` for an AppKit window and a Linux
version. The phone needs the same layers:

- the host protocol's frames (`HostControlProtocol.swift`);
- session models;
- MCP process summaries.

The first extraction is a `CherryHostWire` target, Foundation only, that
both the Mac app and `CherryMobileKit` import. The prototype copies what it
needs instead, so the Mac app is untouched until that extraction.

## Phases

| Phase | What | Done when |
| --- | --- | --- |
| P0 prototype | `Mobile/`: `CherryMobileKit` (SSH, host frames, agent state, a demo Mac) and the app (Macs, inbox, screen with quick replies, full terminal) | It builds for the simulator, its kit tests pass, it talks to a private host over a loopback sshd in tests, and the demo Mac runs in the simulator |
| P1 daily use | Your phone: install with Apple Development signing, pairing from the Mac app, reconnects, host-key UI, Tailscale names | You use it for a week to answer agents |
| P2 host-published attention | `cherry.attention` tag from the Mac app; size-neutral attach; approval menus as buttons from the screen | The phone needs only `cherry control` and `cherry attach` |
| P3 notifications | APNs from the Mac app (or a relay), the ntfy fallback | "Needs you" reaches a locked phone within seconds |
| P4 iPad and polish | Hardware keyboard, split view with inbox and terminal, several terminals, widgets | |

## Open questions

- **Signing:** a free Apple Development team re-signs every 7 days, while
  TestFlight and push need the paid program. Which do we have?
- **Push provider:** the Mac app directly (P3 option 1) or a relay?
- **Shared core:** extract `CherryHostWire` from the Mac app before P1 so
  the frames are never copied twice, or after?
- **Phone-only actions:** should the phone start new agents (`Create`
  through `cherry control`, without `--no-start`)? P0 only looks, types and
  attaches.

## Prototype (P0)

See `Mobile/README.md` for the layout, how to build and test it, and what
it does and does not do yet.
