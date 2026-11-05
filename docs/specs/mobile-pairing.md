# Pairing Cherry for iOS with a Mac

Status: implemented in the Mac app (Settings › Devices › Pair iPhone…,
`Sources/Cherry/MobilePairing/`); Cherry for iOS reads the code on the
`codex/ios-app` branch (`Mobile/`, docs/specs/ios-app.md › Identity and
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
   which the phone shows too. Allow adds the key; Deny refuses it and shows
   a new code. Either answer, or closing the sheet, answers the phone.
5. The phone saves the Mac with the address that answered, the user, the
   SSH port and the host key fingerprints of the offer, and connects. Its
   first connect accepts only a host key the offer listed, then pins it.

## The offer

`cherry-mobile://pair?v=1&name=…&user=…&ssh=22&port=…&code=…&host=…&fp=…`

| Item | |
|---|---|
| `v` | 1 |
| `name` | the Mac's name (Sharing settings') |
| `user` | the user Cherry runs as, whom the phone logs in as |
| `ssh` | the SSH port, 22 |
| `port` | the listener's port |
| `code` | the one-time code, base64url without padding |
| `host` (repeated) | where the Mac may be reached, best first: Tailscale addresses (100.64.0.0/10), its Bonjour name (`<LocalHostName>.local`), other IPv4 addresses of interfaces that are up |
| `fp` (repeated) | `SHA256:…` fingerprints of `/etc/ssh/ssh_host_ed25519_key.pub` and `ssh_host_ecdsa_key.pub` (the phone cannot use RSA host keys); a `+` is written `%2B` |

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

`AuthorizedPhoneKeys` adds `<type> <key> cherry-mobile <phone's name>`
(the name on one line, at most 64 characters), unless the file has the key
already. It writes a file beside it and renames it over, keeping the file's
mode (0600 for a new file, in a `~/.ssh` made 0700), and never writes
through a link: a linked file (home-manager's, say) is left alone and the
sheet shows the line to add there. Settings › Devices lists the
`cherry-mobile` lines as Your iPhones, each with Remove…, which deletes only
that line. Other lines are never read as phones or changed.

The key is not restricted: the phone can log in as the user, as the user's
own keys can, and the prompt says so. docs/specs/ios-app.md plans a
`restrict,command="cherry mobile-gateway"` line that reaches only Cherry's
sessions.
