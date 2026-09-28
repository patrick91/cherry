import AppKit
import CherryControl
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Cherry

private let hostedSessionFixture = """
{"id":"session-123","name":"Editor","cwd":"/remote/project","command":["/bin/zsh"],"cols":100,"rows":35,"state":"running","pid":1234,"exit_code":null,"attached":false,"exit_signal":null}
"""

/// Status messages `cherry attach --status-file` writes when an attachment
/// ended without the host's confirmation: a detach at the end of its input
/// that the host never confirmed, a lost connection, and a hangup.
private let unconfirmedDetach = "detached without the host's confirmation after 5 s without progress (the session is not reading its input, or the connection stalled); input not yet delivered to the session was discarded"
private let lostConnection = "connection lost while attached to session-123; the session may still be running on the host. Reattach to resume; input was not resent"
private let hangupInterruption = "interrupted by signal 1; the host session was not terminated"

@Test func HostedSessionDecodesHostIdentityAndExitState() throws {
    let list = try JSONDecoder().decode(HostedSessionList.self, from: Data("""
    {"host_id":"host-a","sessions":[\(hostedSessionFixture)]}
    """.utf8))
    #expect(list.hostID == "host-a")
    #expect(list.sessions.first?.isRunning == true)
    #expect(list.sessions.first?.attached == false)
    #expect(list.sessions.first?.statusText == "Running")
    let exited = hostedSessionFixture
        .replacingOccurrences(of: "\"running\"", with: "\"exited\"")
        .replacingOccurrences(of: "\"exit_code\":null", with: "\"exit_code\":137")
        .replacingOccurrences(of: "\"exit_signal\":null", with: "\"exit_signal\":9")
    let session = try JSONDecoder().decode(HostedSessionInfo.self, from: Data(exited.utf8))
    #expect(!session.isRunning)
    #expect(session.exitCode == 137)
    #expect(session.exitSignal == 9)
    #expect(session.statusText == "Exited (signal 9)")

    // The host only reports running or exited sessions.
    let starting = hostedSessionFixture.replacingOccurrences(of: "\"running\"", with: "\"starting\"")
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(HostedSessionInfo.self, from: Data(starting.utf8))
    }
}

@Test func HostedSessionRejectsSSHOptionsAndWhitespace() throws {
    for invalid in ["", "-oProxyCommand=bad", "host -p 22", "host\nother", "host\u{0}", "host;sh", "$(touch-bad)"] {
        #expect(throws: HostedSessionError.self) { try HostedSessionHost.ssh(invalid) }
    }
    #expect(try HostedSessionHost.ssh(" user@work ").arguments == ["--host", "user@work"])
    #expect(HostedSessionHost.local.arguments.isEmpty)
    #expect(try HostedSessionHost.ssh("local").id != HostedSessionHost.local.id)
}

@Test @MainActor func HostedSessionSavedHostsAndTrustedIdentitiesRoundTrip() throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = try store.add("devbox")
    let other = try store.add("other")
    _ = try store.add(" devbox ")
    #expect(store.hosts == [host, other])
    store.trust("host-a", for: host)
    store.trust("host-b", for: other)
    // This Mac is never pinned: only this user's own host can answer locally.
    store.trust("host-local", for: .local)
    #expect(store.trustedHostID(for: .local) == nil)
    let reloaded = HostedSessionHostStore(defaults: defaults)
    #expect(reloaded.hosts == [host, other])
    #expect(reloaded.trustedHostID(for: host) == "host-a")
    #expect(reloaded.trustedHostID(for: other) == "host-b")
    #expect(reloaded.trustedHostID(for: .local) == nil)

    // Forgetting a host forgets the identity it was pinned to.
    store.remove(host)
    let afterForget = HostedSessionHostStore(defaults: defaults)
    #expect(afterForget.hosts == [other])
    #expect(afterForget.trustedHostID(for: host) == nil)
    #expect(afterForget.trustedHostID(for: other) == "host-b")
}

@Test @MainActor func HostedSessionKeepsRemotePathsOutOfLocalLaunchAndRetainsIdentity() throws {
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/a/path/only/on/remote",
        executablePath: "/tmp/cherry tools/cherry",
        environment: ["SSH_AUTH_SOCK": "/login/agent.sock", "TERM": "dumb"]
    )
    let workspace = TerminalWorkspace(createInitialSession: false)
    let session = workspace.attachHostedSession(attachment, launchShell: false)
    #expect(session.workingDirectory == NSHomeDirectory())
    #expect(session.projectRoot == nil)
    session.ingestNativeWorkingDirectory("/remote/changed")
    #expect(session.workingDirectory == NSHomeDirectory())
    // The adapter attaches as the tab (`--client-id`): the host replaces the
    // tab's previous attachment when it launches again.
    #expect(session.nativeExecLaunch.command == "'/tmp/cherry tools/cherry' '--host' 'devbox' '--expected-host-id' 'host-a' 'attach' 'session-123' '--detach-key' 'none' '--client-id' '\(session.id.uuidString)'")
    #expect(session.nativeExecLaunch.environment["CHERRY_STARTUP_COMMAND"] == nil)
    // The adapter runs ssh with the login shell's agent socket.
    #expect(session.nativeExecLaunch.environment["SSH_AUTH_SOCK"] == "/login/agent.sock")
    #expect(session.nativeExecLaunch.environment["TERM"] == "xterm-256color")
    #expect(session.nativeExecLaunch.environment["COLORTERM"] == "truecolor")
    #expect(!session.hasRunningProcess())
    #expect(!workspace.canAddSplitPane(to: session.id))
    session.disconnectHostedSession()
    #expect(session.hostedAttachment == attachment)
    #expect(session.hostedAttachmentStatus == .disconnected(nil))
    // Control clients must not see a disconnected tab as an exited program.
    #expect(session.state.label == "disconnected")
    #expect(session.exitCode == nil)
    #expect(session.restartActionTitle == "Reconnect")
    #expect(session.closeActionTitle == "Disconnect & Close")
    #expect(session.sidebarDetail == "devbox · disconnected")
    let second = workspace.attachHostedSession(attachment, launchShell: false)
    #expect(second === session)
    #expect(workspace.sessions.count == 1)

    let otherHost = HostedSessionAttachment(
        host: try .ssh("other"), hostID: "host-b", sessionID: "session-123",
        name: "Other", remoteWorkingDirectory: "/remote", executablePath: "/tmp/cherry"
    )
    #expect(workspace.attachHostedSession(otherHost, launchShell: false) !== session)
}

@Test @MainActor func HostedSessionSelectedTabNeverSeedsNewLocalTabDirectory() throws {
    let projectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-hosted-project-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    let workspace = TerminalWorkspace(
        projectRoot: projectRoot.path, createInitialSession: false, launchBackend: .hostManaged
    )
    defer {
        workspace.closeAllSessions()
        try? FileManager.default.removeItem(at: projectRoot)
    }
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/remote", executablePath: "/tmp/cherry"
    )
    let hosted = workspace.attachHostedSession(attachment, launchShell: false)
    #expect(workspace.selectedSession === hosted)
    let local = workspace.addSession()
    #expect(local.hostedAttachment == nil)
    #expect(local.workingDirectory == workspace.projectRoot)
}

@Test func HostedSessionExecEscapesSingleQuotesAndMetacharacters() throws {
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "id';$(touch bad)",
        name: "Editor", remoteWorkingDirectory: "/remote", executablePath: "/tmp/it's cherry"
    )
    let statusFile = URL(fileURLWithPath: "/tmp/it's status/status.json")
    #expect(attachment.execCommand(statusFile: statusFile, takeover: true) == "'/tmp/it'\\''s cherry' '--host' 'devbox' '--expected-host-id' 'host-a' 'attach' 'id'\\'';$(touch bad)' '--takeover' '--detach-key' 'none' '--status-file' '/tmp/it'\\''s status/status.json'")
    #expect(attachment.arguments(statusFile: nil) == [
        "--host", "devbox", "--expected-host-id", "host-a", "attach", "id';$(touch bad)", "--detach-key", "none"
    ])
    #expect(attachment.execCommand(statusFile: nil, clientID: "tab';$(touch bad)") == "'/tmp/it'\\''s cherry' '--host' 'devbox' '--expected-host-id' 'host-a' 'attach' 'id'\\'';$(touch bad)' '--detach-key' 'none' '--client-id' 'tab'\\'';$(touch bad)'")
}

/// The fake CLI takes `--client-id` as the real one does (1 to 128 bytes),
/// and records an adapter that starts while another of its client runs.
@Test func HostedSessionFakeCLIChecksClientIDsAndOverlappingAdapters() async throws {
    let cli = try HostedSessionFakeCLI()
    var running: [Process] = []
    defer {
        running.forEach { $0.terminate() }
        cli.cleanUp()
    }
    func start(_ clientArguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = cli.executable
        process.arguments = ["attach", "session-1", "--detach-key", "none"] + clientArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
    func waitForAdapters(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while cli.lines("attach-clients").count < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(cli.lines("attach-clients").count == count)
    }

    // 128 bytes in 32 characters. (Not "é": `Process` passes arguments
    // decomposed, as file names.)
    let longest = String(repeating: "🍒", count: 32)
    for bad in [
        ["--client-id="],
        ["--client-id", ""],
        ["--client-id", longest + "x"], // 33 characters, 129 bytes
        ["--client-id", String(repeating: "x", count: 129)],
    ] {
        let process = try start(bad)
        process.waitUntilExit()
        #expect(process.terminationStatus == 2, "\(bad)")
    }

    running.append(try start(["--client-id", longest]))
    try await waitForAdapters(1)
    running.append(try start(["--client-id", "tab-2"]))
    try await waitForAdapters(2)
    #expect(cli.clientOverlaps.isEmpty)
    // The same client again while the first still runs.
    running.append(try start(["--client-id=" + longest]))
    try await waitForAdapters(3)
    #expect(cli.clientOverlaps.count == 1)
    #expect(cli.clientOverlaps.first?.hasPrefix(longest + " \(running[0].processIdentifier) ") == true)
}

@Test func HostedSessionStatusFileMapsEveryOutcome() throws {
    func status(_ json: String) -> HostedAttachmentStatus {
        HostedAttachmentStatusFile.status(from: Data(json.utf8))
    }
    #expect(status(#"{"outcome":"exited","exit_code":3,"signal":null,"message":null}"#) == .exited(code: 3, signal: nil))
    #expect(status(#"{"outcome":"exited","exit_code":137,"signal":9,"message":null}"#) == .exited(code: 137, signal: 9))
    #expect(status(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":null}"#) == .disconnected(nil))
    // A confirmed detach has no message.
    #expect(status(#"{"outcome":"detached","exit_code":null,"signal":null,"message":null}"#) == .disconnected(nil))
    // A detach the host never confirmed, and a lost connection, say what happened.
    #expect(status(#"{"outcome":"detached","exit_code":null,"signal":null,"message":"\#(unconfirmedDetach)"}"#)
        == .disconnected(unconfirmedDetach))
    #expect(status(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":"\#(lostConnection)\n"}"#)
        == .disconnected(lostConnection))
    #expect(status(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":" "}"#) == .disconnected(nil))
    #expect(status(#"{"outcome":"taken_over","exit_code":null,"signal":null,"message":null}"#) == .takenOver)
    #expect(status(#"{"outcome":"failed","exit_code":null,"signal":null,"message":"no such session"}"#) == .failed("no such session"))
    #expect(status(#"{"outcome":"failed","exit_code":null,"signal":null,"message":null}"#) == .failed("The session could not be attached."))
    #expect(status(#"{"outcome":"from-a-newer-cli"}"#) == .disconnected(nil))
    #expect(status("not json") == .disconnected(nil))
    #expect(status("") == .disconnected(nil))

    #expect(HostedAttachmentStatus.exited(code: 3, signal: nil).summary == "Session ended (exit 3)")
    #expect(HostedAttachmentStatus.exited(code: 137, signal: 9).summary == "Session ended (signal 9)")
    #expect(HostedAttachmentStatus.takenOver.summary == "Another client took over")
    #expect(HostedAttachmentStatus.failed("no such session").summary == "no such session")
    #expect(HostedAttachmentStatus.disconnected(nil).summary == "Disconnected")
    #expect(HostedAttachmentStatus.disconnected(unconfirmedDetach).summary == "Disconnected: \(unconfirmedDetach)")
    #expect(HostedAttachmentStatus.disconnected(unconfirmedDetach).sidebarLabel == "disconnected")
    #expect(HostedAttachmentStatus.exited(code: 0, signal: nil).sessionEnded)
    #expect(!HostedAttachmentStatus.takenOver.sessionEnded)

    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let first = try HostedAttachmentStatusFile.makeLaunchDirectory(in: parent)
    let second = try HostedAttachmentStatusFile.makeLaunchDirectory(in: parent)
    #expect(first != second)
    #expect(first.lastPathComponent.hasPrefix("cherry-attach-\(getpid())-"))
    let permissions = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int
    #expect(permissions == 0o700)
    // Nothing written yet: the adapter is still running.
    #expect(HostedAttachmentStatusFile.read(from: first) == nil)
    try Data(#"{"outcome":"taken_over","exit_code":null,"signal":null,"message":null}"#.utf8)
        .write(to: HostedAttachmentStatusFile.statusFileURL(in: first))
    #expect(HostedAttachmentStatusFile.read(from: first) == .takenOver)
    HostedAttachmentStatusFile.removeLaunchDirectory(first, after: 0)
    #expect(!FileManager.default.fileExists(atPath: first.path))
}

@Test func HostedSessionStatusFileTellsTheLiveStateFromTheFinalOutcome() throws {
    func live(_ json: String) -> HostedAdapterLiveStatus? {
        HostedAttachmentStatusFile.liveStatus(from: Data(json.utf8))
    }
    #expect(live(HostedSessionFakeCLI.attachedStatus()) == HostedAdapterLiveStatus())
    #expect(live(HostedSessionFakeCLI.attachedStatus(viewport: true)) == HostedAdapterLiveStatus(viewport: true))
    #expect(live(HostedSessionFakeCLI.attachedStatus(reconnecting: true)) == HostedAdapterLiveStatus(reconnecting: true))
    #expect(live(#"{"outcome":"attached"}"#) == HostedAdapterLiveStatus())
    #expect(live(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":null}"#) == nil)
    #expect(live("not json") == nil)
    #expect(HostedAdapterLiveStatus().followsProgram)
    #expect(HostedAdapterLiveStatus().showsWholeScreen)
    #expect(HostedAdapterLiveStatus(viewport: true).followsProgram)
    #expect(!HostedAdapterLiveStatus(viewport: true).showsWholeScreen)
    #expect(!HostedAdapterLiveStatus(reconnecting: true).followsProgram)
    #expect(!HostedAdapterLiveStatus(reconnecting: true).showsWholeScreen)

    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let launch = try HostedAttachmentStatusFile.makeLaunchDirectory(in: parent)
    let file = HostedAttachmentStatusFile.statusFileURL(in: launch)
    // A running adapter's state is no outcome: it has not ended.
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(reconnecting: true), to: file)
    #expect(HostedAttachmentStatusFile.read(from: launch) == nil)
    #expect(HostedAttachmentStatusFile.readLive(from: launch) == HostedAdapterLiveStatus(reconnecting: true))
    // A live state left behind by an adapter that was killed means it ended.
    #expect(HostedAttachmentStatusFile.status(from: try Data(contentsOf: file)) == .disconnected(nil))
    try HostedSessionFakeCLI.writeStatus(#"{"outcome":"exited","exit_code":2,"signal":null,"message":null}"#, to: file)
    #expect(HostedAttachmentStatusFile.read(from: launch) == .exited(code: 2, signal: nil))
    #expect(HostedAttachmentStatusFile.readLive(from: launch) == nil)
}

@Test @MainActor func HostedAdapterStatusWatcherReportsEachNewLiveState() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let launch = try HostedAttachmentStatusFile.makeLaunchDirectory(in: parent)
    let file = HostedAttachmentStatusFile.statusFileURL(in: launch)
    let reported = Recorder<[HostedAdapterLiveStatus]>([])
    let watcher = try #require(HostedAdapterStatusWatcher(directory: launch) { reported.value.append($0) })
    func waitFor(_ count: Int) async -> Bool {
        for _ in 0..<500 where reported.value.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reported.value.count == count
    }

    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(), to: file)
    #expect(await waitFor(1))
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(reconnecting: true), to: file)
    #expect(await waitFor(2))
    // The same state again, and a final outcome, are not reported.
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(reconnecting: true), to: file)
    try HostedSessionFakeCLI.writeStatus(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":null}"#, to: file)
    try await Task.sleep(for: .milliseconds(200))
    #expect(reported.value == [HostedAdapterLiveStatus(), HostedAdapterLiveStatus(reconnecting: true)])
    // Nothing after it is cancelled.
    watcher.cancel()
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(viewport: true), to: file)
    try await Task.sleep(for: .milliseconds(200))
    #expect(reported.value.count == 2)
    // A state written before the watch started is reported at once.
    let written = try HostedAttachmentStatusFile.makeLaunchDirectory(in: parent)
    try HostedSessionFakeCLI.writeStatus(
        HostedSessionFakeCLI.attachedStatus(viewport: true), to: HostedAttachmentStatusFile.statusFileURL(in: written)
    )
    let early = Recorder<[HostedAdapterLiveStatus]>([])
    let second = try #require(HostedAdapterStatusWatcher(directory: written) { early.value.append($0) })
    #expect(early.value == [HostedAdapterLiveStatus(viewport: true)])
    second.cancel()
}

@Test func HostedSessionAttachStatusDirectoriesOfQuitAppsAreRemoved() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-status-sweep-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let exited = Process()
    exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try exited.run()
    exited.waitUntilExit()
    let quitPID = exited.processIdentifier

    let own = try HostedAttachmentStatusFile.makeLaunchDirectory(in: parent)
    // An app that quit with a hosted tab attached: its adapter wrote the
    // outcome after the app was gone.
    let abandoned = try HostedAttachmentStatusFile.makeLaunchDirectory(in: parent, ownerPID: quitPID)
    try Data(#"{"outcome":"disconnected"}"#.utf8).write(to: HostedAttachmentStatusFile.statusFileURL(in: abandoned))
    // Another running app (launchd stands in: signalling it is not permitted).
    let otherApp = try HostedAttachmentStatusFile.makeLaunchDirectory(in: parent, ownerPID: 1)
    let unrelated = parent.appendingPathComponent("cherry-attach-\(quitPID)-not-a-uuid")
    let unrelatedPrefix = parent.appendingPathComponent("cherry-attachments")
    for directory in [unrelated, unrelatedPrefix] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    HostedAttachmentStatusFile.removeAbandonedLaunchDirectories(in: parent)
    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    for kept in [own, otherApp, unrelated, unrelatedPrefix] {
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    // The liveness check is injectable; the running app never removes its own.
    HostedAttachmentStatusFile.removeAbandonedLaunchDirectories(in: parent, isRunning: { _ in false })
    #expect(FileManager.default.fileExists(atPath: own.path))
    #expect(!FileManager.default.fileExists(atPath: otherApp.path))
}

private func fixtureSession() throws -> HostedSessionInfo {
    try JSONDecoder().decode(HostedSessionInfo.self, from: Data(hostedSessionFixture.utf8))
}

@Test @MainActor func HostedSessionCreateSendsNamesAndDirectoriesVerbatim() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let control = makeFakeHostControl(
        fake, host: try .ssh("devbox"), hostStore: store, loginEnvironment: ["SSH_AUTH_SOCK": "/login/agent.sock"]
    )
    defer { control.disconnect() }
    let requestID = UUID()
    let name = "editor;$(touch should-not-exist)"
    let session = try await control.create(
        name: name, cwd: "/remote/path with spaces", requestID: requestID, expectedHostID: "host-a"
    )
    #expect(session.id == "session-\(requestID.uuidString.lowercased())")
    let sent = try #require(fake.requests("create").last)
    #expect(sent.string("name") == name)
    #expect(sent.string("cwd") == "/remote/path with spaces")
    #expect(sent.string("request_id") == requestID.uuidString.lowercased())
    // The helper runs with the login shell's variables, not only the app's.
    #expect(fake.launches.last?.environment["SSH_AUTH_SOCK"] == "/login/agent.sock")

    // Values that start with "-" stay values: no argument parser is involved.
    for hyphenated in ["-dev", "-- scratch", "--name"] {
        _ = try await control.create(name: hyphenated, cwd: "/tmp")
        #expect(fake.requests("create").last?.string("name") == hyphenated)
    }
    _ = try await control.create(name: "Default directory", cwd: "")
    #expect(fake.requests("create").last?.string("cwd") == "~")
    _ = try await control.create(name: "Home path", cwd: "~/code/app")
    #expect(fake.requests("create").last?.string("cwd") == "~/code/app")
    // A path the app passes is used exactly as given: a directory name may
    // end in a space (only text a person typed is trimmed, by the sheet).
    _ = try await control.create(name: "Trailing space", cwd: "/Users/me/Client Work ")
    #expect(fake.requests("create").last?.string("cwd") == "/Users/me/Client Work ")
    _ = try await control.create(name: "Newline", cwd: "/tmp/odd\n")
    #expect(fake.requests("create").last?.string("cwd") == "/tmp/odd\n")
    let creates = fake.requests("create").count
    await #expect(throws: HostedSessionError.self) {
        try await control.create(name: "Not trimmed", cwd: " ~/code/app ")
    }
    #expect(fake.requests("create").count == creates)

    try await control.terminate("session-123", expectedHostID: "host-a")
    #expect(fake.requests.last?.op == "kill")
    #expect(fake.requests.last?.string("id") == "session-123")
    try await control.remove("session-123", expectedHostID: "host-a")
    #expect(fake.requests.last?.op == "remove")
    #expect(fake.requests.last?.string("id") == "session-123")
}

@Test @MainActor func HostedSessionWorkingDirectoryMustBeAbsoluteOrHomeRelative() async throws {
    #expect(try HostedSessionClient.hostWorkingDirectory("") == "~")
    #expect(try HostedSessionClient.hostWorkingDirectory("~") == "~")
    #expect(try HostedSessionClient.hostWorkingDirectory("~/code") == "~/code")
    #expect(try HostedSessionClient.hostWorkingDirectory("/srv/app") == "/srv/app")
    // Typed text is trimmed; a path the app passes is not.
    #expect(try HostedSessionClient.hostWorkingDirectory(" ~/code \n") == "~/code")
    #expect(try HostedSessionClient.validatedHostWorkingDirectory("/srv/app ") == "/srv/app ")
    #expect(try HostedSessionClient.validatedHostWorkingDirectory("") == "~")
    #expect(throws: HostedSessionError.self) { try HostedSessionClient.validatedHostWorkingDirectory(" /srv/app") }
    for relative in ["code/app", ".", "../x", "~other/code"] {
        #expect(throws: HostedSessionError.self) { try HostedSessionClient.hostWorkingDirectory(relative) }
    }

    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let control = makeFakeHostControl(fake, hostStore: store)
    await #expect(throws: HostedSessionError.self) {
        try await control.create(name: "x", cwd: "code/app")
    }
    #expect(fake.launches.isEmpty)
}

@Test @MainActor func HostedSessionCreateRetriesTransportFailureWithTheSameRequestID() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let login = ["SSH_AUTH_SOCK": "/login/agent.sock"]
    let registry = makeFakeHostControlRegistry(fake, hostStore: store, clientProvider: {
        HostedSessionClient(
            executableURL: URL(fileURLWithPath: "/fake/bin/cherry"), loginEnvironment: { _ in .init(environment: login) }
        )
    })
    defer { registry.disconnectAll() }
    let controller = HostedSessionsController(controls: registry, hostStore: store)
    await controller.refresh(.local)
    #expect(controller.hostID == "host-a")

    // The first answer is lost with its connection.
    let losses = FakeCountdown(1)
    fake.respond = { request, _ in
        request.op == "create" && losses.take() ? .exit(stderr: "cherry: connection to the host was lost") : nil
    }
    let attachment = await controller.create(on: .local, name: "-dev", cwd: "~/code")
    #expect(controller.error == nil)
    let requestIDs = fake.requests("create").compactMap { $0.string("request_id") }
    #expect(requestIDs.count == 2)
    #expect(Set(requestIDs).count == 1)
    #expect(UUID(uuidString: requestIDs[0]) != nil)
    #expect(attachment?.sessionID == "session-\(requestIDs[0])")
    #expect(fake.requests("create").last?.string("name") == "-dev")
    #expect(fake.requests("create").last?.string("cwd") == "~/code")
    // What a person typed in the sheet is trimmed before it is sent.
    fake.respond = nil
    _ = await controller.create(on: .local, name: "typed", cwd: "  ~/code/app \n")
    #expect(fake.requests("create").last?.string("cwd") == "~/code/app")
    fake.respond = { request, _ in
        request.op == "create" && losses.take() ? .exit(stderr: "cherry: connection to the host was lost") : nil
    }
    // The attach adapter gets the helper and login environment the control
    // connection runs with.
    #expect(attachment?.environment == login)
    #expect(attachment?.executablePath == "/fake/bin/cherry")
    #expect(attachment?.hostID == "host-a")
    #expect(controller.sessions.contains { $0.id == attachment?.sessionID })

    // A second failure keeps the reconcile hint; the next Create is a new request.
    losses.set(2)
    #expect(await controller.create(on: .local, name: "again", cwd: "") == nil)
    #expect(controller.error?.contains("Refresh before trying again") == true)
    let retried = Array(fake.requests("create").compactMap { $0.string("request_id") }.dropFirst(3))
    #expect(retried.count == 2)
    #expect(Set(retried).count == 1)
    #expect(retried.first != requestIDs[0])

    // A host rejection is a definite answer: no retry and no "may have been created".
    fake.respond = { request, _ in
        request.op == "create"
            ? .answer(.error(code: "request_failed", message: "working directory does not exist")) : nil
    }
    #expect(await controller.create(on: .local, name: "rejected", cwd: "/missing") == nil)
    #expect(controller.error?.contains("working directory does not exist") == true)
    #expect(controller.error?.contains("may have been created") == false)
    #expect(fake.requests("create").count == 6)
}

@Test @MainActor func HostedSessionRefreshPinsSSHHostIdentityUntilTrustedAgain() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [try fixtureSession()])
    let registry = makeFakeHostControlRegistry(fake, hostStore: store)
    defer { registry.disconnectAll() }
    let controller = HostedSessionsController(controls: registry, hostStore: store)
    let devbox = try store.add("devbox")
    func dropConnections(of host: HostedSessionHost) async {
        fake.dropAll()
        let control = registry.control(for: host)
        let deadline = Date().addingTimeInterval(5)
        while control.state == .connected, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    await controller.refresh(devbox)
    // The fake's identities are not UUIDs, so the helper is not told which
    // one to expect (HostControlTests covers that): the app checks the Welcome.
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "control"])
    #expect(store.trustedHostID(for: devbox) == "host-a")
    #expect(controller.sessions.count == 1)

    // The connection stays open; a refresh lists again.
    let launches = fake.launches.count
    await controller.refresh(devbox)
    #expect(fake.launches.count == launches)
    #expect(controller.error == nil)

    // A different machine (or a reset host) answers for the same destination.
    fake.hostID = "host-b"
    await dropConnections(of: devbox)
    await controller.refresh(devbox)
    #expect(controller.identityMismatchHost == devbox)
    #expect(controller.error?.contains("different host identity") == true)
    // The identity lives in the host's durable state directory, not in /tmp.
    #expect(controller.error?.contains("state directory is deleted or reset") == true)
    #expect(controller.error?.contains("runs as another user") == true)
    #expect(controller.error?.contains("/tmp") == false)
    #expect(controller.hostID == nil)
    #expect(controller.loadedHost == nil)
    #expect(controller.sessions.isEmpty)
    #expect(store.trustedHostID(for: devbox) == "host-a")
    #expect(await controller.create(on: devbox, name: "blocked", cwd: "") == nil)
    #expect(fake.requests("create").isEmpty)

    await controller.trustNewHostIdentity(devbox)
    #expect(fake.launches.last?.arguments == ["--host", "devbox", "control"])
    #expect(controller.error == nil)
    #expect(controller.identityMismatchHost == nil)
    #expect(controller.hostID == "host-b")
    #expect(store.trustedHostID(for: devbox) == "host-b")

    // Forgetting a destination drops its pin.
    store.remove(devbox)
    #expect(store.trustedHostID(for: devbox) == nil)

    // This Mac is never pinned: the helper already rejects a local socket or
    // peer owned by another user, so a changed identity is still this user's host.
    await controller.refresh(.local)
    #expect(fake.launches.last?.arguments == ["control"])
    fake.hostID = "host-c"
    await dropConnections(of: .local)
    await controller.refresh(.local)
    #expect(controller.error == nil)
    #expect(controller.identityMismatchHost == nil)
    #expect(controller.hostID == "host-c")
    #expect(store.trustedHostID(for: .local) == nil)
}

@Test @MainActor func HostedSessionDiskImageCopyNeverRunsALocalHostCommand() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [try fixtureSession()])
    let registry = makeFakeHostControlRegistry(fake, hostStore: store)
    defer { registry.disconnectAll() }
    let controller = HostedSessionsController(
        controls: registry, hostStore: store,
        localHostUnavailableReason: "Move Cherry to Applications first."
    )
    let devbox = try HostedSessionHost.ssh("devbox")
    #expect(controller.isUnavailable(.local))
    #expect(!controller.isUnavailable(devbox))

    // Even connecting would start the local daemon from the disk image.
    await controller.refresh(.local)
    await controller.trustNewHostIdentity(.local)
    #expect(fake.launches.isEmpty)
    #expect(controller.loadedHost == nil)
    #expect(controller.hostID == nil)
    #expect(controller.error == nil)
    #expect(!controller.isBusy)
    #expect(await controller.create(on: .local, name: "local", cwd: "") == nil)
    #expect(fake.launches.isEmpty)

    // SSH hosts run their own daemon.
    await controller.refresh(devbox)
    #expect(controller.loadedHost == devbox)
    let session = try #require(controller.sessions.first)
    #expect(controller.attachment(for: session, on: devbox) != nil)
    #expect(await controller.create(on: devbox, name: "remote", cwd: "") != nil)

    // Switching back to This Mac clears the SSH list without a local helper.
    let launches = fake.launches.count
    await controller.refresh(.local)
    #expect(fake.launches.count == launches)
    #expect(fake.launches.allSatisfy { $0.arguments.first == "--host" })
    #expect(controller.sessions.isEmpty)
    #expect(controller.loadedHost == nil)
    #expect(controller.attachment(for: session, on: .local) == nil)
}

@Test @MainActor func HostedSessionSheetFollowsTheHostsLiveSessionList() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [try fixtureSession()])
    let registry = makeFakeHostControlRegistry(fake, hostStore: store)
    defer { registry.disconnectAll() }
    let controller = HostedSessionsController(controls: registry, hostStore: store)
    await controller.refresh(.local)
    let connection = try #require(fake.connections.last)

    // Another client creates a session and renames this one: the open sheet
    // shows it without a refresh.
    connection.push(.event(.added(hostedSession("other", name: "Other"))))
    connection.push(.event(.changed(HostedSessionInfo(
        id: "session-123", name: "Renamed", cwd: "/remote/project", command: ["/bin/zsh"], cols: 100, rows: 35, pid: 1234
    ))))
    let deadline = Date().addingTimeInterval(5)
    while controller.sessions.count < 2 || controller.sessions.first?.name != "Renamed", Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.sessions.map(\.id) == ["session-123", "other"])
    #expect(controller.sessions.first?.displayName == "Renamed")
    // The sheet keeps the host's connection while it shows the host.
    #expect(registry.control(for: .local).state == .connected)
}

/// SwiftUI's `.task(id: selectedHost.id)` cancels the previous refresh when
/// the host changes (or the sheet closes).
@Test @MainActor func HostedSessionSheetSwitchingHostsWhileLoadingShowsTheNewHost() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper(sessions: [hostedSession("s1")])
    let held = FakeHeldRequest()
    // The SSH host is slow to answer.
    fake.respond = { request, connection in
        guard request.op == "subscribe", connection.launch.arguments.first == "--host" else { return nil }
        return held.hold(request, on: connection)
    }
    let registry = makeFakeHostControlRegistry(fake, hostStore: store)
    defer { registry.disconnectAll() }
    let controller = HostedSessionsController(controls: registry, hostStore: store, localHostUnavailableReason: nil)
    let devbox = try store.add("devbox")

    let slow = Task { await controller.refresh(devbox) }
    #expect(await fake.wait { held.isHeld })
    #expect(controller.isBusy)
    // The user picks This Mac: its load replaces the one under way.
    slow.cancel()
    await controller.refresh(.local)
    #expect(controller.loadedHost == .local)
    #expect(controller.hostID == "host-a")
    #expect(controller.error == nil)
    #expect(!controller.isBusy)

    // The replaced load ends without reporting or changing anything.
    held.answer(.ok)
    await slow.value
    #expect(controller.loadedHost == .local)
    #expect(controller.sessions.map(\.id) == ["s1"])
    #expect(controller.error == nil)
    #expect(!controller.isBusy)

    // Closing the sheet while a host loads is not an error either.
    fake.respond = { request, connection in
        guard request.op == "list", connection.launch.arguments.first == "--host" else { return nil }
        return held.hold(request, on: connection)
    }
    let closed = Task { await controller.refresh(devbox) }
    #expect(await fake.wait { held.isHeld })
    closed.cancel()
    await closed.value
    #expect(controller.error == nil)
    #expect(!controller.isBusy)
    #expect(controller.loadedHost == nil)
}

@Test func HostedSessionConnectionBarOffersOnlyActionsTheTabCanTake() {
    let connected = HostedConnectionBarState(isRunning: true, status: .active, removedFromHost: false, canClose: true)
    #expect(connected.message == nil)
    #expect(connected.actions == [.disconnect])

    for status in [
        HostedAttachmentStatus.disconnected(nil), .disconnected(unconfirmedDetach), .takenOver, .failed("no such session")
    ] {
        let state = HostedConnectionBarState(isRunning: false, status: status, removedFromHost: false, canClose: false)
        #expect(state.message == status.summary)
        #expect(state.actions == [.reconnect])
    }

    // An ended session cannot be reconnected; it can be removed and closed.
    let ended = HostedAttachmentStatus.exited(code: 3, signal: nil)
    let closable = HostedConnectionBarState(isRunning: false, status: ended, removedFromHost: false, canClose: true)
    #expect(closable.message == "Session ended (exit 3)")
    #expect(closable.actions == [.removeFromHost, .closeTab(enabled: true)])
    // A workspace's last tab stays open, as in the sidebar.
    let lastTab = HostedConnectionBarState(isRunning: false, status: ended, removedFromHost: false, canClose: false)
    #expect(lastTab.actions == [.removeFromHost, .closeTab(enabled: false)])
    // After removal the host has nothing left to remove.
    let removed = HostedConnectionBarState(isRunning: false, status: ended, removedFromHost: true, canClose: false)
    #expect(removed.message == "Removed from host")
    #expect(removed.actions == [.closeTab(enabled: false)])
}

@Test @MainActor func HostedSessionNativeAdapterReportsOutcomesAndNeverReconnectsAnEndedSession() async throws {
    let cli = try HostedSessionFakeCLI()
    let workspace = TerminalWorkspace(createInitialSession: false)
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/remote/project", executablePath: cli.executable.path,
        environment: ["SSH_AUTH_SOCK": "/login/agent.sock"]
    )
    let session = workspace.attachHostedSession(attachment)
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    window.orderFrontRegardless()
    defer {
        workspace.closeAllSessions()
        container.detachActiveSession()
        window.close()
        cli.cleanUp()
    }

    func waitForLaunches(_ count: Int) async throws -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let launches = cli.calls.filter { $0.contains(" attach ") }
            if launches.count >= count { return launches }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HostedSessionError.message("The native attach adapter did not launch")
    }
    func statusFile(of launch: String) throws -> URL {
        let parts = launch.split(separator: " ").map(String.init)
        let index = try #require(parts.firstIndex(of: "--status-file"))
        return URL(fileURLWithPath: parts[index + 1])
    }
    func writeStatus(_ json: String, for launch: String) throws {
        try Data(json.utf8).write(to: try statusFile(of: launch))
    }
    let prefix = "--host devbox --expected-host-id host-a attach session-123"

    // Every launch attaches as the tab, so the host replaces the tab's
    // previous attachment instead of keeping a stale one.
    let client = "--client-id \(session.id.uuidString)"
    let first = try await waitForLaunches(1)[0]
    #expect(first.hasPrefix("\(prefix) --detach-key none \(client) --status-file "))
    #expect(session.usesNativePTYBackend)
    #expect(!session.hasRunningProcess())
    #expect(session.childProcessID == nil)
    #expect(session.hostedAttachmentStatus == .active)
    #expect(session.state.label == "live")
    #expect(session.ghosttyBridge.terminalView.window === window)
    #expect(cli.read("ssh-auth-sock") == "/login/agent.sock")
    #expect(cli.read("term") == "xterm-256color")
    let firstStatus = try statusFile(of: first)
    #expect(FileManager.default.fileExists(atPath: firstStatus.deletingLastPathComponent().path))

    // Another client took over: the program still runs, so this is no exit.
    try writeStatus(#"{"outcome":"taken_over","exit_code":null,"signal":null,"message":null}"#, for: first)
    session.ingestNativeChildExit(exitCode: 0)
    #expect(session.hostedAttachmentStatus == .takenOver)
    #expect(session.state.label == "disconnected")
    #expect(session.exitCode == nil)
    #expect(session.sidebarDetail == "devbox · taken over")
    #expect(session.canRestart)
    #expect(!FileManager.default.fileExists(atPath: firstStatus.deletingLastPathComponent().path))

    session.reconnectHostedSession()
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    let second = try await waitForLaunches(2)[1]
    #expect(try statusFile(of: second) != firstStatus)
    #expect(!second.contains("--takeover"))
    #expect(second.contains(" \(client) "))
    // Reconnecting the same selected tab must replace its mounted view, not
    // just start an adapter whose Ghostty surface renders offscreen.
    #expect(session.ghosttyBridge.terminalView.window === window)
    #expect(session.ghosttyBridge.terminalView.isDescendant(of: container))

    session.disconnectHostedSession()
    #expect(!session.isRunning)
    #expect(session.hostedAttachmentStatus == .disconnected(nil))
    #expect(session.state.label == "disconnected")
    #expect(session.hostedAttachment == attachment)
    // Only an ended session can be removed from its host.
    session.noteHostedSessionRemovedFromHost()
    #expect(!session.hostedSessionRemovedFromHost)
    // Clearing a disconnected tab must not start an adapter.
    session.clearScrollback()
    try await Task.sleep(for: .milliseconds(200))
    #expect(cli.calls.filter { $0.contains(" attach ") }.count == 2)

    // Attach & Take Over from the sheet reuses the tab for this launch only.
    #expect(workspace.attachHostedSession(attachment, takeover: true) === session)
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    let third = try await waitForLaunches(3)[2]
    #expect(third.hasPrefix("\(prefix) --takeover --detach-key none \(client) --status-file "))

    // The hosted program exited: report it, and offer no reconnect.
    try writeStatus(#"{"outcome":"exited","exit_code":3,"signal":null,"message":null}"#, for: third)
    session.ingestNativeChildExit(exitCode: 3)
    #expect(session.hostedAttachmentStatus == .exited(code: 3, signal: nil))
    #expect(session.state.label == "exit 3")
    #expect(session.exitCode == 3)
    #expect(session.hostedSessionEnded)
    #expect(!session.canRestart)
    #expect(session.closeActionTitle == "Close")
    #expect(session.sidebarDetail == "devbox · ended")
    session.noteHostedSessionRemovedFromHost()
    #expect(session.hostedSessionRemovedFromHost)
    session.restart()
    session.reconnectHostedSession()
    _ = workspace.attachHostedSession(attachment)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!session.isRunning)
    #expect(cli.calls.filter { $0.contains(" attach ") }.count == 3)
    #expect(session.hostedAttachment?.sessionID == "session-123")
    // Each launch started once the previous adapter was gone, though it
    // still ran when the tab reconnected (taken over, then disconnected):
    // two adapters of one tab would drop each other's attachment in turn.
    #expect(cli.clientOverlaps.isEmpty)
}

@Test @MainActor func HostedSessionTabShowsWhyItsAdapterDisconnected() async throws {
    let cli = try HostedSessionFakeCLI()
    let workspace = TerminalWorkspace(createInitialSession: false)
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/remote/project", executablePath: cli.executable.path
    )
    let session = workspace.attachHostedSession(attachment)
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    window.orderFrontRegardless()
    defer {
        workspace.closeAllSessions()
        container.detachActiveSession()
        window.close()
        cli.cleanUp()
    }

    func waitForLaunches(_ count: Int) async throws -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let launches = cli.calls.filter { $0.contains(" attach ") }
            if launches.count >= count { return launches }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HostedSessionError.message("The native attach adapter did not launch")
    }
    func statusFile(of launch: String) throws -> URL {
        let parts = launch.split(separator: " ").map(String.init)
        let index = try #require(parts.firstIndex(of: "--status-file"))
        return URL(fileURLWithPath: parts[index + 1])
    }
    func writeStatus(outcome: String, message: String, for launch: String) throws {
        let record: [String: Any] = ["outcome": outcome, "exit_code": NSNull(), "signal": NSNull(), "message": message]
        try JSONSerialization.data(withJSONObject: record).write(to: try statusFile(of: launch))
    }
    func bar() -> HostedConnectionBarState {
        HostedConnectionBarState(
            isRunning: session.isRunning, status: session.hostedAttachmentStatus, removedFromHost: false, canClose: true
        )
    }

    // The fake adapter only sleeps. Answer the tab's hangup the way
    // `cherry attach` does, synchronously so the order is deterministic: an
    // adapter whose launch directory still exists writes why it ended
    // ("interrupted by signal 1"), unless it already wrote an outcome, and
    // then exits. A tab's later stops can reach an adapter again; only the
    // last one hung up on matters.
    var hungUpLaunches: [String] = []
    let terminate = session.terminateNativeSession
    session.terminateNativeSession = { pid in
        defer { terminate(pid) }
        guard let launch = cli.calls.last(where: { $0.contains(" attach ") }),
              let file = try? statusFile(of: launch),
              FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path)
        else { return }
        hungUpLaunches.append(launch)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try writeStatus(outcome: "disconnected", message: hangupInterruption, for: launch)
        } catch {
            Issue.record(error)
        }
    }

    // The adapter gave up waiting for the host to confirm its detach.
    let first = try await waitForLaunches(1)[0]
    try writeStatus(outcome: "detached", message: unconfirmedDetach, for: first)
    session.ingestNativeChildExit(exitCode: 0)
    #expect(session.hostedAttachmentStatus == .disconnected(unconfirmedDetach))
    #expect(session.state == .disconnected)
    #expect(session.exitCode == nil)
    #expect(session.sidebarDetail == "devbox · disconnected")
    #expect(session.canRestart)
    #expect(bar().message == "Disconnected: \(unconfirmedDetach)")
    #expect(bar().actions == [.reconnect])

    // An outcome the adapter wrote before the tab stopped it (a close reported
    // before the exit callback) keeps its reason.
    session.reconnectHostedSession()
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    let second = try await waitForLaunches(2)[1]
    #expect(session.hostedAttachmentStatus == .active)
    #expect(bar().message == nil)
    try writeStatus(outcome: "disconnected", message: lostConnection, for: second)
    session.stop()
    #expect(hungUpLaunches.last == second)
    #expect(session.hostedAttachmentStatus == .disconnected(lostConnection))
    #expect(bar().message == "Disconnected: \(lostConnection)")

    // A disconnect the user asked for needs no explanation. The tab reads the
    // outcome before it hangs up on the adapter, so what the adapter writes
    // about that hangup is never shown.
    session.reconnectHostedSession()
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    let third = try await waitForLaunches(3)[2]
    session.disconnectHostedSession()
    #expect(hungUpLaunches.last == third)
    #expect(try String(contentsOf: statusFile(of: third), encoding: .utf8).contains(hangupInterruption))
    #expect(session.hostedAttachmentStatus == .disconnected(nil))
    #expect(bar().message == "Disconnected")
    #expect(bar().actions == [.reconnect])
}

// ghostty routes queued surface messages by surface address, and a relaunched
// tab's surface is usually allocated where the old one was. An adapter that
// exited before the relaunch, with its exit report still queued, must not end
// the new attachment (which would also delete the new launch's status
// directory, so the adapter's outcome would be lost).
@Test @MainActor func HostedSessionRelaunchIgnoresTheReplacedAdapterExit() async throws {
    let cli = try HostedSessionFakeCLI()
    let workspace = TerminalWorkspace(createInitialSession: false)
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/remote/project", executablePath: cli.executable.path
    )
    let session = workspace.attachHostedSession(attachment)
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    window.orderFrontRegardless()
    defer {
        workspace.closeAllSessions()
        container.detachActiveSession()
        window.close()
        cli.cleanUp()
    }

    func waitForLaunches(_ count: Int) async throws -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let launches = cli.calls.filter { $0.contains(" attach ") }
            if launches.count >= count { return launches }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HostedSessionError.message("The native attach adapter did not launch")
    }
    func statusDirectory(of launch: String) throws -> URL {
        let parts = launch.split(separator: " ").map(String.init)
        let index = try #require(parts.firstIndex(of: "--status-file"))
        return URL(fileURLWithPath: parts[index + 1]).deletingLastPathComponent()
    }
    /// Blocks the main thread until the process is gone. ghostty reports a
    /// child's exit through a main-thread tick, so the report stays queued.
    func holdMainThreadUntilExited(_ pid: pid_t) {
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline { usleep(200) }
    }
    /// Runs the main-queue work enqueued before this call, including the
    /// ghostty tick that delivers a queued exit report.
    func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    _ = try await waitForLaunches(1)
    // stop_process, then start_process before the main thread ran again (or a
    // takeover relaunch whose hangup the adapter handled quickly). Surface
    // addresses are reused from the second rebuild on, so relaunch a few times.
    for count in 2...5 {
        let adapter = try #require(session.ghosttyBridge.nativeSessionLeaderPID())
        session.stop()
        holdMainThreadUntilExited(adapter)
        #expect(kill(adapter, 0) != 0)
        session.reconnectHostedSession()
        await drainMainQueue()
        #expect(session.state == .live)
        #expect(session.hostedAttachmentStatus == .active)
        let launch = try await waitForLaunches(count)[count - 1]
        #expect(FileManager.default.fileExists(atPath: try statusDirectory(of: launch).path))
    }
}

// The adapter writes its `exited` outcome and exits, but ghostty reports the
// exit on a later main-thread tick. Reconnect (Cmd-R, or Attach & Take Over
// from the sheet) in between must not start another attach for a session
// that ended: stopping the tab reads the outcome, and that decides.
@Test(arguments: ["restart", "takeover"])
@MainActor func HostedSessionRelaunchReadsTheAdapterOutcomeBeforeDeciding(relaunch: String) async throws {
    let cli = try HostedSessionFakeCLI()
    let workspace = TerminalWorkspace(createInitialSession: false)
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/remote/project", executablePath: cli.executable.path
    )
    let session = workspace.attachHostedSession(attachment)
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    window.orderFrontRegardless()
    defer {
        workspace.closeAllSessions()
        container.detachActiveSession()
        window.close()
        cli.cleanUp()
    }

    func launches() -> [String] { cli.calls.filter { $0.contains(" attach ") } }
    func waitForLaunches(_ count: Int) async throws -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if launches().count >= count { return launches() }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HostedSessionError.message("The native attach adapter did not launch")
    }
    func statusFile(of launch: String) throws -> URL {
        let parts = launch.split(separator: " ").map(String.init)
        let index = try #require(parts.firstIndex(of: "--status-file"))
        return URL(fileURLWithPath: parts[index + 1])
    }
    /// Whether the tab started another adapter.
    func relaunchTab() -> Bool {
        if relaunch == "restart" { return session.restart() }
        #expect(workspace.attachHostedSession(attachment, takeover: true) === session)
        return session.isRunning
    }

    // An adapter that reported nothing is relaunched.
    _ = try await waitForLaunches(1)
    #expect(relaunchTab())
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    let second = try await waitForLaunches(2)[1]
    #expect(session.hostedAttachmentStatus == .active)

    try Data(#"{"outcome":"exited","exit_code":3,"signal":null,"message":null}"#.utf8)
        .write(to: try statusFile(of: second))
    // The tab has not seen the adapter exit yet.
    #expect(session.canRestart)
    #expect(session.state.label == "live")
    #expect(!relaunchTab())
    #expect(session.hostedAttachmentStatus == .exited(code: 3, signal: nil))
    #expect(session.state.label == "exit 3")
    #expect(session.exitCode == 3)
    #expect(!session.canRestart)
    #expect(!session.isRunning)
    // The replaced adapter's exit report changes nothing.
    session.ingestNativeChildExit(exitCode: 0)
    #expect(session.hostedAttachmentStatus == .exited(code: 3, signal: nil))
    #expect(!session.reconnectHostedSession(takeover: true))
    try await Task.sleep(for: .milliseconds(300))
    #expect(launches().count == 2)
}

@Test @MainActor func HostedSessionSheetResolvesTheLoginEnvironmentOffTheMainActorAndExplainsItsAbsence() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    final class Login: @unchecked Sendable {
        private let lock = NSLock()
        private var value: HostedSessionLoginEnvironment.Capture?
        private var calls: [Bool] = []
        private var mainThreadResolves = 0
        var capture: HostedSessionLoginEnvironment.Capture? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        /// `retryingNow` of each resolve.
        var resolves: [Bool] { lock.withLock { calls } }
        var resolvedOnMainThread: Int { lock.withLock { mainThreadResolves } }
        func resolve(retryingNow: Bool) -> HostedSessionLoginEnvironment.Capture? {
            lock.withLock {
                if Thread.isMainThread { mainThreadResolves += 1 }
                calls.append(retryingNow)
                return value
            }
        }
    }
    let login = Login()
    let fake = FakeControlHelper(sessions: [try fixtureSession()])
    let registry = makeFakeHostControlRegistry(fake, hostStore: store, clientProvider: {
        HostedSessionClient(
            executableURL: URL(fileURLWithPath: "/fake/bin/cherry"), loginEnvironment: { login.resolve(retryingNow: $0) }
        )
    })
    defer { registry.disconnectAll() }
    let controller = HostedSessionsController(controls: registry, hostStore: store, terminationTimeout: 0.3)
    let host = try HostedSessionHost.ssh("devbox")
    let hint = HostedSessionsController.missingLoginEnvironmentHint
    let captured = HostedSessionLoginEnvironment.Capture(environment: ["SSH_AUTH_SOCK": "/login/agent.sock"])

    // ssh could not authenticate while Cherry had no login environment: say so.
    fake.exitBeforeWelcome = "devbox: Permission denied (publickey).\n"
    await controller.refresh(host)
    #expect(controller.error?.contains("Permission denied") == true)
    #expect(controller.error?.contains(hint) == true)
    // Also when only the POSIX fallback worked: the user's shell files never ran.
    login.capture = .init(environment: ["FROM_PROFILE": "yes"], fromUserShell: false)
    await controller.refresh(host)
    #expect(controller.error?.contains(hint) == true)
    // Not when the user's shell was captured, and never for This Mac.
    login.capture = captured
    await controller.refresh(host)
    #expect(controller.error?.contains("Permission denied") == true)
    #expect(controller.error?.contains(hint) == false)
    login.capture = nil
    await controller.refresh(.local)
    #expect(controller.error?.contains("Permission denied") == true)
    #expect(controller.error?.contains(hint) == false)
    // Nor for an answer that says nothing about reaching the host.
    fake.exitBeforeWelcome = nil
    fake.respond = { request, connection in
        guard request.op == "list" else { return nil }
        connection.write(try! HostFrame.frame(body: Data(#"{"type":"sessions","host_id":1,"req":\#(request.req!)}"#.utf8)))
        return .silence
    }
    await controller.refresh(host)
    #expect(controller.error?.contains("cannot read") == true)
    #expect(controller.error?.contains(hint) == false)
    fake.respond = nil
    // Each new connection resolves once; only the Refresh button skips the
    // wait after a failed capture.
    #expect(login.resolves == [false, false, false, false, false])
    login.capture = captured
    await controller.refresh(host, retryingLoginEnvironment: true)
    #expect(login.resolves.last == true)

    // Helpers and attachments get what the connection resolved.
    #expect(controller.error == nil)
    let listed = try #require(controller.sessions.first)
    let resolvesAfterList = login.resolves.count
    login.capture = .init(environment: ["SSH_AUTH_SOCK": "/later/agent.sock"])
    #expect(controller.attachment(for: listed, on: host)?.environment == ["SSH_AUTH_SOCK": "/login/agent.sock"])
    // A kill and the wait for its exit never run the user's shell, nor
    // does a create on the open connection.
    await controller.terminate(listed, on: host)
    #expect(fake.requests("kill").last?.string("id") == "session-123")
    #expect(fake.launches.last?.environment["SSH_AUTH_SOCK"] == "/login/agent.sock")
    let created = await controller.create(on: host, name: "New", cwd: "~")
    #expect(created?.environment == ["SSH_AUTH_SOCK": "/login/agent.sock"])
    #expect(login.resolves.count == resolvesAfterList)
    // A new connection resolves again, and its adapters get the new value.
    fake.dropAll()
    let control = registry.control(for: host)
    let deadline = Date().addingTimeInterval(5)
    while control.loginEnvironment?.environment["SSH_AUTH_SOCK"] != "/later/agent.sock" || control.state != .connected,
          Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    await controller.refresh(host)
    #expect(fake.launches.last?.environment["SSH_AUTH_SOCK"] == "/later/agent.sock")
    #expect(controller.attachment(for: listed, on: host)?.environment == ["SSH_AUTH_SOCK": "/later/agent.sock"])
    #expect(login.resolvedOnMainThread == 0)
}

@Test @MainActor func HostedSessionControlServerReportsDisconnectedTabsAsNeverExited() async throws {
    let harness = try ControlServerHarness()
    let cli = try HostedSessionFakeCLI()
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/remote/project", executablePath: cli.executable.path
    )
    let session = harness.workspace.attachHostedSession(attachment, launchShell: false)
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    window.orderFrontRegardless()
    harness.server.start()
    defer {
        harness.stop()
        container.detachActiveSession()
        window.close()
        cli.cleanUp()
    }
    let processID = session.id.uuidString

    func status() async throws -> ProcessSummary {
        let response = try await harness.send(.getProcessStatus(.init(processID: processID)))
        guard case .getProcessStatus(let result)? = response.result else {
            throw HostedSessionError.message("Expected getProcessStatus, got \(String(describing: response))")
        }
        return result.process
    }
    func expectDisconnected(_ process: ProcessSummary) {
        #expect(process.state == "disconnected")
        #expect(process.exitCode == nil)
        #expect(process.exitedAt == nil)
        #expect(process.pid == nil)
        #expect(!process.acceptsInput)
    }
    func waitReason() async throws -> ProcessIdleWaitReason? {
        let response = try await harness.send(.waitForProcessIdle(.init(
            processID: processID, requireNewOutput: false, quietMilliseconds: 0, timeoutMilliseconds: 2_000
        )))
        guard case .waitForProcessIdle(let waited)? = response.result else { return nil }
        #expect(!waited.timedOut)
        return waited.reason
    }
    func waitForLaunches(_ count: Int) async throws -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let launches = cli.calls.filter { $0.contains(" attach ") }
            if launches.count >= count { return launches }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HostedSessionError.message("The native attach adapter did not launch")
    }

    // A tab that was never connected, as after reopening its window.
    #expect(session.state == .disconnected)
    let listResponse = try await harness.send(.listProcesses(.init(kind: nil)))
    guard case .listProcesses(let listed)? = listResponse.result else {
        Issue.record("Expected listProcesses, got \(String(describing: listResponse))")
        return
    }
    expectDisconnected(try #require(listed.processes.first { $0.id == processID }))
    #expect(try await waitReason() == .disconnected)

    // start_process reconnects a disconnected tab.
    let startResponse = try await harness.send(.startProcess(.init(processID: processID)))
    #expect(startResponse.error == nil)
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    _ = try await waitForLaunches(1)
    let live = try await status()
    #expect(live.state == "live")
    // The local process is only the attach adapter; the hosted program has no local PID.
    #expect(live.pid == nil)

    // stop_process only disconnects; the hosted program keeps running.
    let stopResponse = try await harness.send(.stopProcess(.init(processID: processID)))
    guard case .stopProcess(let stopped)? = stopResponse.result else {
        Issue.record("Expected stopProcess, got \(String(describing: stopResponse))")
        return
    }
    expectDisconnected(stopped.process)
    #expect(session.state == .disconnected)
    #expect(session.hostedAttachmentStatus == .disconnected(nil))
    #expect(try await waitReason() == .disconnected)

    // restart_process reconnects too.
    let restartResponse = try await harness.send(.restartProcess(.init(processID: processID)))
    #expect(restartResponse.error == nil)
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    let restarted = try await waitForLaunches(2)[1]
    #expect(try await status().state == "live")
    #expect(try await status().failureMessage == nil)

    // An attach that failed is a failed launch that says why, not a disconnect.
    let restartedParts = restarted.split(separator: " ").map(String.init)
    let restartedStatusIndex = try #require(restartedParts.firstIndex(of: "--status-file"))
    try Data(#"{"outcome":"failed","exit_code":null,"signal":null,"message":"no such session"}"#.utf8)
        .write(to: URL(fileURLWithPath: restartedParts[restartedStatusIndex + 1]))
    session.ingestNativeChildExit(exitCode: 1)
    #expect(session.state == .failed("no such session"))
    #expect(session.hostedAttachmentStatus == .failed("no such session"))
    #expect(session.sidebarDetail == "devbox · not attached")
    let failed = try await status()
    #expect(failed.state == "failed")
    #expect(failed.failureMessage == "no such session")
    #expect(failed.exitCode == nil)
    #expect(failed.exitedAt == nil)
    #expect(!failed.acceptsInput)
    #expect(try await waitReason() == .exited)

    // start_process retries the attach.
    let retryResponse = try await harness.send(.startProcess(.init(processID: processID)))
    #expect(retryResponse.error == nil)
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    let launches = try await waitForLaunches(3)
    let retried = try await status()
    #expect(retried.state == "live")
    #expect(retried.failureMessage == nil)

    // Only an `exited` outcome is an exit, and an ended session cannot restart.
    // The adapter wrote it, but the tab has not seen the adapter exit:
    // restart_process learns it when it stops the adapter.
    let parts = launches[2].split(separator: " ").map(String.init)
    let statusIndex = try #require(parts.firstIndex(of: "--status-file"))
    try Data(#"{"outcome":"exited","exit_code":3,"signal":null,"message":null}"#.utf8)
        .write(to: URL(fileURLWithPath: parts[statusIndex + 1]))
    #expect(try await status().state == "live")
    let racedRestart = try await harness.send(.restartProcess(.init(processID: processID)))
    #expect(racedRestart.error?.code == "hosted_session_ended")
    // The adapter's exit report arrives late and changes nothing.
    session.ingestNativeChildExit(exitCode: 0)
    let ended = try await status()
    #expect(ended.state == "exit 3")
    #expect(ended.exitCode == 3)
    #expect(ended.failureMessage == nil)
    #expect(try await waitReason() == .exited)
    for request in [
        CherryControlRequest.startProcess(.init(processID: processID)),
        .restartProcess(.init(processID: processID)),
        .restartTerminal(.init(terminalID: processID)),
    ] {
        let response = try await harness.send(request)
        #expect(response.error?.code == "hosted_session_ended")
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(cli.calls.filter { $0.contains(" attach ") }.count == 3)
}

// Build the Rust helpers first with Scripts/build-host debug. This exercises the
// different Ghostty versions in the host snapshot producer and native renderer.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"))
@MainActor func HostedSessionRealHostSharesNativeGhosttyInputAndReconnectsBothScreens() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // The same Cargo output directories the app's development lookup uses.
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
    // Short enough for a Unix socket path, and private (0700) as the CLI requires.
    let root = URL(fileURLWithPath: "/tmp/ch-vt-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    // Registered first so it runs last: after the daemon below has stopped,
    // and also when a later setup step throws.
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("host.sock")
    let ready = root.appendingPathComponent("ready")
    // A host keeps its identity and lock under HOME (~/Library/Application
    // Support/cherry-host), and the test must never create state beside the
    // user's real host. The daemon and the helpers get a private HOME, the way
    // the app hands helpers its login environment. Ghostty starts the attach
    // adapters through login(1), which resets HOME, so no helper may start a
    // daemon: CHERRY_HOST_PATH names nothing, and only the daemon below serves.
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(
        at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    let helperVariables = [
        "HOME": home.path,
        "CHERRY_HOST_SOCKET": socket.path,
        "CHERRY_HOST_PATH": root.appendingPathComponent("no-auto-start").path
    ]
    var helperEnvironment = HostedSessionLoginEnvironment.helperEnvironment(
        base: ProcessInfo.processInfo.environment, login: helperVariables
    )
    helperEnvironment["XDG_STATE_HOME"] = nil
    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    let host = try RealHostTestDaemon(executable: hostURL, environment: helperEnvironment, socket: socket)
    let workspace = TerminalWorkspace(createInitialSession: false)
    let secondWorkspace = TerminalWorkspace(createInitialSession: false)
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    let secondContainer = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let secondWindow = NSWindow(contentRect: secondContainer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    secondWindow.isReleasedWhenClosed = false
    secondWindow.contentView = secondContainer
    var ownedChildPID: Int32?
    defer {
        workspace.closeAllSessions()
        secondWorkspace.closeAllSessions()
        container.detachActiveSession()
        secondContainer.detachActiveSession()
        window.close()
        secondWindow.close()
        // The test owns this isolated child and daemon; never touch a global host.
        if let pid = ownedChildPID, getsid(pid) == pid { Darwin.kill(-pid, SIGKILL) }
        host.stop()
    }

    // The tabs under test, whose state a timeout reports.
    var watched: [(name: String, session: TerminalSession)] = []
    // What the host lists, once its control connection exists.
    var hostSessions: () async -> [String] = { [] }
    let started = Date()
    var steps: [String] = []
    func describe(_ session: TerminalSession) -> String {
        let bridge = session.ghosttyBridge
        let view = bridge.terminalView
        let screen = bridge.readNativeScreenText().map {
            $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .suffix(6).joined(separator: " | ")
        }
        // No tty: the surface never spawned its child. Else what runs on
        // it: login(1) still starting, or `cherry attach` connecting.
        let tty = view.ttyName
        let processes = tty.map { tty -> String in
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "pid=,stat=,etime=,command=", "-t", (tty as NSString).lastPathComponent]
            let pipe = Pipe()
            ps.standardOutput = pipe
            ps.standardError = FileHandle.nullDevice
            guard (try? ps.run()) != nil else { return "ps failed" }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            return output.split(separator: "\n").map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) }
                .joined(separator: " / ")
        }
        return "status \(String(describing: session.hostedAttachmentStatus)), "
            + "adapter \(String(describing: session.adapterLiveStatus)), "
            + "child pid \(String(describing: session.childProcessID)), "
            + "view in window \(view.window != nil) bounds \(view.bounds.size), "
            + "tty \(tty ?? "none") running [\(processes ?? "")], "
            + "screen \(screen.map { "\"\($0)\"" } ?? "unreadable (no surface)")"
    }
    // Each surface launch runs `cherry attach` (a debug build) through
    // Ghostty's login(1) wrapper, which connects, attaches and repaints
    // before Ghostty's IO thread parses it. On a loaded machine login(1)
    // alone can take seconds: under 16 CPU hogs and `taskpolicy -c
    // background` one was seen still starting (ps state U) after 48 s, and on a
    // 3-core CI runner (whose jobs are QoS-clamped) this first launch once
    // took over 10 s while the whole test usually takes 2 s. Steps that wait
    // for a surface launch get `launchTimeout`; a timeout says what the tab,
    // its tty and the host were doing.
    let launchTimeout: TimeInterval = 30
    func waitFor(
        _ description: String, timeout: TimeInterval = 10, _ predicate: () async throws -> Bool
    ) async throws {
        let stepStart = Date()
        let deadline = stepStart.addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() {
                steps.append(String(format: "%@ %.1fs", description, Date().timeIntervalSince(stepStart)))
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let tabs = watched.map { "\($0.name): \(describe($0.session))" }.joined(separator: "; ")
        let hosted = await hostSessions()
        throw HostedSessionError.message(
            "Timed out waiting for \(description) after \(String(format: "%.1f", Date().timeIntervalSince(stepStart)))s "
                + "(\(String(format: "%.1f", Date().timeIntervalSince(started)))s into the test; earlier steps: "
                + "\(steps.joined(separator: ", "))). Tabs: \(tabs.isEmpty ? "none" : tabs). Host sessions: \(hosted)"
        )
    }
    try await waitFor("isolated host socket") { FileManager.default.fileExists(atPath: socket.path) }
    // The app's control plane: `cherry control` over the isolated socket.
    let control = HostControl(
        host: .local,
        clientProvider: {
            HostedSessionClient(executableURL: cliURL, loginEnvironment: { _ in .init(environment: helperVariables) })
        },
        hostStore: HostedSessionHostStore(defaults: UserDefaults(suiteName: "CherryTests.RealHost.\(UUID().uuidString)")!),
        masters: disabledSSHMasters,
        localHostUnavailableReason: nil
    )
    defer { control.disconnect() }
    hostSessions = {
        (try? await control.list().sessions.map { "\($0.id) attached \($0.attached) running \($0.isRunning)" }) ?? ["unlisted"]
    }
    let initialList = try await control.list()
    // The host keeps its identity in the private HOME.
    let stateRoot = home.appendingPathComponent("Library/Application Support/cherry-host", isDirectory: true)
    let stateKeys = try FileManager.default.contentsOfDirectory(atPath: stateRoot.path)
    #expect(stateKeys.count == 1)
    let identity = try String(
        contentsOf: stateRoot.appendingPathComponent(try #require(stateKeys.first)).appendingPathComponent("host-id"),
        encoding: .utf8
    )
    #expect(identity.trimmingCharacters(in: .whitespacesAndNewlines) == initialList.hostID)
    let command = """
    stty raw -echo
    printf 'PRIMARY_SNAPSHOT\\r\\n\\033[?1049h\\033[2J\\033[HALTERNATE_SNAPSHOT'
    printf ready > \(quote(ready.path))
    dd bs=1 count=1 >/dev/null 2>&1
    printf '\\033[?1049l\\r\\nAFTER_INPUT'
    dd bs=1 count=1 >/dev/null 2>&1
    printf '\\r\\nSECOND_CLIENT_INPUT'
    dd bs=1 count=1 >/dev/null 2>&1
    printf '\\r\\nAFTER_SECOND_DISCONNECT'
    sleep 60
    """
    // Created through the control plane with an explicit command.
    let created = try await control.create(
        name: "Snapshot integration", cwd: "/tmp", command: ["/bin/sh", "-c", command],
        expectedHostID: initialList.hostID
    )
    #expect(control.sessions.contains { $0.id == created.id })
    ownedChildPID = created.pid.map(Int32.init)
    try await waitFor("host application alternate screen") { FileManager.default.fileExists(atPath: ready.path) }

    let attachment = HostedSessionAttachment(
        host: .local, hostID: initialList.hostID, sessionID: created.id,
        name: created.name, remoteWorkingDirectory: created.cwd, executablePath: cliURL.path,
        environment: helperVariables
    )
    let session = workspace.attachHostedSession(attachment)
    watched.append(("first", session))
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    window.orderFrontRegardless()
    try await waitFor("native Ghostty to render the host snapshot", timeout: launchTimeout) {
        session.ghosttyBridge.readNativeScreenText()?.contains("ALTERNATE_SNAPSHOT") == true
    }
    #expect(session.usesNativePTYBackend)
    let secondSession = secondWorkspace.attachHostedSession(attachment)
    watched.append(("second", secondSession))
    secondContainer.configure(with: secondSession, colorScheme: .dark, allowsAutoFocus: false)
    secondWindow.orderFrontRegardless()
    try await waitFor("second native Ghostty to share the alternate screen", timeout: launchTimeout) {
        secondSession.ghosttyBridge.readNativeScreenText()?.contains("ALTERNATE_SNAPSHOT") == true
    }
    #expect(secondSession !== session)
    #expect(secondSession.hostedAttachment == session.hostedAttachment)
    session.disconnectHostedSession()
    #expect(session.hostedAttachmentStatus == .disconnected(nil))
    try await waitFor("second attachment to survive the first disconnect") {
        let current = try await control.list().sessions.first { $0.id == created.id }
        return current?.attached == true && current?.pid == created.pid && current?.isRunning == true
    }
    session.reconnectHostedSession()
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    try await waitFor("native Ghostty to render the reattached snapshot", timeout: launchTimeout) {
        session.ghosttyBridge.readNativeScreenText()?.contains("ALTERNATE_SNAPSHOT") == true
    }
    #expect(session.ghosttyBridge.terminalView.window === window)
    #expect(session.ghosttyBridge.terminalView.isDescendant(of: container))
    session.send(text: "x")
    try await waitFor("first client input to restore the primary screen in both terminals") {
        [session, secondSession].allSatisfy { terminal in
            guard let screen = terminal.ghosttyBridge.readNativeScreenText() else { return false }
            return screen.contains("PRIMARY_SNAPSHOT") && screen.contains("AFTER_INPUT")
        }
    }
    secondSession.send(text: "y")
    try await waitFor("second client input to reach both terminals") {
        [session, secondSession].allSatisfy {
            $0.ghosttyBridge.readNativeScreenText()?.contains("SECOND_CLIENT_INPUT") == true
        }
    }
    secondSession.disconnectHostedSession()
    session.send(text: "z")
    try await waitFor("first client to continue after the second disconnects") {
        session.ghosttyBridge.readNativeScreenText()?.contains("AFTER_SECOND_DISCONNECT") == true
    }
    let finalList = try await control.list()
    #expect(finalList.sessions.count == 1)
    #expect(finalList.sessions.first?.id == created.id)
    #expect(finalList.sessions.first?.pid == created.pid)
    try await control.terminate(created.id, expectedHostID: initialList.hostID)
    // The exit arrives as an event.
    try await waitFor("host process termination") {
        control.sessions.first { $0.id == created.id }?.isRunning == false
    }
    ownedChildPID = nil
    // The still-attached adapter reports the exit through its status file.
    try await waitFor("the attached tab to report that the session ended") {
        session.hostedSessionEnded
    }
    #expect(!session.canRestart)
}
