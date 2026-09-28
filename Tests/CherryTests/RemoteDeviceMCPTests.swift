import AppKit
import CherryControl
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// Cherry MCP for agents on another Mac (docs/specs/remote-devices.md, phase
// 4b): tokens, the device listener's handshake, scoping equal to a local
// agent's, the launch environment, the forward's scripts and the setup's
// commands. No test here reaches ssh, a daemon or an agent CLI: the setup's
// script runs against stand-in `claude` and `codex` in a private HOME.

/// A device's hosting for a device window in tests: inert (nothing
/// connects, never ssh; its tabs fail at once), so the window's tabs are
/// the device's (`CherryControlServer.isSession(_:in:onDevice:)`) as the
/// app's are.
@MainActor
func inertDeviceHosting(_ destination: String, name: String) -> PersistentHostSessions {
    let host = HostedSessionHost(sshDestination: destination)
    return PersistentHostSessions.remote(
        profile: .remote(host: host, displayName: name),
        installationID: UUID(),
        control: { RemoteDeviceStore.inertControl(host: host, reason: "No connection in tests.") },
        installationUnavailableReason: { "No connection in tests." },
        status: PersistentSessionsStatus(),
        instanceLock: nil,
        terminalColors: { nil }
    )
}

/// A control server as the app runs it (its default providers: the shared
/// ProjectWindowRegistry), with real windows registered there: a window of
/// the device's project (the caller's), one of another device's project,
/// and a This Mac window whose "Echo" command is a live `/bin/cat`.
@MainActor
private final class DeviceMCPHarness {
    let defaultsName = "CherryTests.RemoteMCP.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AgentSettings
    let deviceID = UUID()
    let otherDeviceID = UUID()
    let remotePath = "/Users/them/work/app"
    let deviceWorkspace: TerminalWorkspace
    let otherDeviceWorkspace: TerminalWorkspace
    let localWorkspace: TerminalWorkspace
    let localRoot: URL
    let socketURL: URL
    let server: CherryControlServer
    let tokens = RemoteMCPTokens(key: SymmetricKey(size: .bits256))
    let tab: TerminalSession
    /// The device's hosting its window runs tabs on (inert: nothing
    /// connects, its tabs fail at once), as the app gives a device window.
    let deviceHosting: PersistentHostSessions
    let otherDeviceHosting: PersistentHostSessions
    /// This Mac's port detection, as the server calls it.
    let localServices = RecordingLocalServices()
    private var windows: [(NSWindow, String)] = []

    static func inertHosting(_ destination: String, name: String) -> PersistentHostSessions {
        inertDeviceHosting(destination, name: name)
    }

    var deviceKey: String { ProjectLocation.remote(deviceID: deviceID, path: remotePath).key }
    var otherDeviceKey: String { ProjectLocation.remote(deviceID: otherDeviceID, path: remotePath).key }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        settings = AgentSettings(defaults: defaults)
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("ch-mcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        localRoot = URL(fileURLWithPath: created.path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return created.path }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let key = ProjectLocation.remote(deviceID: deviceID, path: remotePath).key
        let otherKey = ProjectLocation.remote(deviceID: otherDeviceID, path: remotePath).key
        _ = settings.addProject(path: localRoot.path)
        _ = settings.addProject(path: key)
        _ = settings.addProject(path: otherKey)
        try settings.upsertCommand(ProjectCommandDefinition(name: "Echo", command: "/bin/cat"), for: localRoot.path)
        // Device windows run their tabs on their device's hosting, as the app's do.
        deviceHosting = Self.inertHosting("studio-\(deviceID.uuidString.prefix(8))", name: "Studio")
        otherDeviceHosting = Self.inertHosting("mini-\(otherDeviceID.uuidString.prefix(8))", name: "Mini")
        deviceWorkspace = TerminalWorkspace(
            projectRoot: key, createInitialSession: false, launchBackend: .nativePTY,
            backendPolicy: .remote(deviceHosting, settings: { .native }, hostReconnects: nil)
        )
        otherDeviceWorkspace = TerminalWorkspace(
            projectRoot: otherKey, createInitialSession: false, launchBackend: .nativePTY,
            backendPolicy: .remote(otherDeviceHosting, settings: { .native }, hostReconnects: nil)
        )
        localWorkspace = TerminalWorkspace(projectRoot: localRoot.path, createInitialSession: false, launchBackend: .hostManaged)
        tab = deviceWorkspace.addSession(title: "Agent there")
        _ = deviceWorkspace.addSession(title: "Server there")
        _ = otherDeviceWorkspace.addSession(title: "Elsewhere")
        socketURL = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))/control.sock")
        let local = localWorkspace
        server = CherryControlServer(
            workspaceProvider: { local },
            socketURL: socketURL,
            agentSettings: settings,
            serviceDetector: localServices
        )
        server.mcpTokens = tokens
        tokens.newGeneration(tabID: tab.id, deviceID: deviceID)
        for (workspace, root) in [(localWorkspace, localRoot.path), (deviceWorkspace, key), (otherDeviceWorkspace, otherKey)] {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled, .closable], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            #expect(ProjectWindowRegistry.shared.register(
                window: window, projectRoot: root, workspace: workspace,
                noteStore: nil, todoStore: nil, chromeState: nil
            ))
            windows.append((window, root))
        }
        server.start()
    }

    var credentials: CherryControlCredentials {
        CherryControlCredentials(token: tokens.currentToken(tabID: tab.id, deviceID: deviceID) ?? "", processID: tab.id.uuidString)
    }

    /// This Mac's live command, started as a local agent would.
    func startLocalEcho() async throws -> TerminalSession {
        let response = try await send(
            .scoped(.init(projectRoot: localRoot.path, request: .startProcess(.init(processName: "Echo", kind: "command")))),
            credentials: nil
        )
        guard case .startProcess(let started)? = response.result else {
            throw HostedSessionError.message("Echo did not start: \(response)")
        }
        return try #require(localWorkspace.session(id: started.process.id))
    }

    /// A This Mac session's output, as a local caller reads it.
    func output(of session: TerminalSession) async throws -> String {
        let response = try await send(
            .scoped(.init(projectRoot: localRoot.path, request: .getProcessOutput(.init(processID: session.id.uuidString)))),
            credentials: nil
        )
        guard case .getProcessOutput(let output)? = response.result else { return "" }
        return output.lines.joined(separator: "\n")
    }

    func send(
        _ request: CherryControlRequest,
        to socket: URL? = nil,
        credentials: CherryControlCredentials?
    ) async throws -> CherryControlResponse {
        let url = socket ?? socketURL
        return try await Task.detached {
            try CherryControlClient(socketURL: url, credentials: credentials, controlMachine: "Laptop").send(request)
        }.value
    }

    /// Sends a raw request line (any JSON) and returns the answer.
    func sendLine(_ line: String, to socket: URL) async throws -> CherryControlResponse {
        try await Task.detached {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                socket.path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw HostedSessionError.message("connect failed") }
            let data = Data((line + "\n").utf8)
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
            var answer = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                answer.append(contentsOf: buffer.prefix(count))
                if answer.last == 0x0A { break }
            }
            return try JSONDecoder().decode(CherryControlResponse.self, from: answer)
        }.value
    }

    func processIDs(_ response: CherryControlResponse) -> Set<String>? {
        guard case .listProcesses(let result)? = response.result else { return nil }
        return Set(result.processes.map(\.id))
    }

    func stop() {
        server.stop()
        for (window, root) in windows { ProjectWindowRegistry.shared.unregister(window: window, projectRoot: root) }
        for workspace in [localWorkspace, deviceWorkspace, otherDeviceWorkspace] {
            workspace.sessions.forEach { $0.stop() }
            workspace.closeAllSessions(intent: .windowClosed)
        }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: localRoot)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
}

/// This Mac's port detection (lsof), recorded: never run for a caller on
/// another Mac.
final class RecordingLocalServices: ServiceDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(processes: [String], includeUnattributed: Bool)] = []
    var calls: [(processes: [String], includeUnattributed: Bool)] { lock.withLock { _calls } }

    func detectServices(processes: [InspectableProcess], includeUnattributed: Bool) async throws -> [ServiceRecord] {
        lock.withLock { _calls.append((processes.map(\.id), includeUnattributed)) }
        guard includeUnattributed else { return [] }
        return [ServiceRecord(
            processID: nil, processName: nil, kind: nil, pid: 4242, port: 5432, host: "127.0.0.1",
            url: "http://127.0.0.1:5432", attribution: .unattributed, protocolGuess: nil, readiness: .bound,
            lastSeenAt: Date(), commandName: nil, agentName: nil
        )]
    }
}

// MARK: - Tokens

@Test func RemoteDeviceMCPTokensAreTheTabsLaunchesAndKeptInPrivateFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ch-mcpkey-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let keyURL = directory.appendingPathComponent("mcp-token-key")
    let tokens = RemoteMCPTokens(keyURL: keyURL)
    let tab = UUID(), other = UUID(), device = UUID(), otherDevice = UUID()
    // No launch yet: no token is valid.
    #expect(tokens.currentToken(tabID: tab, deviceID: device) == nil)
    #expect(!tokens.isValid(String(repeating: "0", count: 64), tabID: tab, deviceID: device))
    let token = tokens.newGeneration(tabID: tab, deviceID: device)
    // 256 bits, hex.
    #expect(token.count == 64 && token.allSatisfy(\.isHexDigit))
    #expect(tokens.isValid(token, tabID: tab, deviceID: device))
    #expect(tokens.isValid(token.uppercased(), tabID: tab, deviceID: device))
    #expect(!tokens.isValid(token, tabID: other, deviceID: device))
    #expect(!tokens.isValid(token, tabID: tab, deviceID: otherDevice))
    #expect(!tokens.isValid(String(token.dropLast()), tabID: tab, deviceID: device))
    #expect(!tokens.isValid("", tabID: tab, deviceID: device))
    // The key and generation files: 0600; the next run (a relaunch) reads
    // them, so a restored tab's token is still valid.
    var status = stat()
    #expect(lstat(keyURL.path, &status) == 0)
    #expect(status.st_mode & 0o777 == 0o600)
    #expect(try Data(contentsOf: keyURL).count == 32)
    let generations = directory.appendingPathComponent("mcp-generations.json")
    #expect(lstat(generations.path, &status) == 0 && status.st_mode & 0o777 == 0o600)
    #expect(RemoteMCPTokens(keyURL: keyURL).isValid(token, tabID: tab, deviceID: device))
    // Another key: another token.
    #expect(!RemoteMCPTokens(key: SymmetricKey(size: .bits256)).isValid(token, tabID: tab, deviceID: device))
    // A key file others can read is not used.
    chmod(keyURL.path, 0o644)
    #expect(RemoteMCPTokens.loadOrCreateKey(at: keyURL) == nil)
    #expect(!RemoteMCPTokens(keyURL: keyURL).isValid(token, tabID: tab, deviceID: device))
}

/// (f) A leaked token stops working when the tab's program restarts: each
/// launch (its Create's spec) makes a new generation.
@Test @MainActor func RemoteDeviceMCPTokenChangesWhenTheTabsProgramRestarts() throws {
    let tokens = RemoteMCPTokens(key: SymmetricKey(size: .bits256))
    let deviceID = UUID(), tab = UUID()
    let mcp = RemoteMCPLaunch(deviceID: deviceID, socketPath: "/var/folders/x/T/cherry-mcp-1/control.sock", helperPath: nil, controlMachine: "Laptop", tokens: tokens)
    let configuration = ShellProcessController.Configuration(
        shellPath: "/bin/zsh", workingDirectory: "/Users/them/app", processID: tab.uuidString,
        term: "xterm-ghostty", initialSize: TerminalViewportSize(columns: 80, rows: 24)
    )
    let first = try #require(RemoteLaunchSpec.make(for: configuration, device: .init(mcp: mcp), localeEnvironment: [:]).environment["CHERRY_MCP_TOKEN"])
    #expect(tokens.isValid(first, tabID: tab, deviceID: deviceID))
    // Restarted: a new Create, a new token; the old one is refused.
    let second = try #require(RemoteLaunchSpec.make(for: configuration, device: .init(mcp: mcp), localeEnvironment: [:]).environment["CHERRY_MCP_TOKEN"])
    #expect(second != first)
    #expect(tokens.isValid(second, tabID: tab, deviceID: deviceID))
    #expect(!tokens.isValid(first, tabID: tab, deviceID: deviceID))
}

// MARK: - The handshake and the boundary

@Test @MainActor func RemoteDeviceMCPListenerRefusesCallersWithoutAValidTokenOfAnOpenTab() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    #expect(listener.deletingLastPathComponent() == harness.socketURL.deletingLastPathComponent())
    var status = stat()
    #expect(lstat(listener.path, &status) == 0 && status.st_mode & S_IFMT == S_IFSOCK && status.st_mode & 0o077 == 0)
    let tabID = harness.tab.id.uuidString
    func refused(_ credentials: CherryControlCredentials?) async throws -> CherryControlError? {
        try await harness.send(.listProcesses(.init()), to: listener, credentials: credentials).error
    }
    // No token: refused (never identified by its process).
    #expect(try await refused(nil)?.code == "unauthorized")
    // A wrong token, another tab's id, another device's token, a tab id that is no UUID.
    #expect(try await refused(.init(token: String(repeating: "0", count: 64), processID: tabID))?.code == "unauthorized")
    let other = try #require(harness.deviceWorkspace.sessions.first { $0.id != harness.tab.id })
    #expect(try await refused(.init(token: harness.credentials.token, processID: other.id.uuidString))?.code == "unauthorized")
    let otherDeviceToken = harness.tokens.token(tabID: harness.tab.id, deviceID: harness.otherDeviceID, generation: "x")
    #expect(try await refused(.init(token: otherDeviceToken, processID: tabID))?.code == "unauthorized")
    #expect(try await refused(.init(token: "x", processID: "not-a-tab"))?.code == "unauthorized")
    // A This Mac tab's id with a token made for it: not a device's tab.
    let here = try await harness.startLocalEcho()
    let hereToken = harness.tokens.newGeneration(tabID: here.id, deviceID: harness.deviceID)
    #expect(try await refused(.init(token: hereToken, processID: here.id.uuidString))?.code == "unauthorized")
    // The tab's own token: its window's processes.
    let response = try await harness.send(.listProcesses(.init()), to: listener, credentials: harness.credentials)
    #expect(response.error == nil)
    #expect(harness.processIDs(response) == Set(harness.deviceWorkspace.sessions.map(\.id.uuidString)))
    // Another device's listener refuses this device's token.
    let otherListener = try harness.server.addDeviceListener(deviceID: harness.otherDeviceID)
    #expect(try await harness.send(.listProcesses(.init()), to: otherListener, credentials: harness.credentials).error?.code == "unauthorized")
    // Closing the tab revokes its token.
    let valid = harness.credentials
    harness.deviceWorkspace.close(harness.tab, allowEmptyWorkspace: true)
    #expect(try await refused(valid)?.code == "unauthorized")
    harness.server.removeDeviceListener(deviceID: harness.deviceID)
    #expect(!FileManager.default.fileExists(atPath: listener.path))
}

/// (a) `..` in a project root never leaves the caller's Mac: refused, and
/// This Mac's live command gets no spawn and no input.
@Test @MainActor func RemoteDeviceMCPDotDotInAProjectRootIsRefusedAndReachesNoThisMacWindow() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let echo = try await harness.startLocalEcho()
    // It is live: a local caller's input reaches it.
    let local = try await harness.send(
        .scoped(.init(projectRoot: harness.localRoot.path, request: .sendProcessInput(.init(
            processID: echo.id.uuidString, text: "local-ok\n", rawBase64: nil, waitMilliseconds: 300, lineLimit: 20
        )))),
        credentials: nil
    )
    #expect(local.error == nil, "\(local)")
    #expect(try await harness.output(of: echo).contains("local-ok"))
    let sessionsBefore = harness.localWorkspace.sessions.map(\.id)
    let escapes = [
        String(repeating: "/..", count: 40) + harness.localRoot.path,
        "/Users/them/work/app/" + String(repeating: "../", count: 40) + harness.localRoot.path.dropFirst(),
        harness.deviceKey + String(repeating: "/..", count: 40) + harness.localRoot.path,
        "/./" + harness.localRoot.path.dropFirst(),
    ]
    for root in escapes {
        let spawn = try await harness.send(
            .scoped(.init(projectRoot: root, request: .spawnProcess(.init(kind: "terminal", title: "escaped", text: "spawned-here\n")))),
            to: listener, credentials: harness.credentials
        )
        #expect(spawn.error?.code == "invalid_project_root", "\(root): \(spawn)")
        let input = try await harness.send(
            .scoped(.init(projectRoot: root, request: .sendProcessInput(.init(processName: "Echo", text: "escaped-input\n")))),
            to: listener, credentials: harness.credentials
        )
        #expect(input.error?.code == "invalid_project_root", "\(root): \(input)")
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.localWorkspace.sessions.map(\.id) == sessionsBefore)
    let echoed = try await harness.output(of: echo)
    #expect(echoed.contains("local-ok"))
    #expect(!echoed.contains("escaped-input") && !echoed.contains("spawned-here"))
}

/// (b) A scoped request inside a scoped one, as one JSON line: refused.
@Test @MainActor func RemoteDeviceMCPNestedScopedRequestIsRefused() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    _ = try await harness.startLocalEcho()
    let sessionsBefore = harness.localWorkspace.sessions.map(\.id)
    let inner = CherryControlRequest.scoped(.init(
        projectRoot: harness.localRoot.path,
        request: .spawnProcess(.init(kind: "terminal", title: "nested"))
    ))
    let envelope = CherryControlEnvelope(
        cherryAuth: harness.credentials,
        request: .scoped(.init(projectRoot: harness.remotePath, request: inner))
    )
    let line = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    let answer = try await harness.sendLine(line, to: listener)
    #expect(answer.error?.code == "invalid_request", "\(answer)")
    // An unscoped request carrying a scoped one is refused too.
    let bare = CherryControlEnvelope(cherryAuth: harness.credentials, request: inner)
    let bareAnswer = try await harness.sendLine(String(decoding: try JSONEncoder().encode(bare), as: UTF8.self), to: listener)
    #expect(bareAnswer.error != nil, "\(bareAnswer)")
    #expect(harness.localWorkspace.sessions.map(\.id) == sessionsBefore)
}

/// (c) A This Mac tab's process id, its window registered where the server
/// looks: not found for a caller on another Mac, for every tool that takes
/// one.
@Test @MainActor func RemoteDeviceMCPThisMacProcessIDsAreNotFoundForARemoteCaller() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let echo = try await harness.startLocalEcho()
    let id = echo.id.uuidString
    // A local caller in the device window finds it (the window is registered).
    let localView = try await harness.send(
        .scoped(.init(projectRoot: harness.deviceKey, request: .getProcessStatus(.init(processID: id, processName: nil)))),
        credentials: nil
    )
    #expect(localView.error == nil, "\(localView)")
    let otherDeviceTab = try #require(harness.otherDeviceWorkspace.sessions.first).id.uuidString
    let requests: [CherryControlRequest] = [
        .getProcessStatus(.init(processID: id, processName: nil)),
        .getProcessOutput(.init(processID: id)),
        .sendProcessInput(.init(processID: id, text: "remote-input\n")),
        .sendInput(.init(terminalID: id, text: "remote-send-input\n", rawBase64: nil, waitMilliseconds: nil, lineLimit: nil)),
        .restartProcess(.init(processID: id)),
        .closeProcess(.init(processID: id)),
        .stopProcess(.init(processID: id)),
        .getProcessPorts(.init(processID: id)),
        .getTerminalOutput(.init(terminalID: id, startLine: nil, lineLimit: nil)),
        .getProcessStatus(.init(processID: otherDeviceTab, processName: nil)),
    ]
    for request in requests {
        let answer = try await harness.send(request, to: listener, credentials: harness.credentials)
        #expect(["terminal_not_found", "process_not_found"].contains(answer.error?.code), "\(request): \(answer)")
    }
    // A link to it resolves to nothing.
    let link = CherryDeepLink(projectRoot: harness.localRoot.path, kind: .terminal, targetID: id).absoluteString
    let resolved = try await harness.send(.resolveLink(.init(link: link, includeOutput: true)), to: listener, credentials: harness.credentials)
    guard case .resolveLink(let result)? = resolved.result else {
        Issue.record("Expected resolveLink, got \(resolved)")
        return
    }
    #expect(!result.found && result.output == nil && result.process == nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(echo.isRunning)
    let echoed = try await harness.output(of: echo)
    #expect(!echoed.contains("remote-input") && !echoed.contains("remote-send-input"))
}

/// (d) Another device's key, or a This Mac root, as a project: refused.
@Test @MainActor func RemoteDeviceMCPAnotherMacsProjectIsRefused() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let before = harness.otherDeviceWorkspace.sessions.map(\.id)
    for request: CherryControlRequest in [
        .scoped(.init(projectRoot: harness.otherDeviceKey, request: .listProcesses(.init()))),
        .scoped(.init(projectRoot: harness.otherDeviceKey, request: .spawnProcess(.init(kind: "terminal", title: "x")))),
        .openProject(.init(projectRoot: harness.otherDeviceKey)),
    ] {
        let answer = try await harness.send(request, to: listener, credentials: harness.credentials)
        #expect(answer.error?.code == "outside_caller_mac", "\(request): \(answer)")
    }
    // This Mac's path is a path on the caller's Mac, which is not open.
    let local = try await harness.send(
        .scoped(.init(projectRoot: harness.localRoot.path, request: .listProcesses(.init()))), to: listener, credentials: harness.credentials
    )
    #expect(local.error?.code == "project_unavailable", "\(local)")
    let open = try await harness.send(.openProject(.init(projectRoot: harness.localRoot.path)), to: listener, credentials: harness.credentials)
    #expect(open.error?.code == "project_not_found", "\(open)")
    // Its own project by path and by key: its window.
    let byPath = try await harness.send(
        .scoped(.init(projectRoot: harness.remotePath, request: .listProcesses(.init()))), to: listener, credentials: harness.credentials
    )
    #expect(harness.processIDs(byPath) == Set(harness.deviceWorkspace.sessions.map(\.id.uuidString)))
    let byKey = try await harness.send(
        .scoped(.init(projectRoot: harness.deviceKey, request: .listProcesses(.init()))), to: listener, credentials: harness.credentials
    )
    #expect(harness.processIDs(byKey) == Set(harness.deviceWorkspace.sessions.map(\.id.uuidString)))
    // A folder inside it: its window too.
    let inside = try await harness.send(
        .scoped(.init(projectRoot: harness.remotePath + "/Sources", request: .getProjectStatus)), to: listener, credentials: harness.credentials
    )
    guard case .getProjectStatus(let status)? = inside.result else {
        Issue.record("Expected project status, got \(inside)")
        return
    }
    #expect(status.projectRoot == harness.deviceKey)
    #expect(harness.otherDeviceWorkspace.sessions.map(\.id) == before)
}

/// (e) Listing tools list only the caller's Mac.
@Test @MainActor func RemoteDeviceMCPListingsShowOnlyTheCallersMac() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let echo = try await harness.startLocalEcho()
    let deviceIDs = Set(harness.deviceWorkspace.sessions.map(\.id.uuidString))
    // Projects: only its Mac's (This Mac's and the other device's are
    // configured and open, and a local caller sees them).
    let projects = try await harness.send(.listProjects, to: listener, credentials: harness.credentials)
    guard case .listProjects(let listed)? = projects.result else {
        Issue.record("Expected listProjects, got \(projects)")
        return
    }
    #expect(listed.projects.map(\.root) == [harness.deviceKey])
    #expect(listed.activeProjectRoot == harness.deviceKey)
    let localProjects = try await harness.send(.listProjects, credentials: nil)
    guard case .listProjects(let all)? = localProjects.result else { return }
    #expect(all.projects.count == 3 && all.projects.map(\.root).contains(harness.otherDeviceKey))
    #expect(all.projects.contains { !ProjectLocation.isRemoteKey($0.root) })
    // Processes, terminals and services: its window's only.
    #expect(harness.processIDs(try await harness.send(.listProcesses(.init()), to: listener, credentials: harness.credentials)) == deviceIDs)
    let terminals = try await harness.send(.listTerminals, to: listener, credentials: harness.credentials)
    guard case .listTerminals(let listedTerminals)? = terminals.result else {
        Issue.record("Expected listTerminals, got \(terminals)")
        return
    }
    #expect(Set(listedTerminals.terminals.map(\.id)) == deviceIDs)
    #expect(!listedTerminals.terminals.map(\.id).contains(echo.id.uuidString))
    let status = try await harness.send(.getProjectStatus, to: listener, credentials: harness.credentials)
    guard case .getProjectStatus(let project)? = status.result else { return }
    #expect(project.projectRoot == harness.deviceKey)
}

@Test @MainActor func RemoteDeviceMCPEnvelopeIsOneLineAndAPlainRequestStaysPlain() throws {
    let credentials = CherryControlCredentials(token: "ab", processID: UUID().uuidString)
    let data = try JSONEncoder().encode(CherryControlEnvelope(cherryAuth: credentials, request: .listProjects))
    #expect(!data.contains(0x0A))
    let decoded = try CherryControlEnvelope.decode(data)
    #expect(decoded.credentials == credentials)
    #expect(decoded.request == .listProjects)
    let plain = try CherryControlEnvelope.decode(JSONEncoder().encode(CherryControlRequest.getProjectStatus))
    #expect(plain.credentials == nil && plain.request == .getProjectStatus)
    // From the environment: both the token and the tab id, or nothing.
    let id = UUID().uuidString
    #expect(CherryControlCredentials.fromEnvironment(["CHERRY_MCP_TOKEN": "t", "CHERRY_PROCESS_ID": id]) == .init(token: "t", processID: id))
    #expect(CherryControlCredentials.fromEnvironment(["CHERRY_MCP_TOKEN": "t", "CHERRY_AGENT_ID": id]) == .init(token: "t", processID: id))
    #expect(CherryControlCredentials.fromEnvironment(["CHERRY_PROCESS_ID": id]) == nil)
    #expect(CherryControlCredentials.fromEnvironment(["CHERRY_MCP_TOKEN": " ", "CHERRY_PROCESS_ID": id]) == nil)
}

@Test func RemoteDeviceMCPClientSaysCherryOnTheMacIsNotReachable() throws {
    let socket = URL(fileURLWithPath: "/tmp/cherry-nowhere-\(UUID().uuidString.prefix(8))/control.sock")
    let credentials = CherryControlCredentials(token: "t", processID: UUID().uuidString)
    do {
        _ = try CherryControlClient(socketURL: socket, credentials: credentials, controlMachine: "Laptop").send(.listProjects)
        Issue.record("Expected an error")
    } catch let error as CherryControlError {
        #expect(error.code == "cherry_unreachable")
        #expect(error.message.hasPrefix("Cherry on Laptop is not reachable"))
    }
    // A local caller keeps its message.
    do {
        _ = try CherryControlClient(socketURL: socket, credentials: nil).send(.listProjects)
        Issue.record("Expected an error")
    } catch let error as CherryControlError {
        #expect(error.code == "cherry_unavailable")
    }
}

// MARK: - The launch

@Test @MainActor func RemoteDeviceMCPLaunchSpecCarriesTheForwardedSocketAndTheTabsToken() throws {
    let tokens = RemoteMCPTokens(key: SymmetricKey(size: .bits256))
    let deviceID = UUID(), installation = UUID(), tab = UUID()
    let temporary = "/var/folders/8s/f8v56gzs3232x21hn7nngwmc0000gn/T/"
    let socket = try #require(RemoteMCPPaths.remoteSocket(temporaryDirectory: temporary, installationID: installation, deviceID: deviceID))
    // In the account's own temporary directory, never the shared /tmp, and
    // short enough for a Unix socket.
    #expect(socket.hasPrefix(temporary + "cherry-mcp-") && socket.utf8.count <= 103)
    #expect(socket != RemoteMCPPaths.remoteSocket(temporaryDirectory: temporary, installationID: UUID(), deviceID: deviceID))
    // Not usable: a relative, `..` or too long directory, or none.
    #expect(RemoteMCPPaths.remoteSocket(temporaryDirectory: nil, installationID: installation, deviceID: deviceID) == nil)
    #expect(RemoteMCPPaths.remoteSocket(temporaryDirectory: "T/", installationID: installation, deviceID: deviceID) == nil)
    #expect(RemoteMCPPaths.remoteSocket(temporaryDirectory: "/var/../tmp/", installationID: installation, deviceID: deviceID) == nil)
    #expect(RemoteMCPPaths.remoteSocket(temporaryDirectory: "/" + String(repeating: "x", count: 70), installationID: installation, deviceID: deviceID) == nil)
    let mcp = RemoteMCPLaunch(
        deviceID: deviceID, socketPath: socket,
        helperPath: "/Users/them/Library/Application Support/cherry-host/bin/b1/CherryMCP",
        controlMachine: "Laptop", tokens: tokens
    )
    // This Mac's own values never travel.
    let configuration = ShellProcessController.Configuration(
        shellPath: "/bin/zsh", workingDirectory: "/Users/them/app",
        projectRoot: ProjectLocation.remote(deviceID: deviceID, path: "/Users/them/app").key,
        processID: tab.uuidString,
        environment: [
            "CHERRY_CONTROL_SOCKET": "/tmp/cherry-501/x/control.sock",
            "CHERRY_MCP_TOKEN": "local", "CHERRY_MCP_HELPER": "/Applications/Cherry.app/x", "CHERRY_CONTROL_MACHINE": "x",
        ],
        term: "xterm-ghostty", initialSize: TerminalViewportSize(columns: 80, rows: 24)
    )
    let spec = RemoteLaunchSpec.make(for: configuration, device: .init(mcp: mcp), localeEnvironment: [:])
    #expect(spec.environment["CHERRY_CONTROL_SOCKET"] == socket)
    #expect(spec.environment["CHERRY_MCP_TOKEN"] == tokens.currentToken(tabID: tab, deviceID: deviceID))
    #expect(spec.environment["CHERRY_MCP_HELPER"] == "/Users/them/Library/Application Support/cherry-host/bin/b1/CherryMCP")
    #expect(spec.environment["CHERRY_CONTROL_MACHINE"] == "Laptop")
    #expect(spec.environment["CHERRY_PROCESS_ID"] == tab.uuidString)
    #expect(spec.environment["CHERRY_PROJECT_ROOT"] == "/Users/them/app")
    // Without Cherry MCP (a device store with no installation id): none of it.
    let plain = RemoteLaunchSpec.make(for: configuration, localeEnvironment: [:])
    for key in ["CHERRY_CONTROL_SOCKET", "CHERRY_MCP_TOKEN", "CHERRY_MCP_HELPER", "CHERRY_CONTROL_MACHINE"] {
        #expect(plain.environment[key] == nil)
    }
    // The helper there is the install's.
    #expect(RemoteMCPPaths.helperPath(remoteHostPath: "~/Library/Application Support/cherry-host/bin/b1/cherry-host", homeDirectory: "/Users/them")
        == "/Users/them/Library/Application Support/cherry-host/bin/b1/CherryMCP")
    #expect(RemoteMCPPaths.helperPath(remoteHostPath: "/usr/local/bin/cherry-host", homeDirectory: "/Users/them") == nil)
}

@Test @MainActor func RemoteDeviceMCPDeviceStoreGivesItsTabsCherryMCP() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ch-mcpstore-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "CherryTests.RemoteMCPStore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let installation = UUID()
    let store = RemoteDeviceStore(
        fileURL: directory.appendingPathComponent("devices.json"),
        hostStore: HostedSessionHostStore(defaults: defaults),
        installationID: { installation },
        registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
        remoteHostPaths: HostedRemoteHostPaths()
    )
    let device = try #require(try store.add(
        name: "Studio", sshDestination: "studio",
        remoteHostPath: "~/Library/Application Support/cherry-host/bin/b1/cherry-host",
        homeDirectory: "/Users/them", installedBuild: "b1"
    ))
    // Its per-user temporary directory not known yet: no Cherry MCP (never
    // a socket in the shared /tmp).
    #expect(store.launchDevice(id: device.id)?.mcp == nil)
    store.update(device.id) { $0.userTemporaryDirectory = "/var/folders/ab/cd/T/" }
    let launch = try #require(store.launchDevice(id: device.id)?.mcp)
    #expect(launch.socketPath == RemoteMCPPaths.remoteSocket(temporaryDirectory: "/var/folders/ab/cd/T/", installationID: installation, deviceID: device.id))
    // No resources recorded: no CherryMCP there to name.
    #expect(launch.helperPath == nil)
}

// MARK: - The forward's scripts

@Test func RemoteDeviceMCPForwardPreparesAPrivateDirectoryThere() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("ch-mcpdir-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    func run(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text
    }
    // The account's per-user temporary directory, as the script finds it.
    let temporary = try #require(run("getconf DARWIN_USER_TEMP_DIR\n").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    let name = "cherry-mcp-test-\(UUID().uuidString.prefix(8))"
    let directory = (temporary.hasSuffix("/") ? String(temporary.dropLast()) : temporary) + "/" + name
    defer { try? FileManager.default.removeItem(atPath: directory) }
    // Made 0700 there, reported; a socket a master that died left is removed.
    let first = try run(RemoteMCPForwards.prepareScript(directoryName: name))
    #expect(first.contains("prepared=1") && first.contains("usertmp=\(temporary)\n") && first.contains("dir=\(directory)\n"), "\(first)")
    var status = stat()
    #expect(lstat(directory, &status) == 0 && status.st_mode & 0o777 == 0o700)
    FileManager.default.createFile(atPath: directory + "/control.sock", contents: Data())
    chmod(directory, 0o755)
    #expect(try run(RemoteMCPForwards.prepareScript(directoryName: name)).contains("prepared=1"))
    #expect(!FileManager.default.fileExists(atPath: directory + "/control.sock"))
    #expect(lstat(directory, &status) == 0 && status.st_mode & 0o777 == 0o700)
    // A link in its place (someone else's folder): refused.
    let linkName = "cherry-mcp-link-\(UUID().uuidString.prefix(8))"
    let link = (temporary.hasSuffix("/") ? String(temporary.dropLast()) : temporary) + "/" + linkName
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: base.path)
    defer { try? FileManager.default.removeItem(atPath: link) }
    let refused = try run(RemoteMCPForwards.prepareScript(directoryName: linkName))
    #expect(!refused.contains("prepared=1") && refused.contains("error="))
    // Cleanup removes the socket and the folder.
    FileManager.default.createFile(atPath: directory + "/control.sock", contents: Data())
    _ = try run(RemoteMCPForwards.cleanupScript(directoryName: name))
    #expect(!FileManager.default.fileExists(atPath: directory))
    // The forward's arguments, and ssh's refusal told apart.
    #expect(RemoteMCPForwards.commandArguments("forward", remote: "/tmp/r.sock", local: "/tmp/l.sock", controlPath: "/c%", destination: "studio")
        == ["-o", "ControlPath=/c%%", "-o", "BatchMode=yes", "-O", "forward", "-R", "/tmp/r.sock:/tmp/l.sock", "--", "studio"])
    #expect(RemoteMCPForwards.isRefusal("mux_client_forward: forwarding request failed: remote port forwarding failed for listen path /tmp/x"))
    #expect(!RemoteMCPForwards.isRefusal("Control socket connect(/x): No such file or directory"))
    #expect(RemoteMCPForwardError.refused(machine: "Studio", reason: "r").localizedDescription.contains("AllowStreamLocalForwarding"))
    #expect(RemoteMCPForwardError.refused(machine: "Studio", reason: "r").localizedDescription.contains("AllowTcpForwarding"))
}

// MARK: - Set Up Cherry MCP

@Test func RemoteDeviceMCPSetupRegistersTheLauncherIdempotentlyAndRemovesIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ch-mcpsetup-\(UUID().uuidString.prefix(8))")
    let home = root.appendingPathComponent("home")
    let stubs = root.appendingPathComponent("stubs")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Stand-in agent CLIs: each logs its arguments and keeps a registry;
    // codex's add and remove also write its config.toml as Codex does.
    // (g) The config is a link into a dotfiles folder, as many keep it.
    let codexConfig = home.appendingPathComponent(".codex/config.toml")
    let dotfiles = root.appendingPathComponent("dotfiles")
    let realConfig = dotfiles.appendingPathComponent("codex-config.toml")
    try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    try "model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"other\"\n".write(to: realConfig, atomically: true, encoding: .utf8)
    chmod(realConfig.path, 0o640)
    try FileManager.default.createSymbolicLink(at: codexConfig, withDestinationURL: realConfig)
    for tool in ["claude", "codex"] {
        let config = tool == "codex" ? """
          add) printf '\\n[mcp_servers.%s]\\ncommand = "%s"\\nenv_vars = [\\n  "OLD",\\n]\\nargs = []\\n' "$3" "$5" >> "$HOME/.codex/config.toml" ;;
        """ : ""
        let unconfig = tool == "codex" ? """
        /usr/bin/awk -v t="[mcp_servers.$3]" '/^\\[/ { skip = ($0 == t) } !skip { print }' "$HOME/.codex/config.toml" > "$HOME/.codex/x" && cat "$HOME/.codex/x" > "$HOME/.codex/config.toml" && rm "$HOME/.codex/x";
        """ : ""
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(root.path)/\(tool).log'
        case "$2" in
          add) printf '%s\\n' "$*" > '\(root.path)/\(tool).registered' ;;
          remove) [ -f '\(root.path)/\(tool).registered' ] || { echo "No MCP server named cherry" >&2; exit 1; }; rm -f '\(root.path)/\(tool).registered'; \(unconfig) ;;
        esac
        case "$2" in
        \(config)
        esac
        exit 0
        """
        let url = stubs.appendingPathComponent(tool)
        try script.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }
    // The login shell only reports the stubs' PATH (never the real CLIs).
    let loginShell = stubs.appendingPathComponent("login-shell")
    try "#!/bin/sh\nprintf '%s' '\(stubs.path):/usr/bin:/bin'\n".write(to: loginShell, atomically: true, encoding: .utf8)
    chmod(loginShell.path, 0o755)
    let helper = root.appendingPathComponent("CherryMCP")
    try "#!/bin/sh\n[ \"$1\" = --version ] && { echo '{\"name\":\"CherryMCP\"}'; exit 0; }\necho \"ran $*\"\n".write(to: helper, atomically: true, encoding: .utf8)
    chmod(helper.path, 0o755)
    func run(_ mode: RemoteMCPSetup.Mode) throws -> RemoteMCPSetup.Report {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        process.environment = ["HOME": home.path, "SHELL": loginShell.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(RemoteMCPSetup.script(mode: mode, name: "cherry", helperPath: helper.path).utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let fields = try #require(RemoteHostInstaller.fields(.init(status: process.terminationStatus, standardOutput: text, standardError: "")))
        return RemoteMCPSetup.Report(fields: fields)
    }
    let launcher = home.appendingPathComponent(RemoteMCPPaths.launcherRelativePath).path
    // The check reads no agent configuration and changes nothing.
    let checked = try run(.check)
    #expect(checked.claude == stubs.appendingPathComponent("claude").path)
    #expect(checked.codex == stubs.appendingPathComponent("codex").path)
    #expect(checked.helperVersion == "{\"name\":\"CherryMCP\"}")
    #expect(!checked.launcherInstalled)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("claude.log").path))
    func inode(_ url: URL) -> ino_t {
        var status = stat()
        return lstat(url.path, &status) == 0 ? status.st_ino : 0
    }
    let inodeBefore = inode(realConfig)
    // Set Up: the launcher, then each CLI's add with it; twice gives the same.
    for _ in 0..<2 {
        let report = try run(.install)
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.claudeResult == "ok" && report.codexResult == "ok" && report.launcherInstalled)
        #expect(try String(contentsOf: root.appendingPathComponent("claude.registered"), encoding: .utf8)
            == "mcp add --scope user --transport stdio cherry -- \(launcher)\n")
        #expect(try String(contentsOf: root.appendingPathComponent("codex.registered"), encoding: .utf8)
            == "mcp add cherry -- \(launcher)\n")
    }
    #expect(FileManager.default.isExecutableFile(atPath: launcher))
    // Codex's table got the variables it must pass, once; the rest is kept.
    let envVars = "env_vars = [\"CHERRY_MCP_TOKEN\", \"CHERRY_CONTROL_SOCKET\", \"CHERRY_PROCESS_ID\", \"CHERRY_AGENT_ID\", \"CHERRY_PROJECT_ROOT\", \"CHERRY_MCP_HELPER\", \"CHERRY_CONTROL_MACHINE\"]"
    let config = try String(contentsOf: codexConfig, encoding: .utf8)
    // Codex's own multi-line env_vars is replaced whole; the keys after it
    // stay.
    #expect(config.contains("[mcp_servers.cherry]\n\(envVars)\ncommand = \"\(launcher)\"\nargs = []\n"), "\(config)")
    #expect(config.components(separatedBy: "env_vars").count == 2)
    #expect(!config.contains("OLD"))
    // Replaced atomically (a new file renamed over it), through the link:
    // the link stays a link to the same file, which keeps its mode, and no
    // temporary file is left.
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: codexConfig.path) == realConfig.path)
    #expect(inode(realConfig) != inodeBefore)
    #expect((try FileManager.default.attributesOfItem(atPath: realConfig.path)[.posixPermissions] as? Int) == 0o640)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dotfiles.path) == ["codex-config.toml"])
    #expect(config.hasPrefix("model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"other\"\n"))
    // The launcher runs the tab's CherryMCP (CHERRY_MCP_HELPER), else says why.
    func launch(_ environment: [String: String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = ["--call", "x"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }
    #expect(try launch(["HOME": home.path, "CHERRY_MCP_HELPER": helper.path]) == (0, "ran --call x\n"))
    let (status, message) = try launch(["HOME": home.path])
    #expect(status == 1 && message.contains("no CherryMCP on this Mac"))
    // Without CHERRY_MCP_HELPER: the newest installed build by its build
    // id, not the name that sorts last.
    for build in ["20250101000000.b", "20200101000000.a", "zzz-dev"] {
        let installed = home.appendingPathComponent("Library/Application Support/cherry-host/bin/\(build)")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let copy = installed.appendingPathComponent("CherryMCP")
        try "#!/bin/sh\necho \"\(build) $*\"\n".write(to: copy, atomically: true, encoding: .utf8)
        chmod(copy.path, 0o755)
    }
    #expect(try launch(["HOME": home.path]) == (0, "20250101000000.b --call x\n"))
    // Remove: both registrations go.
    let removed = try run(.remove)
    #expect(removed.claudeResult == "ok" && removed.codexResult == "ok")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("claude.registered").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("codex.registered").path))
    #expect(try String(contentsOf: codexConfig, encoding: .utf8).contains("[mcp_servers.other]"))
    #expect(!(try String(contentsOf: codexConfig, encoding: .utf8)).contains("mcp_servers.cherry"))
    let claudeLog = try String(contentsOf: root.appendingPathComponent("claude.log"), encoding: .utf8)
    #expect(claudeLog.components(separatedBy: "\n").filter { $0.hasPrefix("mcp add") }.count == 2)
    // The sheet shows exactly these commands.
    #expect(RemoteMCPSetup.commands(mode: .install, name: "cherry").contains(
        "claude mcp remove --scope user cherry; claude mcp add --scope user --transport stdio cherry -- \"$HOME/Library/Application Support/cherry-host/mcp/cherry-mcp\""
    ))
}

@Test @MainActor func RemoteDeviceMCPSetupIsInTheDeviceMenu() throws {
    let device = RemoteDevice(name: "Studio", sshDestination: "studio")
    let item = TitlebarProjectMenuModel.deviceItem(
        .init(device: device, state: RemoteDeviceConnectionState(control: .connected, sessionCount: 0, lastSeen: nil), sessions: []),
        currentProjectKey: nil, now: Date()
    )
    let actions = (item.children ?? []).compactMap { entry -> TitlebarProjectMenuModel.Item? in
        if case .item(let item) = entry { return item }
        return nil
    }
    let setUp = try #require(actions.first { $0.action == .setUpDeviceMCP(device.id) })
    #expect(setUp.title == "Set Up Cherry MCP on Studio…")
    #expect(setUp.isEnabled)
}

// MARK: - Second review: sessions of other hosts, local scans, the directory there, request limits

/// A session of This Mac, or of another SSH host, attached into the
/// device's window (Persistent Sessions): not on the caller's Mac, so it
/// is neither listed nor found by id or name, and its token is refused. A
/// session of the device's own host attached there is its Mac's.
@Test @MainActor func RemoteDeviceMCPSessionsOfAnotherHostInTheDevicesWindowAreNotItsMacs() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    func attachment(_ host: HostedSessionHost, _ id: String, _ name: String) -> HostedSessionAttachment {
        HostedSessionAttachment(
            host: host, hostID: "host-\(id)", sessionID: id, name: name,
            remoteWorkingDirectory: "/Users/me", executablePath: "/nonexistent/cherry"
        )
    }
    let deviceTabs = Set(harness.deviceWorkspace.sessions.map(\.id.uuidString))
    let thisMac = harness.deviceWorkspace.attachHostedSession(attachment(.local, "here", "Here Shell"), launchShell: false)
    let otherHost = harness.deviceWorkspace.attachHostedSession(
        attachment(try HostedSessionHost.ssh("elsewhere"), "there", "Elsewhere Shell"), launchShell: false
    )
    let ownHost = harness.deviceWorkspace.attachHostedSession(
        attachment(harness.deviceHosting.profile.host, "own", "Own Shell"), launchShell: false
    )
    // The attached This Mac tab is the one the window shows.
    harness.deviceWorkspace.select(thisMac)
    let reachable = deviceTabs.union([ownHost.id.uuidString])

    // Listings: only the device's.
    let processes = try await harness.send(.listProcesses(.init()), to: listener, credentials: harness.credentials)
    #expect(harness.processIDs(processes) == reachable, "\(processes)")
    if case .listProcesses(let listed)? = processes.result { #expect(listed.selectedProcessID == nil) }
    let terminals = try await harness.send(.listTerminals, to: listener, credentials: harness.credentials)
    guard case .listTerminals(let listedTerminals)? = terminals.result else {
        Issue.record("Expected listTerminals, got \(terminals)")
        return
    }
    #expect(Set(listedTerminals.terminals.map(\.id)) == reachable)
    #expect(listedTerminals.selectedTerminalID == nil)
    let status = try await harness.send(.getProjectStatus, to: listener, credentials: harness.credentials)
    if case .getProjectStatus(let project)? = status.result {
        #expect(project.processCounts.total == reachable.count)
        #expect(project.selectedProcessID == nil)
    } else {
        Issue.record("Expected project status, got \(status)")
    }
    // The device's own host's session is reachable.
    let own = try await harness.send(.getProcessStatus(.init(processID: ownHost.id.uuidString)), to: listener, credentials: harness.credentials)
    #expect(own.error == nil, "\(own)")

    // By id, by name, and every tool that acts on a session: not found.
    for foreign in [thisMac, otherHost] {
        let id = foreign.id.uuidString
        let requests: [CherryControlRequest] = [
            .getProcessStatus(.init(processID: id)),
            .getProcessStatus(.init(processName: foreign.title)),
            .getProcessOutput(.init(processID: id)),
            .sendProcessInput(.init(processID: id, text: "remote-input\n")),
            .sendProcessInput(.init(processName: foreign.title, text: "remote-input\n")),
            .sendInput(.init(terminalID: id, text: "x\n", rawBase64: nil, waitMilliseconds: nil, lineLimit: nil)),
            .getTerminalOutput(.init(terminalID: id, startLine: nil, lineLimit: nil)),
            .restartProcess(.init(processID: id)),
            .restartTerminal(.init(terminalID: id)),
            .closeProcess(.init(processID: id)),
            .closeTerminal(.init(terminalID: id)),
            .stopProcess(.init(processID: id)),
            .selectProcess(.init(processID: id)),
            .waitForProcessIdle(.init(processID: id, timeoutMilliseconds: 50)),
            .getProcessPorts(.init(processID: id)),
            .waitForBoundPort(.init(processID: id, timeoutMilliseconds: 50)),
        ]
        for request in requests {
            let answer = try await harness.send(request, to: listener, credentials: harness.credentials)
            #expect(["terminal_not_found", "process_not_found"].contains(answer.error?.code), "\(request): \(answer)")
        }
        let link = CherryDeepLink(projectRoot: harness.deviceKey, kind: .terminal, targetID: id).absoluteString
        let resolved = try await harness.send(.resolveLink(.init(link: link, includeOutput: true)), to: listener, credentials: harness.credentials)
        if case .resolveLink(let result)? = resolved.result {
            #expect(!result.found && result.process == nil && result.output == nil, "\(result)")
        } else {
            Issue.record("Expected resolveLink, got \(resolved)")
        }
        // Its token is refused: it is not a tab of the device.
        let token = harness.tokens.newGeneration(tabID: foreign.id, deviceID: harness.deviceID)
        let asIt = try await harness.send(.listProcesses(.init()), to: listener, credentials: .init(token: token, processID: id))
        #expect(asIt.error?.code == "unauthorized", "\(asIt)")
    }
    #expect(harness.deviceWorkspace.session(withID: thisMac.id) != nil)
    #expect(harness.deviceWorkspace.session(withID: otherHost.id) != nil)
    // This Mac's own callers still see the whole window.
    let local = try await harness.send(
        .scoped(.init(projectRoot: harness.deviceKey, request: .listProcesses(.init()))), credentials: nil
    )
    #expect(harness.processIDs(local) == reachable.union([thisMac.id.uuidString, otherHost.id.uuidString]))
}

/// This Mac's port scan (lsof) never runs for a caller on another Mac, and
/// `include_unattributed` (This Mac's every listener) is refused.
@Test @MainActor func RemoteDeviceMCPNeverScansThisMacsPorts() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let tabID = harness.tab.id.uuidString
    for request: CherryControlRequest in [
        .servicesList(.init(includeUnattributed: true)),
        .getProcessPorts(.init(processID: tabID, includeUnattributed: true)),
        .waitForBoundPort(.init(port: 5432, timeoutMilliseconds: 50, includeUnattributed: true)),
        .waitForBoundPort(.init(port: 5432, timeoutMilliseconds: 50, includeUnattributed: true, probeHTTP: true)),
    ] {
        let answer = try await harness.send(request, to: listener, credentials: harness.credentials)
        #expect(answer.error?.code == "unattributed_not_available", "\(request): \(answer)")
        if case .servicesList(let result)? = answer.result { #expect(result.unattributed.isEmpty) }
    }
    // Without it: nothing of This Mac's is scanned either.
    let services = try await harness.send(.servicesList(.init()), to: listener, credentials: harness.credentials)
    #expect(services.error == nil, "\(services)")
    let wait = try await harness.send(
        .waitForBoundPort(.init(port: 5432, timeoutMilliseconds: 200, probeHTTP: true)), to: listener, credentials: harness.credentials
    )
    #expect(wait.error?.code == "port_wait_timed_out", "\(wait)")
    #expect(harness.localServices.calls.isEmpty, "\(harness.localServices.calls)")
    // A local caller's scan still runs.
    _ = try await harness.send(.servicesList(.init(includeUnattributed: true)), credentials: nil)
    #expect(harness.localServices.calls.contains { $0.includeUnattributed })
}

/// A device's port whose forward could not be made is never probed at
/// This Mac's localhost (its `url` then is the address there).
@Test func RemoteDeviceMCPProbeOnlyThroughTheDevicesForward() {
    func record(forwardedFrom: String?) -> ServiceRecord {
        ServiceRecord(
            processID: "p", processName: "web", kind: "command", pid: nil, port: 8080, host: "127.0.0.1",
            url: forwardedFrom == nil ? "http://localhost:8080" : "http://127.0.0.1:61234", attribution: .processTree,
            protocolGuess: nil, readiness: .bound, lastSeenAt: Date(), commandName: nil, agentName: nil,
            machine: "Studio", remoteURL: "http://localhost:8080", forwardedFrom: forwardedFrom,
            forwardError: forwardedFrom == nil ? "refused" : nil
        )
    }
    #expect(CherryControlServer.probeURL(for: record(forwardedFrom: nil), path: nil) == nil)
    #expect(CherryControlServer.probeURL(for: record(forwardedFrom: "Studio"), path: "/health")?.absoluteString == "http://127.0.0.1:61234/health")
    let local = ServiceRecord(
        processID: "p", processName: "web", kind: "command", pid: 1, port: 3000, host: "127.0.0.1",
        url: "http://localhost:3000", attribution: .processTree, protocolGuess: nil, readiness: .bound,
        lastSeenAt: Date(), commandName: nil, agentName: nil
    )
    #expect(CherryControlServer.probeURL(for: local, path: nil)?.absoluteString == "http://localhost:3000/")
}

/// The directory a device reports for its per-user temporary files goes
/// into `ssh -R` (which expands `${…}` and splits at `:`) only when it is
/// a plain absolute path.
@Test func RemoteDeviceMCPTemporaryDirectoryThereIsAllowListed() throws {
    let installation = UUID(), device = UUID()
    func directory(_ path: String) -> String? {
        RemoteMCPPaths.remoteDirectory(temporaryDirectory: path, installationID: installation, deviceID: device)
    }
    #expect(directory("/var/folders/8s/f8v56gzs3232x21hn7nngwmc0000gn/T/") != nil)
    #expect(directory("/private/var/folders/ab/c_d+e-f.g/T") != nil)
    for bad in [
        "/var/folders/${HOME}/T", "/var/folders/$HOME/T", "/var/fol:ders/T", "/var/folders/a b/T",
        "/var/folders/%h/T", "/var/folders/../T", "/var/folders/./T", "var/folders/T", "/var/folders/\nT",
        "/var/folders/é/T", "/var/folders/a;b/T", "/var/folders/`id`/T", "/" + String(repeating: "a", count: 300),
    ] {
        #expect(directory(bad) == nil, "\(bad)")
    }
    // From the check's output: dropped.
    let parsed = RemoteDeviceProbe.parse(.init(
        status: 0,
        standardOutput: [RemoteDeviceProbe.beginMarker, "usertmp=/var/folders/${X}/T/", RemoteDeviceProbe.endMarker].joined(separator: "\n"),
        standardError: ""
    ))
    #expect(parsed.userTemporaryDirectory == nil)
    // From devices.json: dropped.
    let json = #"{"id":"\#(device.uuidString)","name":"Studio","sshDestination":"studio","userTemporaryDirectory":"/tmp/a:b"}"#
    let decoded = try JSONDecoder().decode(RemoteDevice.self, from: Data(json.utf8))
    #expect(decoded.userTemporaryDirectory == nil)
    let good = #"{"id":"\#(device.uuidString)","name":"Studio","sshDestination":"studio","userTemporaryDirectory":"/var/folders/x/T/"}"#
    #expect(try JSONDecoder().decode(RemoteDevice.self, from: Data(good.utf8)).userTemporaryDirectory == "/var/folders/x/T/")
}

/// Opens a connection to `socket` (no SIGPIPE).
private func connectUnix(_ socket: URL) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        socket.path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        close(fd)
        throw HostedSessionError.message("connect failed")
    }
    return fd
}

/// Reads one answer line (until EOF).
private func readAnswer(_ fd: Int32) -> CherryControlResponse? {
    var answer = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        answer.append(contentsOf: buffer.prefix(count))
        if answer.last == 0x0A { break }
    }
    return try? JSONDecoder().decode(CherryControlResponse.self, from: answer)
}

/// A device listener refuses a body over its cap before decoding it.
@Test @MainActor func RemoteDeviceMCPListenerRefusesAnOversizedRequest() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let answer = try await Task.detached { () -> CherryControlResponse? in
        let fd = try connectUnix(listener)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // 9 MB of a JSON string, never a newline.
        let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: 1 << 20)
        _ = write(fd, "{\"x\":\"", 6)
        for _ in 0..<9 {
            var offset = 0
            while offset < chunk.count {
                let written = chunk.withUnsafeBytes { write(fd, $0.baseAddress! + offset, chunk.count - offset) }
                if written <= 0 { break }
                offset += written
            }
            if offset < chunk.count { break }
        }
        shutdown(fd, SHUT_WR)
        return readAnswer(fd)
    }.value
    #expect(answer?.error?.code == "request_too_large", "\(String(describing: answer))")
}

/// A device listener serves at most `maxConnections` connections at once:
/// the next is refused at once.
@Test @MainActor func RemoteDeviceMCPListenerLimitsConcurrentConnections() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    // Silent connections hold every slot.
    var silent: [Int32] = []
    defer { silent.forEach { close($0) } }
    for _ in 0..<16 { silent.append(try connectUnix(listener)) }
    try await Task.sleep(for: .milliseconds(300))
    let started = Date()
    let answer = try await harness.send(.listProcesses(.init()), to: listener, credentials: harness.credentials)
    #expect(answer.error?.code == "too_many_connections", "\(answer)")
    #expect(Date().timeIntervalSince(started) < 5)
    // Once they go, it answers again.
    silent.forEach { close($0) }
    silent = []
    try await Task.sleep(for: .milliseconds(500))
    let again = try await harness.send(.listProcesses(.init()), to: listener, credentials: harness.credentials)
    #expect(again.error == nil, "\(again)")
}

/// A device listener's connection has one deadline for its whole request:
/// a client that sends a byte now and then is cut off.
@Test @MainActor func RemoteDeviceMCPListenerHasAnOverallRequestDeadline() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let (answer, elapsed) = try await Task.detached { () -> (CherryControlResponse?, TimeInterval) in
        let fd = try connectUnix(listener)
        defer { close(fd) }
        let started = Date()
        _ = write(fd, "{", 1)
        // A byte every 400 ms for up to 30 s, until the server answers.
        var answer: CherryControlResponse?
        while Date().timeIntervalSince(started) < 30 {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&poller, 1, 400) > 0 {
                answer = readAnswer(fd)
                break
            }
            if write(fd, " ", 1) <= 0 {
                answer = readAnswer(fd)
                break
            }
        }
        return (answer, Date().timeIntervalSince(started))
    }.value
    #expect(answer?.error?.code == "request_timeout", "\(String(describing: answer))")
    #expect(elapsed >= 14 && elapsed < 20, "\(elapsed)")
}

/// A device window's Persistent Sessions sheet offers only its own Mac.
@Test @MainActor func RemoteDeviceMCPPersistentSessionsSheetOfADeviceWindowOffersOnlyThatMac() throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    #expect(HostedSessionsSheet.deviceHost(of: harness.deviceWorkspace) == harness.deviceHosting.profile.host)
    #expect(HostedSessionsSheet.deviceHost(of: harness.localWorkspace) == nil)
}
