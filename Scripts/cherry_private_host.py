"""Run Cherry apart from the user's own, and tear down its cherry-host daemon.

Scripts/test-packaged-app, Scripts/test-mcp-concurrency and
Scripts/perf-run-emulator-comparison launch a Cherry whose local tabs are
persistent sessions (the default) on a daemon of its own: CHERRY_HOST_SOCKET
names a socket in a private (0700) directory and HOME is private too, so the
user's daemon, sessions and saved tabs are never touched. `stop` leaves nothing
of that daemon behind: sessions, holders, attach adapters or a state directory
outside the private HOME.

`make_private_directory`, `layout`, `isolated_environment` and
`stop_private_run` are the pieces for a run from one private directory
(`home/`, `control.sock`, `host.sock`). To end a run that was left open:

    python3 Scripts/cherry_private_host.py stop DIRECTORY [--cli CHERRY]
"""

import argparse
import json
import os
import pwd
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def reachable(socket_path):
    """Whether something accepts connections on the Unix socket."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(1)
        try:
            connection.connect(str(socket_path))
        except OSError:
            return False
    return True


def sessions(cli, socket_path, environment, cwd=None, prefix=()):
    """The session objects the host lists, or None when it does not answer.

    `cherry list` starts a host when none runs, so an unreachable socket is
    not listed at all.
    """
    if not reachable(socket_path):
        return None
    try:
        result = subprocess.run([*prefix, str(cli), "--socket", str(socket_path), "list", "--json"],
                                env=environment, cwd=cwd, capture_output=True, text=True, timeout=30)
        listing = json.loads(result.stdout) if result.returncode == 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    items = listing.get("sessions") if isinstance(listing, dict) else None
    if not isinstance(items, list):
        return None
    return [item for item in items if isinstance(item, dict) and isinstance(item.get("id"), str)]


def state_dir(home, socket_path):
    """The macOS state directory (identity, lock, log, session manifests) of
    the daemon for a socket other than the default one: keyed by the FNV-1a
    hash of the socket path, as state_key in Host/crates/cherry-host/src/paths.rs.
    """
    key = 0xCBF29CE484222325
    for byte in os.fsencode(str(socket_path)):
        key = ((key ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return Path(home) / "Library/Application Support/cherry-host" / f"{key:016x}"


def processes(matches):
    """(pid, command line) of every other process whose command line `matches`."""
    listing = subprocess.run(["/bin/ps", "-axww", "-o", "pid=,command="],
                             capture_output=True, text=True, check=False).stdout
    found = []
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(" ")
        command = command.strip()
        if pid.isdigit() and int(pid) != os.getpid() and matches(command):
            found.append((int(pid), command))
    return found


def terminate(matches, grace=3.0):
    """SIGTERM every process whose command line `matches`, then SIGKILL what
    is left after `grace` seconds."""
    for signal_number, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 2.0)):
        targets = {pid for pid, _ in processes(matches)}
        if not targets:
            return
        for pid in targets:
            try:
                os.kill(pid, signal_number)
            except OSError:
                pass
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline and targets & {pid for pid, _ in processes(matches)}:
            time.sleep(0.1)


def _is_host(command):
    """A daemon (`cherry-host serve --socket …`) or holder (`hold --socket …`)."""
    return re.search(r" (serve|hold) --socket ", command) is not None


def stop(cli, socket_path, environment, cwd=None, prefix=(), markers=()):
    """End every session on the daemon at `socket_path`, then the daemon.

    `cli` is a cherry executable, run as `prefix + [cli, …]` with
    `environment` (which keeps the daemon's private HOME); None stops
    processes only. Processes whose command line contains one of `markers`
    (such as the private directory a test's Cherry runs from) are stopped too.
    Returns what could not be cleaned up, as a list of messages.
    """
    socket_path = str(socket_path)
    listed = sessions(cli, socket_path, environment, cwd, prefix) if cli else None
    ids = [item["id"] for item in listed or []]

    # Ghostty runs attach adapters (`cherry … attach <id>`) through login(1),
    # which resets HOME to the user's own: an adapter that outlived the daemon
    # would start it again, with its state beside the user's real host. Stop
    # them, and whatever else the markers name, while the daemon still runs.
    def adapter_or_marked(command):
        return not _is_host(command) and (
            any(f" attach {session_id}" in command for session_id in ids)
            or any(marker in command for marker in markers))

    terminate(adapter_or_marked)
    if cli and reachable(socket_path):
        def cherry(*arguments):
            try:
                subprocess.run([*prefix, str(cli), "--socket", socket_path, *arguments],
                               env=environment, cwd=cwd, capture_output=True, timeout=30)
            except (OSError, subprocess.SubprocessError):
                pass

        for item in sessions(cli, socket_path, environment, cwd, prefix) or []:
            if item.get("state") != "exited":
                cherry("kill", item["id"])
        deadline = time.monotonic() + 15
        remaining = []
        while time.monotonic() < deadline:
            remaining = sessions(cli, socket_path, environment, cwd, prefix) or []
            if all(item.get("state") == "exited" for item in remaining):
                break
            time.sleep(0.2)
        # A removed session's holder exits; shutdown is refused while any
        # session runs.
        for item in remaining:
            cherry("remove", item["id"])
        cherry("shutdown")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and reachable(socket_path):
            time.sleep(0.1)

    # A daemon that refused to stop, holders of sessions that could not be
    # removed, anything else still running from the markers.
    def leftover(command):
        return socket_path in command or any(marker in command for marker in markers)

    terminate(leftover)
    problems = [f"still running: {pid} {command}" for pid, command in processes(leftover)]
    # The daemon keeps its state under its HOME, the private one. A state
    # directory for this socket under the user's own home can only be from a
    # daemon an adapter started again (see above): the socket path is unique
    # to this run.
    private_home = environment.get("HOME")
    for home in {str(Path.home()), pwd.getpwuid(os.getuid()).pw_dir} - {private_home}:
        stray = state_dir(home, socket_path)
        if stray.is_dir():
            shutil.rmtree(stray, ignore_errors=True)
            problems.append(f"removed a host state directory outside the private HOME: {stray}")
    return problems


def make_private_directory(prefix):
    """A new private (0700) directory for one Cherry run, with its private
    HOME made (see `layout`). It is under /private/tmp on macOS, which keeps
    the socket paths in it short enough for a Unix socket."""
    base = "/private/tmp" if os.path.isdir("/private/tmp") else None
    directory = Path(tempfile.mkdtemp(prefix=prefix, dir=base))
    layout(directory)[0].mkdir(mode=0o700)
    return directory


def layout(directory):
    """The private HOME, control socket and session-host socket of a run
    from `directory`."""
    directory = Path(directory)
    return directory / "home", directory / "control.sock", directory / "host.sock"


def isolated_environment(base, home, control_socket, host_socket):
    """`base` for a Cherry that runs apart from the user's own.

    The CHERRY_* variables a Cherry tab sets (its control socket and
    namespace, its process id, a host socket) would point the run at the
    user's app, so they are dropped, except the helper override
    CHERRY_CLI_PATH. HOME and CFFIXED_USER_HOME (which Foundation's home
    directory, and so Application Support, follows) are the private HOME, and
    the control and session-host sockets are the private ones.
    """
    environment = {key: value for key, value in base.items()
                   if not key.startswith("CHERRY_") or key == "CHERRY_CLI_PATH"}
    environment.update({
        "HOME": str(home),
        "CFFIXED_USER_HOME": str(home),
        "CHERRY_CONTROL_SOCKET": str(control_socket),
        "CHERRY_HOST_SOCKET": str(host_socket),
    })
    return environment


def _exact_executable(path):
    """Whether `path` is an executable file under exactly its own name. On a
    case-insensitive volume `cherry` also opens a `Cherry` (the GUI), which
    HostedSessionClient.isHelper rejects too."""
    try:
        return (path.name in os.listdir(path.parent) and path.is_file()
                and os.access(path, os.X_OK))
    except OSError:
        return False


def development_cli(repository, environment, cwd=None):
    """The cherry an unbundled Cherry run from `repository` with
    `environment` and working directory `cwd` uses, in
    HostedSessionClient.installed's order: CHERRY_CLI_PATH; the Host
    workspace's Cargo output (CARGO_TARGET_DIR, else CARGO_BUILD_TARGET_DIR,
    relative to `cwd`; then Host/target), debug before release; then PATH.
    None when there is none."""
    override = environment.get("CHERRY_CLI_PATH")
    if override:
        return Path(override) if os.path.isfile(override) and os.access(override, os.X_OK) else None
    directories = []
    configured = environment.get("CARGO_TARGET_DIR") or environment.get("CARGO_BUILD_TARGET_DIR")
    if configured:
        directories.append(Path(cwd or os.getcwd()) / configured)
    directories.append(Path(repository) / "Host/target")
    candidates = [directory / configuration / "cherry"
                  for directory in directories for configuration in ("debug", "release")]
    candidates += [Path(entry) / "cherry" for entry in environment.get("PATH", "").split(":") if entry]
    return next((candidate for candidate in candidates if _exact_executable(candidate)), None)


def stop_private_run(directory, cli, cwd=None):
    """`stop` the daemon of a run from `directory` (see `layout`), with
    everything whose command line names the directory, then delete the
    directory. Returns what could not be cleaned up, as a list of messages."""
    directory = Path(directory)
    home, control_socket, host_socket = layout(directory)
    environment = isolated_environment(os.environ, home, control_socket, host_socket)
    try:
        problems = stop(cli, host_socket, environment, cwd=cwd or directory, markers=[directory.name])
    except (OSError, subprocess.SubprocessError) as error:
        problems = [f"cleanup failed: {error}"]
    shutil.rmtree(directory, ignore_errors=True)
    if directory.exists():
        problems.append(f"could not delete {directory}")
    return problems


def _private_run_directory(value):
    """Only a directory `make_private_directory` could have made: this user's,
    private (0700), with a private HOME in it. The command deletes it."""
    directory = Path(value).resolve()
    try:
        status = directory.stat()
    except OSError as error:
        raise argparse.ArgumentTypeError(f"{value}: {error.strerror}")
    if (not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid()
            or stat.S_IMODE(status.st_mode) != 0o700 or not layout(directory)[0].is_dir()):
        raise argparse.ArgumentTypeError(
            f"{value} is not a private Cherry run directory (0700, yours, with home/ in it)")
    return directory


def main(arguments=None):
    parser = argparse.ArgumentParser(
        prog="Scripts/cherry_private_host.py",
        description="Tear down a Cherry run from a private directory (home/, control.sock, host.sock).")
    actions = parser.add_subparsers(dest="action", required=True)
    stop_parser = actions.add_parser(
        "stop", help="End every session on the run's cherry-host, the daemon, its holders and attach adapters, "
                     "and everything that names the directory, then delete the directory. Quit its Cherry first.")
    stop_parser.add_argument("directory", type=_private_run_directory)
    stop_parser.add_argument("--cli", help="The cherry executable to end sessions with "
                                           "(default: the one an unbundled Cherry from this checkout uses).")
    options = parser.parse_args(arguments)
    repository = Path(__file__).resolve().parent.parent
    home, control_socket, host_socket = layout(options.directory)
    cli = Path(options.cli) if options.cli else development_cli(
        repository, isolated_environment(os.environ, home, control_socket, host_socket), cwd=repository)
    problems = stop_private_run(options.directory, cli)
    for problem in problems:
        print(f"cherry_private_host: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main())
