import Darwin
import Foundation
import Testing
@testable import Cherry

/// A stand-in for OpenSSH's master and `-O` commands. `ssh -M` records how
/// it was started, creates its "socket" (a plain file is enough for `-O
/// check` here) and runs until signalled; `-O check` succeeds while the
/// socket exists; `-O exit` stops the master. Behaviour switches are files:
/// `master-fails` (printed to stderr by a master that exits 255, as BatchMode
/// does when it cannot authenticate), `check-fails` and `exit-slow` (`-O
/// exit` takes half a second, as over a slow link).
private struct FakeSSH {
    let directory: URL
    let executable: URL

    init() throws {
        // Short: control sockets must fit a Unix socket path.
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-ssh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("s"), withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        executable = directory.appendingPathComponent("ssh")
        let quoted = "'" + directory.path + "'"
        try """
        #!/bin/sh
        dir=\(quoted)
        printf '%s\\n' "$*" >> "$dir/calls"
        path=
        command=
        master=no
        while [ $# -gt 0 ]; do
          case "$1" in
            -M) master=yes ;;
            -O) shift; command=$1 ;;
            -o) shift; case "$1" in ControlPath=*) path=${1#ControlPath=} ;; esac ;;
            --) shift; break ;;
          esac
          shift
        done
        if [ "$master" = yes ]; then
          printf '%s' "${SSH_AUTH_SOCK-}" > "$dir/master-agent"
          if [ -f "$dir/master-fails" ]; then cat "$dir/master-fails" >&2; exit 255; fi
          printf '%s' "$$" > "$dir/master-pid"
          printf '%s' "$$" > "$path.pid"
          trap 'rm -f "$path" "$path.pid"; exit 0' TERM INT HUP
          : > "$path"
          while :; do /bin/sleep 0.05; done
        fi
        case "$command" in
          check)
            if [ -e "$path" ] && [ ! -f "$dir/check-fails" ]; then exit 0; fi
            printf 'Control socket connect(%s): No such file or directory\\n' "$path" >&2
            exit 255 ;;
          exit)
            if [ -f "$dir/exit-slow" ]; then /bin/sleep 0.5; fi
            if [ -f "$path.pid" ]; then kill -TERM "$(cat "$path.pid")"
            elif [ -f "$dir/master-pid" ]; then kill -TERM "$(cat "$dir/master-pid")"; fi
            printf 'Exit request sent.\\n' >&2
            exit 0 ;;
        esac
        exit 2
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var sockets: URL { directory.appendingPathComponent("s", isDirectory: true) }

    func manager(
        healthCheckInterval: TimeInterval = 3_600,
        restartDelay: (initial: TimeInterval, maximum: TimeInterval) = (0.05, 0.2),
        stableUptime: TimeInterval = 60
    ) -> HostSSHMasterManager {
        let sockets = sockets
        let executable = executable.path
        return HostSSHMasterManager(configuration: .init(
            directory: { sockets },
            sshExecutable: { _ in executable },
            startTimeout: 5,
            healthCheckInterval: healthCheckInterval,
            idleStopDelay: 0.2,
            restartDelay: restartDelay,
            pollInterval: 0.02,
            commandTimeout: 2,
            stableUptime: stableUptime
        ))
    }

    func write(_ name: String, _ contents: String) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    var calls: [String] { (read("calls") ?? "").split(separator: "\n").map(String.init) }
    var masterCalls: [String] { calls.filter { $0.hasPrefix("-M ") } }
    var masterPID: pid_t? { read("master-pid").flatMap { pid_t($0) } }

    /// Each running master's pid, by its control path.
    var masterPIDs: [pid_t] {
        ((try? FileManager.default.contentsOfDirectory(atPath: sockets.path)) ?? [])
            .filter { $0.hasSuffix(".pid") }
            .compactMap { try? String(contentsOf: sockets.appendingPathComponent($0), encoding: .utf8) }
            .compactMap { pid_t($0) }
    }

    func cleanUp() {
        if let pid = masterPID { kill(pid, SIGKILL) }
        for pid in masterPIDs { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func eventually(
    isolation: isolated (any Actor)? = #isolation,
    _ timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test func HostSSHMasterCommandsAreExactAndPathsFitASocket() throws {
    #expect(HostSSHMasterManager.masterArguments(destination: "me@devbox", controlPath: "/t/cherry-ssh-1/abc") == [
        "-M", "-N", "-T",
        "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "ControlPath=/t/cherry-ssh-1/abc",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ClearAllForwardings=yes",
        "-o", "GatewayPorts=no", "-o", "RemoteCommand=none", "-o", "PermitLocalCommand=no", "-o", "BatchMode=yes",
        "--", "me@devbox",
    ])
    #expect(HostSSHMasterManager.commandArguments("check", destination: "devbox", controlPath: "/t/s") == [
        "-o", "ControlPath=/t/s", "-o", "BatchMode=yes", "-O", "check", "--", "devbox",
    ])
    // ssh expands % tokens in the path.
    #expect(HostSSHMasterManager.controlPathOption("/t/100%/s") == "ControlPath=/t/100%%/s")

    let directory = URL(fileURLWithPath: "/tmp/cherry-ssh-42", isDirectory: true)
    let path = try #require(HostSSHMasterManager.controlPath(in: directory, destination: "devbox"))
    #expect(path.hasPrefix("/tmp/cherry-ssh-42/"))
    #expect(path.split(separator: "/").last?.count == 16)
    #expect(HostSSHMasterManager.controlPath(in: directory, destination: "devbox") == path)
    #expect(HostSSHMasterManager.controlPath(in: directory, destination: "other") != path)
    // ssh binds `<path>.<16 characters>` first: the whole must fit sun_path.
    let long = URL(fileURLWithPath: "/" + String(repeating: "d", count: 70), isDirectory: true)
    #expect(HostSSHMasterManager.controlPath(in: long, destination: "devbox") == nil)
    // ssh's option parser splits values on whitespace and quotes.
    #expect(HostSSHMasterManager.controlPath(in: URL(fileURLWithPath: "/tmp/a b"), destination: "devbox") == nil)

    // The CLI shares the master only when asked.
    let devbox = try HostedSessionHost.ssh("devbox")
    #expect(devbox.arguments(sshControlPath: path) == ["--host", "devbox", "--ssh-control-path", path])
    #expect(devbox.arguments(sshControlPath: nil) == ["--host", "devbox"])
    #expect(HostedSessionHost.local.arguments(sshControlPath: path).isEmpty)
    // The app's own masters are never up in tests: attach adapters use their own ssh.
    let attachment = HostedSessionAttachment(
        host: devbox, hostID: "host-a", sessionID: "s", name: "S", remoteWorkingDirectory: "~", executablePath: "/c"
    )
    #expect(!attachment.arguments(statusFile: URL(fileURLWithPath: "/tmp/x/status.json")).contains("--ssh-control-path"))
}

@Test func HostedSessionHostArgumentsNameTheRemoteCherryHostWhenItIsNotOnThePath() throws {
    // A Mac Cherry installed cherry-host on: the device store says where.
    let paths = HostedRemoteHostPaths { destination in
        destination == "studio" ? "~/Library/Application Support/Cherry/bin/cherry-host" : nil
    }
    let studio = try HostedSessionHost.ssh("studio")
    #expect(studio.arguments(sshControlPath: "/t/cp", remoteHostPaths: paths) == [
        "--host", "studio", "--ssh-control-path", "/t/cp",
        "--remote-host-path", "~/Library/Application Support/Cherry/bin/cherry-host",
    ])
    #expect(studio.arguments(sshControlPath: nil, remoteHostPaths: paths) == [
        "--host", "studio", "--remote-host-path", "~/Library/Application Support/Cherry/bin/cherry-host",
    ])
    // Other destinations, and This Mac, use the cherry-host on the PATH.
    #expect(try HostedSessionHost.ssh("devbox").arguments(sshControlPath: nil, remoteHostPaths: paths) == ["--host", "devbox"])
    #expect(HostedSessionHost.local.arguments(sshControlPath: nil, remoteHostPaths: paths).isEmpty)
    // The resolver can change (a device is added or updated).
    paths.setResolver { _ in "/opt/cherry/cherry-host" }
    #expect(studio.arguments(sshControlPath: nil, remoteHostPaths: paths).suffix(2) == ["--remote-host-path", "/opt/cherry/cherry-host"])
    paths.setResolver { _ in "" }
    #expect(studio.arguments(sshControlPath: nil, remoteHostPaths: paths) == ["--host", "studio"])
}

@Test func HostSSHMasterStartsIsSharedAndStopsWhenNothingNeedsIt() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    let environment = ["SSH_AUTH_SOCK": "/login/agent.sock", "PATH": "/usr/bin:/bin"]

    #expect(manager.controlPathIfUp(for: "devbox") == nil)
    let lease = manager.acquire("devbox", environment: environment)
    let path = try #require(await manager.waitUntilUp("devbox"))
    #expect(path.hasPrefix(ssh.sockets.path + "/"))
    #expect(manager.controlPathIfUp(for: "devbox") == path)
    #expect(manager.status(of: "devbox")?.phase == .up)
    #expect(ssh.masterCalls == [HostSSHMasterManager.masterArguments(destination: "devbox", controlPath: path).joined(separator: " ")])
    // The master runs with the login shell's agent.
    #expect(ssh.read("master-agent") == "/login/agent.sock")
    let firstMaster = try #require(ssh.masterPID)

    // A second user of the same destination shares it.
    let second = manager.acquire("devbox", environment: environment)
    #expect(await manager.waitUntilUp("devbox") == path)
    #expect(ssh.masterCalls.count == 1)
    #expect(manager.status(of: "devbox")?.leases == 2)
    second.release()
    second.release()
    #expect(manager.status(of: "devbox")?.leases == 1)

    // An adapter launch that got the path keeps the master running after
    // every lease is gone, until the launch ends.
    #expect(manager.controlPath(forLaunch: "/tmp/launch-1", destination: "devbox") == path)
    #expect(manager.controlPath(forLaunch: "/tmp/launch-1", destination: "devbox") == path)
    #expect(manager.status(of: "devbox")?.launches == 1)
    lease.release()
    try await Task.sleep(for: .milliseconds(400))
    #expect(manager.status(of: "devbox")?.phase == .up)
    #expect(kill(firstMaster, 0) == 0)
    manager.endLaunch("/tmp/launch-1")
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
    #expect(ssh.calls.contains { $0.contains("-O exit") })
    #expect(await eventually { kill(firstMaster, 0) != 0 })
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(manager.controlPathIfUp(for: "devbox") == nil)
    // Nothing up: a launch gets no path and holds nothing.
    #expect(manager.controlPath(forLaunch: "/tmp/launch-2", destination: "devbox") == nil)
    #expect(manager.status(of: "devbox")?.launches == 0)

    // Needed again: a new master.
    let again = manager.acquire("devbox", environment: environment)
    #expect(await manager.waitUntilUp("devbox") == path)
    #expect(ssh.masterCalls.count == 2)

    // A master that dies while needed is restarted (after its stale socket
    // is cleared).
    let crashed = try #require(ssh.masterPID)
    kill(crashed, SIGKILL)
    #expect(await eventually { ssh.masterCalls.count == 3 && manager.status(of: "devbox")?.phase == .up })
    #expect(ssh.masterPID != crashed)

    // Quitting stops it for good, even while still leased.
    let last = try #require(ssh.masterPID)
    manager.stopAll()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
    #expect(await eventually { kill(last, 0) != 0 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(ssh.masterCalls.count == 3)
    let afterQuit = manager.acquire("devbox", environment: environment)
    #expect(await manager.waitUntilUp("devbox") == nil)
    #expect(ssh.masterCalls.count == 3)
    afterQuit.release()
    again.release()
}

@Test func HostSSHMasterLeasedAgainWhileItsIdleStopRunsIsWaitedForAndStartedAgain() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    try ssh.write("exit-slow", "")
    let lease = manager.acquire("devbox", environment: [:])
    let path = try #require(await manager.waitUntilUp("devbox"))
    lease.release()
    // The idle stop runs its (slow) `ssh -O exit`: the master is stopping.
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopping })
    // A lease taken now (a port forward, a control connection) waits for
    // the master's next start rather than finding no connection.
    let again = manager.acquire("devbox", environment: [:])
    #expect(await manager.waitUntilUp("devbox") == path)
    #expect(manager.status(of: "devbox")?.phase == .up)
    #expect(ssh.masterCalls.count == 2)
    again.release()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
}

@Test func HostSSHMasterThatCannotAuthenticateLeavesSSHToItsUsers() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    try ssh.write("master-fails", "devbox: Permission denied (publickey).\n")
    let lease = manager.acquire("devbox", environment: [:])
    #expect(await manager.waitUntilUp("devbox") == nil)
    #expect(manager.controlPathIfUp(for: "devbox") == nil)
    #expect(await eventually { manager.status(of: "devbox")?.lastError?.contains("Permission denied") == true })
    #expect(manager.status(of: "devbox")?.phase == .stopped)
    // Not retried on a timer while needed: each attempt would be another
    // failed login on the server (which may count them).
    try await Task.sleep(for: .milliseconds(400))
    #expect(ssh.masterCalls.count == 1)

    // A helper that connected on its own shows logging in works: it tries again.
    manager.retry("devbox", environment: [:])
    #expect(await eventually { ssh.masterCalls.count == 2 && manager.status(of: "devbox")?.phase == .stopped })
    // It can succeed then (say, the agent was unlocked).
    ssh.remove("master-fails")
    manager.retry("devbox", environment: ["SSH_AUTH_SOCK": "/unlocked/agent.sock"])
    #expect(await eventually { manager.status(of: "devbox")?.phase == .up })
    #expect(manager.status(of: "devbox")?.lastError == nil)
    #expect(ssh.read("master-agent") == "/unlocked/agent.sock")
    // A retry leaves a master that is up alone.
    manager.retry("devbox", environment: [:])
    #expect(ssh.masterCalls.count == 3)
    lease.release()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
    // Nothing needs it: a retry starts nothing.
    manager.retry("devbox", environment: [:])
    try await Task.sleep(for: .milliseconds(100))
    #expect(ssh.masterCalls.count == 3)

    // A new lease tries once; released while failing, nothing more runs.
    try ssh.write("master-fails", "devbox: Permission denied (publickey).\n")
    let failing = manager.acquire("devbox", environment: [:])
    #expect(await manager.waitUntilUp("devbox") == nil)
    #expect(ssh.masterCalls.count == 4)
    failing.release()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
    try await Task.sleep(for: .milliseconds(400))
    #expect(ssh.masterCalls.count == 4)

    // Masters switched off: nothing runs.
    let disabled = HostSSHMasterManager(configuration: .init(directory: { nil }, sshExecutable: { _ in "/nonexistent" }))
    let none = disabled.acquire("devbox", environment: [:])
    #expect(await disabled.waitUntilUp("devbox") == nil)
    #expect(disabled.status(of: "devbox") == nil)
    none.release()
}

@Test func HostSSHMasterIsRestartedWhenItStopsAnswering() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager(healthCheckInterval: 0.1)
    let lease = manager.acquire("devbox", environment: [:])
    defer { lease.release() }
    #expect(await manager.waitUntilUp("devbox") != nil)
    let first = try #require(ssh.masterPID)
    try ssh.write("check-fails", "")
    #expect(await eventually { kill(first, 0) != 0 })
    ssh.remove("check-fails")
    #expect(await eventually { ssh.masterCalls.count == 2 && manager.status(of: "devbox")?.phase == .up })
}

@Test @MainActor func HostControlSharesTheSSHMasterWhileConnected() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let devbox = try store.add("devbox")
    let control = makeFakeHostControl(
        fake, host: devbox, hostStore: store, loginEnvironment: ["SSH_AUTH_SOCK": "/login/agent.sock"], masters: manager
    )
    _ = try await control.list()
    let path = try #require(manager.controlPathIfUp(for: "devbox"))
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "--ssh-control-path", path, "control"])
    #expect(ssh.read("master-agent") == "/login/agent.sock")
    #expect(manager.status(of: "devbox")?.leases == 1)
    control.disconnect()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
    #expect(manager.status(of: "devbox")?.leases == 0)

    // Without a master (it cannot authenticate) the helper runs its own ssh.
    try ssh.write("master-fails", "Permission denied\n")
    let lease = control.retain()
    defer { lease.release() }
    _ = try await control.list()
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "control"])
    // The helper logged in on its own, so the master tries once more. It
    // still fails, and nothing retries it on a timer.
    #expect(await eventually { ssh.masterCalls.count == 3 && manager.status(of: "devbox")?.phase == .stopped })
    try await Task.sleep(for: .milliseconds(300))
    #expect(ssh.masterCalls.count == 3)

    // Once logging in works, the next connection made without the master
    // starts it again, and the one after uses it.
    ssh.remove("master-fails")
    let launches = fake.launches.count
    fake.dropAll()
    #expect(await eventually { fake.launches.count == launches + 1 && control.state == .connected })
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "control"])
    #expect(await eventually { manager.status(of: "devbox")?.phase == .up })
    fake.dropAll()
    #expect(await eventually { fake.launches.count == launches + 2 && control.state == .connected })
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "--ssh-control-path", path, "control"])
    control.disconnect()
}

@Test @MainActor func HostControlReleasesTheSSHMasterWhenNothingWaitsToReconnect() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let devbox = try store.add("devbox")
    let control = makeFakeHostControl(fake, host: devbox, hostStore: store, masters: manager)
    defer { control.disconnect() }
    let lease = control.retain()
    #expect(await eventually { control.state == .connected })
    #expect(manager.status(of: "devbox")?.leases == 1)

    // The host becomes unreachable: while leased, the control waits to
    // reconnect and keeps the master for it.
    fake.launchFailure = "ssh: connect to host devbox port 22: Connection refused"
    fake.dropAll()
    #expect(await eventually {
        if case .waitingToReconnect = control.state { return true }
        return false
    })
    #expect(manager.status(of: "devbox")?.leases == 1)

    // The last user goes: no reconnect follows, and nothing holds the master.
    lease.release()
    #expect(await eventually { manager.status(of: "devbox")?.leases == 0 })
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
    guard case .failed = control.state else {
        Issue.record("Expected a failed connection, got \(control.state)")
        return
    }
    let launches = fake.launches.count
    try await Task.sleep(for: .milliseconds(300))
    #expect(fake.launches.count == launches)
    #expect(ssh.masterCalls.count == 1)
}

@Test @MainActor func HostControlLetsTheSSHMasterStopOnceItsConnectionIsUnused() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let devbox = try store.add("devbox")
    var configuration = HostControl.Configuration.fastTests
    // Heartbeats every idle period several times over, as in production.
    configuration.heartbeatInterval = .milliseconds(30)
    configuration.idleDisconnectDelay = .milliseconds(400)
    let control = makeFakeHostControl(fake, host: devbox, hostStore: store, masters: manager, configuration: configuration)
    defer { control.disconnect() }
    _ = try await control.list()
    #expect(manager.status(of: "devbox")?.leases == 1)

    #expect(await eventually { control.state == .idle })
    #expect(fake.requests("ping").count >= 2)
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
    #expect(manager.status(of: "devbox")?.leases == 0)
}

@Test func HostSSHMasterSharesAtMostMaxChannelsPerMasterAdapterLaunchesAndShardsTheRest() async throws {
    // sshd's MaxSessions is 10 by default: the control helper and one-off
    // commands need room beside the adapters. Over the cap, launches share
    // a second master (a shard), started before it is needed.
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    #expect(manager.configuration.maxChannelsPerMaster == 8)
    #expect(manager.configuration.spareChannels == 1)
    let lease = manager.acquire("devbox", environment: ["SSH_AUTH_SOCK": "/login/agent.sock"])
    let path = try #require(await manager.waitUntilUp("devbox"))
    for index in 1...6 {
        #expect(manager.controlPath(forLaunch: "/tmp/launch-\(index)", destination: "devbox") == path)
    }
    // Room for two more: no second master yet.
    #expect(manager.shardStatuses(of: "devbox").count == 1)
    // The seventh leaves one slot: the next master starts now.
    #expect(manager.controlPath(forLaunch: "/tmp/launch-7", destination: "devbox") == path)
    let shards = manager.shardStatuses(of: "devbox")
    #expect(shards.map(\.shard) == [1, 2])
    let secondPath = try #require(shards.last?.controlPath)
    #expect(secondPath != path)
    #expect(secondPath == HostSSHMasterManager.controlPath(in: ssh.sockets, destination: "devbox#2"))
    #expect(await eventually { manager.shardStatuses(of: "devbox").last?.phase == .up })
    // It is its own connection to the same destination, with the same agent.
    #expect(ssh.masterCalls.last == HostSSHMasterManager.masterArguments(destination: "devbox", controlPath: secondPath).joined(separator: " "))
    #expect(ssh.masterCalls.count == 2)
    #expect(manager.controlPath(forLaunch: "/tmp/launch-8", destination: "devbox") == path)
    #expect(manager.status(of: "devbox")?.launches == 8)
    // Full: the ninth shares the second master instead of its own ssh.
    #expect(manager.controlPath(forLaunch: "/tmp/launch-9", destination: "devbox") == secondPath)
    #expect(manager.shardStatuses(of: "devbox").map(\.launches) == [8, 1])
    // A launch that has its channel keeps it.
    #expect(manager.controlPath(forLaunch: "/tmp/launch-3", destination: "devbox") == path)
    #expect(manager.controlPath(forLaunch: "/tmp/launch-9", destination: "devbox") == secondPath)
    // A slot of the first master frees: the next launch takes it.
    manager.endLaunch("/tmp/launch-1")
    #expect(manager.controlPath(forLaunch: "/tmp/launch-10", destination: "devbox") == path)
    #expect(manager.shardStatuses(of: "devbox").map(\.launches) == [8, 1])
    // The second master stops once nothing uses it and the first has room.
    for index in [2, 3, 4, 9] { manager.endLaunch("/tmp/launch-\(index)") }
    #expect(await eventually { manager.shardStatuses(of: "devbox").last?.phase == .stopped })
    #expect(manager.status(of: "devbox")?.phase == .up)
    for index in [5, 6, 7, 8, 10] { manager.endLaunch("/tmp/launch-\(index)") }
    lease.release()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
    #expect(await eventually { ssh.masterPIDs.isEmpty })
}

@Test func HostSSHMasterShardsAtMostMaxMastersAndAnAdapterOverThemRunsItsOwnSSH() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let sockets = ssh.sockets
    let executable = ssh.executable.path
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets },
        sshExecutable: { _ in executable },
        startTimeout: 5, healthCheckInterval: 3_600, idleStopDelay: 0.2, restartDelay: (0.05, 0.2),
        pollInterval: 0.02, commandTimeout: 2, stableUptime: 60,
        maxChannelsPerMaster: 2, spareChannels: 1, maxMasters: 2
    ))
    let lease = manager.acquire("devbox", environment: [:])
    let path = try #require(await manager.waitUntilUp("devbox"))
    #expect(manager.controlPath(forLaunch: "/tmp/a", destination: "devbox") == path)
    #expect(await eventually { manager.shardStatuses(of: "devbox").last.map { $0.shard == 2 && $0.phase == .up } == true })
    let second = try #require(manager.shardStatuses(of: "devbox").last?.controlPath)
    #expect(manager.controlPath(forLaunch: "/tmp/b", destination: "devbox") == path)
    #expect(manager.controlPath(forLaunch: "/tmp/c", destination: "devbox") == second)
    #expect(manager.controlPath(forLaunch: "/tmp/d", destination: "devbox") == second)
    // Every master full, and no third allowed: its own ssh, holding nothing.
    #expect(manager.controlPath(forLaunch: "/tmp/e", destination: "devbox") == nil)
    #expect(manager.shardStatuses(of: "devbox").count == 2)
    #expect(manager.shardStatuses(of: "devbox").map(\.launches) == [2, 2])
    for name in ["/tmp/a", "/tmp/b", "/tmp/c", "/tmp/d"] { manager.endLaunch(name) }
    lease.release()
    #expect(await eventually { manager.shardStatuses(of: "devbox").allSatisfy { $0.phase == .stopped } })
    #expect(await eventually { ssh.masterPIDs.isEmpty })
}

private func shardManager(
    _ ssh: FakeSSH, cap: Int = 2, idleStopDelay: TimeInterval = 0.2, shardRetryDelay: TimeInterval = 60
) -> HostSSHMasterManager {
    let sockets = ssh.sockets
    let executable = ssh.executable.path
    return HostSSHMasterManager(configuration: .init(
        directory: { sockets },
        sshExecutable: { _ in executable },
        startTimeout: 5, healthCheckInterval: 3_600, idleStopDelay: idleStopDelay, restartDelay: (0.05, 0.2),
        pollInterval: 0.02, commandTimeout: 2, stableUptime: 60,
        maxChannelsPerMaster: cap, spareChannels: 1, maxMasters: 8, shardRetryDelay: shardRetryDelay
    ))
}

@Test func HostSSHMasterAShardThatCannotLogInStopsFurtherShardsUntilItsBackoffPasses() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = shardManager(ssh, shardRetryDelay: 1.5)
    let lease = manager.acquire("devbox", environment: [:])
    let path = try #require(await manager.waitUntilUp("devbox"))
    // Logins fail from now on: the shard the first launch starts fails.
    try ssh.write("master-fails", "devbox: Permission denied (publickey).\n")
    #expect(manager.controlPath(forLaunch: "/tmp/a", destination: "devbox") == path)
    #expect(await eventually { manager.shardStatuses(of: "devbox").last.map { $0.shard == 2 && $0.phase == .stopped } == true })
    let failedLogins = ssh.masterCalls.count
    #expect(failedLogins == 2)
    // Its reservation is gone, and while the backoff runs no shard is tried
    // again, however many launches come: they run their own ssh.
    #expect(manager.controlPath(forLaunch: "/tmp/b", destination: "devbox") == path)
    for name in ["/tmp/c", "/tmp/d", "/tmp/e"] {
        #expect(manager.controlPath(forLaunch: name, destination: "devbox") == nil)
    }
    manager.endLaunch("/tmp/b")
    #expect(manager.controlPath(forLaunch: "/tmp/b2", destination: "devbox") == path)
    try await Task.sleep(for: .milliseconds(300))
    #expect(ssh.masterCalls.count == failedLogins)
    #expect(manager.shardStatuses(of: "devbox").count == 2)
    #expect(manager.shardStatuses(of: "devbox").last?.phase == .stopped)
    // Once it passed (and logins work again), the next launch's balance
    // starts it again.
    ssh.remove("master-fails")
    try await Task.sleep(for: .milliseconds(1_300))
    #expect(manager.controlPath(forLaunch: "/tmp/f", destination: "devbox") == nil)
    #expect(await eventually { manager.shardStatuses(of: "devbox").last?.phase == .up })
    #expect(ssh.masterCalls.count == failedLogins + 1)
    for name in ["/tmp/a", "/tmp/b2"] { manager.endLaunch(name) }
    lease.release()
    manager.stopAll()
}

@Test func HostSSHMasterKeepsAnIdleShardWhenTheFirstIsFullInsteadOfStartingAnother() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = shardManager(ssh, idleStopDelay: 3)
    let lease = manager.acquire("devbox", environment: [:])
    let path = try #require(await manager.waitUntilUp("devbox"))
    // The first launch leaves one slot: the second master starts as spare.
    #expect(manager.controlPath(forLaunch: "/tmp/a", destination: "devbox") == path)
    #expect(await eventually { manager.shardStatuses(of: "devbox").last.map { $0.shard == 2 && $0.phase == .up } == true })
    let second = try #require(manager.shardStatuses(of: "devbox").last?.controlPath)
    // It ends: the first has room again, so the spare is let go (its idle
    // stop is pending, it still runs).
    manager.endLaunch("/tmp/a")
    // The first fills up again before it stopped: the spare is kept (its
    // stop cancelled), not a third master started.
    #expect(manager.controlPath(forLaunch: "/tmp/b", destination: "devbox") == path)
    #expect(manager.controlPath(forLaunch: "/tmp/c", destination: "devbox") == path)
    #expect(manager.shardStatuses(of: "devbox").count == 2)
    #expect(ssh.masterCalls.count == 2)
    #expect(manager.controlPath(forLaunch: "/tmp/d", destination: "devbox") == second)
    try await Task.sleep(for: .milliseconds(300))
    // (The second is in use now, so a third starts as the spare.)
    #expect(Array(manager.shardStatuses(of: "devbox").map(\.phase).prefix(2)) == [.up, .up])
    for name in ["/tmp/b", "/tmp/c", "/tmp/d"] { manager.endLaunch(name) }
    lease.release()
    manager.stopAll()
}

@Test func HostSSHMasterAnAdapterOverTheCapSharesTheNextMasterWhenItRelaunches() async throws {
    // Each launch of a tab's adapter registers afresh (a new status file
    // directory): the relaunch after its reconnect window gives up, or a
    // Reconnect, takes a slot on the first master with room.
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let sockets = ssh.sockets
    let executable = ssh.executable.path
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets },
        sshExecutable: { _ in executable },
        startTimeout: 5, healthCheckInterval: 3_600, idleStopDelay: 0.2, restartDelay: (0.05, 0.2),
        pollInterval: 0.02, commandTimeout: 2, stableUptime: 60,
        maxChannelsPerMaster: 8, spareChannels: 1, maxMasters: 1
    ))
    let lease = manager.acquire("devbox", environment: [:])
    let path = try #require(await manager.waitUntilUp("devbox"))
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "s", name: "S", remoteWorkingDirectory: "~",
        executablePath: "/c"
    )
    var launches: [URL] = []
    func launch() throws -> [String] {
        let directory = try HostedAttachmentStatusFile.makeLaunchDirectory(in: ssh.directory)
        launches.append(directory)
        return attachment.arguments(statusFile: HostedAttachmentStatusFile.statusFileURL(in: directory), masters: manager)
    }
    for _ in 1...8 { #expect(try launch().contains(path)) }
    // One master only (maxMasters 1): the ninth runs its own ssh, and
    // holds no slot.
    let over = try launch()
    #expect(!over.contains("--ssh-control-path"))
    #expect(manager.status(of: "devbox")?.launches == 8)
    // Its relaunch while the master is still full: its own ssh again.
    HostedAttachmentStatusFile.removeLaunchDirectory(launches[8], after: 0, masters: manager)
    #expect(!(try launch()).contains("--ssh-control-path"))
    // A tab's adapter ends: the next relaunch takes the free slot.
    HostedAttachmentStatusFile.removeLaunchDirectory(launches[9], after: 0, masters: manager)
    HostedAttachmentStatusFile.removeLaunchDirectory(launches[0], after: 0, masters: manager)
    #expect(manager.status(of: "devbox")?.launches == 7)
    let relaunched = try launch()
    #expect(Array(relaunched.prefix(4)) == ["--host", "devbox", "--ssh-control-path", path])
    #expect(manager.status(of: "devbox")?.launches == 8)
    for directory in launches { HostedAttachmentStatusFile.removeLaunchDirectory(directory, after: 0, masters: manager) }
    #expect(manager.status(of: "devbox")?.launches == 0)
    lease.release()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
}

@Test func HostSSHMasterKeepsOnlyAdapterLaunchesThatStillRun() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    let lease = manager.acquire("devbox", environment: [:])
    let path = try #require(await manager.waitUntilUp("devbox"))
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "s", name: "S", remoteWorkingDirectory: "~",
        executablePath: "/c"
    )
    let launch = try HostedAttachmentStatusFile.makeLaunchDirectory(in: ssh.directory)
    let statusFile = HostedAttachmentStatusFile.statusFileURL(in: launch)
    let arguments = attachment.arguments(statusFile: statusFile, masters: manager)
    #expect(Array(arguments.prefix(8)) == [
        "--host", "devbox", "--ssh-control-path", path, "--expected-host-id", "host-a", "attach", "s",
    ])
    #expect(manager.status(of: "devbox")?.launches == 1)
    // Without a status file there is no launch to keep the master for.
    #expect(!attachment.arguments(statusFile: nil, masters: manager).contains("--ssh-control-path"))

    // The adapter ended and its directory is gone. Computing its arguments
    // again (not to launch) keeps nothing running.
    HostedAttachmentStatusFile.removeLaunchDirectory(launch, after: 0, masters: manager)
    #expect(manager.status(of: "devbox")?.launches == 0)
    #expect(!attachment.arguments(statusFile: statusFile, masters: manager).contains("--ssh-control-path"))
    #expect(manager.status(of: "devbox")?.launches == 0)
    lease.release()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
}

@Test func HostSSHMasterRegistersAnAdapterLaunchOnceAndItsCommandStaysTheSame() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager()
    let lease = manager.acquire("devbox", environment: [:])
    let path = try #require(await manager.waitUntilUp("devbox"))
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "s", name: "S", remoteWorkingDirectory: "~",
        executablePath: "/c"
    )
    let launch = try HostedAttachmentStatusFile.makeLaunchDirectory(in: ssh.directory)
    let statusFile = HostedAttachmentStatusFile.statusFileURL(in: launch)

    // Registered explicitly when the launch starts (TerminalSession.startShell)...
    #expect(attachment.registerAdapterLaunch(statusFile: statusFile, masters: manager) == path)
    #expect(manager.status(of: "devbox")?.launches == 1)
    // ... then the command is pure: a surface rebuild computes it again and
    // gets the same command, registering nothing.
    let command = attachment.execCommand(statusFile: statusFile, takeover: false, sshControlPath: path)
    #expect(command.contains("'--ssh-control-path' '\(path)'"))
    #expect(attachment.execCommand(statusFile: statusFile, takeover: false, sshControlPath: path) == command)
    #expect(manager.status(of: "devbox")?.launches == 1)
    // A launch that shares no master runs its own ssh.
    #expect(!attachment.arguments(statusFile: statusFile, takeover: false, sshControlPath: nil).contains("--ssh-control-path"))
    // This Mac never shares a master.
    let local = HostedSessionAttachment(
        host: .local, hostID: "host-a", sessionID: "s", name: "S", remoteWorkingDirectory: "~", executablePath: "/c"
    )
    #expect(local.registerAdapterLaunch(statusFile: statusFile, masters: manager) == nil)

    HostedAttachmentStatusFile.removeLaunchDirectory(launch, after: 0, masters: manager)
    #expect(manager.status(of: "devbox")?.launches == 0)
    lease.release()
    #expect(await eventually { manager.status(of: "devbox")?.phase == .stopped })
}

@Test func HostSSHMasterCleansUpAfterAnAppThatCrashed() throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ch-sweep-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let exited = Process()
    exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try exited.run()
    exited.waitUntilExit()
    let deadPID = exited.processIdentifier

    let abandoned = parent.appendingPathComponent("cherry-ssh-\(deadPID)")
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
    let socketPath = abandoned.appendingPathComponent("0123456789abcdef").path
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(listener) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try #require(bound == 0)
    try Data().write(to: abandoned.appendingPathComponent("not-a-socket"))
    let own = parent.appendingPathComponent("cherry-ssh-\(getpid())")
    let unrelated = parent.appendingPathComponent("cherry-ssh-notapid")
    for directory in [own, unrelated] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    var stopped: [String] = []
    HostSSHMasterManager.removeAbandonedDirectories(in: parent, stopMaster: { stopped.append($0) })
    #expect(stopped == [socketPath])
    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    #expect(FileManager.default.fileExists(atPath: own.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))

    // A directory someone else could use is never accepted for sockets.
    let shared = parent.appendingPathComponent("shared")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    #expect(!HostSSHMasterManager.makePrivateDirectory(shared))
    let fresh = parent.appendingPathComponent("fresh")
    #expect(HostSSHMasterManager.makePrivateDirectory(fresh))
    #expect(HostSSHMasterManager.makePrivateDirectory(fresh))
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
    #expect(!HostSSHMasterManager.makePrivateDirectory(link))
}

@Test func HostSSHMasterFindsTheLoginShellsSSH() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ch-path-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ssh = directory.appendingPathComponent("ssh")
    try "#!/bin/sh\n".write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
    #expect(HostSSHMasterManager.sshExecutable(in: ["PATH": "relative:/nonexistent:\(directory.path):/usr/bin"]) == ssh.path)
    #expect(HostSSHMasterManager.sshExecutable(in: [:]) == "/usr/bin/ssh")
}

@Test func HostSSHMasterThatDiesSoonAfterLoggingInIsRestartedLessAndLessOften() async throws {
    let ssh = try FakeSSH()
    defer { ssh.cleanUp() }
    let manager = ssh.manager(restartDelay: (0.1, 10), stableUptime: 3_600)
    let lease = manager.acquire("devbox", environment: [:])
    defer {
        lease.release()
        manager.stopAll()
    }
    #expect(await manager.waitUntilUp("devbox") != nil)

    // Up, then dropped at once, three times: each restart waits twice as
    // long as the one before (not the initial delay every time).
    var restartedAfter: [TimeInterval] = []
    for round in 1...3 {
        let master = try #require(ssh.masterPID)
        let killedAt = Date()
        kill(master, SIGKILL)
        #expect(await eventually { manager.status(of: "devbox")?.phase == .waitingToRestart })
        #expect(manager.status(of: "devbox")?.failures == round)
        #expect(await eventually(10) { ssh.masterCalls.count == round + 1 && manager.status(of: "devbox")?.phase == .up })
        restartedAfter.append(Date().timeIntervalSince(killedAt))
    }
    #expect(restartedAfter[2] >= 0.4)
    #expect(restartedAfter[1] >= 0.2)

    // One that stayed up long enough starts the backoff over.
    let stable = ssh.manager(restartDelay: (0.1, 10), stableUptime: 0)
    let stableLease = stable.acquire("other", environment: [:])
    defer {
        stableLease.release()
        stable.stopAll()
    }
    #expect(await stable.waitUntilUp("other") != nil)
    for _ in 1...2 {
        let master = try #require(ssh.masterPID)
        kill(master, SIGKILL)
        #expect(await eventually { stable.status(of: "other")?.phase == .waitingToRestart })
        #expect(stable.status(of: "other")?.failures == 1)
        #expect(await eventually { stable.status(of: "other")?.phase == .up && ssh.masterPID != master })
    }
}

@Test func HostSignallableProcessIsNeverSignalledOnceItExited() async throws {
    let process = try HostSpawnedProcess.spawn(executable: "/bin/sleep", arguments: ["30"], environment: [:])
    let child = HostSignallableProcess(pid: process.pid)
    let status = Recorder<Int32?>(nil)
    child.startReaping { status.value = $0 }
    #expect(!child.hasExited)
    // Signal 0 only checks that it can be signalled.
    #expect(child.signal(0))
    #expect(child.signal(SIGTERM))
    #expect(await eventually { child.hasExited && status.value != nil })
    // Reaped: its pid may belong to another process now, which must
    // never get the signal meant for it.
    #expect(!child.signal(SIGTERM))
    #expect(!child.signal(SIGKILL, group: true))

    // Escalation stops at a child that exits on SIGTERM, and kills one
    // that ignores it.
    let stubborn = try HostSpawnedProcess.spawn(
        executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do /bin/sleep 0.05; done"], environment: [:]
    )
    let ignoring = HostSignallableProcess(pid: stubborn.pid)
    ignoring.startReaping()
    try await Task.sleep(for: .milliseconds(100))
    ignoring.escalateTermination(grace: 0.1)
    #expect(await eventually { ignoring.hasExited })
}
