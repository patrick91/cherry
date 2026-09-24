# Cherry session host

Cherry's opt-in persistent sessions run in a portable Rust daemon on macOS or
Linux. The daemon owns the PTY and a headless Ghostty terminal; the `cherry`
client reconnects locally through a Unix socket or remotely through system SSH.
Closing Cherry, detaching, or losing SSH leaves the workload running while the
host daemon remains alive. There is no public network listener or relay.

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
Rust target triple for the library; the complete host build and packaging
scripts build native binaries.

`Scripts/build-host`, `Scripts/package-host`, and `Scripts/install-local-app`
use Cargo's output directory: `CARGO_TARGET_DIR`, else `CARGO_BUILD_TARGET_DIR`,
else `Host/target`. With either variable set, copy the binaries from
`<that directory>/release/` instead of the path above. `Scripts/build-host`
rebuilds the VT library when it is missing or its stamps do not match (unless
`CHERRY_GHOSTTY_VT_DIR` is set), deletes the previous `cherry` and
`cherry-host` in the output directory before building, and fails if a Cargo
config `build.target` would put them somewhere else.

`Scripts/package-host` creates
`dist/host/cherry-host-<rust-target>.tar.gz`, containing both executables,
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
cherry list --json
```

`--cwd` accepts an absolute path, `~`, or `~/…`; the host expands `~` with its
own `HOME` and rejects relative paths. An empty value (`--cwd=`) means the home
directory. Quote `~` so your local shell does not expand it:
`--cwd '~/project'`. Use the `--name=VALUE` and `--cwd=VALUE` forms for values
that start with `-`. A new session starts at 120×32; the first attachment sets
its real size. `list --json` prints `{"host_id": …, "sessions": […]}`; each
session has `id`, `name`, `cwd`, `command`, `cols`, `rows`, `state` (`running`
or `exited`), `pid`, `exit_code`, `exit_signal`, and `attached`.

`kill` explicitly terminates the workload (see
[Lifetime](#lifetime-service-setup-and-updates)). `remove` only removes an
exited session's retained record; it refuses live sessions. Exited sessions
remain listed until removed. Attaching to an exited session shows its final
screen, then exits with its exit code. `shutdown` stops the daemon and is
refused while any session is running. When it returns, the daemon has already
removed its socket and released its lock, so a new daemon can start at once.
`start` starts the local daemon without doing anything else.

Multiple terminals can attach to the same session and type into it. Each
receives the same output; closing one leaves the others connected. Reconnect
is explicit, and keyboard input is never automatically replayed after a lost
connection. The shared terminal uses the smallest requested column count and
row count among its attached clients, so the application fits on every device.
It grows again when the smaller client disconnects. The larger terminal
displays the shared screen at its top left; see the scrollback limits below.
`cherry attach SESSION_ID --takeover` disconnects the other attachments and
continues alone; they end with the outcome `taken_over`, and their unsent
input is discarded. Attaching to a session from inside that same session is
refused.

### Attach options

- **Detaching.** Ctrl-] detaches after 400 ms, or immediately when another key
  follows it; that key is not sent. Pressing Ctrl-] twice within 400 ms sends
  one Ctrl-] to the session (Vim tag jumps, a nested `cherry attach`). The key
  is also recognized in kitty keyboard and modifyOtherKeys encodings, with Caps
  Lock or Num Lock on, and is ignored inside a bracketed paste. End of input
  (piped stdin) also detaches, after everything read before it.
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
- **`--status-file PATH`.** On every exit path, including signals and a lost
  connection, the CLI writes one JSON object to `PATH` (a temporary file in the
  same directory, then a rename; mode 0600):

  ```json
  {"outcome":"exited","exit_code":129,"signal":1,"message":null}
  ```

  `outcome` is `detached` (this client detached; the session keeps running),
  `exited` (the program ended; `exit_code` and `signal` are set),
  `disconnected` (the connection was lost or the CLI was interrupted after
  attaching; the session may still run), `taken_over` (another client used
  `--takeover`), or `failed` (the CLI could not attach, or rejected its command
  line). `message` explains every outcome except `exited` and a confirmed
  detach, where it is `null`.
- **Exit status.** `attach` exits with the session's exit code when the program
  ended, 0 when it detached (also without the host's confirmation), 1 for
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

It never becomes an SSH ControlMaster (it can still use an existing one) and
ignores an alias's `RemoteCommand` and port forwards. `attach` keeps your
agent forwarding settings (see [agent forwarding](#sockets-state-and-access)).
`--socket` is passed on as `cherry-host gateway --socket 'PATH'`. Management
commands (`list`, `new`, `kill`, `remove`, `shutdown`) add
`-a -o BatchMode=yes -o ConnectTimeout=10`, so they never forward an agent,
and must finish within 30 seconds; the desktop cannot answer password or
host-key prompts in the background. `kill`, `remove`, and `shutdown` run
`cherry-host gateway --no-start`. `attach` may prompt and allows 120 seconds
for the handshake.

The gateway prints `CHERRY-GATEWAY 3` on a line of its own before relaying
protocol frames. The client skips up to 64 KiB of output that a remote shell
prints before that line. Beyond that it fails with "the remote shell printed
output before cherry-host gateway started; remove output from non-interactive
shell startup files such as ~/.bashrc" and the first line printed. A gateway
that cannot reach a usable daemon (none is running for a command that never
starts one, it speaks another protocol version, its socket directory is not
trusted, or it does not answer) prints `cherry-host: REASON` on stderr and
exits 1 before its preamble. The client shows that line once, as its own
error `cherry-host on my-server: REASON`; the rest of ssh's stderr reaches
you as it arrives. `cherry-host gateway --no-start` never starts a daemon
(when none is running it creates nothing and fails) and otherwise makes the
same trust and version checks. With no daemon running,
`cherry --host my-server kill ID` fails with
`cherry-host on my-server: no cherry-host is running at PATH (this command
never starts one)`. When the connection closes before the preamble for
another reason, such as `cherry-host` missing from the remote `PATH`, the
client says the SSH connection closed before the gateway started, below ssh's
own errors.

### Starting the daemon

`list`, `new`, and `attach` start a daemon when none is running: locally through
`cherry-host start`, remotely through `cherry-host gateway`. `kill`, `remove`,
and `shutdown` never start one; they fail with `no cherry-host is running at
PATH (this command never starts one)`. Remotely they run
`cherry-host gateway --no-start`. `start` is local only.

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

`--socket /absolute/private/path/host.sock` selects a separate host (its own
daemon and state directory); with `--host`, that path is on the remote machine.
`--expected-host-id UUID` rejects a different host identity before acting.
`new --request-id UUID` makes retries of the same creation idempotent: a retry
with the same launch arguments returns the existing session, even from a
differently sized terminal, and reusing the ID for different arguments is
rejected. The host keeps that receipt until the session is removed or 4096
newer requests evict it; after that the same ID creates a new session.

## Use in the Mac app

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
Support folder let it run alongside Cherry. It does not have separate sessions:
both apps use the same local daemon (`/tmp/cherry-host-<uid>/host.sock`), so
**This Mac** lists the same sessions in each. The daemon keeps running the
`cherry-host` of whichever app started it and serves both, so both apps must
speak the same protocol version. The app includes both session helpers;
**This Mac** needs no separate CLI installation. Choose **Create & Attach**,
run a command, then close the tab or quit Cherry. Reopen Persistent Sessions
and attach to the same session to continue it. This local build is ad-hoc
signed by default and is not notarized. **This Mac** is unavailable while the
app runs from the disk image or an App Translocation location; SSH hosts still
work.

`Scripts/install-local-app` bundles `cherry` and `cherry-host` beside the Mac
app executable. It needs Rust for that; `CHERRY_SKIP_HOST=1` installs the app
without them, and Persistent Sessions is then unavailable in that copy.

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
`script/build_and_run.sh` builds the helpers and bundles them into
`CherryDev.app`, unless `CHERRY_SKIP_HOST=1`.

Existing local project terminals keep their native Ghostty process path.
Persistent sessions are a separate, opt-in workflow. Remote project discovery,
Git/worktree operations, previews/port forwarding, file transfer, and remote
MCP integration are not implemented by this feature.

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
- `host.log`: the stderr of a daemon started by a client. Under systemd, stderr
  goes to the journal instead.

These directories are never removed automatically. Session state itself is in
memory.

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
reaches later sessions. Sessions also get `TERM=xterm-256color`,
`COLORTERM=truecolor`, `TERM_PROGRAM=Cherry`, `CHERRY_SESSION_ID`, and
`SSH_AUTH_SOCK` as above. `PATH` defaults to
`/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` when the daemon has none; a login
shell re-reads your profile.

`cherry new` sends the invoking terminal's `LANG`, `LC_ALL`, `LC_*` locale
categories, and `TZ`; the host accepts no other variables from a client. When a
client sends any locale variable, it replaces the daemon's locale variables as a
whole. The daemon raises its own descriptor limit (up to 16384); sessions start
with the limit it had before.

The working directory must be absolute, `~`, or `~/…`, expanded with the
daemon's `HOME`, and must exist on the host. The descriptor reports the resolved
path. The host never resolves a relative path against its own working directory.

## Lifetime, service setup, and updates

Processes survive app exit and SSH disconnection, not daemon crash, host
reboot, or the operating system killing the user's processes at logout.

`cherry kill` (Terminate in the app) signals every live process in the
session's kernel session: SIGHUP, then SIGTERM after 2 seconds, then SIGKILL
after 4 seconds, repeated until the session's first process is gone. Each
signal except SIGKILL is followed by SIGCONT so stopped jobs act on it. The
host acknowledges the request immediately; the session is listed as exited when
its processes have gone, so a `list` right after `kill` may still show it
running for up to about 4 seconds. Processes that moved into their own session
(`setsid`, tmux or pm2 servers, daemons) are not signalled.

When the session's program exits on its own, the host sends no signals. As in
any terminal, the exit is a hangup: the kernel signals the foreground job and
the host closes the PTY. Jobs started with `nohup` or disowned keep running.

`exit_code` is the program's exit status. For a program ended by a signal it is
128 plus the signal number, and `exit_signal` holds the signal. A shell ended by
Terminate usually reports 129 (SIGHUP).

On Linux with systemd, use the provided user service if logout policy would
otherwise terminate the detached daemon. First finish existing sessions and
run `cherry shutdown` so there is no already-running unmanaged daemon. With
the binaries installed in `~/.local/bin`, from this checkout:

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

The template uses `Restart=no`: restarting a dead daemon cannot recover its
previous jobs. It uses `KillMode=process`: stopping the service signals only the
daemon, whose sessions then end when it closes their PTYs. Processes that
hosted sessions detached into their own session (tmux or pm2 servers,
`emacs --daemon`, `setsid nohup job &`) stay in the unit's cgroup and survive;
systemd reports them as left-over processes when the unit starts again. The
template uses the default socket and executable path; edit the unit if you
installed elsewhere. No launchd agent is provided for macOS.

There is no hot upgrade, and there is no compatibility across versions: client
and host must speak the same protocol version. A client or gateway that finds
a daemon speaking another version refuses to use it and never stops or
replaces it. Installing a new binary leaves an existing daemon running its old
code, and once a machine's binaries are replaced, nothing reaches that daemon
any more: the new `cherry` and the new gateway both refuse it, so neither
`cherry shutdown` there nor `cherry --host my-server shutdown` can stop it.

So update in this order:

1. Before installing new binaries on a machine, finish or terminate
   (`cherry kill`) its sessions and stop its daemon with the old binaries still
   installed: `cherry shutdown` locally, `cherry --host my-server shutdown`
   while your client is still the old version too, or `cherry shutdown` run on
   that host itself (for example `ssh my-server cherry shutdown`).
2. Install the same new version on every machine: the client and each host.
   The Mac app bundles its own `cherry` and `cherry-host`, so replacing the app
   counts as installing new binaries on that Mac.
3. The next `list`, `new`, or `attach` starts a daemon of the new version. For
   the systemd installation, start the service again with
   `systemctl --user start cherry-host.service`. Never restart the service
   expecting its jobs to survive.

A daemon left running under replaced binaries can only be stopped on its host
by a signal, for example `systemctl --user stop cherry-host.service` or
`pkill -u "$USER" -f 'cherry-host serve'`. Its sessions end with it, as after
a crash.

## Connections and flow control

- **Heartbeat.** An attached client sends `Ping` every 15 seconds, also while
  a slow terminal is still taking its output, so a slow terminal does not get
  the attachment evicted. The host drops an attachment that sends nothing for
  45 seconds, so a vanished laptop stops constraining the shared grid; a
  client whose input it holds back is exempt (see input backpressure). A
  connection that is not attached must send its next request within 10
  seconds. The CLI ends an attachment when its connection neither accepts nor
  delivers anything for 45 seconds while it has input to send; over SSH,
  `ServerAliveInterval` detects a dead network. It also gives up when its own
  terminal accepts no output at all for 15 seconds (outcome `disconnected`;
  the session keeps running). When the host stops reading the connection
  without closing it, the CLI ends the attachment 5 seconds later as a lost
  connection, unless what the host sent before (a takeover notice, the
  program's exit) decides the outcome first; while detaching, see
  [Host closing first](#attach-options).
- **Slow clients.** A client's queued output has a 4 MiB budget. Beyond that
  the host drops the client's queued output and, once what remains in its
  queue is at most 256 KiB, sends it a fresh snapshot (`Attached` with reason
  `resync`). Output that a snapshot cannot rebuild is kept, within bounds, and
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
  slow client never slows the session or other clients and is not
  disconnected for being slow; a failed write, meaning the peer is gone, ends
  the attachment. A client that stops reading replies while sending requests
  is no longer read from once more than 32 MiB of replies wait.
- **Input backpressure.** While more than 1 MiB of a session's input waits for
  the program, the host stops reading from any client that sends more input,
  and resumes below 256 KiB. A large paste into a slow program is delivered in
  full instead of disconnecting the client. A held client is never
  disconnected for being silent, since its heartbeats wait behind the held
  input: the host sends it a `Pong` every 15 seconds while nothing moves, and
  at most one a second while the program consumes the input. Only a hangup, a
  failed write, a takeover, or the session's end stops the wait. The CLI keeps
  displaying output meanwhile and stops queueing terminal input while 1 MiB
  of it is unsent. With a detach key, it then reads at most 64 KiB more, in
  order, so a detach key typed behind that input is still seen (pressing it
  twice still sends Ctrl-]). Such a detach discards unsent input, as
  described in [Input order](#attach-options). Input beyond that waits in the
  terminal. So after pasting well over 2 MiB into a program that is not
  reading, the detach key is not seen until the program reads or the
  `cherry` process ends (for example because its terminal window was
  closed). With `--detach-key none`, the terminal is not read beyond the
  1 MiB.
- **Resizing.** The CLI sends at most one resize per 50 ms during a window drag.
  The host applies a change to the shared grid once the requested size has been
  stable for 75 ms, so a drag produces one replacement rather than one per
  step. A replacement is `Attached` with reason `resize`. For most windows it
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
  its resync. A resize that cannot be applied is reported as `resize_failed`
  without ending the attachment.

## Bounds and terminal fidelity

The daemon allows 128 sessions, including retained exited sessions, and 128
concurrent connections. Remove exited sessions to free session slots. It keeps
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

When an attachment's size matches the shared grid, it uses the ordinary
terminal stream and its own scrollback. A larger attachment is repainted from a
bounded view of the shared active screen, so its native terminal scrollback is
not available while its dimensions differ from the shared grid. The host still
retains its bounded history. A window that returns to ordinary rendering (the
shared grid grows to it when the smaller client disconnects, or the window
shrinks to the grid) gets a full snapshot with retained history. A window that
stayed on the stream while the grid followed its own resize keeps its own
scrollback. This is a limit of simultaneous differently sized views, not
a separate process or terminal session.

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
viewport mode enables them there. Size replies use nominal 8×16 pixel
cells; colour replies use fixed dark defaults. Kitty graphics reach renderers
with `q=2`, so only the host replies. Other queries (status reports such as
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

Frames are a 4-byte big-endian length followed by a JSON message of at most
16 MiB; terminal bytes are base64 strings. The client opens with `Hello` and the
host answers `Welcome` with its identity. The current version is 3, and the
host accepts only an exact match: any other version gets the error
`version_mismatch` and nothing else happens on that connection. An attached
client must accept a replacement `Attached` snapshot at any time (reasons
`attach`, `resize`, `resync`) and resume output at its offset. A `resize`
replacement may hold only the screens, without a reset or history, for a
renderer that keeps its own history or paints a viewport. An `Attached`
offset may be lower than the offset of the stream when carried output
follows it (see [slow clients](#connections-and-flow-control)); that output
starts at the `Attached` offset, so resuming there needs nothing more. An
attached client may also receive `Query` messages at any time: terminal
queries for its own terminal, placed between `Output` messages in stream
order but carrying no offset. The client writes them to its terminal as they
are, and the terminal's replies return as ordinary `Input`. `Attach` has a
required `answers_queries` flag: true only when the client writes queries to
a terminal whose replies it reads as input. The host sends no queries to a
client that sets it false. Errors carry a code: `version_mismatch`,
`request_failed`, `taken_over`, `resize_failed`, or `snapshot_failed`.
`resize_failed`, and `snapshot_failed` for a replacement snapshot, do not end
an attachment; `snapshot_failed` in reply to `Attach` means the attach
failed. The definitions are in
[cherry-protocol](crates/cherry-protocol/src/lib.rs).

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

After building the Rust debug binaries with `Scripts/build-host debug`, verify
the snapshot through Cherry's actual native Ghostty renderer on macOS:

```sh
CHERRY_TEST_HOST_INTEGRATION=1 swift test --no-parallel --filter HostedSessionRealHost
```

The seven ignored `real_host` tests run the `cherry` that `cargo test` builds
and the `cherry-host` beside it (hence `cargo build --bins` first; set
`CHERRY_TEST_HOST` to use another), each daemon with a private socket and a
temporary `HOME`. They cover shared attachment and takeover, only the
terminal that typed last answering the program's queries, process and
screen survival across reconnects, piped input and detaching behind input the
program never reads or reads slowly (about 5 seconds), and remote `kill`,
`remove`, and `shutdown` through the real gateway behind a fake `ssh`. The
ignored Neovim tests in `cherry-host` and `cherry-vt` need `nvim` on PATH: they
run real Neovim on a PTY, reconstruct its state in a second terminal (or
reattach through the host at a new size), and check returning to the shell.
The ignored test that checks the daemon drops other users' connections only
runs as root. The Swift integration test opens two differently sized native
Ghostty views, sends input from both, and checks screen restoration and
disconnect survival. `Scripts/test-host-linux` runs the Rust tests above
natively as root in a Debian 12 Docker image with a pinned Neovim.
`Scripts/test-host-ssh` runs that suite, then exercises a local client against
a Linux host in that image through actual SSH with disposable keys and pinned
fixture host keys; it requires Docker and OpenSSH tools.

Two GitHub workflows are configured. `host.yml` runs the Rust commands above on
macOS 15 arm64, Ubuntu 22.04 x86_64, and Ubuntu 24.04 arm64, plus a job that
runs `Scripts/test-host-ssh`. `app.yml` builds the helpers and the Swift
package on macOS 26 and runs the hosted-session and app-identity tests and the
native Ghostty integration test. Both cache the VT library keyed on
`Scripts/build-host-vt`. Configuring a workflow does not establish that it has
passed. Dependency notices are in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)
and [vendor/ghostty-vt](vendor/ghostty-vt/README.md).
