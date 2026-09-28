import AppKit
import Combine
import Foundation
import os
import Testing
@testable import Cherry

// Settings › Sessions' "Session Host" card (`SessionHostDiagnostics`, which
// runs `cherry status`, `cherry doctor` and `cherry restart`) and the app's
// session diagnostics in the unified log (`SessionLog`).

private let runningStatus = #"""
{"running":true,"remote":null,"host_id":"h","build":"20260927101500.abc1234","protocol":7,
 "host":{"host_id":"h","version":7,"build":"20260927101500.abc1234","pid":4242,"started_at":1,"uptime_ms":7500000,
  "socket":"/tmp/cherry-host-501/host.sock","state_dir":"/state","log_path":"/state/host.log","executable":"/x/cherry-host",
  "executable_changed":false,"sessions":3,"running_sessions":2,"max_sessions":128,"connections":5,"max_connections":1024,
  "holders_registered":3,"holders_expected":0,"lost_sessions":0,"fd_limit":16384},
 "pending_holders":0,
 "sessions":[{"id":"a","holder_build":"20260927101500.abc1234"},{"id":"b","holder_build":"20260101000000.0ld0000"},{"id":"c"}],
 "client":{"build":"20260927101500.abc1234","protocol":7}}
"""#

private let stoppedStatus = #"""
{"client":{"build":"20260927101500.abc1234","protocol":7},"log_path":"/state/host.log","running":false,
 "socket":"/tmp/cherry-host-501/host.sock","state_dir":"/state"}
"""#

/// Answers `cherry` commands from a script and records them.
private final class ScriptedCherry: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _answers: [String: HostCommandOutput] = [:]

    var calls: [[String]] { lock.withLock { _calls } }

    func answer(_ arguments: [String], _ output: HostCommandOutput) {
        lock.withLock { _answers[arguments.joined(separator: " ")] = output }
    }

    var runner: HostCommandRunner {
        { [self] arguments in
            lock.withLock {
                _calls.append(arguments)
                return _answers[arguments.joined(separator: " ")]
                    ?? HostCommandOutput(status: 2, output: "", errors: "error: unexpected \(arguments)\n")
            }
        }
    }
}

@Test func HostControlStatusReadsWhatCherryStatusReports() throws {
    let status = try #require(SessionHostStatus.parse(Data(runningStatus.utf8)))
    #expect(status.running)
    #expect(status.build == "20260927101500.abc1234")
    #expect(status.pid == 4242)
    #expect(status.logPath == "/state/host.log")
    #expect(status.otherHolderBuilds == 1)
    #expect(status.headline == "Running · build 20260927101500.abc1234 · up 2h 5m")
    #expect(status.detail == "3 sessions (2 running) of 128 · 5 of 1024 connections · 1 session runs in a holder of another build · pid 4242")

    let stopped = try #require(SessionHostStatus.parse(Data(stoppedStatus.utf8)))
    #expect(!stopped.running)
    #expect(stopped.headline == "Not running")
    #expect(stopped.logPath == "/state/host.log")
    #expect(stopped.detail == "It starts with the first persistent tab. Socket: /tmp/cherry-host-501/host.sock.")

    #expect(SessionHostStatus.parse(Data("not json".utf8)) == nil)
    #expect(SessionHostStatus.duration(12) == "12s")
    #expect(SessionHostStatus.duration(250) == "4m 10s")
    #expect(SessionHostStatus.duration(3 * 86_400 + 4 * 3_600) == "3d 4h")
}

@Test @MainActor func HostControlDiagnosticsShowCopyRevealAndRestart() async throws {
    let cherry = ScriptedCherry()
    cherry.answer(["status", "--json"], HostCommandOutput(status: 0, output: runningStatus, errors: ""))
    cherry.answer(["status"], HostCommandOutput(status: 0, output: "cherry-host 20260927101500.abc1234, protocol 7, pid 4242, up 2h 5m\n", errors: ""))
    cherry.answer(["doctor"], HostCommandOutput(status: 1, output: "PROBLEM  stale PID file /state/host.pid\n         fix: remove it\n1 problem found.\n", errors: ""))
    cherry.answer(["restart"], HostCommandOutput(status: 0, output: "", errors: ""))
    var revealed: [URL] = []
    var copied: [String] = []
    let diagnostics = SessionHostDiagnostics(
        runner: cherry.runner,
        unavailableReason: { nil },
        revealInFinder: { revealed.append($0) },
        copyToPasteboard: { copied.append($0) }
    )

    await diagnostics.refresh()
    #expect(diagnostics.status?.pid == 4242)
    #expect(diagnostics.problem == nil)
    diagnostics.revealLog()
    #expect(revealed == [URL(fileURLWithPath: "/state/host.log")])

    await diagnostics.copyDiagnostics()
    let report = try #require(copied.last)
    #expect(report.contains("$ cherry status\ncherry-host 20260927101500.abc1234, protocol 7, pid 4242, up 2h 5m\n"), "\(report)")
    #expect(report.contains("$ cherry doctor\nPROBLEM  stale PID file /state/host.pid\n"), "\(report)")
    #expect(report.contains("(exit status 1)"), "\(report)")

    await diagnostics.restartHost()
    #expect(diagnostics.restartFailure == nil)
    #expect(!diagnostics.isRestarting)
    // Only these commands ran: none of them starts a host by itself.
    #expect(cherry.calls == [["status", "--json"], ["status"], ["doctor"], ["restart"], ["status", "--json"]])

    // A restart that fails says why.
    cherry.answer(["restart"], HostCommandOutput(status: 1, output: "", errors: "cherry: refusing to restart the host; it keeps running: no cherry-host to start\n"))
    await diagnostics.restartHost()
    #expect(diagnostics.restartFailure == "cherry: refusing to restart the host; it keeps running: no cherry-host to start")
}

@Test @MainActor func HostControlDiagnosticsRunNothingWhereSessionsCannotRun() async throws {
    let cherry = ScriptedCherry()
    let diagnostics = SessionHostDiagnostics(
        runner: cherry.runner,
        unavailableReason: { "Cherry is running from a disk image." },
        revealInFinder: { _ in },
        copyToPasteboard: { _ in }
    )
    await diagnostics.refresh()
    #expect(diagnostics.status == nil)
    #expect(diagnostics.problem == "Cherry is running from a disk image.")
    #expect(cherry.calls.isEmpty)
    // What `cherry status` could not say is reported too.
    let failing = ScriptedCherry()
    let broken = SessionHostDiagnostics(
        runner: failing.runner, unavailableReason: { nil }, revealInFinder: { _ in }, copyToPasteboard: { _ in }
    )
    await broken.refresh()
    #expect(broken.status == nil)
    #expect(broken.problem == "error: unexpected [\"status\", \"--json\"]")
}

@Test @MainActor func HostControlSessionDiagnosticsGoToTheUnifiedLog() async throws {
    let seen = OSAllocatedUnfairLock<[SessionLog.Entry]>(initialState: [])
    let token = SessionLog.observe { entry in seen.withLock { $0.append(entry) } }
    defer { SessionLog.remove(token) }
    #expect(SessionLog.subsystem == (Bundle.main.bundleIdentifier ?? "Cherry"))

    let workspace = TerminalWorkspace(createInitialSession: false)
    defer { workspace.closeAllSessions() }
    let host = try HostedSessionHost.ssh("devbox")
    let id = UUID()
    func attachment(_ sessionID: String) -> HostedSessionAttachment {
        HostedSessionAttachment(
            host: host, hostID: "host-a", sessionID: sessionID,
            name: sessionID, remoteWorkingDirectory: "/remote", executablePath: "/fake/bin/cherry"
        )
    }
    let first = workspace.attachHostedSession(attachment("one"), id: id, launchShell: false)
    let second = workspace.attachHostedSession(attachment("two"), id: id, launchShell: false)
    #expect(first.id == id)
    #expect(second.id != id)
    let messages = seen.withLock { $0 }
    #expect(messages.contains { entry in
        entry.type == .default && !entry.isPrivate
            && entry.message == "tab id \(id.uuidString) is already open; the new tab gets another id"
    }, "\(messages.map(\.message))")
}

@Test @MainActor func HostControlTypedInputTracesArePrivateInTheLog() async throws {
    let seen = OSAllocatedUnfairLock<[SessionLog.Entry]>(initialState: [])
    let token = SessionLog.observe { entry in seen.withLock { $0.append(entry) } }
    let wasEnabled = inputDebugEnabled
    inputDebugEnabled = true
    defer {
        inputDebugEnabled = wasEnabled
        SessionLog.remove(token)
    }
    let session = TerminalSession(
        title: "Input",
        subtitle: "cat",
        tint: .systemGreen,
        launchShell: true,
        launchCommand: "stty -echo; cat >/dev/null",
        launchBackend: .hostManaged
    )
    defer { session.stop() }
    let deadline = Date(timeIntervalSinceNow: 2)
    while !session.acceptsInput, Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    try #require(session.acceptsInput)
    session.send(text: "hunter2")
    let traces = seen.withLock { $0 }.filter { $0.message.contains("hunter2") }
    #expect(!traces.isEmpty)
    #expect(traces.allSatisfy { $0.isPrivate && $0.type == .debug }, "\(traces)")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"))
@MainActor func HostControlRealHostDiagnosticsDescribeAndRestartAPrivateHost() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let targetDirectories = HostedSessionClient.developmentTargetDirectories(
        environment: ProcessInfo.processInfo.environment, sourceRoot: repository
    )
    let binaries = try #require(
        targetDirectories.map { $0.appendingPathComponent("debug") }.first { directory in
            ["cherry", "cherry-host"].allSatisfy {
                FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
            }
        },
        "Build the Rust helpers first with Scripts/build-host debug (looked in \(targetDirectories.map(\.path)))"
    )
    let cliURL = binaries.appendingPathComponent("cherry")
    let hostURL = binaries.appendingPathComponent("cherry-host")
    // A private socket and HOME: never the user's host.
    let root = URL(fileURLWithPath: "/tmp/ch-dg-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("host.sock")
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(
        at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    var environment = HostedSessionLoginEnvironment.helperEnvironment(
        base: ProcessInfo.processInfo.environment,
        login: ["HOME": home.path, "CHERRY_HOST_SOCKET": socket.path, "CHERRY_HOST_PATH": hostURL.path]
    )
    environment["XDG_STATE_HOME"] = nil
    let runner = SessionHostDiagnostics.processRunner(executable: cliURL, environment: environment)
    let diagnostics = SessionHostDiagnostics(
        runner: runner, unavailableReason: { nil }, revealInFinder: { _ in }, copyToPasteboard: { _ in }
    )

    // Nothing runs there yet, and asking starts nothing.
    await diagnostics.refresh()
    #expect(diagnostics.status?.running == false)
    #expect(!FileManager.default.fileExists(atPath: socket.path))

    let daemon = try RealHostTestDaemon(executable: hostURL, environment: environment, socket: socket)
    defer {
        // The daemon the restart started is not the test's: shut it down
        // (it has no sessions), then end what the test's own left.
        _ = try? runProcessSync(cliURL, ["shutdown"], environment)
        daemon.stop()
    }
    let deadline = Date().addingTimeInterval(5)
    while diagnostics.status?.running != true, Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
        await diagnostics.refresh()
    }
    let status = try #require(diagnostics.status)
    #expect(status.running)
    #expect(status.pid == Int(daemon.pid))
    #expect(status.build == status.clientBuild)
    #expect(status.sessions == 0)
    #expect(status.maxSessions == 128)

    let report = await diagnostics.diagnostics()
    #expect(report.contains("$ cherry status\ncherry-host \(status.build ?? "?"), protocol "), "\(report)")
    #expect(report.contains("the host runs this cherry's build and protocol"), "\(report)")

    await diagnostics.restartHost()
    #expect(diagnostics.restartFailure == nil)
    let restarted = try #require(diagnostics.status)
    #expect(restarted.running)
    #expect(restarted.pid != Int(daemon.pid))
}

private func runProcessSync(_ executable: URL, _ arguments: [String], _ environment: [String: String]) throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Test @MainActor func HostControlLeasedReconnectsPauseAfterARefusedSSHLogin() async throws {
    let fake = FakeControlHelper()
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let control = makeFakeHostControl(fake, host: try .ssh("devbox"), hostStore: hostStore)
    defer { control.disconnect() }
    fake.exitBeforeWelcome = "Host key verification failed.\n"
    let lease = control.retain()
    defer { lease.release() }
    #expect(await fake.wait {
        if case .waitingToReconnect = control.state { return true }
        return false
    })
    // The reconnect backoff is 20 ms here: none follows a refused login.
    try await Task.sleep(for: .milliseconds(300))
    #expect(fake.launches.count == 1)
    // A wake or network change (`reconnectNow`) tries once more.
    fake.exitBeforeWelcome = nil
    control.reconnectNow()
    #expect(await fake.wait { control.state == .connected })
    #expect(fake.launches.count == 2)
}

@Test @MainActor func HostControlAvailabilityEndsWhenTheHostSpeaksAnotherProtocol() async throws {
    let fake = FakeControlHelper()
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let control = makeFakeHostControl(fake, host: try .ssh("devbox"), hostStore: hostStore)
    defer { control.disconnect() }
    fake.version = HostProtocol.version + 1
    let fired = Recorder(false)
    let finished = Recorder(false)
    let subscription = control.availability().sink(
        receiveCompletion: { _ in finished.value = true },
        receiveValue: { fired.value = true }
    )
    defer { subscription.cancel() }
    // A protocol this app cannot use is permanent: no reconnecting forever.
    #expect(await fake.wait { finished.value })
    #expect(!fired.value)
    guard case .failed(let error) = control.state else {
        Issue.record("expected a failed connection, got \(control.state)")
        return
    }
    #expect(error.isVersionMismatch)
    let launches = fake.launches.count
    try await Task.sleep(for: .milliseconds(300))
    #expect(fake.launches.count == launches)
}

@Test @MainActor func HostControlAvailabilityFiresForAConnectionUpWhenItIsSubscribed() async throws {
    let fake = FakeControlHelper()
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let control = makeFakeHostControl(fake, host: try .ssh("devbox"), hostStore: hostStore)
    defer { control.disconnect() }
    let availability = control.availability()
    // It connects before anyone subscribes (a restore's result is applied
    // later): the subscriber still hears of it.
    #expect(await fake.wait { control.state == .connected })
    let fired = Recorder(false)
    let subscription = availability.sink { fired.value = true }
    defer { subscription.cancel() }
    #expect(await fake.wait { fired.value })
}
