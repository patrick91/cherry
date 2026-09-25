"""Tests for cherry_private_host, the private run setup and daemon teardown
the GUI test and perf scripts use. The end-to-end tests run the cherry and
cherry-host built by Scripts/build-host debug on a private socket with a
private HOME; they are skipped when those are missing, unless
CHERRY_TEST_HOST_INTEGRATION=1 (as in CI), which makes that a failure.
Run: python3 Scripts/test_cherry_private_host.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import cherry_private_host as host  # noqa: E402

REPOSITORY = Path(__file__).resolve().parent.parent


def debug_helpers():
    """The cherry executable beside a cherry-host, where the Swift tests look."""
    configured = os.environ.get("CARGO_TARGET_DIR") or os.environ.get("CARGO_BUILD_TARGET_DIR")
    candidates = ([Path(configured)] if configured else []) + [REPOSITORY / "Host/target"]
    for directory in candidates:
        cli = directory / "debug/cherry"
        if os.access(cli, os.X_OK) and os.access(directory / "debug/cherry-host", os.X_OK):
            return cli
    return None


def orphan(*arguments):
    """Start a sleeping process that is not this one's child (like an attach
    adapter whose GUI is gone, launchd reaps it) with `arguments` on its
    command line, and return its pid."""
    launcher = ("import subprocess, sys; "
                "print(subprocess.Popen(sys.argv[1:], start_new_session=True, "
                "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid)")
    sleeper = [sys.executable, "-c", "import time; time.sleep(120)"]
    return int(subprocess.run([sys.executable, "-c", launcher, *sleeper, *arguments],
                              capture_output=True, text=True, check=True).stdout)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)
    return True


class StateDirTests(unittest.TestCase):
    def test_matches_the_hosts_state_key(self):
        # The vector from state_keys_are_stable_and_distinguish_sockets in
        # Host/crates/cherry-host/src/paths.rs.
        self.assertEqual(host.state_dir("/h", "/x"),
                         Path("/h/Library/Application Support/cherry-host/07d64e07b49caeb2"))


def executable(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(0o755)
    return path


class IsolatedEnvironmentTests(unittest.TestCase):
    def test_drops_a_cherry_tabs_variables_and_sets_the_private_ones(self):
        base = {
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/someone",
            "CHERRY_CONTROL_SOCKET": "/tmp/cherry-501/users-app/control.sock",
            "CHERRY_CONTROL_NAMESPACE": "users-app",
            "CHERRY_PROCESS_ID": "1234",
            "CHERRY_HOST_SOCKET": "/tmp/cherry-host-501/host.sock",
            "CHERRY_CLI_PATH": "/opt/cherry/bin/cherry",
            "CARGO_TARGET_DIR": "/cargo",
        }
        original = dict(base)

        environment = host.isolated_environment(base, "/p/home", "/p/control.sock", "/p/host.sock")

        self.assertEqual(environment, {
            "PATH": "/usr/bin:/bin",
            "HOME": "/p/home",
            "CFFIXED_USER_HOME": "/p/home",
            "CHERRY_CONTROL_SOCKET": "/p/control.sock",
            "CHERRY_HOST_SOCKET": "/p/host.sock",
            "CHERRY_CLI_PATH": "/opt/cherry/bin/cherry",
            "CARGO_TARGET_DIR": "/cargo",
        })
        self.assertEqual(base, original)


class PrivateDirectoryTests(unittest.TestCase):
    def test_is_private_with_a_private_home_and_short_socket_paths(self):
        directory = host.make_private_directory("chp-")
        self.addCleanup(shutil.rmtree, directory, True)
        home, control_socket, host_socket = host.layout(directory)

        self.assertEqual(os.stat(directory).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(home).st_mode & 0o777, 0o700)
        self.assertEqual((control_socket.parent, host_socket.parent), (directory, directory))
        # sockaddr_un.sun_path is 104 bytes on macOS.
        self.assertLess(len(os.fsencode(str(host_socket))), 104)
        self.assertLess(len(os.fsencode(str(control_socket))), 104)

    def test_stop_refuses_a_directory_it_did_not_make(self):
        for mode, with_home in ((0o755, True), (0o700, False)):
            directory = Path(tempfile.mkdtemp(prefix="chp-"))
            self.addCleanup(shutil.rmtree, directory, True)
            directory.chmod(mode)
            if with_home:
                (directory / "home").mkdir()
            with self.subTest(mode=oct(mode), with_home=with_home):
                result = subprocess.run([sys.executable, str(REPOSITORY / "Scripts/cherry_private_host.py"),
                                         "stop", str(directory), "--cli", "/nonexistent/cherry"],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("not a private Cherry run directory", result.stderr)
                self.assertTrue(directory.is_dir())


class DevelopmentCliTests(unittest.TestCase):
    """The lookup order of HostedSessionClient.installed for an unbundled run."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="chp-cli-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.repository = self.root / "repo"
        self.repository.mkdir()

    def cli(self, **environment):
        return host.development_cli(self.repository, environment, cwd=self.root)

    def test_cherry_cli_path_comes_first_and_must_be_executable(self):
        override = executable(self.root / "override/cherry")
        executable(self.repository / "Host/target/debug/cherry")
        self.assertEqual(self.cli(CHERRY_CLI_PATH=str(override)), override)
        override.chmod(0o644)
        self.assertIsNone(self.cli(CHERRY_CLI_PATH=str(override)))

    def test_the_configured_target_directory_before_the_workspaces_and_debug_before_release(self):
        workspace_debug = executable(self.repository / "Host/target/debug/cherry")
        self.assertEqual(self.cli(), workspace_debug)
        configured_release = executable(self.root / "cargo/release/cherry")
        self.assertEqual(self.cli(CARGO_TARGET_DIR=str(self.root / "cargo")), configured_release)
        configured_debug = executable(self.root / "cargo/debug/cherry")
        self.assertEqual(self.cli(CARGO_TARGET_DIR=str(self.root / "cargo")), configured_debug)
        # Cargo's precedence; an empty value is unset; a relative one is
        # relative to Cherry's working directory.
        self.assertEqual(self.cli(CARGO_TARGET_DIR="", CARGO_BUILD_TARGET_DIR=str(self.root / "cargo")),
                         configured_debug)
        self.assertEqual(self.cli(CARGO_BUILD_TARGET_DIR="cargo"), self.root / "cargo/debug/cherry")
        self.assertEqual(self.cli(CARGO_TARGET_DIR=str(self.root / "missing")), workspace_debug)

    def test_path_last_and_only_under_its_exact_name(self):
        executable(self.root / "gui/Cherry")
        self.assertIsNone(self.cli(PATH=str(self.root / "gui")))
        on_path = executable(self.root / "bin/cherry")
        self.assertEqual(self.cli(PATH=f"{self.root / 'gui'}:{self.root / 'bin'}"), on_path)
        workspace_release = executable(self.repository / "Host/target/release/cherry")
        self.assertEqual(self.cli(PATH=str(self.root / "bin")), workspace_release)


@unittest.skipUnless(sys.platform == "darwin", "the state directory and process listing are macOS'")
class StopTests(unittest.TestCase):
    def setUp(self):
        self.cli = debug_helpers()
        if self.cli is None:
            # CI builds the helpers first and sets this, so it never skips.
            if os.environ.get("CHERRY_TEST_HOST_INTEGRATION") == "1":
                self.fail("Host/target/debug/cherry and cherry-host are missing; run Scripts/build-host debug")
            self.skipTest("run Scripts/build-host debug first")
        # Private (0700) and short enough for a Unix socket path.
        self.root = Path(tempfile.mkdtemp(prefix="chp-", dir="/private/tmp"))
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        self.socket = self.root / "host.sock"
        self.environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.home),
            "USER": os.environ.get("USER", ""),
            "LOGNAME": os.environ.get("LOGNAME", ""),
            "CHERRY_HOST_SOCKET": str(self.socket),
        }
        self.orphans = []
        self.addCleanup(self.clean_up)

    def clean_up(self):
        # Whatever a failed test left: the orphans, and everything that names
        # this directory (the daemon and holders name its socket).
        for pid in self.orphans:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        host.terminate(lambda command: self.root.name in command)
        shutil.rmtree(self.root, ignore_errors=True)

    def orphan(self, *arguments):
        pid = orphan(*arguments)
        self.orphans.append(pid)
        return pid

    def cherry(self, *arguments):
        return subprocess.run([str(self.cli), "--socket", str(self.socket), *arguments], env=self.environment,
                              cwd=self.root, capture_output=True, text=True, timeout=30, check=True).stdout

    def new(self, *command):
        lines = [line for line in self.cherry("new", f"--cwd={self.root}", "--", *command).splitlines()
                 if line.strip()]
        return json.loads(lines[-1])

    def test_ends_sessions_adapters_holders_and_the_daemon(self):
        running = self.new("/bin/sh", "-c", "sleep 120")
        self.new("/bin/sh", "-c", "trap '' HUP; sleep 120")
        exited = self.new("/bin/sh", "-c", "exit 3")
        self.assertTrue(wait_for(lambda: any(
            item["id"] == exited["id"] and item.get("state") == "exited"
            for item in host.sessions(self.cli, self.socket, self.environment) or [])))
        programs = [item["pid"] for item in host.sessions(self.cli, self.socket, self.environment)
                    if item.get("state") == "running"]
        self.assertEqual(len(programs), 2)
        self.assertTrue(host.state_dir(self.home, self.socket).is_dir(),
                        "the daemon's state directory is not where state_dir says")
        holders = host.processes(lambda command: f"hold --socket {self.socket}" in command)
        self.assertEqual(len(holders), 3)
        # An attach adapter the GUI left, and another process from the
        # test's private directory.
        adapter = self.orphan("attach", running["id"])
        marked = self.orphan(str(self.root / "marker"))
        self.assertTrue(alive(adapter) and alive(marked))

        problems = host.stop(self.cli, self.socket, self.environment, cwd=self.root, markers=[self.root.name])

        self.assertEqual(problems, [])
        self.assertFalse(host.reachable(self.socket))
        self.assertEqual(host.processes(lambda command: str(self.socket) in command), [])
        for pid in [adapter, marked, *programs]:
            self.assertTrue(wait_for(lambda: not alive(pid), 5), f"process {pid} still runs")
        # Every session was removed before the daemon stopped.
        manifests = host.state_dir(self.home, self.socket) / "sessions"
        self.assertEqual(sorted(manifests.glob("*.json")) if manifests.is_dir() else [], [])

    def test_stop_command_ends_a_private_runs_daemon_and_deletes_its_directory(self):
        directory = host.make_private_directory("chp-run-")
        self.addCleanup(host.terminate, lambda command: directory.name in command)
        self.addCleanup(shutil.rmtree, directory, True)
        home, control_socket, host_socket = host.layout(directory)
        environment = host.isolated_environment(self.environment, home, control_socket, host_socket)
        created = subprocess.run([str(self.cli), "--socket", str(host_socket), "new", f"--cwd={directory}",
                                  "--", "/bin/sh", "-c", "sleep 120"], env=environment, cwd=directory,
                                 capture_output=True, text=True, timeout=30, check=True).stdout
        program = json.loads([line for line in created.splitlines() if line.strip()][-1])
        pid = next(item["pid"] for item in host.sessions(self.cli, host_socket, environment)
                   if item["id"] == program["id"])
        self.assertTrue(host.reachable(host_socket))

        result = subprocess.run([sys.executable, str(REPOSITORY / "Scripts/cherry_private_host.py"),
                                 "stop", str(directory), "--cli", str(self.cli)],
                                capture_output=True, text=True, timeout=120)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(directory.exists())
        self.assertFalse(host.reachable(host_socket))
        self.assertEqual(host.processes(lambda command: directory.name in command), [])
        self.assertTrue(wait_for(lambda: not alive(pid), 5), f"session program {pid} still runs")
        self.assertFalse(host.state_dir(Path.home(), host_socket).exists())

    def test_without_a_daemon_it_only_stops_marked_processes(self):
        marked = self.orphan(str(self.root / "marker"))
        problems = host.stop(self.cli, self.socket, self.environment, cwd=self.root, markers=[self.root.name])
        self.assertEqual(problems, [])
        self.assertTrue(wait_for(lambda: not alive(marked), 5))
        # Listing an unreachable socket must not have started a daemon there.
        self.assertFalse(host.reachable(self.socket))
        self.assertFalse(host.state_dir(self.home, self.socket).exists())


if __name__ == "__main__":
    unittest.main()
