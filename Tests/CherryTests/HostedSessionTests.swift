import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Cherry

private let hostedSessionFixture = """
{"id":"session-123","name":"Editor","cwd":"/remote/project","command":["/bin/zsh"],"cols":100,"rows":35,"state":"running","pid":1234,"exit_code":null,"attached":false}
"""

@Test func HostedSessionDecodesHostIdentityAndExitState() throws {
    let list = try JSONDecoder().decode(HostedSessionList.self, from: Data("""
    {"host_id":"host-a","sessions":[\(hostedSessionFixture)]}
    """.utf8))
    #expect(list.hostID == "host-a")
    #expect(list.sessions.first?.isRunning == true)
    #expect(list.sessions.first?.attached == false)
    let exited = hostedSessionFixture
        .replacingOccurrences(of: "\"running\"", with: "\"exited\"")
        .replacingOccurrences(of: "\"exit_code\":null", with: "\"exit_code\":137")
    let session = try JSONDecoder().decode(HostedSessionInfo.self, from: Data(exited.utf8))
    #expect(!session.isRunning)
    #expect(session.exitCode == 137)
}

@Test func HostedSessionRejectsSSHOptionsAndWhitespace() throws {
    for invalid in ["", "-oProxyCommand=bad", "host -p 22", "host\nother", "host\u{0}", "host;sh", "$(touch-bad)"] {
        #expect(throws: HostedSessionError.self) { try HostedSessionHost.ssh(invalid) }
    }
    #expect(try HostedSessionHost.ssh(" user@work ").arguments == ["--host", "user@work"])
    #expect(HostedSessionHost.local.arguments.isEmpty)
    #expect(try HostedSessionHost.ssh("local").id != HostedSessionHost.local.id)
}

@Test @MainActor func HostedSessionSavedHostsRoundTripWithoutDuplicates() throws {
    let suite = "CherryTests.HostedSessions.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HostedSessionHostStore(defaults: defaults)
    let host = try store.add("devbox")
    _ = try store.add(" devbox ")
    #expect(store.hosts == [host])
    #expect(HostedSessionHostStore(defaults: defaults).hosts == [host])
    store.remove(host)
    #expect(HostedSessionHostStore(defaults: defaults).hosts.isEmpty)
}

@Test @MainActor func HostedSessionKeepsRemotePathsOutOfLocalLaunchAndRetainsIdentity() throws {
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/a/path/only/on/remote",
        executablePath: "/tmp/cherry tools/cherry"
    )
    let workspace = TerminalWorkspace(createInitialSession: false)
    let session = workspace.attachHostedSession(attachment, launchShell: false)
    #expect(session.workingDirectory == NSHomeDirectory())
    #expect(session.projectRoot == nil)
    session.ingestNativeWorkingDirectory("/remote/changed")
    #expect(session.workingDirectory == NSHomeDirectory())
    #expect(session.nativeExecLaunch.command == "'/tmp/cherry tools/cherry' '--host' 'devbox' '--expected-host-id' 'host-a' 'attach' 'session-123'")
    #expect(session.nativeExecLaunch.environment["CHERRY_STARTUP_COMMAND"] == nil)
    #expect(!session.hasRunningProcess())
    #expect(!workspace.canAddSplitPane(to: session.id))
    session.disconnectHostedSession()
    #expect(session.hostedAttachment == attachment)
    #expect(session.hostedAttachmentStatus == .disconnected(adapterExitCode: nil))
    let second = workspace.attachHostedSession(attachment, launchShell: false)
    #expect(second === session)
    #expect(workspace.sessions.count == 1)

    let otherHost = HostedSessionAttachment(
        host: try .ssh("other"), hostID: "host-b", sessionID: "session-123",
        name: "Other", remoteWorkingDirectory: "/remote", executablePath: "/tmp/cherry"
    )
    #expect(workspace.attachHostedSession(otherHost, launchShell: false) !== session)
}

@Test func HostedSessionExecEscapesSingleQuotesAndMetacharacters() throws {
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "id';$(touch bad)",
        name: "Editor", remoteWorkingDirectory: "/remote", executablePath: "/tmp/it's cherry"
    )
    #expect(attachment.execCommand == "'/tmp/it'\\''s cherry' '--host' 'devbox' '--expected-host-id' 'host-a' 'attach' 'id'\\'';$(touch bad)'")
}

@Test func HostedSessionClientPassesCreationAsArgumentsAndReadsJSON() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-host-client-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("cherry")
    let argumentsFile = root.appendingPathComponent("arguments.txt")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > '\(argumentsFile.path)'
    cat <<'JSON'
    \(hostedSessionFixture)
    JSON
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = HostedSessionClient(executableURL: executable)
    let name = "editor;$(touch should-not-exist)"
    let session = try await client.create(on: .ssh("devbox"), expectedHostID: "host-a", name: name, cwd: "/remote/path with spaces")
    #expect(session.id == "session-123")
    let arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(arguments == ["--host", "devbox", "--expected-host-id", "host-a", "new", "--name", name, "--cwd", "/remote/path with spaces"])

    _ = try await client.create(on: .ssh("devbox"), expectedHostID: "host-a", name: "Default directory", cwd: "")
    let defaultArguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(defaultArguments.suffix(2) == ["--cwd", "~"])

    try await client.terminate("session-123", on: .ssh("devbox"), expectedHostID: "host-a")
    let killArguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(killArguments == ["--host", "devbox", "--expected-host-id", "host-a", "kill", "session-123"])
    try await client.remove("session-123", on: .ssh("devbox"), expectedHostID: "host-a")
    let removeArguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(removeArguments == ["--host", "devbox", "--expected-host-id", "host-a", "remove", "session-123"])
}

@Test func HostedSessionClientReportsFailureAndBoundsHungCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-host-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("cherry")
    try "#!/bin/sh\nprintf 'SSH permission denied\\n' >&2\nexit 42\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = HostedSessionClient(executableURL: executable, timeout: 5)
    do {
        _ = try await client.list(on: .ssh("devbox"))
        Issue.record("A failed SSH command must not return a session list")
    } catch {
        #expect(error.localizedDescription.contains("SSH permission denied"))
    }

    try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: executable, atomically: true, encoding: .utf8)
    let hungClient = HostedSessionClient(executableURL: executable, timeout: 0.2)
    let start = Date()
    await #expect(throws: HostedSessionError.self) { try await hungClient.list(on: .local) }
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test @MainActor func HostedSessionNativeAdapterReconnectsWithoutCreatingOrKillingHostedSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-attach-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("cherry")
    let argumentLog = root.appendingPathComponent("arguments.txt")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$*" >> '\(argumentLog.path)'
    printf 'Attached test session\\r\\n'
    exec /bin/sleep 30
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let workspace = TerminalWorkspace(createInitialSession: false)
    let attachment = HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-a", sessionID: "session-123",
        name: "Editor", remoteWorkingDirectory: "/remote/project", executablePath: executable.path
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
        try? FileManager.default.removeItem(at: root)
    }

    func waitForLaunches(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let log = try? String(contentsOf: argumentLog, encoding: .utf8),
               log.split(separator: "\n").count >= count { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HostedSessionError.message("The native attach adapter did not launch")
    }

    try await waitForLaunches(1)
    #expect(session.usesNativePTYBackend)
    #expect(!session.hasRunningProcess())
    #expect(session.ghosttyBridge.terminalView.window === window)
    session.disconnectHostedSession()
    #expect(!session.isRunning)
    #expect(session.hostedAttachment == attachment)
    session.reconnectHostedSession()
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    try await waitForLaunches(2)
    // Reconnecting the same selected tab must replace its mounted view, not
    // just start an adapter whose Ghostty surface renders offscreen.
    #expect(session.ghosttyBridge.terminalView.window === window)
    #expect(session.ghosttyBridge.terminalView.isDescendant(of: container))
    session.ingestNativeChildExit(exitCode: 255)
    #expect(session.hostedAttachmentStatus == .disconnected(adapterExitCode: 255))
    #expect(session.hostedAttachment?.sessionID == "session-123")
    let invocations = try String(contentsOf: argumentLog, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(invocations == [
        "--host devbox --expected-host-id host-a attach session-123",
        "--host devbox --expected-host-id host-a attach session-123"
    ])
}

// Build the Rust helpers first with Scripts/build-host. This exercises the
// different Ghostty versions in the host snapshot producer and native renderer.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"))
@MainActor func HostedSessionRealHostSharesNativeGhosttyInputAndReconnectsBothScreens() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binaries = repository.appendingPathComponent("Host/target/debug")
    let cliURL = binaries.appendingPathComponent("cherry")
    let hostURL = binaries.appendingPathComponent("cherry-host")
    try #require(FileManager.default.isExecutableFile(atPath: cliURL.path), "Build the Rust cherry CLI first")
    try #require(FileManager.default.isExecutableFile(atPath: hostURL.path), "Build cherry-host first")
    let root = URL(fileURLWithPath: "/tmp/ch-vt-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    let socket = root.appendingPathComponent("host.sock")
    let adapter = root.appendingPathComponent("cherry")
    let ready = root.appendingPathComponent("ready")
    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    try "#!/bin/sh\nexec \(quote(cliURL.path)) --socket \(quote(socket.path)) \"$@\"\n"
        .write(to: adapter, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adapter.path)

    let host = Process()
    host.executableURL = hostURL
    host.arguments = ["serve", "--socket", socket.path]
    host.standardInput = FileHandle.nullDevice
    host.standardOutput = FileHandle.nullDevice
    host.standardError = FileHandle.standardError
    try host.run()
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
        if host.isRunning { host.terminate() }
        host.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }

    func waitFor(_ description: String, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HostedSessionError.message("Timed out waiting for \(description)")
    }
    try await waitFor("isolated host socket") { FileManager.default.fileExists(atPath: socket.path) }
    let client = HostedSessionClient(executableURL: adapter, timeout: 10)
    let initialList = try await client.list(on: .local)
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
    // Session creation uses the real CLI with an explicit command. The public
    // Swift client deliberately offers the simpler default-shell create flow.
    let creation = Process()
    let output = Pipe()
    creation.executableURL = adapter
    creation.arguments = [
        "--expected-host-id", initialList.hostID, "new", "--cwd", "/tmp", "--name", "Snapshot integration",
        "--", "/bin/sh", "-c", command
    ]
    creation.standardInput = FileHandle.nullDevice
    creation.standardOutput = output
    creation.standardError = FileHandle.standardError
    try creation.run()
    let createdJSON = output.fileHandleForReading.readDataToEndOfFile()
    creation.waitUntilExit()
    try #require(creation.terminationStatus == 0)
    let created = try JSONDecoder().decode(HostedSessionInfo.self, from: createdJSON)
    ownedChildPID = created.pid.map(Int32.init)
    try await waitFor("host application alternate screen") { FileManager.default.fileExists(atPath: ready.path) }

    let attachment = HostedSessionAttachment(
        host: .local, hostID: initialList.hostID, sessionID: created.id,
        name: created.name, remoteWorkingDirectory: created.cwd, executablePath: adapter.path
    )
    let session = workspace.attachHostedSession(attachment)
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    window.orderFrontRegardless()
    try await waitFor("native Ghostty to render the host snapshot") {
        session.ghosttyBridge.readNativeScreenText()?.contains("ALTERNATE_SNAPSHOT") == true
    }
    #expect(session.usesNativePTYBackend)
    let secondSession = secondWorkspace.attachHostedSession(attachment)
    secondContainer.configure(with: secondSession, colorScheme: .dark, allowsAutoFocus: false)
    secondWindow.orderFrontRegardless()
    try await waitFor("second native Ghostty to share the alternate screen") {
        secondSession.ghosttyBridge.readNativeScreenText()?.contains("ALTERNATE_SNAPSHOT") == true
    }
    #expect(secondSession !== session)
    #expect(secondSession.hostedAttachment == session.hostedAttachment)
    session.disconnectHostedSession()
    try await waitFor("second attachment to survive the first disconnect") {
        let current = try await client.list(on: .local).sessions.first { $0.id == created.id }
        return current?.attached == true && current?.pid == created.pid && current?.isRunning == true
    }
    session.reconnectHostedSession()
    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
    try await waitFor("native Ghostty to render the reattached snapshot") {
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
    let finalList = try await client.list(on: .local)
    #expect(finalList.sessions.count == 1)
    #expect(finalList.sessions.first?.id == created.id)
    #expect(finalList.sessions.first?.pid == created.pid)
    try await client.terminate(created.id, on: .local, expectedHostID: initialList.hostID)
    try await waitFor("host process termination") {
        try await client.list(on: .local).sessions.first?.isRunning == false
    }
    ownedChildPID = nil
}
