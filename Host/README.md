# Cherry session host

Cherry runs its local terminal, command and agent tabs as persistent sessions
by default, and can attach to sessions on other Macs and Linux machines over
SSH. The sessions live in a portable Rust host on macOS or Linux: each session
has its own holder process (`cherry-host hold`), which owns the PTY, the
program and a headless Ghostty terminal, and a daemon (`cherry-host serve`)
registers the holders and serves the clients. The `cherry` client connects
locally through a Unix socket or remotely through system SSH. Closing Cherry,
detaching, losing SSH, and a crash, restart or upgrade of the daemon leave the
workload running; a reboot of the machine, or a log out that ends the user's
processes, ends it (the Mac app then brings its tabs back as ended tabs). There
is no public network listener or relay.

## Build and install

Build on the machine and architecture that will run the binaries:

```sh
Scripts/build-host release
# Outputs Host/target/release/cherry and Host/target/release/cherry-host
install -d "$HOME/.local/bin"
install -m 755 Host/target/release/cherry Host/target/release/cherry-host "$HOME/.local/bin/"
```

The build requires Rust/Cargo, a C/C++ toolchain, Git, curl, tar, and network
access for dependencies. On macOS, install the Xcode command-line tools; on
Debian/Ubuntu, install `build-essential git curl xz-utils`. The VT build script
downloads checksum-pinned Zig 0.16.0 and builds a pinned Ghostty revision as a
ReleaseSafe library. See [the VT dependency notes](vendor/ghostty-vt/README.md)
for revision, stamp, and toolchain overrides. `Scripts/build-host-vt` accepts a
Rust target triple for the library. On Linux the complete host build and
packaging scripts build native binaries. On macOS `Scripts/build-host` builds
universal ones: each of `aarch64-apple-darwin` and `x86_64-apple-darwin`
with its own VT library, joined with `lipo` and signed (ad hoc, or
`CHERRY_CODESIGN_IDENTITY`), because the Mac app installs them on the user's
other Macs of either kind. A missing Rust target stops the build with the
command that installs it (`rustup target add x86_64-apple-darwin`);
`CHERRY_HOST_ARCHS=native` builds for this Mac only, and says so.
`Scripts/check-helper-archs FILE…` checks that `lipo -archs` lists arm64
and x86_64; `Scripts/install-local-app` (unless `CHERRY_HOST_ARCHS=native`)
and `Scripts/package-dmg` run it on the helpers they bundle.

`Scripts/build-host`, `Scripts/package-host`, and `Scripts/install-local-app`
use Cargo's output directory: `CARGO_TARGET_DIR`, else `CARGO_BUILD_TARGET_DIR`,
else `Host/target`. With either variable set, copy the binaries from
`<that directory>/release/` instead of the path above. `Scripts/build-host`
rebuilds the VT library when it is missing or its stamps do not match (unless
`CHERRY_GHOSTTY_VT_DIR` is set), deletes the previous `cherry` and
`cherry-host` in the output directory before building, and fails if a Cargo
config `build.target` would put them somewhere else.

`Scripts/package-host` creates
`dist/host/cherry-host-<rust-target>.tar.gz` (`universal-apple-darwin` for
universal macOS executables), containing both executables,
documentation, service templates, and dependency notices. Install the matching
archive on each host:

```sh
tar -xzf cherry-host-x86_64-unknown-linux-gnu.tar.gz
install -d "$HOME/.local/bin"
install -m 755 cherry-host/cherry cherry-host/cherry-host "$HOME/.local/bin/"
```

Remote connections require `cherry-host` on the remote SSH command's `PATH`; an
interactive shell's PATH may differ. Verify it with
`ssh my-server 'command -v cherry-host'`.

The supported build targets are macOS arm64/x86_64 and GNU Linux arm64/x86_64.
Linux tests run natively in a Debian 12 container (`Scripts/test-host-linux`),
and CI is configured for Ubuntu 22.04 x86_64 and 24.04 arm64. The Ghostty
archive is built with a glibc 2.31 target, but this is
**not a verified glibc floor for the complete Rust binaries**. Build on your
deployment distribution or validate an archive there. Musl Linux and Windows
are not supported by these scripts.

## Use from the command line

```sh
cherry new --cwd /absolute/path/to/project --name Work
cherry list
cherry attach SESSION_ID
# Press Ctrl-] to detach.
cherry attach SESSION_ID
cherry kill SESSION_ID
cherry remove SESSION_ID
```

`new` prints a JSON session descriptor, including `id`, and defaults to a login
shell (`$SHELL -l`, using the daemon's `SHELL` or the account's shell). To run
a particular program, append `-- PROGRAM ARG...`:

```sh
cherry new --cwd /absolute/path/to/project --name Editor -- nvim README.md
cherry new --cwd '~' --env EDITOR=nvim --owner my-script --tag role=build -- make watch
cherry list --json
```

`--env NAME=VALUE` sets a variable in the session's environment (a letter or
underscore, then letters, digits or underscores; repeatable, the last value of
a name wins; see
[Session environment](#session-environment-and-working-directory)). `--owner`
records who created the session (the Mac app records its app identity and
restores only its own sessions), and `--tag KEY=VALUE` keeps metadata with it
(repeatable; at most 64 tags, keys of 1 to 128 bytes, 16 KiB in all). Use the
`--owner=VALUE` and `--tag=KEY=VALUE` forms for values that start with `-`.

`--cwd` accepts an absolute path, `~`, or `~/…`; the host expands `~` with its
own `HOME` and rejects relative paths. An empty value (`--cwd=`) means the home
directory. Quote `~` so your local shell does not expand it:
`--cwd '~/project'`. Use the `--name=VALUE` and `--cwd=VALUE` forms for values
that start with `-`. A new session starts at 120×32; the first attachment sets
its real size. `list --json` prints
`{"host_id": …, "pending_holders": N, "sessions": […]}`. `pending_holders`
counts the sessions that a daemon which just started still expects back from
their holders (see [Lifetime](#lifetime-service-setup-and-updates)): a
session missing from the list may still come back, so list again while it is
not 0. Each session has `id`, `name`, `cwd`, `command`, `cols`, `rows`,
`state` (`running` or `exited`), `pid`, `exit_code`, `exit_signal`,
`attached`, `clients` (how many clients are attached), `title` and `pwd` (as
the program last reported them), `foreground` (`{"pid", "name"}` of the
terminal's foreground process group while it runs), `owner`, `tags`,
`created_at` (milliseconds since the Unix epoch), `alternate_screen`,
`kitty_keyboard_flags` (0 for legacy key encoding),
`application_cursor_keys` (whether the program turned on application cursor
keys, DECCKM `ESC[?1h`, so unmodified arrows, Home and End go as `ESC O x`
in legacy key encoding; while `kitty_keyboard_flags` is not 0 the kitty
encoding applies instead and never sends them as `ESC O x`; always false for
a session whose holder predates holder link version 4, so false can also mean
unknown), `bracketed_paste` (whether the program turned on bracketed paste,
mode 2004; left out when unknown: for a session whose holder predates holder
link version 7), `request_id` (the request ID of the `new` that created
it), and, for a session that ended because its holder was lost rather than
because its program exited, `ended_by` (`holder_lost`) and `holder_log` (the
host log the holder wrote to, `host.log` in the state directory, when the
daemon's stderr is that file); both are left out otherwise. The plain `list`
prints such a session's state as `Exited (the session host crashed)`.

`kill` explicitly terminates the workload (see
[Lifetime](#lifetime-service-setup-and-updates)). `remove` only removes an
exited session's retained record; it refuses live sessions. Exited sessions
remain listed until removed. Attaching to an exited session shows its final
screen, then exits with its exit code. `shutdown` stops the daemon and is
refused while any session is running; it also ends the holders of exited
sessions. When it returns, the daemon has already removed its socket and
released its lock, so a new daemon can start at once. `start` starts the local
daemon without doing anything else. `restart` (local only) replaces the local
daemon with this `cherry`'s `cherry-host` whatever sessions run (it refuses,
and leaves the daemon running, when it finds no cherry-host it could start): the old
daemon makes way as for an update (below), its sessions carry on in their
holders, and the new one adopts them. Use it when an update of the same
protocol version replaced or removed the running daemon's executable, which
then starts new sessions from whatever build is installed, or none. (`list`,
`new`, `attach` and `control` do it themselves when the daemon reports an
older build than theirs; see [Updates](#updates).) `restart --if-pid PID
--if-executable PATH --if-build BUILD` (any of them) restarts only the daemon
they describe: it asks the daemon's status on the connection that then asks
it to restart, and when another daemon runs (or it cannot say) it leaves it
running and exits with status 4. The Mac app's Update Session Host… uses it,
so a daemon that changed after it looked is never restarted.

`cherry status` describes the daemon and never starts one:

```sh
cherry status
cherry status --json
cherry --host my-server status
```

It prints the daemon's build and protocol, pid and uptime, its socket, state
directory and log, its sessions against the limit of 128 (exited ones
included) and how many run, its connections against the limit of 1024, its
holders (registered, still expected after a restart, lost when it started),
its descriptor limit, whether its executable was replaced or removed since
it started, this `cherry`'s build, and each session with the build of the
holder that runs it (holders keep the build they started with; see
[Updates](#updates)). `--json` prints `{"running": true, "build", "host_id",
"protocol", "host": {…}, "pending_holders", "sessions": [{"id", "name",
"state", "pid", "exit_code", "clients", "owner", "created_at",
"holder_build"}], "client": {"build", "protocol"}}`; `host` is null for a
daemon that predates `status` (its sessions are still listed). With no
daemon running it says so (`{"running": false, "socket", "state_dir",
"log_path", "client"}`) and exits with status 3.

`cherry doctor` checks the local host and says how to fix what it finds,
without starting one:

```sh
cherry doctor
```

It checks this `cherry` and the `cherry-host` it would start (a translocated
or disk image copy, a missing one, a build other than its own), the socket
directory and socket (owner and mode, a stale socket nothing listens on, one
another account serves, a daemon that does not answer), the running daemon
(its protocol and build against this `cherry`'s, an executable an update
replaced or removed, or one on a disk image, its descriptor limit against
its connection limit, and its session and connection limits), the state
directory, the daemon's PID file (`host.pid`: stale, or naming another
process than the daemon that serves), the size of `host.log`, and, when no
daemon runs, sessions whose holders still run without one. Each line is `ok`
or `PROBLEM` followed by a `fix:` line; it exits with status 1 when it found
a problem and 0 otherwise. With `--host` it refuses: run it on that machine
(`ssh my-server cherry doctor`).

`cherry control` connects as `list` does (starting a host, or replacing one
that speaks an older protocol, when needed) and then relays protocol frames
between its standard input and output until either side closes: standard
output starts with the host's `Welcome`, and the caller sends requests, not
`Hello`. The Mac app keeps one such connection per host for listing,
creating, ending, typing into and reading sessions, and for their events.
With `--host`, `--ssh-control-path PATH` makes every ssh the command runs use
the SSH master connection listening at `PATH` (`-o ControlPath=PATH`, next to
`-o ControlMaster=no`), or connect directly when none is; the path is absolute,
at most 100 bytes, without spaces, quotes, backslashes, `=`, `${` or control
characters. The Mac app passes the master connection it keeps per SSH
destination.

Multiple terminals can attach to the same session and type into it. Each
receives the same output; closing one leaves the others connected. `attach`
connects again by itself after a lost connection (see
[Reconnecting](#attach-options)), and keyboard input is never replayed after a
lost connection. The shared terminal uses the smallest requested column count and
row count among its attached clients, so the application fits on every device.
It grows again when the smaller client disconnects. The larger terminal
displays the shared screen at its top left; see the scrollback limits below.
`cherry attach SESSION_ID --takeover` disconnects the other attachments and
continues alone; they end with the outcome `taken_over`, and their unsent
input is discarded. `cherry attach SESSION_ID --client-id ID` names the client
(1 to 128 bytes; the Mac app passes each tab's ID): when an attachment of the
session with the same ID is still there (an earlier run of the same client,
or its connection that the host has not noticed is lost), the host drops it
as the new one attaches, as if its connection had ended: its unsent input is
discarded, and nobody else is told anything. The dropped attachment itself
is sent the error `replaced` (not `taken_over`) as its last message, and a
`cherry attach` that still runs ends on it with the outcome `replaced`
instead of connecting again, which would drop the newer attachment in turn.
So a client that starts again never leaves a stale attachment behind that
holds the shared grid at its old size, and two running copies of one client
never take turns. An attachment that connects again (see
[Reconnecting](#attach-options)) sends the same ID.
Attaching to a session from inside that same session is refused.

### Attach options

- **Detaching.** Ctrl-] detaches after 400 ms, or immediately when another key
  follows it; that key is not sent. Pressing Ctrl-] twice within 400 ms sends
  one Ctrl-] to the session (Vim tag jumps, a nested `cherry attach`). The key
  is also recognized in kitty keyboard and modifyOtherKeys encodings, with Caps
  Lock or Num Lock on, and is ignored inside a bracketed paste. End of input
  (piped stdin) also detaches, after everything read before it. A lone Escape
  is held for 25 ms to tell it from an encoded detach key; a termination
  signal (SIGTERM, SIGHUP) sends what is held to the session before the
  client leaves (waiting up to 250 ms for the transport to take it), so an
  Escape typed just before it still leaves Neovim's insert mode.
  `--detach-key none` disables in-band detaching and forwards every byte; the
  Mac app uses it. Detaching resets the local terminal's modes and leaves any
  alternate screen. Modes whose default comes from the terminal's own
  settings (DECARM 8, alternate scroll 1007, the Meta and Alt key modes 1035,
  1036 and 1039, grapheme clustering 2027) are left as the session last set
  them.
- **Leaving the terminal clean.** On every exit, the CLI writes that reset
  while the terminal is still in raw mode. Except after a termination signal,
  a device-attributes query (`CSI c`) follows the reset when the session left
  the terminal able to send reports of its own (mouse tracking 9, 1000, 1002
  or 1003, focus 1004, colour-scheme notifications 2031, or kitty keyboard
  flags), when a query was passed to the terminal during the attachment, or
  when input read while detaching ends mid-sequence. The CLI then reads the
  terminal's input until the answer arrives, for at most 3 seconds. Mouse,
  focus, kitty-key and query reports that the terminal sent for the session
  are dropped; X10 mouse reports are recognized in the session's encoding
  (one byte per coordinate, or UTF-8 with mode 1005). Keys typed meanwhile,
  including while the CLI waits for the host to confirm a detach, are given
  back to the shell with `TIOCSTI` where the system allows it (Linux can
  refuse it; see `dev.tty.legacy_tiocsti`), and are lost otherwise. This
  applies only when standard input and output are the same terminal.
- **Input order.** Detach is ordered after the input sent before it, so that
  input still reaches the program after the client leaves. The host confirms
  the detach once that input is queued for the program. After the detach key
  the CLI waits a fixed 2 seconds for that confirmation. After end of input it
  waits as long as the input before the Detach keeps moving (the connection
  accepts more of it, or the host sends a `Pong`; see [Protocol](#protocol))
  and gives up after 5 seconds without progress. While more than 1 MiB of
  input waits for a program that is not reading it, the host stops reading the
  connection (see [input backpressure](#connections-and-flow-control)) and
  cannot confirm; a stalled connection has the same effect. When its wait runs
  out, the CLI drops the connection and detaches anyway: it exits 0 with
  outcome `detached`, and says on stderr and in the status file's `message`
  that it detached without the host's confirmation and that input not yet
  delivered to the session was discarded. What is lost is the input still in
  the CLI's buffer and the input the host had not yet written to the PTY.
  Bytes already written to the PTY stay there for the program to read. If the
  host reads the Detach before it notices the dropped connection, it keeps
  the input and delivers it. A program that pauses reading for more than 5
  seconds while more than about 1 MiB of piped input waits looks the same as
  one that stopped, so the rest is discarded.
- **Host closing first.** When the host closes the connection before
  confirming a detach (it stopped or crashed, the SSH connection was lost, or
  it never read the Detach), the CLI also exits 0 with outcome `detached`; the
  message says the host closed the connection without confirming and that
  input not yet delivered to the session may have been discarded. When the
  host stops reading the connection without closing it, the CLI waits at most
  5 seconds for what the host sent before, however long its detach wait
  would last, and then exits the same way; the message says the host stopped
  reading the connection without confirming the detach. Outcome `detached`
  with a `null` `message` always means the host confirmed.
- **Reconnecting.** When the connection is lost while the session may still
  run (its end of file, a failed read or write, a host that accepted and sent
  nothing for 45 seconds, a daemon that crashed, restarted or made way for a
  newer version), `attach` keeps the terminal as it is (raw mode, the screen)
  and connects again for 30 seconds from the loss: at once, then after 250 ms,
  doubling up to 2 s. Once attached again it starts over from the host's new
  snapshot. One attempt may take 5 seconds to connect locally, 15 over SSH,
  and as long again for each answer. Attempts run beside the terminal, so the
  detach key and end of input still act at once; detaching while reconnecting
  exits 0 with outcome `detached` and a message that says so. A reattachment
  that is lost again within 10 seconds continues the same reconnection: its
  window still counts from the first loss. Reconnecting never takes over (even
  when the first attach did), starts or replaces a local host as `attach`
  does, and runs ssh in batch mode (`-o BatchMode=yes -o ConnectTimeout=10`),
  so it cannot prompt. What ssh, or a host started to reconnect, prints never
  reaches the screen once the session shows; its last line goes into the
  message. SIGUSR1 asks a reconnecting `attach` to try again now (the Mac
  app's Reconnect Now, and its Start or MCP `start_process` on a
  reconnecting tab): the next attempt runs at once and the reconnection
  starts over, a new 30-second window from the signal and the backoff from
  250 ms; one that comes during an attempt applies when that attempt fails.
  While attached, and in every other `cherry` command, SIGUSR1 is ignored
  and never ends the process. The live status names the process to signal:
  `pid` and `started` (its kernel start time, `seconds.microseconds` on
  macOS), so a supervisor that runs `attach` under a wrapper such as
  login(1) signals the attachment itself, and only while that pid is still
  it.

  It never reconnects after the program exited, a takeover, a detach or a
  host error, and it stops at once, with outcome `disconnected`, when
  connecting again cannot help: another host identity answers, the host
  speaks a protocol this `cherry` cannot use or replace (a newer one, one
  older than protocol 4, or one that refused to make way), the remote
  gateway is another version of cherry-host, or the host no longer has the
  session. Otherwise it gives up when the window ends; the message then ends
  with `could not reconnect within 30 s (<last error>)`.

  Input is never sent twice, or sent blind. What the lost connection had not
  delivered is dropped with it, since the host may or may not have queued it.
  Terminal input typed while reconnecting is discarded, and
  `cherry: reconnecting; input is discarded` is painted once over the top
  line. After a reattach, the rest of a bracketed paste the terminal began
  before the attachment was back (its start went over the lost connection,
  or it began while reconnecting) is discarded too, until its end marker or
  until the terminal sends nothing for 1 second, so that its lines are not
  run as typed commands. Only then, and only when the paste's start marker
  had been written to the lost connection and the session still has
  bracketed paste (mode 2004) on, is an end marker (`ESC [201~`) sent first,
  so the program does not take what is typed next as pasted. Input from a
  pipe or a file is not read while reconnecting; once some of it went to the
  lost connection, the attachment ends as `disconnected` instead, since a
  part of it may be missing.
- **`--status-file PATH`.** The CLI writes one JSON object to `PATH` (a
  temporary file in the same directory, then a rename, so a reader never sees
  a partial file; mode 0600). Once the first snapshot is painted, and again
  whenever `viewport` or `reconnecting` changes, it holds the live state:

  ```json
  {"outcome":"attached","viewport":false,"reconnecting":false,"exit_code":null,"signal":null,"message":null}
  ```

  `viewport` is true while the window paints a viewport of a shared grid of
  another size; `reconnecting` is true while the attachment connects again.
  `attached` is not a final outcome, and a CLI killed with SIGKILL leaves it
  in the file, so a supervisor should also watch the process. On every exit
  path, including signals and a lost connection, the final outcome replaces
  it:

  ```json
  {"outcome":"exited","exit_code":129,"signal":1,"message":null}
  ```

  `outcome` is `detached` (this client detached; the session keeps running),
  `exited` (the program ended; `exit_code` and `signal` are set),
  `disconnected` (the connection was lost and not reconnected, or the CLI was
  interrupted after attaching; the session may still run), `taken_over`
  (another client used `--takeover`), `replaced` (a newer attachment with
  the same `--client-id` replaced this one; the session keeps running), or
  `failed` (the CLI could not attach, or rejected its command line). `message` explains every outcome except
  `exited` and a confirmed detach, where it is `null`. A final outcome has no
  `viewport` or `reconnecting` field. A `disconnected` or `failed` outcome
  that connecting again can never resolve adds `"reconnectable": false`:
  another host identity answered, a host speaking a protocol this `cherry`
  can neither use nor replace, or a host that no longer has the session. The
  Mac app then stops trying to bring the tab back (see
  [Persistent Sessions](#persistent-sessions)).
- **Exit status.** `attach` exits with the session's exit code when the program
  ended, 0 when it detached (also without the host's confirmation) or was
  replaced by another attachment of its client, 1 for
  errors (including `taken_over` and a lost connection), and 2 for usage
  errors. A `cherry` stopped by signal N exits with 128+N; stopping an attach
  client never terminates the hosted session.

### Remote hosts

For another Mac or Linux machine, install `cherry-host` there and establish
SSH trust and authentication with an ordinary `ssh my-server` first. Cherry
uses normal SSH aliases, keys, agents, and jump-host configuration:

```sh
cherry --host my-server new --cwd '~/project' --name Remote
cherry --host my-server list --json
cherry --host my-server attach SESSION_ID
cherry --host my-server kill SESSION_ID
cherry --host my-server remove SESSION_ID
```

The client runs system ssh with a fixed remote command:

```sh
ssh -T -o ControlMaster=no -o RemoteCommand=none -o ClearAllForwardings=yes \
  -o PermitLocalCommand=no -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -- my-server 'cherry-host gateway'
```

It never becomes an SSH ControlMaster (it can still use an existing one, and
`--ssh-control-path` adds `-o ControlPath=PATH`) and ignores an alias's
`RemoteCommand` and port forwards. `attach` keeps your agent forwarding
settings (see [agent forwarding](#sockets-state-and-access)). `--socket` is
passed on as `cherry-host gateway --socket 'PATH'`. Management commands
(`list`, `new`, `kill`, `remove`, `shutdown`) add
`-a -o BatchMode=yes -o ConnectTimeout=10`, so they never forward an agent,
and must finish within 30 seconds; the desktop cannot answer password or
host-key prompts in the background. `control`, and the connections an
attachment makes to reconnect, add `-o BatchMode=yes -o ConnectTimeout=10`
and keep your agent forwarding settings. `kill`, `remove`, and `shutdown` run
`cherry-host gateway --no-start`. `attach` may prompt and allows 120 seconds
for the handshake.

When the remote machine's `cherry-host` is not on its login shell's `PATH`
(Cherry installs one under the remote home for a device,
[remote-devices.md](../docs/specs/remote-devices.md)), `--remote-host-path
PATH` (global, needs `--host`) runs that one instead: an absolute path is
passed single-quoted (`'/opt/cherry/cherry-host' gateway`), and `~/…` as
`"$HOME"/'…'` (`"$HOME"/'Library/Application Support/Cherry/bin/cherry-host'
gateway`), which sh, bash, zsh and fish all expand to the path under the
remote home, and so do csh and tcsh. A path with a backslash, a `!` or a
control character is refused (fish reads `\'` as an escape even inside
single quotes, and csh and tcsh expand `!` as history there). The Mac app passes it
for a destination its device list gives a path for
(`HostedRemoteHostPaths`).

The Mac app's devices (**Add Mac…** in the project picker,
[remote-devices.md](../docs/specs/remote-devices.md)) use exactly this. Their
check runs `ssh -T -o ControlMaster=no -o RemoteCommand=none
-o ClearAllForwardings=yes -o PermitLocalCommand=no -o BatchMode=yes
-o ConnectTimeout=10 -a -- HOST 'sh -s'` with a POSIX script on standard
input (so any login shell runs it), which prints the Mac's system,
`cherry-host version --json` and `cherry-host status --json` (from
`--remote-host-path`, the remote `PATH`, `~/Library/Application
Support/Cherry/bin`, the newest install in `~/Library/Application
Support/cherry-host/bin`, or the `Contents/MacOS` of `/Applications/Cherry.app`
or `~/Applications/Cherry.app`; never starting or replacing a daemon), and whether a protected folder and the
login keychain can be read over SSH. Add Project on a Mac checks the folder
the same way (`test -d`, `pwd -P`). A device's tabs are sessions of the
daemon on that Mac's default socket, which that Mac's own Cherry shares:
they are created with the owner `<app>@<installation id>`, so neither app
adopts the other's sessions (the other's are attached, never owned).

Add Mac… (and a device's Update Session Host…) installs the Mac app's own
`cherry` and `cherry-host` on that Mac, in
`~/Library/Application Support/cherry-host/bin/<build>/` (with Ghostty's
terminfo and shell integration, and the app's `CherryMCP` for agents in its
tabs, checked by the same `resources_hash` digest), and passes
`--remote-host-path ~/Library/Application Support/cherry-host/bin/<build>/cherry-host`
from then on. Each build has its own directory, which is never changed once
in place: a running signed executable whose pages change is killed by
macOS, and daemons and holders of older builds keep running from theirs.
The check also lists those directories with the SHA-256 of their files, and
the `cherry-host version --json` of any `/Applications/Cherry.app` or
`~/Applications/Cherry.app`. The copy is `tar -cf - cherry cherry-host`
piped into `ssh … '/bin/sh -c …'`, whose one-line script (quoted so that
sh, bash, zsh, fish, csh and tcsh all hand it to sh unchanged) makes
`<build>.partial-<uuid>` with `umask 077` and extracts the archive there
(extended attributes travel with it); it goes through the device's SSH
master when that is up. Then, over `sh -s`: `xattr -c` on both files,
`codesign --verify --strict` of both, `cherry-host version --json` from the
copy (exit 137: macOS refused its signature) and `shasum -a 256` of both,
which must match what was sent; a failed copy is removed. The checked copy
is then renamed to `<build>` with rename(2) (`perl -e rename`), which fails
when the target exists, so concurrent installs of one build never nest.
When `<build>` is there, it is used only when both executables are, their
hashes match, both signatures verify and cherry-host runs; a damaged one
that no process runs from is moved aside and replaced, one in use is left
and the copy goes to `<build>-<hash>`. A partial copy nested inside a build
by an older installer is removed. When the check found `<build>` (or
`<build>-<hash>`) with the same hashes nothing is copied, but it is checked
the same way (and copied after all if it fails). The check lists every build
directory, incomplete ones too (a missing file's hash is `-`), so they get
repaired. The scripts run the system tools by absolute path (`/usr/bin/stat`,
`/usr/bin/tar`, `/usr/bin/shasum`, `/usr/bin/xattr`, `/usr/bin/codesign`,
`/bin/ps`, `/usr/bin/perl`), so a PATH with GNU coreutils first changes
nothing. Once in place, the new build's `cherry-host status --json` asks the
daemon again (the check may have found no cherry-host to ask): a newer
protocol, or one before 4, is refused and the device is not changed; another
daemon it did not know of is reported.

With the helpers go Ghostty's terminfo (`xterm-ghostty`) and shell
integration, as `<build>/terminfo` and `<build>/Ghostty` (the tar stream
carries both trees; `xattr -cr` clears them). They are checked by digest
like the helpers' SHA-256 (`resources_hash`: the SHA-256 of the `shasum -a
256` lines of every file in both trees, sorted by path), the check reports
each build's digest, a build without them (installed by an older Cherry)
does not match, and `verify_dir` requires it. A device's terminal tabs set
`TERM=xterm-ghostty`, `TERMINFO` and `GHOSTTY_RESOURCES_DIR` to them, and run
its login shell as `/bin/bash --noprofile --norc -c 'exec -l <shell>'` with
Ghostty's zsh (`ZDOTDIR`), bash (`--posix` and `ENV`) or fish
(`XDG_DATA_DIRS`) integration, so the host sees the shell's OSC 7, titles
and prompt marks as it does This Mac's.

Every Cherry installation that uses a build marks it: the install, each
check and each connection of a device's control (at most every 6 hours)
touch `<build>/.used-by/<installation id>`. Afterwards a build is removed
only when it is not the current one, not one of the two most recently
installed others, no running process (from `ps`, read once before anything
searches it) or the daemon (`cherry status --json`: its executable, its
build, its running sessions' holder builds) uses it, no marker is younger
than 30 days, and it was installed (`<build>/.installed`, else the
directory's time) more than 7 days ago; so another Mac whose device record
points at a build keeps it. Partial copies and directories moved aside go
after an hour unless in use. A device whose recorded cherry-host is gone
anyway says so ("Its session host is missing") and offers **Reinstall
Session Host…**.

Which daemon runs on that Mac's default socket (`cherry-host status
--json`) decides what the installer does:

| Daemon there | What happens |
|---|---|
| none | install; the first tab's gateway starts it |
| this protocol | install; the gateway relays to that daemon |
| an older protocol (4 or later) | warn (Cherry there is older: update it too), install; the gateway's `Replace` moves the daemon to this build and its sessions carry on |
| a newer protocol | refused: update Cherry on this Mac |
| older than protocol 4 | refused, with how to stop it (see [Updates](#updates)) |

A daemon of the same protocol is handed over to the new build only when it
runs from one of this installer's own directories (under
`~/Library/Application Support/cherry-host/bin/`, or the older manual place
`~/Library/Application Support/Cherry/bin/`; never the other Mac's
Cherry.app's), its build is not newer than the new one, and the user asked
for the install or update; the new build's `cherry restart` then moves it,
and the sessions' holders keep running and register with the new daemon.
The gateway itself never hands a remote daemon over to another build of
its protocol (see [Updates](#updates)), so a device's own Cherry and this one
never take turns replacing each other's daemon.

An SSH server allows a limited number of sessions on one connection
(`MaxSessions`, 10 by default). When ssh reports that the master connection
at `--ssh-control-path` refused a session (`Session open refused by peer`)
before the gateway's preamble arrived, the client connects again once,
directly, without the ControlPath. The Mac app shares one master among at
most 8 attach adapters per destination
(`HostSSHMasterManager.Configuration.maxChannelsPerMaster`), leaving room
for its control connection and one-off commands; further adapters share a
second master to the same destination (a shard, `dest#2`, then `dest#3`, up
to 8), which starts once the masters up have one free slot left, so it is up
before it is needed and stops when nothing uses it and the others have room.
A shard that cannot log in is not tried again for a minute (or until the
first master comes up again). Only an adapter that finds no master with room
(the next one still starting, or backing off) runs its own ssh; the app's
one-shot commands and scp connect directly when a master refuses a session.

When the client expects a particular host identity (`--expected-host-id`, or
the host an attachment reconnects to), the remote command is
`env CHERRY_EXPECTED_HOST_ID='ID' cherry-host gateway …`. The Mac app passes
one for every tab it attaches, and for its control connection once it trusts
the host's identity. The gateway never replaces or reports a daemon of
another version whose identity differs: it relays it, and the client fails
with
`host identity changed (expected X, received Y)`, as it does locally. A
cherry-host of another version ignores the variable and still reports its
version through its preamble. If you restrict an SSH key to the command
`cherry-host gateway` (`command=` in `authorized_keys`, or `ForceCommand`),
the forced command drops the variable, and the gateway then replaces an
older daemon without checking its identity.

The gateway prints `CHERRY-GATEWAY <version>` (`CHERRY-GATEWAY 6` for this
version) on a line of its own before relaying protocol frames. The client
skips up to 64 KiB of output that a remote shell prints before that line.
Beyond that it fails with "the remote shell printed output before cherry-host
gateway started; remove output from non-interactive shell startup files such
as ~/.bashrc" and the first line printed. A preamble of another version means
the `cherry-host` on the remote `PATH` is another version:
`protocol version mismatch: the remote cherry-host gateway speaks version N,
this cherry speaks version M; install the same Cherry version on both
machines`. A gateway that cannot reach a usable daemon (none is running for a
command that never starts one, one of another protocol version that it does
not replace, its socket directory is not trusted, or it does not answer)
prints `cherry-host: REASON` on stderr and exits 1 before its preamble. The
client shows that line once, as its own error `cherry-host on my-server:
REASON`; the rest of ssh's stderr reaches you as it arrives. Without
`--no-start`, the gateway starts a daemon when none is running and replaces
one that speaks an older protocol (see [Updates](#updates)).
`cherry-host gateway --no-start` never starts or replaces a daemon (when none
is running it creates nothing and fails) and otherwise makes the same trust
and version checks. With no daemon running, `cherry --host my-server kill ID` fails with
`cherry-host on my-server: no cherry-host is running at PATH (this command
never starts one)`. When the connection closes before the preamble for
another reason, such as `cherry-host` missing from the remote `PATH`, the
client says the SSH connection closed before the gateway started, below ssh's
own errors.

### Starting the daemon

`list`, `new`, `attach`, and `control` start a daemon when none is running:
locally through `cherry-host start`, remotely through `cherry-host gateway`.
They also replace a daemon that speaks an older protocol (see
[Updates](#updates)). `kill`, `remove`, and `shutdown` never start or replace
one; they fail with `no cherry-host is
running at PATH (this command never starts one)`, or report the other
version. Remotely they run `cherry-host gateway --no-start`. `start` is local
only, and neither `cherry start` nor `cherry-host start` replaces a daemon.

`cherry-host start` starts a detached daemon, with its stderr in `host.log`
(see [Sockets, state, and access](#sockets-state-and-access)), or the systemd
user service when it is enabled (see
[Lifetime](#lifetime-service-setup-and-updates)), and returns once it answers.
`cherry-host serve` runs the daemon in the foreground with stderr on the
terminal; the systemd unit uses it. Both take `--socket PATH`.

The client finds `cherry-host` through `CHERRY_HOST_PATH`, then a sibling
`cherry-host` next to the `cherry` executable, then `PATH`. It refuses to start
a sibling under a macOS App Translocation path or, on macOS, on a read-only
volume (such as a mounted disk image), because sessions would stop working when
that location goes away; move the app to `/Applications` or set
`CHERRY_HOST_PATH`. On Linux a sibling on a read-only file system is started
normally, so read-only system directories work.

`cherry-host version --json` prints what the executable is, without
touching any daemon: `{"protocol":7,"build":"…","version":"0.1.0",
"os":"macos","arch":"aarch64","min_macos":"11.0"}` (`min_macos` is null on
Linux). `cherry-host status --json [--socket PATH]` says whether a daemon
answers at the socket, from one Hello, and never starts, replaces or changes
one: `{"running":true,"state":"ready","protocol":7,"build":"…",
"host_id":"…"}`; `state` is `absent` (`running` false and the rest null),
`ready`, `older` (an older protocol, which `list`, `new`, `attach` and
`control` would replace), `other` (a newer protocol, or one too old to
replace), `unresponsive` (with `error`), or `error` when the socket could
not be checked at all: its directory is not private to this user, another
account listens on it, or connecting failed otherwise (`running` false, the
rest null, and `error` saying why, for example `{"running":false,
"state":"error",…,"error":"refusing to use /tmp/x/host.sock: …"}`). Both
always print JSON with `--json` and exit 0 whatever they report, so a client
can parse every outcome; without `--json`, `status` prints one line. Cherry's
Add Mac check runs them on the other machine
([remote-devices.md](../docs/specs/remote-devices.md)).

`cherry control --no-start` relays like `control` but, like `list
--no-start`, never starts or replaces a host.

`cherry list --json --no-start` lists without ever starting a host or
replacing one of an older protocol (through `cherry-host gateway --no-start`
with `--host`): when none of this version runs it says "no cherry-host is
running" and exits 1. Cherry uses it to look at another Mac's sessions
(Background Sessions, the project picker) without starting anything there.

`cherry-host project-info --json PATH…` describes project folders on this
machine for a Cherry on another Mac, in one round trip over its SSH master:
`{"version":1,"projects":[{"path":"…","exists":true,"is_directory":true,
"git":{"top_level":"…","common_dir":"…","worktrees":"<git worktree list
--porcelain -z>"},"cherry_toml":{"size":123,"text":"…"}}]}`. `git` is null
(with `git_error`) outside a repository; `cherry_toml` is null when the
folder has none, and has no `text` (but an `error`) when it is larger than
256 KiB or not UTF-8. It runs only the `git` that `CHERRY_GIT` names
(Cherry's script picks one that will not ask to install the command line
tools); without it no git runs (`git_error` is `git not found`), never one
from `PATH`. Git runs only for `rev-parse` and `worktree list`; it reads
at most 64 paths, never starts or talks to a daemon and changes nothing. It
ships with the cherry-host Cherry installs, so its answer's format follows
the app; an older cherry-host without it makes the app say to update it.

`cherry-host ports --json PID…` says which TCP ports the process trees of
these pids of this machine listen on (a session's program, `SessionInfo.pid`,
and everything it started), for a Cherry on another Mac that forwards them
(docs/specs/remote-devices.md, phase 4a), in one round trip over its SSH
master: `{"version":1,"processes":[{"pid":123,"alive":true,"ports":[{"port":
3000,"host":"127.0.0.1","pid":130,"command":"node"}]}]}`. A pid that is gone
is `alive: false` with no ports; `host` is the address listened on (`*` for
every address). It reads the process table (`ps`) and, on macOS, `lsof
-a -p <tree> -iTCP -sTCP:LISTEN`, on Linux `/proc`; when those cannot be
read it says why in `error` (and reports no ports). At most 256 pids; it
never starts or talks to a daemon and changes nothing. Like `project-info`
it runs as a one-shot command over the master rather than as a request on
the control connection, so the protocol (and a daemon another app shares)
is unchanged, and an older cherry-host without it makes the app say to
update it.

Cherry MCP for agents in a device's tabs (docs/specs/remote-devices.md,
phase 4b) uses neither the host nor its protocol: the app reverse-forwards
a listener of its own control server to that Mac over the device's SSH
master (`ssh -O forward -R <DARWIN_USER_TEMP_DIR>/cherry-mcp-<hash>/control.sock:<here>`; the
directory is 0700 and this account's, and the socket a dead master left is
removed first, since sshd's StreamLocalBindUnlink is off by default), and
the tabs' Create carries `CHERRY_CONTROL_SOCKET` (that path),
`CHERRY_MCP_TOKEN`, `CHERRY_MCP_HELPER` and `CHERRY_CONTROL_MACHINE` in
its environment like any other variable. The holder does nothing with them.
The server's sshd must allow remote forwards of Unix sockets:
`AllowStreamLocalForwarding` and `AllowTcpForwarding` yes or remote (sshd
denies one under `AllowTcpForwarding local`); both are yes by default.

`--socket /absolute/private/path/host.sock` selects a separate host (its own
daemon and state directory); with `--host`, that path is on the remote machine.
`--expected-host-id UUID` rejects a different host identity before acting,
and before replacing an older daemon.
`new --request-id UUID` makes retries of the same creation idempotent: a retry
with the same launch arguments returns the existing session, even from a
differently sized terminal, and reusing the ID for different arguments is
rejected. The host keeps that receipt until the session is removed or 4096
newer requests evict it; after that the same ID creates a new session.

## Use in the Mac app

### Local tabs

Local terminal, command and agent tabs run as persistent sessions on This
Mac's daemon by default (**Settings › Sessions › Run local terminals as
persistent sessions**, which applies to new tabs). Each tab's Ghostty surface
runs `cherry attach … --detach-key none --status-file … --client-id <tab ID>`
(the attach adapter),
and the app keeps one `cherry control` connection per host. Quitting Cherry,
a crash of Cherry or an update leaves the programs running, and each project
window reopens its saved tabs attached to them. Closing a tab (Cmd-W) ends
its session; **Detach Tab** (Cmd-D, or Detach in the sidebar's menus) closes
the tab and leaves its session running in the background. **Cmd-Z** brings
back a tab just closed or detached, where it was and attached to the same
session again (no new Create), while its notice would stay (about 6 s); a
closed tab's session is ended (Kill, then Remove) only once that has passed,
or when its window closes or Cherry quits, and meanwhile it is recorded in
`sessions-to-end.json` so the next launch ends it if Cherry exits first.
Quitting or
closing a project window while local sessions run there asks one question,
**Keep N sessions running in the background?**: **Keep Running** (the
default) leaves them running for next time, **End Sessions** ends them (and
the sessions of that window's saved tabs no open tab shows), and **Cancel**
stays; it also names the native programs that stop anyway, so no second
dialog follows. **Don't ask again** stores the answer in **When quitting or
closing a window** (Ask, Keep Running, End Sessions). A quit that keeps
sessions exits at once, touching no tab (the attach adapters end with the
app), unless native tabs have busy programs to stop or a tab closed just
before still has a session to end (its Kill under way, its **Cmd-Z** still
possible, or its Create still unanswered); that quit, and one that ends
sessions, orders every window out first, then stops the native programs and
ends the sessions, waiting at most 10 s. A closed window likewise leaves
the screen before its tabs are torn down. A log out, restart or
shut down does not ask about sessions and ends none itself (the system then
ends them with the user's processes), but warns about programs still running
in them, as it does for native tabs, so the log out can be cancelled, and an update (the app on disk has
another build number than at launch) keeps them without asking. Removing a
worktree ends its sessions. Closing a tab whose program is at work (an
agent, a command, or a terminal running a job) asks **Close “<name>”?**
first: **Close** stops it, **Detach Instead** keeps it running in the
background, **Cancel** keeps the tab. Detaching asks nothing, nor does
closing a tab whose program keeps running (a session it only attached to);
a notice at the bottom of the window says where it went, with **Reopen**
(after such a close, only when that program was at work). Sessions on SSH
hosts, and sessions a tab only attached to, always keep running when you
close a tab, close a window or quit.

A session of this app that no open tab shows is in the background: its
window was closed with Keep Running, its tab was detached, or it is a
command tab a restore set aside because another tab runs that command.
The Cherry menu bar icon lists them under
**Background sessions**, with the project each belongs to and what it does
(`idle`, the program in the foreground, `running`, `attached`, or `exit N`);
a terminal whose shell exited with status 0 is removed instead, as its tab
would have closed, while **Close a tab when its shell exits** is on.
Clicking one opens (or focuses) its project's window, whose restore brings it
back with its sibling tabs, and shows its tab; a session no saved tab names
becomes a tab of its worktree with its kind and name. **End** (twice, for a
running session) kills it, waits for its exit and removes it; an ended one is
only removed. **Cherry → End Background Sessions…** and **End All…** (in that
list and in **Settings › Sessions › Background Sessions**) end them all after
asking, on a project window. Ending one does not change its window's saved
tabs: that window's next restore finds the session gone and drops its tab.
Sessions of the `cherry` CLI, of **Create & Attach** and of other apps (Cherry
Sessions, CherryDev) are never listed or ended there; Persistent Sessions
manages them. The list never starts a daemon to find out: it shows what
Cherry's control connection knows, and connects only when this run reached
the host already or local tabs run in it. When Cherry opens and sessions at
work (an agent, a command, or a terminal running a job; never an idle shell)
are in the background that it has not told about, it says so once in a
notice at the bottom of its first project window, with **Reopen** (each back
in a tab of its project's window) and **End…** (asks, then ends those
sessions); its time runs only while that window is in front, and it waits
for a closed tab's notice to go. **Settings › Sessions › Tell me about
background sessions when Cherry opens**,
`sessions.backgroundNoticeAtLaunch`, turns it off. Sessions
kept on purpose are never named: a detached tab's, a window's closed with
Keep Running or while **When quitting or closing a window** is Keep
Running. Nor are those a notice named once it
is dismissed, times out or is acted on.

A terminal tab whose shell exits with status 0 closes by itself and its
ended session is removed (`exit` ends the shell with the last command's
status, so after a failed command the tab stays); on a window's last tab the
window closes too, as with Cmd-W, unless a note is shown there (**Settings ›
Sessions › Close a tab when its shell exits**, on by default). A shell that fails or is killed, a shell that ends
within its first second, command and agent tabs, and tabs attached to a
session they do not own stay open and show how the program ended. Such a
terminal that exited with status 0 while Cherry was closed is not restored;
its session is removed. Native tabs cannot report their shell's status (their
launch goes through login(1)), so they close whenever their shell ends.

When the local host cannot run sessions, new tabs run as ordinary native tabs
and Settings › Sessions says why: the app runs from a disk image or an App
Translocation location, it has no `cherry` helper, the daemon did not start a
session (Cherry tries again after 30 seconds), or another copy of the app
with the same app data is running. Only one copy per app identity (its
Application Support folder) owns This Mac's persistent sessions and saved
tabs: the first takes `Application Support/<identity>/instance.lock`, and a
second copy (for example `swift run Cherry` while Cherry.app runs, or
`open -n`) neither restores, saves nor ends them. Such a copy says so once,
in a sheet on its first project window (**Persistent sessions are off in this
copy**).

The settings are the user defaults `sessions.persistLocal`,
`sessions.closeTabOnExit`, `sessions.backgroundNoticeAtLaunch` (booleans) and
`sessions.onQuit` (the string `ask`, `keep` or `end`). As a launch argument,
give a boolean as a plist boolean: `-sessions.persistLocal '<false/>'` (or
`'<true/>'`); `-sessions.persistLocal NO` or `0` is ignored. The string takes
its value as is: `-sessions.onQuit keep`.

### Persistent Sessions

Open **File → Persistent Sessions…** (`Cmd-Shift-R`). Choose **This Mac** or add
an SSH destination, create a session with its host-side directory, then attach.
The directory must be absolute, `~`, or `~/…`; Cherry rejects a relative path
before contacting the host, and an empty one means `~`. The session list offers
Attach, Attach & Take Over, Terminate, and removal of exited records. Forgetting
a saved destination does not terminate its sessions. You can attach from your
laptop while the same session remains open on another Mac or in a command-line
terminal. Both can type, so coordinate commands when another person is using the
session. In a session tab Ctrl-] reaches the program; use Disconnect to detach.

A session tab's bar offers Disconnect while attached and Reconnect after a
disconnection. When the session has ended on its host, the bar shows how it
ended and offers **Remove from Host** (deletes the exited record and closes the
tab) and **Close Tab** instead; a workspace's last tab stays open. Reconnect in
the menu bar and the sidebar is disabled for such a tab.

A tab of an SSH host whose `cherry attach` gave up (it reconnects by itself
for 30 seconds of awake time after a lost connection) or could not reach the
host waits for that host instead of staying disconnected: its bar says
"Waiting for the host to answer…", and a bar over the terminal says how many
tabs wait for the host ("3 tabs waiting for my-server") with **Retry Now**.
Cherry asks the host, once for all of its waiting tabs, after 0.25 seconds,
then after doubling delays up to 8 seconds, and at once when the Mac wakes
from sleep or a network becomes available (after SSH could not sign in, or
refused the host's key, only then or on Retry Now, since every try is a
login); once it answers, each tab whose
session it still lists attaches again. A tab stops waiting, and says why,
when another host identity answers, the host speaks a protocol this Cherry
cannot use, or it no longer has the session. Disconnect, Reconnect and
closing the tab end the wait. Tabs of an SSH host that could not be reached
when a project window opened stay saved, and come back once the host answers
while Cherry runs.

**Create & Attach** uses one request ID per creation. After a connection
failure Cherry retries once with the same ID, so the host creates at most one
session. When the retry also fails, Cherry asks you to refresh before trying
again, because the session may have been created.

Cherry remembers the identity of each saved SSH destination. When one answers
with another identity, for example because a different machine now answers for
that name or its state directory was deleted, Cherry refuses to connect and
offers **Trust New Host Identity**. Attaching always checks the identity the
session was listed with.

The session helpers run with the variables of your login shell
(`SSH_AUTH_SOCK`, `PATH`, `LANG`, and also `CHERRY_HOST_PATH` or
`CHERRY_HOST_SOCKET` when set there) layered over Cherry's own, so SSH agents
and ProxyCommand tools configured in shell startup files work. Cherry captures
these variables by running your login shell as a terminal tab would (csh and
tcsh read the command from standard input). If your shell rejects the flags
or exits without printing them, Cherry uses `/bin/sh -l` (`/etc/profile` and
`~/.profile`) for now; if that fails too, the helpers get Cherry's own
environment only. A capture from your own shell is kept until Cherry quits.
Otherwise Cherry tries your shell again after 15 seconds, then after doubling
delays up to 5 minutes, and at once when you press Refresh in the Persistent
Sessions sheet. When ssh fails to connect or authenticate and your shell's
environment was not captured, the sheet says so. Attaching, terminating, and
removing use the environment of the last list or create.

For a self-contained test build, run `Scripts/package-dmg`, open the resulting
`dist/Cherry Sessions-<architecture>.dmg`, and drag **Cherry Sessions** into
Applications. Its distinct icon, bundle identifier, settings, and Application
Support folder let it run alongside Cherry. Both apps use the same local
daemon (`/tmp/cherry-host-<uid>/host.sock`), so **This Mac** in Persistent
Sessions lists the same sessions in each, but each app restores and owns only
the tab sessions it created itself. The daemon runs the `cherry-host` of
whichever app started it. An app whose helpers speak a newer protocol replaces
a daemon that speaks an older one (its sessions carry on), after which the app
of the older version cannot use it, so build both from the same version. The
app includes both session helpers; **This Mac** needs no separate CLI
installation. Open a project and run a command in a tab, or choose **Create &
Attach** in Persistent Sessions and run one there, then quit the app and
reopen it: the tab comes back with the same program. This local build is
ad-hoc signed by default and is not notarized. While the app runs from the
disk image or an App Translocation location, its local tabs are ordinary tabs
and **This Mac** is unavailable in Persistent Sessions; SSH hosts still work.

`Scripts/install-local-app` bundles `cherry` and `cherry-host` beside the Mac
app executable. It needs Rust for that; `CHERRY_SKIP_HOST=1` installs the app
without them, and Persistent Sessions is then unavailable in that copy (its
local tabs run natively). It builds them with the app's CFBundleVersion as
their build (`CHERRY_BUILD_ID`), so the updated app's helpers hand the
running daemon over to the new build (see [Updates](#updates)).

**Settings › Sessions › Session Host** shows the local daemon's status (what
`cherry status` reports: build, uptime, sessions and connections, sessions
whose holder runs another build) and offers **Reveal Log** (`host.log` in the
Finder), **Copy Diagnostics** (Cherry's version and what `cherry status` and
`cherry doctor` print, for a bug report) and **Restart Host…** (`cherry
restart`, after asking; running programs keep running and tabs reconnect).
Cherry's own messages about tabs and sessions are in the unified log,
subsystem the app's bundle identifier and category `Sessions` (`log stream
--predicate 'category == "Sessions"'`).

Cherry looks for the `cherry` client in this order:

1. `CHERRY_CLI_PATH` in Cherry's own launch environment, for example
   `open --env CHERRY_CLI_PATH=/absolute/path/to/cherry ~/Applications/Cherry.app`
   while the app is not running.
2. The `cherry` beside the app executable. A packaged release app, which
   `install-local-app` and `package-dmg` build by default, stops here.
3. Any other run, including a debug `.app` (`CHERRY_CONFIGURATION=debug
   Scripts/install-local-app`, `CherryDev.app`) and an unbundled
   `swift run Cherry`, then tries `CARGO_TARGET_DIR` (else
   `CARGO_BUILD_TARGET_DIR`) when set, then the `Host/target` of the checkout
   Cherry was built from, each `debug` before `release`, and then `PATH`.

Only Cherry's own environment counts here, not your login shell's. An app
started with `open`, Finder, or the Dock gets launchd's environment, so
exported shell variables do not reach it, and step 3 finds only `Host/target`
and launchd's `PATH`. The client then finds `cherry-host` as described in
[Starting the daemon](#starting-the-daemon), with the login shell's variables:
through `CHERRY_HOST_PATH`, beside the client, or on your login `PATH`.

For development, run `Scripts/build-host debug` before `swift run Cherry`.
`swift run Cherry` has Cherry's own app identity: while Cherry.app runs it is a
second copy (native tabs, no saved tabs), and otherwise it restores, saves and
ends Cherry.app's tabs and sessions on the default daemon. To keep a
development run apart, give it a private `HOME` and `CFFIXED_USER_HOME`
(which Foundation's home directory, and so Application Support, follows) and
private sockets (`CHERRY_HOST_SOCKET`, `CHERRY_CONTROL_SOCKET` in a 0700
directory), as `Scripts/cherry_private_host.py` does for the test scripts
(its `stop DIRECTORY` command tears such a run down), or use
`CherryDev.app`, which has an identity of its own.
`script/build_and_run.sh` builds the helpers and bundles them into
`CherryDev.app`, unless `CHERRY_SKIP_HOST=1`.

SSH hosts get sessions only: remote project discovery, Git/worktree
operations, cherry.toml commands, previews/port forwarding, file transfer, and
remote MCP integration are not implemented.

## Sockets, state, and access

The default socket is `/tmp/cherry-host-<uid>/host.sock`. Set
`CHERRY_HOST_SOCKET` or pass `--socket` to choose another absolute path of at
most 100 bytes. The local `cherry` makes a relative path absolute against its
current directory. `CHERRY_HOST_SOCKET` is not sent to a remote host; use
`--socket` with `--host`. The daemon creates the socket's directory with mode
0700 when it is missing; its parent must exist. Clients trust a socket only
when its directory is a real directory (not a symlink) owned by the current
user with no group or other permissions, the socket file is a socket owned by
that user, and the process listening on it runs as that user. The daemon also
drops connections from other users. When another account created the directory
first, the error names its owner; remove it or choose another socket path. The
socket is mode 0600. The daemon refreshes the timestamps of the socket and its
directory hourly so age-based `/tmp` cleaners leave them alone. A starting
daemon never replaces a socket that answers, even when no daemon holds its
lock; it removes a leftover socket only when connecting to it is refused. A
daemon that shuts down cleanly removes its socket.

Durable state lives outside `/tmp`, in a mode 0700 directory per socket:
`~/Library/Application Support/cherry-host/<key>/` on macOS and
`${XDG_STATE_HOME:-~/.local/state}/cherry-host/<key>/` on Linux. `<key>` is
`default` for the default socket and a hash of the socket path otherwise. It
holds:

- `host-id`: the host identity. It survives daemon restarts, reboots, and
  `/tmp` cleanup; deleting it gives the next daemon a new identity.
- `host.lock`: held while a daemon serves that socket; a second daemon for the
  same socket refuses to start.
- `host.log`: the stderr of a daemon started by a client, and of the holders
  it starts. Under systemd, stderr goes to the journal instead. Each line of
  the daemon's and holders' says when (UTC), which process, its role and
  build: `2026-09-27T10:15:00.123Z cherry-host[1234] daemon 20260927101500.abc1234: started (…)`
  (`holder` for a holder). A daemon logs such a startup line (protocol, pid,
  socket, state directory, holders expected, sessions lost, descriptor
  limit). When `host.log` is over 8 MiB the daemon moves it to `host.log.1`
  (replacing an older one), while it holds `host.lock`: when it starts and,
  checking every minute, while it runs. It and its holders then write to a
  new `host.log`.
- `handover.json`: the last same-protocol handover whose replacement was
  not the newer build (see [Updates](#updates)).
- `host.pid`: the running daemon's pid and when it started, its build, start time and socket, written
  once it holds the lock and removed when it exits normally. One whose process
  is gone is stale (`cherry doctor` reports it); the next daemon writes it
  again.
- `sessions/<id>.json`: one manifest per holder (the session ID, the holder's
  process ID and start time, when it was created, its link version), so that
  a daemon that starts knows which holders to expect. A holder removes its
  manifest when it exits.

These directories are never removed automatically. The sessions themselves,
their screens and their pending input live in the holder processes, not on
disk.

Sessions get `SSH_AUTH_SOCK=<socket directory>/agent.sock`, a link that
follows the clients that use sessions, as with tmux. Locally, `cherry new` and
`cherry attach` repoint it at the caller's own `SSH_AUTH_SOCK` when that is a
socket owned by the user; `list`, `kill`, `remove`, and `shutdown` leave it
alone. A remote gateway repoints it on every connection at the agent
forwarded to that connection, and the client runs ssh with `-a` for every
command except `attach`, so only `cherry --host my-server attach` moves it,
and only with agent forwarding enabled for that host in your SSH
configuration.

A client's agent is lent only while that client uses sessions. It stays lent
for 2 seconds after the client's last connection ends, which covers
`cherry new` followed by `cherry attach` and quick reconnects. After that the
link returns to the most recently lent agent of a client that still lends
one, or is removed. So a session has no agent while nobody who lent one is
connected; a session started by `cherry new` alone has none once that
command has finished, until someone attaches. An agent socket that
disappears (sshd removing a forwarded agent when its connection ends,
`ssh-agent -k`) is dropped within a second, even while its client stays
connected, so the link never keeps naming a `/tmp` path that another local
user could create again. The socket directory also holds `agent-clients/`:
one symlink per lending client process ID, plus `.lock`. A long-lived shell
therefore uses the agent of the most recent client that created or attached
a session and is still connected. (A remote non-interactive shell startup
file that sets `SSH_AUTH_SOCK` itself moves the link for every command, and
the link moves back when that command ends.)

## Session environment and working directory

The daemon may be started by any client, so it closes descriptors it inherited
and runs with working directory `/`. From its environment, sessions receive
only `HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `TMPDIR`, `TZ`, `LANG`, `LC_*`,
`XDG_RUNTIME_DIR`, and `XDG_*_HOME`, and a daemon started by a client keeps
nothing else, so another tab's identity, `PWD`, or a stale agent socket never
reaches later sessions. `PATH` defaults to
`/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` when the daemon has none; a login
shell re-reads your profile. The host's defaults `TERM=xterm-256color`,
`COLORTERM=truecolor`, `TERM_PROGRAM=Cherry`, and `SSH_AUTH_SOCK` (as above)
come next.

Then come the variables the client sends with the session, which replace any
of those: any variable with a non-empty name without `=` or NUL and a value
without NUL, at most 1024 of them and 256 KiB in all (clients run as the
daemon's user, so they may set whatever their own shell could). When a client
sends any locale variable, it replaces the daemon's locale variables as a
whole. `CHERRY_SESSION_ID` and `PWD` are always the host's: `PWD` is the
working directory as the client named it when that names the same directory
without `..`, and the resolved path otherwise. `cherry new` sends the
invoking terminal's `LANG`, `LC_ALL` and `LC_*` locale categories and `TZ`,
and the `--env` variables, which replace them (a locale variable given with
`--env` replaces the terminal's whole locale). The Mac app sends a tab's
whole environment, as a native tab would get it. The daemon raises its own
descriptor limit (up to 16384); sessions start with the limit it had before.

The working directory must be absolute, `~`, or `~/…`, expanded with the
daemon's `HOME`, and must exist on the host. The descriptor reports the resolved
path. The host never resolves a relative path against its own working directory.

## Lifetime, service setup, and updates

Sessions survive app exit, SSH disconnection, and the daemon crashing, being
stopped by a signal, restarting or being replaced by a newer version: each
session's holder process keeps its program, PTY, terminal state and pending
input, and registers with the next daemon. They do not survive a reboot of the
host, the crash of their own holder, or the operating system killing the
user's processes at logout. When a session's holder crashes or is killed
while a daemon runs, the session is reported exited with code 1 and
`ended_by: "holder_lost"` (with `holder_log`, see `list --json`), in `List`
and in its `exited` event. The daemon then ends what is left of the program:
once the holder is gone (it waits up to 2 seconds; a holder that only lost
its link and still runs keeps its program, and dials again), it sends
SIGHUP, then SIGTERM and SIGKILL, each after the kill grace (2 s), to the
processes whose session ID is the program's recorded PID, and to the program
itself only while its PID still belongs to the process recorded when the
holder registered (its start time). So a program that ignores the hangup of
its closed terminal does not run on untracked. A holder that panics logs the
time (UTC), the session, its PID and its build (version, holder link and
protocol versions, executable) to its stderr, the daemon's log, before it
ends. A
holder killed while no daemon runs (a log out or restart kills them all) leaves
its manifest behind, where a holder that exits removes its own: the next daemon
drops such manifests and lists their sessions as `lost_sessions` for its
lifetime, so a client can tell them from sessions that were ended (Kill,
Remove, or their program's exit), which are never there. The Mac app keeps a
copy of those it sees, and brings a saved tab whose session is lost back as
ended ("Ended when you logged out").
A session's terminal has IUTF8 set (a canonical-mode backspace erases a whole
UTF-8 character), as native Mac terminals do, and grapheme clustering (mode
2027) on, as Ghostty does.

While no daemon runs, holders keep their sessions running and keep answering
the terminal queries the host answers. They keep bells, notifications,
progress reports and exits, bounded, for the next daemon, which holds those
that arrive while no client is subscribed for 30 seconds (at most 64) for the
next subscriber. A holder dials the socket again at once when an entry
appears in the socket's directory, and otherwise with backoff from 250 ms to
2 s (up to 30 s while it watches the directory; at most 2 s apart when the
directory cannot be watched, for example after it was removed). The next
client that needs a daemon starts one (or systemd does). A daemon that starts
reads the holders' manifests and, for up to 1 second, holds back `List` and
requests that name a session until the holders it expects have registered;
`pending_holders` in the list counts those still missing.

A stopped program (`kill -STOP`, a debugger, a job-control stop) is not an
exited one: its session keeps serving snapshots, screen text and input, and
`kill` still ends it.

`cherry kill` (Terminate in the app) signals every live process in the
session's kernel session: SIGHUP, then SIGTERM after 2 seconds, then SIGKILL
after 4 seconds, repeated until the session's first process is gone. Each
signal except SIGKILL is followed by SIGCONT so stopped jobs act on it. The
host acknowledges the request immediately; the session is listed as exited when
its processes have gone, so a `list` right after `kill` may still show it
running for up to about 4 seconds. Processes that moved into their own session
(`setsid`, tmux or pm2 servers, daemons) are not signalled. An exited session
keeps its holder, and its last screen, until `cherry remove`, or until
`cherry shutdown` removes every exited session.

When the session's program exits on its own, the host sends no signals. As in
any terminal, the exit is a hangup: the kernel signals the foreground job and
the host closes the PTY. Jobs started with `nohup` or disowned keep running.

`exit_code` is the program's exit status. For a program ended by a signal it is
128 plus the signal number, and `exit_signal` holds the signal. A shell ended by
Terminate usually reports 129 (SIGHUP).

### systemd

On Linux with systemd, use the provided user service if logout policy would
otherwise terminate the detached daemon and its holders. First finish existing
sessions and run `cherry shutdown`, so there is no already-running unmanaged
daemon (the holders it started would stay outside the unit). With the
binaries installed in `~/.local/bin`, from this checkout:

```sh
mkdir -p "$HOME/.config/systemd/user"
cp Host/packaging/cherry-host.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now cherry-host.service
```

In a release archive the template is at `packaging/cherry-host.service`.
To keep the user service manager running after the last login ends, enable
lingering if permitted by your machine's policy:

```sh
loginctl enable-linger "$USER"
```

No service is installed automatically. While `cherry-host.service` is enabled,
a client that would start a daemon for the socket the service serves runs
`systemctl --user start cherry-host.service` instead, so the daemon stays in the
user manager rather than in the caller's login session. The service serves the
user manager's `CHERRY_HOST_SOCKET`, or the default path when the manager has
none; a `CHERRY_HOST_SOCKET` set only in a login shell does not move the service
and does not match it. Diagnostics are in
`journalctl --user -u cherry-host.service`.

The template uses `Restart=on-failure`: after a crash the restarted daemon
adopts every running session, as their holders register with it again. It
uses `KillMode=process`: stopping or restarting the service signals only the
daemon. Holders, and so the sessions, carry on in the unit's cgroup and
register with the next daemon; so do processes that hosted sessions detached
into their own session (tmux or pm2 servers, `emacs --daemon`,
`setsid nohup job &`). systemd reports them as left-over processes when the
unit starts again. End the sessions themselves with `cherry kill`. The
template uses the default socket and executable path; edit the unit if you
installed elsewhere. No launchd agent is provided for macOS.

### Updates

Installing new binaries leaves a running daemon on its old code until a client
of the new version replaces it. Nothing needs to be stopped first:

1. Install the same new version on every machine: the client and each host
   (on a remote host, the `cherry-host` on its SSH command `PATH`). The Mac
   app bundles its own `cherry` and `cherry-host`, so replacing the app
   counts as installing new binaries on that Mac.
2. The next `cherry list`, `new`, `attach` or `control` that finds a daemon
   speaking an older protocol (4 or later) asks it to make way (`Replace`):
   the old daemon stops listening, removes its socket, releases its lock,
   answers and exits with status 0. The client then starts a daemon of its
   own version, and the holders register with it, so every session carries
   on; attachments reconnect by themselves. Remotely the gateway does the
   same when it is started without `--no-start`, so `cherry --host my-server
   list`, `new`, `attach` and `control`, and the Mac app's tabs and control
   connection, upgrade a remote host once its `cherry-host` is updated.

The same holds for an update that keeps the protocol version: every
`cherry` and `cherry-host` reports its build (`--version`, the daemon's
`Welcome`, `cherry status`): a time and a revision (`20260927101500.abc1234`)
when it was built with `CHERRY_BUILD_ID` (`Scripts/install-local-app` passes
the Mac app's CFBundleVersion), or a development build
(`dev-<commit time>.<revision>`) otherwise, which is never newer or older
than another. Locally, the next `cherry list`, `new` or `control` (never
`attach`) that finds a daemon of its protocol but an older build asks it to
make way (`Restart`) and starts its own `cherry-host`, once, when that
`cherry-host` is newer than the daemon's too and is the daemon's own
executable (updated in place), or the daemon reports its executable was
replaced or removed; the sessions carry on as above. It is not done while a
systemd user service manages the daemon, nor, for an hour, again between two
builds whose last handover came back with the older build still answering
(recorded in `handover.json` in the state directory). A daemon of a newer
build, of a development build, one of another installation, or one that does
not report its build is left running, so two copies of Cherry never take
turns replacing the daemon; `cherry restart` moves it to this build. The
gateway does not do this for a remote host: run `cherry restart` there. (The
Mac app's Update Session Host… does it for a device whose daemon runs an
older install of its own; see [Remote hosts](#remote-hosts).)

Running sessions keep the holders, and so the code, of the build that created
them until they are removed; new sessions run the new build (`cherry status`
shows each session's holder build). A daemon speaks
every holder link version a live holder may use, and a session reports only
what its holder knows (one whose holder predates `application_cursor_keys`
lists it as false, one that predates `bracketed_paste` leaves it out, and
one that predates `ClearHistory` answers it `unsupported_operation`).

A replacement only replaces the intended host: when the client expects an
identity (`--expected-host-id`, or the host an attachment reconnects to), a
daemon of another identity is neither replaced nor reported, locally or by
the gateway, and the client fails with
`host identity changed (expected X, received Y)`.

What the other commands and versions do:

- `cherry kill`, `remove` and `shutdown` (remotely `gateway --no-start`) and
  `cherry start` / `cherry-host start` never replace a daemon. The host side
  reports ``a cherry-host speaking protocol N is running at PATH (this is
  protocol M); `cherry list`, `new`, `attach` and `control` replace it with
  this version, and its sessions carry on``; locally `kill`, `remove` and
  `shutdown` say `protocol version mismatch: cherry-host speaks version N,
  this cherry speaks version M; this command never replaces a host (list,
  new, attach and control replace an older one)`.
- A daemon speaking a newer protocol is never replaced: `a cherry-host
  speaking protocol N is running at PATH; it is newer than this cherry-host
  (protocol M), which never replaces it: install the cherry-host (and Cherry)
  that speaks protocol N` (locally, `protocol version mismatch: …; install the
  same Cherry version on both machines`).
- A daemon older than protocol 4 refuses a `Hello` of another version and
  cannot make way; its sessions end with it. The gateway reports ``… it cannot
  make way for this one: finish its sessions and stop it (`cherry shutdown`
  from the matching version), then try again``; locally the CLI reports
  `host rejected request (version_mismatch): …`. Finish its sessions and stop
  it with the binaries of its own version, or by a signal (`pkill -u "$USER"
  -f 'cherry-host serve'`).
- A daemon that refuses to make way keeps running. The gateway reports `a
  cherry-host speaking protocol N is running at PATH and refused to make way
  for this one …`; locally the CLI says `could not replace the cherry-host
  speaking protocol N (this cherry speaks protocol M): …`.

Every report of a daemon of another version that the gateway did not replace
starts with `a cherry-host speaking `; the CLI relies on that prefix, and an
attachment that is reconnecting stops at once on it, as it does when the
remote gateway's preamble shows another version.

With `cherry-host.service` enabled, a replaced daemon exits with status 0, so
`Restart=on-failure` does not start it again; the client then runs
`systemctl --user start cherry-host.service` (the same applies to a local
`cherry list`, `new`, `attach` or `control` on Linux). So the unit's
`ExecStart` must run the updated `cherry-host`: install the new binary in
its place, or point `ExecStart` at it. Otherwise systemd starts the old
version again, and the client fails with ``a cherry-host speaking protocol N
is running at PATH: the systemd user service cherry-host.service started it,
and its ExecStart runs that older cherry-host (<path>); install this version
(protocol M, <exe>) in its place, or point the unit's ExecStart at this one
(`systemctl --user edit --full cherry-host.service`), then try again``. Until
that is fixed, every connection of the new version replaces the old daemon
and systemd starts it again (the gateway cannot tell which protocol the
unit's binary speaks without running it). The sessions carry on in their
holders meanwhile, and clients of the old version cannot reach the host
either, since the `cherry-host` on `PATH` is the new one. After installing a
new `cherry-host` at the unit's path, `systemctl --user restart
cherry-host.service` also moves the daemon to it.

## Connections and flow control

- **Priority.** On macOS the threads that carry an attachment's traffic run at
  the `USER_INTERACTIVE` quality of service while a client is attached: the
  attach adapter's main thread and the thread that writes its terminal
  output, the daemon's connection threads of attached
  clients and the session's worker, and the session's holder (its loop and
  the thread its headless terminal parses on). When nothing is
  attached they return to the default class, so the output of sessions nobody
  watches never competes with the ones on screen. The programs in sessions
  are not affected. On a busy machine each of those thread wakeups otherwise
  waited 10–40 ms behind other work, while the program (Neovim raises its
  own priority) and the terminal did not, which showed as stalls and jumps
  while scrolling. macOS caps that class at the default
  priority in a process without an application role, so `cherry-host` and
  `cherry attach` take the role `TASK_DEFAULT_APPLICATION`, as Neovim does;
  it changes nothing for their threads at the default class, and the
  processes they start do not inherit it. The daemon tells a holder whether
  a client is attached (holder link version 5; an older holder keeps the
  default). On Linux raising a thread's priority takes
  `CAP_SYS_NICE` or an `RLIMIT_NICE` allowance, and lowering it cannot be
  undone without them, so nothing changes there. Output is sent through
  1 MiB send buffers (or the most the system allows; macOS gives Unix
  sockets 8 KiB otherwise), so a frame of a full-screen program travels in
  one write: both ends of the holder link and the daemon's end of client
  connections have them. What a Unix socket holds is its sender's send
  buffer alone, on macOS and Linux alike, so receive buffers are left as
  they are, and a client's end keeps the system's buffers: its input
  backpressure below is unchanged. The daemon writes output to an attached
  client's socket itself when nothing waits ahead of it.
- **Heartbeat.** An attached client sends `Ping` every 15 seconds, also while
  a slow terminal is still taking its output, so a slow terminal does not get
  the attachment evicted; so does a subscribed control connection. The host
  drops an attached or subscribed connection that sends nothing for 45
  seconds, so a vanished laptop stops constraining the shared grid; a client
  whose input it holds back is exempt (see input backpressure). A connection
  that is neither attached nor subscribed must send its next request within
  10 seconds. The CLI takes an attachment's connection as lost when it
  neither accepts nor delivers anything for 45 seconds while it has input to
  send; over SSH, `ServerAliveInterval` detects a dead network. When the host
  stops reading the connection without closing it, the CLI takes it as lost
  5 seconds later, unless what the host sent before (a takeover notice, the
  program's exit) decides the outcome first; while detaching, see
  [Host closing first](#attach-options). A lost connection is reconnected
  (see [Reconnecting](#attach-options)). The CLI gives up at once when its
  own terminal accepts no output at all for 15 seconds (outcome
  `disconnected`; the session keeps running).
- **Slow clients.** A session's program goes at the pace of its fastest
  client, as the program in a native terminal goes at its terminal's pace.
  While any attached client takes its output as fast as the program makes
  it, nothing holds the program back. Once more than 512 KiB of output
  waits in the host for every client (beyond what its socket holds: the
  daemon asks for a 1 MiB send buffer, which Linux doubles; a client that
  just attached counts as keeping up until then), the daemon tells the
  session's holder how far it may read the program's output (holder link
  version 6): as far as the client that can take the most more (the one
  that took the most of its output) can take. It moves that limit on as
  that client takes its output, until no more than 128 KiB waits for it.
  The program's output meanwhile waits in the PTY, and the program with it.
  Output already on its way when the client began to hold the program back
  waits for it as well (up to 256 KiB more), so the program goes on at the
  client's pace from there rather than stop until the client took it. So a
  flood reaches the fastest client whole, at its pace, and the host's
  memory stays bounded; the program gets its output evenly: the limit moves
  on each time that client took at least 8 KiB more and takes no more for
  now (and every 256 KiB it takes without a pause), and `cherry attach`
  reads its connection only as its terminal takes output (see Throughput),
  in steps of 16 KiB or more at a time. A session's only client gets every
  byte at its own pace (unless it takes nothing for the stall below). The
  session's slower clients fall behind and lag as described below: a slow
  client (one over a slow SSH link, say) never holds the program, or the
  session's other clients, back to its pace. A client that takes none of
  its output holds nothing back once it took none of it for 2 seconds
  (while output waits for it). While another client (a lagging one too)
  takes output, it holds nothing back much sooner: once it took none for
  250 ms, or for three times the longest it went between taking any in the
  last second or two, if that is longer (a slow terminal behind `cherry
  attach` takes its output 16 KiB at a time: every 320 ms at 50 KiB/s), and
  the daemon looks every 50 ms from then on whether another client took
  some. So a client that takes nothing holds the program back for at most
  the 2-second stall when no other client takes output, and otherwise only
  for about that short while, however slowly the others take it. When the
  client the program went at the pace of detaches or stalls, the fastest of
  the others takes over at once: the output that waits for it (up to
  3 MiB) goes on waiting, rather than the program stopping until it took
  all that, and the program goes at half its pace until no more than
  768 KiB waits for it. (Of more than 3 MiB, it first takes what waits
  beyond 3 MiB while the program waits: output already on its way to it
  must still fit its 4 MiB budget.) A client that lagged starts afresh once
  resynchronized: it keeps up until more than 512 KiB waits for it again.
  The daemon reads the holder link all the while: replies (snapshots for
  attaches and replacements, screen text, the confirmation of a detach) and
  the session's other clients never wait behind output held back, apart
  from what is queued behind that output for the slow client itself. A
  session whose holder predates link version 6 is not held back: all its
  slow clients lag. A client's queued output has a 4 MiB budget. Beyond
  that the host drops the client's queued output (the client lags) and,
  once what remains in its queue is at most 256 KiB, sends it a fresh
  snapshot (`Attached` with reason `resync`).
  Output that a snapshot cannot rebuild is kept, within bounds, and
  follows the resync snapshot as `Output`: the latest title of each kind, the
  working directory (OSC 7), pointer and cursor shape, one bell, the latest
  clipboard write for each selection (up to 4 selections and 8 MiB in total),
  and the most recent 1 MiB of notifications and colour changes. Kitty
  graphics are not carried. This carried output does not count toward the
  4 MiB budget. The resync `Attached` then has an offset lowered by the
  carried length, and an `Output` at that offset follows at once; live output
  resumes at the session's offset. Queries sent to the client (`Query`; see
  [Bounds and terminal fidelity](#bounds-and-terminal-fidelity)) are not
  output and are not dropped for lag. Those queued behind dropped output or a
  superseded snapshot, and those sent while the client lags, follow its
  resync snapshot and carried output, once each. At most 1 MiB of queries
  waits for a client; a query beyond that is dropped. A failed resync
  snapshot is reported as `snapshot_failed` and retried after 1 second. A
  client that takes nothing never holds the session back for longer than
  that stall, and no client is disconnected for being slow; a failed write,
  meaning the peer is gone, ends the attachment (a connection that sends
  nothing, heartbeats included, is dropped as above). A client that stops
  reading replies while sending requests is no longer read from once more
  than 32 MiB of replies wait.
- **Throughput.** Terminal bytes travel as they are, in binary frames (see
  [Protocol](#protocol)). The holder parses the program's output with its
  headless terminal on a thread of its own, so reading the PTY and sending
  the output never wait for the parse, and hands it each flood's output in
  chunks of up to 64 KiB, or what came within 1 ms (at once when it
  holds a query the host answers, as far as the output's tokens tell);
  snapshots, screen text and resizes wait until the terminal has parsed
  exactly the output sent before them, and input waits until it has parsed
  the output read before it, so the replies to the program's queries reach
  the program before input that arrives after them. During a flood (output
  that came without a pause of 1 ms for 10 ms; a wait while the program is
  held back for a slow client is no pause) the holder reads the PTY again
  at once when it found it empty (a PTY holds a few KiB, and sleeping until
  the program refilled it would cost a wakeup every few KiB), and gathers
  output for up to 1 ms, or 64 KiB, before it sends it; output after a
  pause (an echo, a prompt, a repaint) goes at once, and output that waits
  for the daemon or a client joins what is queued ahead of it, so floods
  travel in fewer, bigger frames. `cherry attach` writes its terminal
  output on a thread of its own, through a queue of at most 256 KiB,
  counting what the thread is writing (a viewport frame is painted only
  once the terminal took the frame before), and reads its connection only
  as the queue has room: as much as it has, 16 KiB at least and 64 KiB at
  most at a time, taking the output of a large `Output` frame as it
  arrives rather than once it arrived whole. So a terminal that takes its
  output slowly has the connection read at its own pace, evenly (see slow
  clients). In direct mode it follows only the session's modes rather than
  a whole copy of its screen: a window of another size asks the host for a
  replacement (`Refresh`) when it needs the screen.
- **Input backpressure.** While more than 1 MiB of a session's input waits for
  the program, the host stops reading from any client that sends more input,
  and resumes below 256 KiB. A large paste into a slow program is delivered in
  full instead of disconnecting the client. A held client is never
  disconnected for being silent, since its heartbeats wait behind the held
  input: the host sends it a `Pong` every 15 seconds while nothing moves, and
  at most one a second while the program consumes the input. Only a hangup, a
  failed write, a takeover, or the session's end stops the wait. The CLI
  sends terminal input as soon as it reads it, also while it waits for its
  terminal to take output. It keeps displaying output meanwhile and stops
  queueing terminal input while 1 MiB of it is unsent. With a detach key, it
  then reads at most 64 KiB more, in order, so a detach key typed behind that
  input is still seen (pressing it twice still sends Ctrl-]). Such a detach
  discards unsent input, as described in [Input order](#attach-options).
  Input beyond that waits in the terminal. So after pasting well over 2 MiB
  into a program that is not reading, the detach key is not seen until the
  program reads or the `cherry` process ends (for example because its
  terminal window was closed). With `--detach-key none`, the terminal is not
  read beyond the 1 MiB.
- **Resizing.** The CLI sends a resize at once, and during a window drag at
  most one per 50 ms: the steps that follow within 50 ms of the last one sent
  go as one, once the 50 ms have passed. The host changes the shared grid at
  once when the resizing window alone sets it (no other window is smaller in
  either dimension): every time when it is the only window, and with other
  windows only for the first step of a drag (when the grid has not changed
  for 75 ms); every other change applies once the requested size has been
  stable for 75 ms, so the other windows get at most two replacements for a
  drag rather than one per step. A replacement is `Attached` with reason
  `resize`. While the program shows the alternate screen (a full-screen
  program, which repaints itself when resized), a window that keeps a copy of
  the stream gets `Resized` instead, which carries no snapshot: the window is
  painted once, by the program, rather than by a replacement and then the
  program's own repaint (the windows of a session whose holder predates
  holder link version 5 always get replacements). `Resized` marks where in
  the stream the new size took effect, so the holder answers with it only
  while nothing was output since the resize (it does so before it reads the
  program's repaint, in the normal case); otherwise, and for a window whose
  copy came from an attach or resync snapshot of an older grid, the window
  gets a replacement. For most windows it
  holds only the screens, with no reset and no history (usually a few KB): a
  window of another size paints a viewport from them, and a window whose own
  resize the grid followed keeps its native scrollback, as does a window that
  goes back to the grid's size before the grid changes (it is repainted). A
  window that rendered a viewport and now matches the grid gets a full
  snapshot with retained history instead, whether the grid changed to its
  size or its own resize made it match a grid another client holds.
  Replacements are queued behind the client's output, which is never dropped
  for a resize. A newer replacement supersedes an older one still queued (one
  that supersedes a full snapshot is full too), so a slow client does not
  receive every intermediate size, and a lagging client gets the new size with
  its resync. An attach or resync snapshot that the holder answered after the
  grid changed (so it still shows the old size) is followed at once by a
  `resize` replacement at the current grid, so a client can see `attach` at
  the old size and then `resize`. A resize that cannot be applied is reported
  as `resize_failed` without ending the attachment.

## Bounds and terminal fidelity

The daemon allows 128 sessions, including retained exited sessions, and 1024
concurrent connections (each session may have attachments, control
connections and its holder's link at once). A connection over that limit is
sent `Error{too_many_connections}` before its `Welcome` and closed, and the
daemon logs it (at most once every 5 seconds, with how many it did not log).
Remove exited sessions to free session slots. It keeps
up to 4096 creation receipts for idempotent retries; the least recently used is
evicted first, and removing a session removes its receipts. Scrollback has a
1 MiB budget per terminal; there is no permanent output journal or recovery of
evicted history.

Reconnect sends a consistent terminal snapshot followed by subsequent output.
A snapshot is limited to 8 MiB: the oldest history is dropped in whole lines
until it fits. When the cut falls inside a soft-wrapped line, the rest of that
line is dropped too, so reattached history never starts with a fragment; when
that line continues onto the visible screen, all history is dropped. If the
active screens alone exceed the limit, the attach fails with
`snapshot_failed`; a replacement snapshot (after a resize or for a resync)
that fails is reported the same way without ending the attachment.
Restoration covers text at its exact row positions, retained
history, styles (including background-only cells and OSC 8 hyperlinks), the
cursor's position, visibility, blink and pen, modes, tab stops, margins,
character sets, the kitty keyboard stack, the primary screen beneath an
alternate screen (1049, 1047, or 47), and the saved cursors (DECSC, 1048) of
the active screen and of that primary screen.

A session's terminal clears the shell's prompt on resize for the shell's
redraw (OSC 133 marks it), as the app's Ghostty terminal does, and before
its rows reflow, so a two-line zsh prompt whose first line the new width
wraps or unwraps is redrawn once, on its own rows, with the output above it
intact; the replacement a window gets after its resize shows that screen.
Details in [cherry-vt](crates/cherry-vt/README.md#prompts-on-resize).

### Kitty graphics

A session's terminal keeps kitty graphics images (32 MiB per screen, PNG
payloads decoded with the `png` crate into 8-bit RGBA, straight into
Ghostty's buffer when the PNG is RGBA already; images over 10000 pixels a
side or 32 MiB decoded, which the storage could not keep, are refused
before decoding, and a malformed PNG fails its command), so it answers
`a=q` probes and acknowledges transmissions itself; renderers get every
other graphics command with `q=2`. A full or limited snapshot (an attach, a
resync, a window that comes back to the grid) begins with a reset, which
deletes the renderer's images, so it re-sends those on screen after the
content of the active screen and before its cursor, modes and the rest of
its state (neither the cursor nor the saved cursor moves):

- each image that has a virtual placement (unicode placeholders) or a
  direct placement all of whose rows are on screen, once, as `a=t` with
  RGBA pixels (`f=32`), zlib-compressed (`o=z`) in chunks of 4096 base64
  bytes. An image the program named by ID is sent with `i=`. One it named
  by number (`I=`) is sent with its number alone, after the others and in
  order of ID, with stand-in images under every lower free ID, deleted
  afterwards: the renderer gives it the lowest free ID, which is then its
  ID on the host, so `i=` and `I=` both keep finding it. A numbered image
  whose ID is above 256 is not re-sent.
- then each virtual placement (`a=p,U=1`) and each such direct placement,
  at its cell with `C=1`, with its source rectangle, offsets, columns, rows
  and z-index, but not its placement ID: libghostty-vt does not say
  whether the program gave it or Ghostty numbered the placement itself,
  and a number of Ghostty's sent as an ID would stand for the program's
  own `p=`. So until the next snapshot a command that names a placement
  by `p=` (`a=p` to move it, `a=d,d=p`) does not reach a re-sent placement
  on the renderer, only on the host.
- then the chunks so far of a transmission the program began (`m=1`) and
  has not ended, as renderers got them, so the chunks still to come
  complete it on the renderer. The holder's display stream keeps them, as
  much as the graphics budget allows; a longer one is not carried.

Every command carries `q=2`. The graphics take at most 6 MiB
(`MAX_SNAPSHOT_GRAPHICS_BYTES`) on top of the 8 MiB of text, newest image
first; an image that does not fit is left out with its placements, and no
image at least as large is compressed after one that did not fit, nor one
that could not fit however well it compressed. The holder keeps the
compressed images it sent (16 MiB, by image ID and generation), so a resync
or another attach does not compress them again, and logs the images a
snapshot left out at most once a minute. A screens-only replacement (a
resize, `Refresh`) keeps the renderer's history and images and re-sends
none.

`cherry attach`'s own copy of the screen (the one a window of another size
is painted from) keeps images too, so a window that goes back to the
stream gets them from the copy's full snapshot; a copy made from the
screens alone lacks those sent before it, so the client then asks the host
for a replacement (`Refresh`), which carries them when the host too took
the window for a viewport.

The PTY's pixels and size replies follow the window that sets the grid
(its columns and rows are the grid's), of those that give a cell size, not
the client that types or answers queries: a new cell size makes the
program repaint, so it changes only with the grid's window.

Known gaps: a window rendering a viewport gets no kitty graphics at all (the
viewport drops APC); only direct transmission is kept (`t=f`, `t=t` and
`t=s` media are off); placements in the history or partly off screen, the
primary screen's images under the alternate screen, images without a
placement, placement IDs (above) and animation frames other than the
current one are not re-sent; sixel and iTerm2 images are not supported
(nor by Ghostty).

When an attachment's size matches the shared grid, it uses the ordinary
terminal stream and its own scrollback. A larger attachment is repainted from a
bounded view of the shared active screen, so its native terminal scrollback is
not available while its dimensions differ from the shared grid. The host still
retains its bounded history. A window that returns to ordinary rendering (the
shared grid grows to it when the smaller client disconnects, or the window
shrinks to the grid) gets a full snapshot with retained history. A window that
stayed on the stream while the grid followed its own resize keeps its own
scrollback. This is a limit of simultaneous differently sized views, not
a separate process or terminal session. A viewport is not repainted while
the program is inside a synchronized update (mode 2026: between the start
and the end of drawing a frame), for at most 150 ms, so it never shows a
half-drawn screen; one that the window must show before a query it answers
is painted at once, inside a synchronized update of the window's own that
the complete frame ends.

A window that renders a viewport still receives the output that acts on the
terminal rather than on its screen: OSC 52 clipboard writes, titles (OSC 0–2)
and the title stack (`CSI 22/23 t`), OSC 7, notifications (OSC 9, 99, 777),
colour settings (OSC 4, 5, 10–19, 21, 104, 105, 110–119), and BEL. OSC 99
notifications pass even when their text contains `?`; only `p=?` capability
queries are held back. Kitty graphics, cursor and pointer shapes, and window
operations are not passed through. A client in either mode writes the
queries the host sends it (`Query`) to its window, which answers them. In
viewport mode the client first writes a frame of the screen up to the query,
so a cursor report matches. A query that arrives after the client sent
Detach is not written.

When a larger client detaches, or is interrupted, while the program is on the
alternate screen (1049, 1047, or 47), its cursor returns to where its own
primary screen had it: the prompt it attached from, or where the last painted
primary-screen frame left it. This also holds inside tmux.

Each terminal query has one responder: the host or one attached client. The
host's terminal answers a fixed set whether or not a client is attached, and
removes those queries from what renderers receive: device attributes, status
and cursor reports (`CSI 5n`, `CSI 6n`), the colour-scheme report, DEC private
mode reports, XTVERSION, DECRQSS, the kitty keyboard, graphics, and clipboard
(OSC 5522) queries, size reports (`CSI 14/16/18 t`), XTGETTCAP names it knows,
and colour queries for the palette, foreground, background, and cursor (OSC 4,
10–12, 21). It also keeps the report modes it answers itself, in-band resize
(2048) and 2033, away from renderers: neither live output, snapshots, nor
viewport mode enables them there. Size replies use the cell size of the
window that sets the grid, of those that report one (see
[kitty graphics](#kitty-graphics)): `Attach` and `Resize` carry `cell_width` and
`cell_height` (pixels, 1 to 1024, both or neither), which `cherry attach`
derives from its terminal's `TIOCGWINSZ` pixels and sends again when only
they change (a new font size, a display of another scale). The holder also
gives the program's PTY those pixels (`cols × cell_width` by `rows ×
cell_height`), which image programs size images by; until a client gave a
cell size, and for a holder older than link version 8, size replies use
nominal 8×16 cells and the PTY reports 0×0 pixels. Colour replies (OSC 10, 11 and 12) and the colour-scheme report
(`CSI ?996n`) use the colours and appearance `Create` named (`colors`; the
Mac app passes its terminal theme for the appearance it shows), or light
grey on black and dark without them. Kitty graphics reach renderers
with `q=2`, so only the host replies (see [kitty graphics](#kitty-graphics)). Other queries (status reports such as
`CSI ?6n`, OSC 5 and 13–19 colour queries, `CSI 11/13/15/19–21 t` and size
reports with extra parameters, ANSI mode requests, DECREQTPARM, DECRQPSR,
DECRQTSR, DECRQUPSS, DECRQCRA, XTREPORTSGR, XTQMODKEYS, XTSMGRAPHICS, OSC 52
clipboard reads, OSC 22 pointer-shape and OSC 99 capability queries, ENQ, and
XTGETTCAP names the host does not know) are taken out of the output and sent
as `Query` to one attached client whose terminal can answer them. That is a
`cherry attach` whose input and output are the same terminal, which includes
the Cherry tab. Of those clients, the one that most recently sent input
answers, or else the one attached most recently. Its terminal answers once,
however many clients are attached and whatever their sizes. A client whose
input or output is not a terminal (for example `printf 'make\n' | cherry
attach ID`, or output redirected to a file) is never sent queries, and its
input does not change which client answers. Queries are not part of output
offsets or snapshots. With no client that can answer attached, queries are
dropped and get no reply.

Control strings are bounded to 64 KiB, except OSC 52 clipboard writes, which
may be up to 8 MiB; longer ones are dropped. Clipboard writes go only to
attached renderers: one made while nothing is attached is lost, and snapshots
never replay it. A client that falls behind gets the latest ones after its
resync snapshot (see [slow clients](#connections-and-flow-control)).

Current snapshot limitations include terminal graphics, palette and dynamic
colour changes, OSC 7 directory metadata, the title, cursor shape, the
contents and saved cursor of an inactive alternate screen, hyperlink ids, and
OSC 133 prompt marks. See [cherry-vt](crates/cherry-vt/README.md) for details.

## Protocol

Frames are a 4-byte big-endian length followed by at most 16 MiB. A frame
whose first byte is `{` holds a JSON message: the handshake and every
control message. An attachment's terminal bytes travel as they are, in
binary frames (protocol 6), whose first byte is their kind:

| Kind | Message | Direction | After the kind |
|---|---|---|---|
| 1 | `Output` | host to client | the offset (8 bytes, big-endian), then the output |
| 2 | `Input` | client to host | the input |
| 3 | `Query` | host to client | the query |
| 4 | `Attached` | host to client | the length of a JSON header (4 bytes, big-endian), the header (`session`, `offset`, `reason`, `refreshes`), then the snapshot |

Those four have no JSON form, and a binary frame carries no `req`. The
bytes of `SendInput` (a JSON request) are a base64 string. Unknown fields
are ignored (the `Attached` header's too), so a field can be added without
breaking an older peer. The client opens with
`Hello{version}`, and the host answers every `Hello`, whatever its version,
with `Welcome{version, host_id}` carrying its own version and identity. The
current version is 7. Normal operation needs the same version on both sides.
When they differ, the client disconnects or, only when the host's version is
lower, sends `Replace`, which the host answers `Ok` once it has stopped
listening and released its socket and lock, and then exits (see
[Updates](#updates)); any other request after a mismatch gets
`version_mismatch`, and the connection closes. `Hello`, `Welcome`, `Replace`,
`Ok`, `Error` and the gateway's `CHERRY-GATEWAY <version>` line keep their
shapes in every version. Hosts before version 4 answer a `Hello` of another
version with `version_mismatch` instead of a `Welcome`.

Once the versions match, a JSON request the host cannot decode is answered
with an `Error` carrying its `req` (`unsupported_operation` for an unknown
`op`, `request_failed` for fields it cannot take), and the connection carries
on (protocol 7; an older host closes the connection).

Any request may carry `"req": <u64>`, which the host echoes on its reply, so
one connection can have several requests in flight. The host answers every
request with exactly one frame, except `Input` and `Resize`, which are
answered only when they fail, and `Refresh`, which is answered with a
replacement snapshot. Frames the host sends on its own (events, and
attachment traffic: `Attached`, `Output`, `Query`, `Exit`, a paused
attachment's `Pong`s) carry none. A connection carries at most one
attachment (`Attach`, `Input`, `Resize`, `Detach`); a control connection
never attaches. Besides `List` (answered `Sessions{host_id, sessions,
pending_holders, lost_sessions}`; `lost_sessions`, left out when empty, names
the sessions whose holders the daemon found killed when it started, see
[Lifetime](#lifetime-service-setup-and-updates)), `Create`, `Kill`, `Remove`, `Shutdown`, `Restart`
(protocol 7: stop as for `Replace`, whatever sessions run, so a new host of
the same version can start; answered `Ok` once the socket and lock are
released) and `Ping`, a control connection may send:

- `Subscribe`, answered `Ok`; the host then pushes `Event{event}`: `added`,
  `changed` (any session field), `removed`, `bell`, `notification`
  (`title`, `body`), `progress` (`state`, `value`), `exited` (`exit_code`,
  `signal`, and `ended_by` and `holder_log` as in `list --json` when its
  holder was lost), and `resync`
  (the subscriber fell behind and should list again). A subscriber's queue
  is bounded and keeps only the latest `changed` of each session. A
  subscribed connection is exempt from the idle limit but pings like an
  attached one.
- `SendInput{id, data}`: input without attaching, at most 64 KiB; answered
  `Ok`, or `not_running` once the session exited. While too much input waits
  for the program, it waits up to 5 seconds for room and then fails.
- `Screen{id, scrollback, max_lines}`: the screen as plain text, answered
  `ScreenText{id, text, cursor_row, cursor_col, alternate_screen}`, with the
  retained history first when `scrollback` is set and only the last
  `max_lines` lines when that is given. A host that knows `max_lines` always
  sends `pending_holders` in `Sessions`; an older one ignores `max_lines`.
- `Update{id, name, tags}`: rename a session or replace its tags; answered
  `Ok`.
- `ClearHistory{id}` (protocol 7): clear the history above the session's
  screen, as `ED 3` would where the output read so far ends (an unfinished
  escape sequence in that output is kept, and completes as it would have;
  a half-written UTF-8 character delays the erase until the output
  completes it); answered `Ok` once the holder did. `Screen` with
  `scrollback` and every later attachment then show none of it; clients
  already attached keep what their terminals show. It is refused with
  `request_failed` while the alternate screen shows (which has no history;
  the primary screen's is kept), or while the session's holder is not
  connected, and with `unsupported_operation` for a holder older than link
  version 7.

`Create` carries `request_id`, `name`, `cwd`, `command`, `env`, `cols`,
`rows`, and optionally `owner` (at most 256 bytes), `tags` (at most 64,
keys of 1 to 128 bytes, 16 KiB in all) and `colors` (protocol 7:
`{"foreground", "background", "cursor", "dark"}`, colours as `#rrggbb`, the
cursor the foreground's when left out; what the session's terminal reports
to its program, see above). Like the size, `colors` is not part of what a
retry with the same `request_id` must repeat.

An attached client must accept a replacement `Attached` snapshot at any time
(reasons `attach`, `resize`, `resync`) and resume output at its offset. A
`resize` replacement may hold only the screens, without a reset or history,
for a renderer that keeps its own history or paints a viewport. It must also
accept `Resized{offset, cols, rows}` (protocol 5): the shared grid took that
size at that point of the stream without a snapshot, since the program on
the alternate screen repaints itself; the output before `offset` was made
for the old size, the output from it on for the new one, and a renderer
resizes its copy of the screens there and keeps what its window shows. Like
a `resize` replacement it is superseded by a newer replacement still queued,
and it never replaces one. `Attach` may carry `client_id` (protocol 5; see
[Use from the command line](#use-from-the-command-line)). An attached
client may send `Refresh` (protocol 6) to be sent an `Attached{resize}`
replacement for the grid, queued behind its output like any replacement (or
`snapshot_failed`); one already on its way answers it too, and a `Resized`
on its way is followed by one. Every host of
protocol 6 answers it, and says so in `Attached`'s `refreshes`: a client
that shows the stream as it is (its window has the grid's size) then keeps
only the session's modes, and asks for the screen when its window leaves
the grid's size. An `Attached`
offset may be lower than the offset of the stream when carried output
follows it (see [slow clients](#connections-and-flow-control)); that output
starts at the `Attached` offset, so resuming there needs nothing more. An
attached client may also receive `Query` messages at any time: terminal
queries for its own terminal, placed between `Output` messages in stream
order but carrying no offset. The client writes them to its terminal as they
are, and the terminal's replies return as ordinary `Input`. `Attach` has a
required `answers_queries` flag: true only when the client writes queries to
a terminal whose replies it reads as input. The host sends no queries to a
client that sets it false. `Attach` and `Resize` may carry the window's cell
size in pixels (`cell_width`, `cell_height`; additive, so protocol 7 is
unchanged and an older host ignores them); a `Resize` may change only
them. Errors carry a code: `version_mismatch`,
`request_failed`, `taken_over`, `replaced` (protocol 5: a newer attachment
of the same `client_id` replaced this one), `resize_failed`, `snapshot_failed`,
`unsupported_operation`, `unknown_session` (no session has that ID),
`not_running` (the session has exited), or `too_many_connections` (sent
instead of the `Welcome` to a connection over the host's limit, which is then
closed). `resize_failed`, and
`snapshot_failed` for a replacement snapshot, do not end an attachment;
`snapshot_failed` in reply to `Attach` means the attach failed. The
definitions are in [cherry-protocol](crates/cherry-protocol/src/lib.rs).

Clients must ignore a `Pong` at any time, including before `Welcome` and
between a request and its reply. Besides answering `Ping`, the host sends one
unrequested while it holds back a connection's input because the session's
pending input is full: at most once a second whenever the program has
consumed more of it or to probe a peer that has finished sending, and every
15 seconds (a third of the heartbeat timeout) while nothing moves, which
keeps a live client from taking the connection for dead. The CLI sends a
`Ping` after every 64 KiB of `Input`, so the host's `Pong`s show how far it
has read. While it waits for a detach confirmation it counts any `Pong` as
progress, and after `Detach` it sends no `Resize` or `Ping`.

## Validation

```sh
Scripts/build-host-vt
cargo fmt --manifest-path Host/Cargo.toml --all -- --check
cargo clippy --manifest-path Host/Cargo.toml --locked --workspace --all-targets -- -D warnings
cargo test --manifest-path Host/Cargo.toml --locked --workspace -- --test-threads=1
cargo build --manifest-path Host/Cargo.toml --locked --bins
cargo test --manifest-path Host/Cargo.toml --locked -p cherry-cli --test real_host -- --ignored --test-threads=1
cargo test --manifest-path Host/Cargo.toml --locked -p cherry-host -p cherry-vt -- --ignored --test-threads=1
```

After building the Rust debug binaries with `Scripts/build-host debug`, run the
Mac app's session tests as CI does:

```sh
Scripts/test-session-suites unit
Scripts/test-session-suites real-host
```

`unit` runs each group of hosted and persistent session suites
(`PersistentLocal`, `PersistentTab`, `WorkspacePersistence`,
`WorkspaceRestore`, `HostControl`, `HostedSession`, `HostedLaunchSpec`,
`NativeSurfaceRelaunch`, `MultiplexerSafety`, `AdapterAwayKeyInput`,
`AgentInputSafety`, `SessionCloseFlow`, `BackgroundSession`, `AppIdentity`,
`RemoteDevice`) on its own. Each group must pass at least
one test; a session test file not named after a group, or a skipped test
that is not a `RealHost` test, fails the run, so a new session suite must be
added to the groups in `Scripts/test-session-suites`. Swift Testing's
`--filter` matches source file names as well as test names, so a group
selects every test in the files named after it. `real-host` sets
`CHERRY_TEST_HOST_INTEGRATION=1` and runs every test whose ID contains
`RealHost` (`HostedSessionRealHost`, `PersistentLocalRealHost`,
`AgentInputRealHost`, `RemoteDeviceRealHost`, `RemoteDeviceRealHostInstall`, …) against the helpers in
`Host/target/debug` (or `CARGO_TARGET_DIR`), each with its own daemon on a
private socket and a private `HOME`; a skipped test fails the run.
`RemoteDeviceRealHost*` reach their daemon as a device through
`Scripts/fake-remote-mac`, a fake remote Mac: an `ssh` shim (the only entry
on the helpers' `PATH`) that refuses master connections, never runs the real
ssh, and runs the remote command with `/bin/sh -c` under `env -i` with that
Mac's private `HOME`, `PATH` and `CHERRY_HOST_SOCKET`; files named `offline`,
`hostkey` and `denied` in its directory make it fail as ssh would, and
`arch` (its contents) is the architecture its `uname` reports. At setup,
`CHERRY_FAKE_REMOTE_HOST` says which cherry-host it has: `link` (the debug
builds on its `PATH`), `none`, `newer` (a stand-in of protocol 99 whose
daemon runs) or `old-build` (an install of build `20200101000000.old` in its
home, as the Mac app installs one); `none` with a daemon runs it from the
debug build (one no check can ask). The install tests put the debug helpers
there with the app's installer, run the gateway from them, update an older
build whose sessions keep running, refuse a newer host, a missing
architecture and a copy without a valid signature (the real
`/usr/bin/codesign` fails on it), clear a quarantine attribute that
travelled with the copy, repair a damaged build, fall back to
`<build>-<hash>` when a damaged one is in use, race three installs of one
build, leave a daemon that changed before the handover, report a daemon the
check could not see, mark builds as used and collect unused ones.
With a file named `masters` in its directory, the shim also runs stand-in
SSH masters (`-M`, `-O check`, `-O exit`), and a command given the
`ControlPath` of one is one of its sessions, at most the number in
`max-sessions` (default 10) at once, as sshd's `MaxSessions`: one more fails
with "Session open refused by peer". The device tests of phase 3 run git
worktrees, `cherry-host project-info`, cherry.toml commands (auto-start,
restart on exit), the installed terminfo and zsh integration (OSC 7 reaching
the tab), `scp -O` of dropped files and SSH master shards through it.
Every fake Mac has an `osascript` stand-in first on its `PATH` (never the
real one, which would set this Mac's clipboard): it copies the image a
`set the clipboard to (read (POSIX file "…") as «class PNGf»)` names to
`clipboard.png` there and reports it to `clipboard info for «class PNGf»`,
and fails as over SSH without a GUI session when a file named `no-gui` is
there. `fake-remote-mac stop` leaves a tombstone (`DIR/stopped`) that the
shim refuses from then on, and ends the daemons and holders of DIR's sockets
again until none has been seen for half a second, so a connection attempt
under way cannot leave a daemon behind; the tests' teardown also shuts its
controls down for good first (`HostControl.shutdown()`), and a fake Mac
with no daemon of its test's own connects with `cherry control --no-start`. A stand-in master answers `-O forward -L SPEC` and `-O cancel -L
SPEC` by logging them to `forwards` (with `forward-fails`, a forward fails
as when its local port is taken). The tests of phase 4a copy a pasted image
there and paste its path, put it on the clipboard there for Ctrl-V (and
fall back to its path when osascript fails, or send Ctrl-V anyway when the
copy fails), run a web server in a tab there, find its port with
`cherry-host ports`, report it through MCP labelled with the Mac and not
forwarded, open its URL through a forward, forward it for an HTTP probe,
and cancel the forwards when the tab closes (or when their tab closed while
they were being made).
`Scripts/test-remote-mac-loopback` checks the same over real SSH to this Mac
without admin rights: a private `sshd` on 127.0.0.1 run as you (with
`MaxSessions 3`), with its own keys and a forced command that sets a private
`HOME` and socket, and an ssh that only ever reads its private config (never
`~/.ssh`); it also runs the app's installer against that sshd (the Swift
test `RemoteDeviceRealHostInstallRunsTheRealCopyOverSSH`, so it builds the
Swift tests first unless `--skip-build`; `--no-install` leaves it out), then
`cherry --host` through the installed cherry-host, then
`RemoteDeviceRealHostShardsSSHMastersAboveTheChannelCap`: the app's master
manager opens a second master once the first has its sessions, where sshd
refuses a fourth session on the first, and
`RemoteDeviceRealHostForwardsAPortThroughTheSSHMaster`: its sshd allows local
forwards to its own loopback only (`AllowTcpForwarding local`, `PermitOpen`),
and a page served on the "remote" side is fetched through `ssh -O forward` on
a master started as the app starts them (`ClearAllForwardings=yes`, which
does not refuse forwards asked for later), then `-O cancel` and the master's
end take the forward away. `Scripts/test-session-suites`
without `--skip-build` builds the Swift tests first, and for `real-host` the
Rust helpers too.

The 20 ignored `real_host` tests run the `cherry` that `cargo test` builds
and the `cherry-host` beside it (hence `cargo build --bins` first; set
`CHERRY_TEST_HOST` to use another), each daemon with a private socket and a
temporary `HOME`. They cover shared attachment and takeover, only the
terminal that typed last answering the program's queries, process and
screen survival across reconnects, piped input and detaching behind input the
program never reads or reads slowly (about 5 seconds), an attachment that
reconnects by itself after its daemon is killed and restarted, `cherry
control` relaying requests with IDs and starting a remote host, and, through
the real gateway behind a fake `ssh`: remote `kill`, `remove`, and
`shutdown` never starting a host, replacing an older remote daemon and
reporting a newer one, leaving a host of another identity to the client, and
a fake remote leaving nothing behind, `cherry status` and `cherry doctor`
against a running daemon, and a client handing a daemon of an older build of
its protocol over to its own build (leaving a newer, development or foreign
build alone, never from an attachment, and not again after the old build
won the race). The
ignored Neovim tests in `cherry-host` and `cherry-vt` need `nvim` on PATH: they
run real Neovim on a PTY, reconstruct its state in a second terminal (or
reattach through the host at a new size), and check returning to the shell.
The ignored test that checks the daemon drops other users' connections only
runs as root. The ignored `ssh_host` test needs a disposable real SSH host
(`CHERRY_TEST_SSH_HOST`, `CHERRY_TEST_SSH_CONFIG`). The Swift real-host tests
open differently sized native Ghostty views and persistent tabs on a real
daemon, and check screen restoration, reconnection after the daemon
restarts, restore, and agent input. `Scripts/test-host-linux` runs the Rust
tests above natively as root in a Debian 12 Docker image with a pinned
Neovim. `Scripts/test-host-ssh` runs that suite, then exercises a local
client against a Linux host in that image through actual SSH with disposable
keys and pinned fixture host keys; it requires Docker and OpenSSH tools.

Tests shorten the host's timing with `CHERRY_HOST_*_MS` variables read when
`serve` starts (`HEARTBEAT_TIMEOUT`, `IDLE_TIMEOUT`, `INPUT_WAIT`,
`KILL_GRACE`, `TOUCH_INTERVAL`, `AGENT_GRACE`, `HOLDER_WAIT`, how long
`List` and requests naming a session wait for the holders a restarted daemon
expects, 1000 ms by default, and `STALL_TIMEOUT`, how long a client that
takes none of its output holds a session's output back at most, 2000 ms by
default; `CHERRY_HOST_MAX_CONNECTIONS` lowers the connection limit,
`CHERRY_HOST_LOG_MAX_BYTES` the size past which the daemon moves `host.log`
aside and `CHERRY_HOST_LOG_CHECK_MS` how often it checks, both passed on by
`cherry-host start`, `CHERRY_HOST_TEST_BUILD` makes a daemon, the holders it
starts and `cherry-host --version` report another build, and
`CHERRY_HOST_TEST_SERVE_BUILD` makes the daemon `cherry-host start` starts
report one), and the CLI's with `CHERRY_TEST_BUILD` (the build it acts as)
and `CHERRY_CLI_*_MS`
(`CONNECT_TIMEOUT`, `HEARTBEAT_INTERVAL`, `HEARTBEAT_TIMEOUT`,
`ESCAPE_WAIT`, `GRID_WAIT`, `RESIZE_COALESCE`, `DETACH_WAIT`, `REPORT_WAIT`,
`CLOSED_WAIT`, `QUIET_WAIT`, `RECONNECT_WINDOW` (0 never reconnects),
`RECONNECT_HEALTHY`,
`RECONNECT_ATTEMPT` and `PASTE_TAIL_WAIT`) and `CHERRY_CLI_INPUT_HIGH_WATER`.
In `cherry-host`'s tests, `tests/support` has `Host::adopted()` (waits until
a respawned daemon has no pending holders), `children(pid)` and
`kill_holder(pid)`, and `tests/holder.rs` guards its holders with `Held`. In
`cherry-cli`'s `tests/real_host.rs`, dropping a `Host` or `FakeRemote` kills
the holders left in the manifests under its private `HOME`; `FakeRemote`
then shuts its daemon down and kills any `cherry-host serve` or `hold` still
using its socket.

Two GitHub workflows are configured. `host.yml` runs the Rust commands above on
macOS 15 arm64, Ubuntu 22.04 x86_64, and Ubuntu 24.04 arm64, plus a job that
runs `Scripts/test-host-ssh`. `app.yml`, on macOS 26, builds the Rust helpers
(`Scripts/build-host debug`), runs `python3 Scripts/test_cherry_private_host.py`
(the teardown the GUI test scripts use), builds the Swift tests, and then
runs `Scripts/test-session-suites --skip-build unit` and
`Scripts/test-session-suites --skip-build real-host`. Both cache the VT
library keyed on `Scripts/build-host-vt`. Configuring a workflow does not
establish that it has passed. Dependency notices are in
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) and
[vendor/ghostty-vt](vendor/ghostty-vt/README.md).
