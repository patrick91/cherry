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
downloads checksum-pinned Zig 0.16.0 and builds a pinned Ghostty revision. See
[the VT dependency notes](vendor/ghostty-vt/README.md) for revision and toolchain
overrides. `Scripts/build-host-vt` accepts a Rust target triple for the library;
the complete host build and packaging scripts build native binaries.

`Scripts/package-host` creates
`dist/host/cherry-host-<rust-target>.tar.gz`, containing both executables,
documentation, service templates, and dependency notices. Install the matching
archive on each host. Remote connections require `cherry-host` on the remote
SSH command's `PATH`; an interactive shell's PATH may differ. Verify it with
`ssh my-server 'command -v cherry-host'`.

The supported build targets are macOS arm64/x86_64 and GNU Linux arm64/x86_64.
Native Linux validation uses Debian 12. The Ghostty archive is built with a
glibc 2.31 target, but this is **not a verified glibc floor for the complete Rust
binaries**. Build on your deployment distribution or validate an archive there.
Musl Linux and Windows are not supported by these scripts.

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

`new` prints a JSON session descriptor, including `id`, and defaults to the
host's login shell. To run a particular program, append `-- PROGRAM ARG...`:

```sh
cherry new --cwd /absolute/path/to/project --name Editor -- nvim README.md
cherry list --json
```

`kill` explicitly terminates the workload. `remove` only removes an exited
session's retained record; it refuses live sessions. Exited sessions remain
listed until removed. Multiple terminals can attach to the same session and
type into it. Each receives the same output; closing one leaves the others
connected. Reconnect is explicit, and keyboard input is never automatically
replayed after a lost connection.

The shared terminal uses the smallest requested column count and row count
among its attached clients, so the application fits on every device. It grows
again when the smaller client disconnects. The larger terminal displays the
shared screen at its top left; see the scrollback limits below.

To explicitly disconnect other attachments and continue alone, the CLI also
offers `cherry attach SESSION_ID --takeover`. Ordinary Attach and Reconnect in
the Mac app keep other terminals connected.

For another Mac or Linux machine, install `cherry-host` there and establish
SSH trust and authentication with an ordinary `ssh my-server` first. Cherry
uses normal SSH aliases, keys, agents, and jump-host configuration:

```sh
cherry --host my-server new --cwd /home/me/project --name Remote
cherry --host my-server list --json
cherry --host my-server attach SESSION_ID
cherry --host my-server kill SESSION_ID
cherry --host my-server remove SESSION_ID
```

Remote management commands use SSH batch authentication and bounded connection
timeouts. The desktop cannot answer password or host-key prompts in the
background. The fixed remote command is `cherry-host gateway`; the daemon
starts automatically if needed. Local commands also start it automatically.

`--socket /absolute/private/path/host.sock` selects a separate host state
directory; with `--host`, that path is on the remote machine.
`--expected-host-id UUID` rejects a different host identity before acting.
`new --request-id UUID` makes retries of the same creation idempotent for the
daemon's lifetime; reusing it for different launch arguments is rejected.

## Use in the Mac app

Open **File → Persistent Sessions…** (`Cmd-Shift-R`). Choose **This Mac** or add
an SSH destination, create a session with its host-side directory, then attach.
The session view offers Disconnect and Reconnect; the session list offers
Terminate and removal of exited records. Forgetting a saved destination does
not terminate its sessions. You can attach from your laptop while the same
session remains open on another Mac or in a command-line terminal. Both can
type, so coordinate commands when another person is using the session.

For a self-contained test build, run `Scripts/package-dmg`, open the resulting
`dist/Cherry Sessions-<architecture>.dmg`, and drag **Cherry Sessions** into
Applications. Its distinct icon, bundle identifier, settings, and private app
data let it run alongside Cherry. The app includes both session helpers;
**This Mac** needs no separate CLI installation.
Choose **Create & Attach**, run a command, then close the tab or quit Cherry.
Reopen Persistent Sessions and attach to the same session to continue it.
This local build is ad-hoc signed by default and is not notarized.

`Scripts/install-local-app` bundles `cherry` and `cherry-host` beside the Mac
app executable. For development, run `Scripts/build-host debug` before
`swift run Cherry`; the app can find the helper in `Host/target/debug`.
`CHERRY_CLI_PATH` can select an explicit executable. The CLI finds its daemon
through `CHERRY_HOST_PATH`, a sibling `cherry-host`, then `PATH`.

Existing local project terminals keep their native Ghostty process path.
Persistent sessions are a separate, opt-in workflow. Remote project discovery,
Git/worktree operations, previews/port forwarding, file transfer, and remote
MCP integration are not implemented by this feature.

## Lifetime, service setup, and updates

The default socket is `/tmp/cherry-host-<uid>/host.sock`, inside a user-owned
0700 directory; the socket is 0600 and accepts same-user peers. The directory
also holds `host-id`, `host.lock`, and `host.log`. Set `CHERRY_HOST_SOCKET` or
pass `--socket` to choose another private directory. Host identity survives
daemon restarts while the identity file remains, but session state is in
memory. Temporary-directory cleanup can remove the default identity.

Processes survive app exit and SSH disconnection, not daemon crash, host
reboot, or the operating system killing the user's processes at logout. On
Linux with systemd, use the provided user service if logout policy would
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

No service is installed automatically. The template uses `Restart=no`:
restarting a dead daemon cannot recover its previous jobs. It uses the default
socket and executable path; edit the unit if you installed elsewhere.

There is no hot upgrade. Installing a new binary leaves an existing daemon
running its old code. Finish or explicitly terminate its sessions, then run
`cherry shutdown` (or `cherry --host my-server shutdown`) before restarting
with the new version. Shutdown refuses while any session is still running.
For the systemd installation, start the service again with
`systemctl --user start cherry-host.service`. Update both client and host for
protocol changes. Never restart the service expecting its jobs to survive.

Shared attachments use protocol version 2. Before upgrading a version 1 host,
finish its jobs and run `cherry shutdown` using the old client, locally or with
`--host my-server` as appropriate. Then update both helpers and reconnect.
The new client rejects an old daemon; it does not kill or replace it
automatically. Keep the old client available until that shutdown is complete.

## Bounds and terminal fidelity

The daemon allows 128 sessions, including retained exited sessions, and keeps
4096 creation receipts for idempotent retries. Remove exited sessions to free
session slots. Once the receipt limit is reached, finish all workloads and
shut down/restart the daemon. Scrollback has a 1 MiB budget per terminal; there
is no permanent output journal or recovery of evicted history.

Reconnect sends a consistent terminal snapshot followed by subsequent output.
The host answers terminal queries even while detached and removes those
queries from the renderer stream to avoid duplicate replies. Restoration
covers text, retained history, styling, cursor, common input modes, and the
primary screen beneath Neovim's normal 1049 alternate screen.

When an attachment's size matches the shared grid, it uses the ordinary
terminal stream and snapshot history. A larger attachment is repainted from a
bounded view of the shared active screen, so its native terminal scrollback is
not available while its dimensions differ from the shared grid. The host still
retains its bounded history. Disconnecting the smaller client lets the shared
grid grow and returns a matching client to ordinary rendering and retained
snapshot history. This is an initial limit of simultaneous differently sized
views, not a separate process or terminal session.

Current snapshot limitations include terminal graphics, palette/theme state,
OSC 7 directory metadata, cursor shape, arbitrary saved cursor slots, and an
inactive alternate screen. Legacy 47/1047 saved-cursor semantics are not
guaranteed. Size replies use nominal 8×16 pixel cells; color replies use fixed
dark defaults. Individual control strings are bounded to 64 KiB. See
[cherry-vt](crates/cherry-vt/README.md) for details.

## Validation

```sh
Scripts/build-host-vt
cargo fmt --manifest-path Host/Cargo.toml --all -- --check
cargo clippy --manifest-path Host/Cargo.toml --locked --workspace --all-targets -- -D warnings
cargo test --manifest-path Host/Cargo.toml --locked --workspace -- --test-threads=1
cargo build --manifest-path Host/Cargo.toml --locked --bins
cargo test --manifest-path Host/Cargo.toml --locked -p cherry-cli --test real_host -- --ignored
cargo test --manifest-path Host/Cargo.toml --locked -p cherry-vt --test neovim -- --ignored
```

After building the Rust debug binaries with `Scripts/build-host debug`, verify
the snapshot through Cherry's actual native Ghostty renderer on macOS:

```sh
CHERRY_TEST_HOST_INTEGRATION=1 swift test --no-parallel --filter HostedSessionRealHost
```

The Rust `neovim` test needs `nvim` on PATH. It runs real Neovim on a PTY, reconstructs
its state in a second headless terminal, and checks returning to the shell.
`real_host` exercises real daemon/CLI attachment and process survival.
The Swift integration test opens two differently sized native Ghostty views,
sends input from both, and checks screen restoration and disconnect survival.
`Scripts/test-host-linux` runs native Linux tests in a Debian 12 Docker image.
`Scripts/test-host-ssh` additionally exercises a local client against a Linux
host through actual SSH with disposable keys and pinned fixture host keys;
it requires Docker and OpenSSH tools.

The GitHub workflow configures macOS arm64, Linux x86_64, and Linux arm64
checks; adding the workflow does not itself establish that those CI jobs have
run. Dependency notices are in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)
and [vendor/ghostty-vt](vendor/ghostty-vt/README.md).
