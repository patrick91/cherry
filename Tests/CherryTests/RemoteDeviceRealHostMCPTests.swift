import AppKit
import CherryControl
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// Cherry MCP for agents on another Mac (docs/specs/remote-devices.md, phase
// 4b) end to end: the real CherryMCP (`swift build --build-tests` builds
// it), the app's control server with a device listener, and the reverse
// forward of the app's control socket made by `RemoteMCPForwards` on an SSH
// master. Against the fake remote Mac (Scripts/fake-remote-mac, whose
// stand-in master bridges `-O forward -R THERE:HERE` with a link, since the
// fake Mac's files are this Mac's), or, for
// RemoteDeviceRealHostForwardsCherryMCPOverSSH run by
// Scripts/test-remote-mac-loopback (CHERRY_TEST_LOOPBACK_SSH), a real
// `ssh -O forward -R` of a Unix socket through a private sshd on 127.0.0.1.
// Gated like the other real-host suites. Every forwarded socket is under
// <DARWIN_USER_TEMP_DIR>/cherry-mcp-<hash of random ids>, removed at the end; the
// app's own control socket and daemon are never touched.

private let mcpRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

/// The CherryMCP `swift build` made.
private func builtCherryMCP() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helper = repository.appendingPathComponent(".build/debug/CherryMCP")
    guard FileManager.default.isExecutableFile(atPath: helper.path) else {
        throw HostedSessionError.message("Build CherryMCP first: swift build --build-tests (or --product CherryMCP)")
    }
    return helper
}

private func mcpSocketDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ch-mcp-\(UUID().uuidString.prefix(6))")
    let sockets = root.appendingPathComponent("s")
    try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return sockets
}

/// This account's per-user temporary directory (`getconf
/// DARWIN_USER_TEMP_DIR`): the fake Mac's and the loopback's too, since
/// they are this Mac.
private func userTemporaryDirectory() throws -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    guard length > 0 else { throw HostedSessionError.message("no DARWIN_USER_TEMP_DIR") }
    return String(cString: buffer)
}

/// Runs CherryMCP `--call` with exactly `environment`.
private func callCherryMCP(_ helper: URL, _ tool: String, _ arguments: String? = nil, environment: [String: String]) async throws -> (status: Int32, output: String) {
    try await Task.detached {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--call", tool] + (arguments.map { [$0] } ?? [])
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
}

private func readFile(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

// MARK: - A device tab's agent through the fake Mac

@Test(.enabled(if: mcpRealHostEnabled))
@MainActor func RemoteDeviceRealHostAgentInADeviceTabUsesCherryMCPThroughTheForward() async throws {
    let helper = try builtCherryMCP()
    let mac = try FakeRemoteMac(name: "mcpmac")
    try Data().write(to: mac.root.appendingPathComponent("masters"))
    let sockets = try mcpSocketDirectory()
    let ssh = mac.bin.appendingPathComponent("ssh").path
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets }, sshExecutable: { _ in ssh }, startTimeout: 10, healthCheckInterval: 3_600, idleStopDelay: 0.2
    ))
    let tokens = RemoteMCPTokens(key: SymmetricKey(size: .bits256))
    let remoteSocket = try #require(RemoteMCPPaths.remoteSocket(
        temporaryDirectory: try userTemporaryDirectory(), installationID: mac.installationID, deviceID: mac.deviceID
    ))
    let launch = RemoteMCPLaunch(
        deviceID: mac.deviceID, socketPath: remoteSocket, helperPath: helper.path, controlMachine: "Laptop", tokens: tokens
    )
    let control = mac.makeControl()
    let hosting = PersistentHostSessions.remote(
        profile: .remote(host: mac.host, displayName: "Studio", machineNames: []) { RemoteLaunchSpec.Device(mcp: launch) },
        installationID: mac.installationID,
        remoteShell: "/bin/bash",
        control: { control },
        installationUnavailableReason: { nil },
        status: PersistentSessionsStatus(),
        instanceLock: nil,
        terminalColors: { nil },
        configuration: FakeRemoteMac.fastConfiguration
    )
    let workspace = TerminalWorkspace(
        projectRoot: mac.projectKey, createInitialSession: false,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
    )
    let defaultsName = "CherryTests.RemoteMCPRealHost.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    let socket = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))/control.sock")
    let server = CherryControlServer(workspace: workspace, socketURL: socket, agentSettings: AgentSettings(defaults: defaults))
    server.mcpTokens = tokens
    let forwards = RemoteMCPForwards(masters: manager, shell: { mac.shell }, server: { server })
    let target = RemoteMCPForwards.Target(
        deviceID: mac.deviceID, destination: mac.name, machine: "Studio", installationID: mac.installationID
    )
    let remoteDirectory = (remoteSocket as NSString).deletingLastPathComponent
    func cleanUp() async {
        await forwards.stopAll()
        server.stop()
        manager.stopAll()
        workspace.closeAllSessions(intent: .windowClosedEndingSessions)
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
        try? FileManager.default.removeItem(atPath: remoteDirectory)
        try? FileManager.default.removeItem(at: sockets.deletingLastPathComponent())
        await mac.tearDown()
    }
    do {
        server.start()
        // A socket a master that died left there: removed before the forward.
        try FileManager.default.createDirectory(atPath: remoteDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: remoteSocket, contents: Data())
        let state = await forwards.ensure(target)
        let controlPath = try #require(manager.controlPathIfUp(for: mac.name))
        let local = server.deviceListenerURL(deviceID: mac.deviceID).path
        #expect(state == .up(controlPath: controlPath, remoteSocket: remoteSocket, localSocket: local))
        #expect(readFile(mac.root.appendingPathComponent("forwards")).contains("forward \(controlPath) -R \(remoteSocket):\(local)"))
        var status = stat()
        #expect(lstat(remoteDirectory, &status) == 0 && status.st_mode & 0o777 == 0o700)
        // Asked again with the same master: the same forward, nothing made.
        #expect(await forwards.ensure(target) == state)
        #expect(readFile(mac.root.appendingPathComponent("forwards")).components(separatedBy: "\n").filter { $0.hasPrefix("forward") }.count == 1)

        // An agent's shell in a tab there.
        let tab = workspace.addSession(title: "Agent")
        try await mac.waitFor("the tab's session there") { tab.remoteProgramProcessID != nil }
        let home = mac.home
        func runThere(_ line: String, name: String) async throws -> (status: String, output: String) {
            let statusFile = home.appendingPathComponent("\(name).status")
            try await tab.sendControlInput(Data("\(line) > \"$HOME/\(name).out\" 2>&1; echo $? > \"$HOME/\(name).status\"\n".utf8), raw: false)
            try await mac.waitFor("\(name) there", timeout: 30) { !readFile(statusFile).isEmpty }
            return (readFile(statusFile).trimmingCharacters(in: .whitespacesAndNewlines), readFile(home.appendingPathComponent("\(name).out")))
        }
        // Its environment: the forwarded socket, its own token.
        let variables = try await runThere("env | grep -E '^CHERRY_(CONTROL_SOCKET|MCP_TOKEN|MCP_HELPER|CONTROL_MACHINE|PROCESS_ID)='", name: "env")
        #expect(variables.output.contains("CHERRY_CONTROL_SOCKET=\(remoteSocket)\n"))
        #expect(variables.output.contains("CHERRY_MCP_TOKEN=\(tokens.currentToken(tabID: tab.id, deviceID: mac.deviceID) ?? "none")\n"))
        #expect(variables.output.contains("CHERRY_MCP_HELPER=\(helper.path)\n"))
        #expect(variables.output.contains("CHERRY_CONTROL_MACHINE=Laptop\n"))
        #expect(!variables.output.contains(socket.path))

        // list_processes through the forward: its window's processes.
        let listed = try await runThere("\"$CHERRY_MCP_HELPER\" --call list_processes", name: "list")
        #expect(listed.status == "0", "\(listed.output)")
        #expect(listed.output.contains(tab.id.uuidString))
        // Its project: the device window, from its path there.
        let project = try await runThere("\"$CHERRY_MCP_HELPER\" --call get_project_status", name: "project")
        #expect(project.status == "0", "\(project.output)")
        #expect(project.output.contains(mac.deviceID.uuidString.lowercased()))
        // Started as Codex starts MCP servers once Set Up listed Cherry's
        // variables in its env_vars: those and a few of its own only.
        let passed = CherryControl.remoteTabEnvironmentKeys.map { "\($0)=\"$\($0)\"" }.joined(separator: " ")
        let stripped = try await runThere(
            "h=\"$CHERRY_MCP_HELPER\"; env -i HOME=\"$HOME\" PATH=/usr/bin:/bin \(passed) \"$h\" --call list_processes", name: "stripped"
        )
        #expect(stripped.status == "0", "\(stripped.output)")
        #expect(stripped.output.contains(tab.id.uuidString))
        // A wrong token is refused.
        let wrong = try await runThere(
            "CHERRY_MCP_TOKEN=0000000000000000000000000000000000000000000000000000000000000000 \"$CHERRY_MCP_HELPER\" --call list_processes",
            name: "wrong"
        )
        #expect(wrong.status == "1")
        #expect(wrong.output.contains("unauthorized"))
        #expect(!wrong.output.contains(tab.id.uuidString))

        // A This Mac window, registered where the server looks, with a
        // terminal: the agent there cannot reach it by a `..` project root
        // (a) or by its process id (c), through the real CherryMCP.
        let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ch-mcp-here-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let here = TerminalWorkspace(projectRoot: localRoot.path, createInitialSession: false, launchBackend: .hostManaged)
        let hereTab = here.addSession(title: "Here")
        let hereWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: true
        )
        hereWindow.isReleasedWhenClosed = false
        #expect(ProjectWindowRegistry.shared.register(
            window: hereWindow, projectRoot: localRoot.path, workspace: here, noteStore: nil, todoStore: nil, chromeState: nil
        ))
        defer {
            ProjectWindowRegistry.shared.unregister(window: hereWindow, projectRoot: localRoot.path)
            here.sessions.forEach { $0.stop() }
        }
        let escape = String(repeating: "/..", count: 40) + localRoot.path
        let dotdot = try await runThere(
            "\"$CHERRY_MCP_HELPER\" --call spawn_process '{\"kind\":\"terminal\",\"project_root\":\"\(escape)\"}'", name: "dotdot"
        )
        #expect(dotdot.status == "1", "\(dotdot.output)")
        #expect(dotdot.output.contains("invalid_project_root"), "\(dotdot.output)")
        #expect(here.sessions.map(\.id) == [hereTab.id])
        let byID = try await runThere(
            "\"$CHERRY_MCP_HELPER\" --call send_process_input '{\"process_id\":\"\(hereTab.id.uuidString)\",\"text\":\"from-there\"}'", name: "byid"
        )
        #expect(byID.status == "1", "\(byID.output)")
        #expect(byID.output.contains("terminal_not_found"), "\(byID.output)")
        let hereStatus = try await runThere(
            "\"$CHERRY_MCP_HELPER\" --call get_process_status '{\"process_id\":\"\(hereTab.id.uuidString)\"}'", name: "status"
        )
        #expect(hereStatus.status == "1" && hereStatus.output.contains("terminal_not_found"), "\(hereStatus.output)")

        // The master went (a reconnect): the next connection's ensure makes
        // the forward again, removing the socket the old one left.
        forwards.masterStopped(mac.name)
        #expect(forwards.states[mac.deviceID] == nil)
        #expect(await forwards.ensure(target) == state)
        let again = try await runThere("\"$CHERRY_MCP_HELPER\" --call list_processes", name: "again")
        #expect(again.status == "0", "\(again.output)")

        // A server that refuses to forward Unix sockets: said so.
        forwards.masterStopped(mac.name)
        try Data().write(to: mac.root.appendingPathComponent("remote-forward-fails"))
        guard case .failed(let reason) = await forwards.ensure(target) else {
            Issue.record("Expected the forward to fail")
            await cleanUp()
            return
        }
        #expect(reason.contains("AllowStreamLocalForwarding"))
        try FileManager.default.removeItem(at: mac.root.appendingPathComponent("remote-forward-fails"))

        // The forward down (Cherry quit, or the Mac is offline): the tool
        // says Cherry is not reachable.
        await forwards.stop(deviceID: mac.deviceID)
        #expect(!FileManager.default.fileExists(atPath: local))
        let offline = try await runThere("\"$CHERRY_MCP_HELPER\" --call list_processes", name: "offline")
        #expect(offline.status == "1")
        #expect(offline.output.contains("Cherry on Laptop is not reachable"))
    } catch {
        Issue.record(error)
    }
    await cleanUp()
}

// MARK: - The forward over a real sshd (or the fake Mac)

@Test(.enabled(if: mcpRealHostEnabled))
@MainActor func RemoteDeviceRealHostForwardsCherryMCPOverSSH() async throws {
    let helper = try builtCherryMCP()
    let environment = ProcessInfo.processInfo.environment
    let sockets = try mcpSocketDirectory()
    let ssh: String
    let destination: String
    var fake: FakeRemoteMac?
    if let loopback = environment["CHERRY_TEST_LOOPBACK_SSH"]?.nilIfEmpty {
        // A real sshd on 127.0.0.1 (Scripts/test-remote-mac-loopback).
        ssh = loopback
        destination = environment["CHERRY_TEST_LOOPBACK_DESTINATION"]?.nilIfEmpty ?? "loopback"
    } else {
        let mac = try FakeRemoteMac(name: "mcpfwd", startsDaemon: false)
        fake = mac
        try Data().write(to: mac.root.appendingPathComponent("masters"))
        ssh = mac.bin.appendingPathComponent("ssh").path
        destination = "mcpfwd"
    }
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets }, sshExecutable: { _ in ssh }, startTimeout: 20, healthCheckInterval: 3_600, idleStopDelay: 0.2
    ))
    let shell = RemoteDeviceShell(sshExecutable: ssh, environment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()])
    // A device window on a test control server: its tab is the device's
    // (its hosting is inert: no program runs).
    let deviceID = UUID(), installationID = UUID()
    let key = ProjectLocation.remote(deviceID: deviceID, path: "/Users/them/app").key
    let workspace = TerminalWorkspace(
        projectRoot: key, createInitialSession: false, launchBackend: .nativePTY,
        backendPolicy: .remote(inertDeviceHosting("inert-\(deviceID.uuidString.prefix(8))", name: "Loopback"), settings: { .native }, hostReconnects: nil)
    )
    let tab = workspace.addSession(title: "Agent there")
    let defaultsName = "CherryTests.RemoteMCPLoopback.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    let socket = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))/control.sock")
    let server = CherryControlServer(workspace: workspace, socketURL: socket, agentSettings: AgentSettings(defaults: defaults))
    let tokens = RemoteMCPTokens(key: SymmetricKey(size: .bits256))
    server.mcpTokens = tokens
    let forwards = RemoteMCPForwards(masters: manager, shell: { shell }, server: { server })
    let remoteSocket = try #require(RemoteMCPPaths.remoteSocket(
        temporaryDirectory: try userTemporaryDirectory(), installationID: installationID, deviceID: deviceID
    ))
    let remoteDirectory = (remoteSocket as NSString).deletingLastPathComponent
    func cleanUp() async {
        workspace.closeAllSessions(intent: .windowClosed)
        await forwards.stopAll()
        server.stop()
        manager.stopAll()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
        try? FileManager.default.removeItem(atPath: remoteDirectory)
        try? FileManager.default.removeItem(at: sockets.deletingLastPathComponent())
        if let fake { await fake.tearDown() }
    }
    tokens.newGeneration(tabID: tab.id, deviceID: deviceID)
    do {
        server.start()
        let target = RemoteMCPForwards.Target(deviceID: deviceID, destination: destination, machine: "Loopback", installationID: installationID)
        let state = await forwards.ensure(target)
        guard case .up = state else {
            Issue.record("The forward was not made: \(state)")
            await cleanUp()
            return
        }
        // "Their" CherryMCP, with a tab's variables.
        let variables = [
            "HOME": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin",
            "CHERRY_CONTROL_SOCKET": remoteSocket,
            "CHERRY_MCP_TOKEN": tokens.currentToken(tabID: tab.id, deviceID: deviceID) ?? "",
            "CHERRY_PROCESS_ID": tab.id.uuidString,
            "CHERRY_PROJECT_ROOT": "/Users/them/app",
            "CHERRY_CONTROL_MACHINE": "Laptop",
        ]
        var listed = (status: Int32(-1), output: "")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            listed = try await callCherryMCP(helper, "list_processes", environment: variables)
            if listed.status == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(listed.status == 0, "\(listed.output)")
        #expect(listed.output.contains(tab.id.uuidString))
        if fake == nil {
            // A real socket sshd made there (not a link).
            var status = stat()
            #expect(lstat(remoteSocket, &status) == 0 && status.st_mode & S_IFMT == S_IFSOCK)
        }
        // Without its token, or with another tab's: refused.
        var noToken = variables
        noToken["CHERRY_MCP_TOKEN"] = nil
        let refusedWithout = try await callCherryMCP(helper, "list_processes", environment: noToken)
        #expect(refusedWithout.status == 1 && refusedWithout.output.contains("unauthorized"))
        var wrong = variables
        wrong["CHERRY_MCP_TOKEN"] = tokens.newGeneration(tabID: UUID(), deviceID: deviceID)
        let refusedWrong = try await callCherryMCP(helper, "list_processes", environment: wrong)
        #expect(refusedWrong.status == 1 && refusedWrong.output.contains("unauthorized"))
        // The forward ends: cancelled, its socket there removed; the tool
        // says so.
        await forwards.stop(deviceID: deviceID)
        #expect(!FileManager.default.fileExists(atPath: remoteSocket))
        let offline = try await callCherryMCP(helper, "list_processes", environment: variables)
        #expect(offline.status == 1 && offline.output.contains("Cherry on Laptop is not reachable"))
    } catch {
        Issue.record(error)
    }
    await cleanUp()
}
