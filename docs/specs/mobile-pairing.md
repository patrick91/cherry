# Pairing Cherry for iOS with a Mac

Status: implemented in the Mac app (Settings › Devices › Pair iPhone…, and
each other Mac's card's, `Sources/Cherry/MobilePairing/`) and the gateway
the phone's key runs (`cherry host mobile-gateway`,
`Host/crates/cherry-cli/src/gateway.rs`); Cherry for iOS reads the code on
the `codex/ios-app` branch (`Mobile/`, docs/specs/ios-app.md › Identity and
pairing).

Cherry for iOS reaches a Mac's sessions over SSH, with a key of its own.
Pairing gets that key into the Mac's `~/.ssh/authorized_keys` and tells
the phone how to reach the Mac and which host key to trust, without typing
an address or copying a key by hand.

## The flow

1. Settings › Devices › Pair iPhone… checks that Remote Login answers on
   127.0.0.1:22. If not, the sheet says to turn it on (System Settings ›
   General › Sharing) and checks again.
2. It starts `MobilePairingListener` on every interface, on a port the
   system picks, with a new one-time code (16 random bytes), and shows the
   offer as a QR code. The code works once, for 10 minutes; the listener
   stops when it is used, when it expires and when the sheet closes.
3. The phone reads the QR code (the iPhone's camera opens the URL in Cherry
   for iOS, or its own scanner), finds an address that reaches the listener
   (`GET /hello` on each, in parallel), and sends its public key and name
   (`POST /pair`). The request waits.
4. The Mac asks: "Allow “<phone>” to connect?", with the key's fingerprint,
   which the phone shows too. Allow adds the key, limited to Cherry's
   sessions (see authorized_keys); Deny refuses it and shows a new code.
   Either answer, or closing the sheet, answers the phone.
5. The phone saves the Mac with the address that answered, the user, the
   SSH port and the host key fingerprints of the offer, and connects. Its
   first connect accepts only a host key the offer listed, then pins it.

## The offer

`cherry-mobile://pair?v=1&name=…&user=…&ssh=22&port=…&code=…&host=…&fp=…`

| Item | |
|---|---|
| `v` | 1; 2 for another Mac (see Another Mac) |
| `name` | the Mac's name (Sharing settings') |
| `user` | the user Cherry runs as, whom the phone logs in as |
| `ssh` | the SSH port, 22 |
| `port` | the listener's port |
| `code` | the one-time code, base64url without padding |
| `host` (repeated) | where the Mac may be reached, best first: Tailscale addresses (100.64.0.0/10), its Bonjour name (`<LocalHostName>.local`), other IPv4 addresses of interfaces that are up |
| `fp` (repeated) | `SHA256:…` fingerprints of `/etc/ssh/ssh_host_ed25519_key.pub` and `ssh_host_ecdsa_key.pub` (the phone cannot use RSA host keys); a `+` is written `%2B` |
| `via` (repeated, version 2 only) | where the listener is: this Mac's addresses, as `host` lists them in version 1 |

The phone keeps the first `host`, in the offer's order, that answered
`/hello`, so a Mac on Tailscale is saved by its Tailscale address and works
away from home.

## The listener

Plain HTTP/1.1, one request per connection, `Connection: close`. A proof is
the HMAC-SHA256 of a message under the code, in lowercase hex: the code
itself never leaves the QR code, so someone on the network can neither
answer for the phone nor swap its key.

- `GET /hello?proof=<proof of "hello">` → 200 `{"v":1,"name":"Patbook"}`;
  404 without a valid proof.
- `POST /pair` with `{"v":1,"key":"ssh-ed25519 AAAA…","name":"…","proof":<proof of "pair\n<key>\n<name>">}`
  → after the Mac's answer: 200 `{"v":1,"name":…,"user":…}`, 403
  `{"error":"declined"}`, or 500 `{"error":"not_added","message":…}` (the
  key could not be written; the Mac shows the line to add by hand). Before
  it: 400 `bad_request` or `bad_key` (only `ssh-ed25519` and
  `ecdsa-sha2-nistp256` keys, checked to decode and name their type
  inside), 401 `bad_proof`, 409 `busy` (another phone is being asked
  about), 410 `used` (the code was answered once, or got 10 wrong proofs).

A request is at most 16 KiB and must arrive within 10 s; at most 8
connections at once. If the Mac's firewall is on, macOS asks once whether
Cherry may accept incoming connections.

## authorized_keys

`AuthorizedPhoneKeys` adds

```
restrict,pty,command="'<cherry>' host mobile-gateway" <type> <key> cherry-mobile <phone's name>
```

(the name on one line, at most 64 characters). `<cherry>` is the `cherry`
link in Cherry's Application Support folder (`TabCLIDirectory`,
`~/Library/Application Support/Cherry/bin/cherry`), which stays put when the
app moves or updates: each launch points it at the app's own. Without it, or
at a path with a quote, a backslash or a control character, nothing is added
and the sheet says why.

`restrict` turns off port, agent and X11 forwarding and `~/.ssh/rc`; `pty`
gives back the terminal an attachment needs. sshd runs the gateway, `cherry
host mobile-gateway` (Host/README.md), for whatever the phone asks. It runs
only what Cherry for iOS sends: `host control --no-start`, relaying only
`list`, `subscribe`, `ping`, `screen` and `send_input` (no `create`, `kill`,
`remove`, `shutdown`, `replace` or `update`), `host attach` with no detach
key and a `mobile-…` client ID, and `host transcript`; its locator script is
answered with the gateway's path, never run. A shell, any other command or
option, a subsystem or another host is refused. The phone can still see and
type into Cherry's sessions, and a terminal session runs what it types: the
key narrows what the phone reaches, not what a session can do.

A line for the key that Cherry wrote (with the marker) is replaced, so
pairing again renames it. A line of the user's with the key is left alone.
The file is written to a file beside it and renamed over, keeping its mode
(0600 for a new file, in a `~/.ssh` made 0700), with every other line, blank
and comment lines included, as it was. Cherry never writes through a link (a
linked file, home-manager's say, is left alone and the sheet shows the line
to add there), nor a file it can't read as UTF-8 text. Settings › Devices
lists the `cherry-mobile` lines as Your iPhones, each with Remove…, which
deletes only that line. Other lines are never read as phones or changed.

Phones paired before keys were limited have a line without the options
(`<type> <key> cherry-mobile <name>`), which logs in like the user's own
keys. Your iPhones marks one "Full SSH access", with Limit to Cherry, which
rewrites its line as above.

## Another Mac

A phone pairs with one of the user's other Macs (Settings › Devices, that
Mac's card › Pair iPhone…) from this Mac, without anyone at that Mac: this
Mac shows the code and runs the listener, and does on that Mac, over the
SSH connection it already has (`RemoteDeviceShell`, through its master when
up), what pairing does here (`RemotePhonePairing`, `RemotePhoneKeys`).
Afterwards the phone connects to that Mac directly; this Mac plays no part.

1. Before showing a code, one script there reads the user it logs in as,
   its home, its interfaces' IPv4 addresses, its Bonjour name, the address
   and port its SSH connection reached (`SSH_CONNECTION`) and its host keys,
   and readies the gateway (below). A Mac it cannot reach, whose install
   predates the gateway, or with no address or host key gets no code; the
   sheet says why (Update Session Host… for an old install).
2. The code is version 2: `host` and `ssh` are that Mac's (its Tailscale
   addresses, the address this Mac reached it at, its Bonjour name, other
   addresses; the port this Mac reached), `name` its name in Cherry, `user`
   its user, `fp` its host keys, and `via` this Mac's addresses for the
   listener. A phone that reads only version 1 refuses it, so it never saves
   this Mac's address for that Mac. The listener's answers name that Mac and
   its user.
3. The phone finds the listener at a `via` address (`/hello`), and keeps
   the first `host`, in the offer's order, that takes a TCP connection on
   `ssh`; with none it says it can't reach that Mac and sends no key.
4. Allow writes the key's line into that Mac's `~/.ssh/authorized_keys` by
   the rules above: read there (its text, mode and SHA-256), changed here,
   then written to a file beside it and renamed over it, only while its
   SHA-256 is still the one read (read again once if not); never through a
   link, nor into a file that is not UTF-8, which get the line to add there.

The line's `<cherry>` is
`<home>/Library/Application Support/cherry-host/cherry`, a link beside this
Cherry's installs there to `bin/<build>/cherry`
(`RemoteHostInstall.gatewayLinkRelativePath`, docs/specs/remote-devices.md ›
Phase 2 as built). Pairing points it at the device's install when that
build's `cherry` runs the gateway (`cherry host mobile-gateway` without a
command refuses, exit 1, saying it reaches only Cherry's sessions), else
keeps a link that runs it. Each install points it at the build it placed,
and no install's clean-up removes the build it points to, so the line
outlives updates. The phone's `cherry host control` there reaches that
Mac's daemon, shared by its own Cherry and this Mac's tabs on it.

Each Mac's card lists the phones paired with it (read over its SSH master
only while that is up: the page never connects a Mac), with Remove… and,
for a line from before keys were limited, Limit to Cherry.

