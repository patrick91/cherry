import AppKit
import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// Pasted images in tabs of another Mac, and phase 4a of devices
// (docs/specs/remote-devices.md: ports, URLs and forwards), against a fake
// remote Mac (Scripts/fake-remote-mac): the real `cherry`, `cherry-host`
// (its `ports`), scp and the fake Mac's `osascript` stand-in (never the real
// one, which would set this Mac's clipboard), reached through the ssh shim.
// Gated like the other real-host suites (CHERRY_TEST_HOST_INTEGRATION=1,
// Scripts/build-host debug). No test touches the general pasteboard.
//
// RemoteDeviceRealHostForwardsAPortThroughTheSSHMaster also runs over a real
// sshd: Scripts/test-remote-mac-loopback sets CHERRY_TEST_LOOPBACK_SSH, and
// the test fetches a page served on the "remote" side through a real
// `ssh -O forward` on a master started as the app starts them
// (ClearAllForwardings=yes). Otherwise it uses the fake Mac's stand-in
// masters, which log each forward.

private let portsRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

private let pastedPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!

@MainActor
private func imagePasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CherryTests.RemotePaste.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setData(pastedPNG, forType: .png)
    return pasteboard
}

/// Restores the seams a test replaced.
@MainActor
private final class Seams {
    private let makeCopier = RemoteFileDropCoordinator.makeCopier
    private let device = RemoteFileDropCoordinator.device
    private let ask = RemoteFileDropCoordinator.ask
    private let imageDirectory = RemoteFileDropCoordinator.imageDirectory
    private let reportFailure = RemoteFileDropCoordinator.reportFailure
    private let makeSetter = RemoteClipboardImagePaste.makeSetter
    private let clipboardToast = RemoteClipboardImagePaste.showToast
    private let opener = RemoteURLOpening.opener
    private let openingDevice = RemoteURLOpening.device
    private let openingToast = RemoteURLOpening.showToast
    private let shared = RemotePortForwards.existing
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CherryRemotePaste-\(UUID().uuidString.prefix(8))/Pasted Images", isDirectory: true)
    var failures: [String] = []

    init(_ mac: FakeRemoteMac) {
        let device = RemoteDevice(id: mac.deviceID, name: "Studio", sshDestination: mac.name, homeDirectory: mac.home.path)
        let shell = mac.shell
        let name = mac.name
        RemoteFileDropCoordinator.makeCopier = { _ in RemoteFileCopier(shell: shell, destination: name, machine: "Studio") }
        RemoteFileDropCoordinator.device = { _ in device }
        RemoteFileDropCoordinator.ask = { question, _, answer in
            Issue.record("asked: \(question.title)")
            answer(false)
        }
        let directory = directory
        RemoteFileDropCoordinator.imageDirectory = { directory }
        RemoteFileDropCoordinator.reportFailure = { [weak self] title, message, _ in self?.failures.append("\(title): \(message)") }
        RemoteClipboardImagePaste.makeSetter = { _ in RemoteClipboardSetter(shell: shell, destination: name, machine: "Studio") }
        RemoteURLOpening.device = { _ in device }
    }

    func restore() {
        RemoteFileDropCoordinator.makeCopier = makeCopier
        RemoteFileDropCoordinator.device = device
        RemoteFileDropCoordinator.ask = ask
        RemoteFileDropCoordinator.imageDirectory = imageDirectory
        RemoteFileDropCoordinator.reportFailure = reportFailure
        RemoteClipboardImagePaste.makeSetter = makeSetter
        RemoteClipboardImagePaste.showToast = clipboardToast
        RemoteURLOpening.opener = opener
        RemoteURLOpening.device = openingDevice
        RemoteURLOpening.showToast = openingToast
        RemotePortForwards.existing = shared
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
}

/// A private directory for SSH master sockets, short enough for a socket
/// path.
private func socketDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ch-pf-\(UUID().uuidString.prefix(6))")
    let sockets = root.appendingPathComponent("s")
    try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return sockets
}

private func contents(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

// MARK: - Pasted images

@Test(.enabled(if: portsRealHostEnabled))
@MainActor func RemoteDeviceRealHostPastedImageIsCopiedToTheDeviceWithoutAskingAndItsPathPasted() async throws {
    let mac = try FakeRemoteMac()
    let seams = Seams(mac)
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    let workspace = TerminalWorkspace(
        projectRoot: mac.projectKey, createInitialSession: false,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
    )
    let pasteboard = imagePasteboard()
    defer { pasteboard.releaseGlobally() }
    do {
        let tab = workspace.addSession(title: "Remote")
        var inserted: [String] = []
        // ⌘V: no question for an image; copied there; its path there pasted.
        #expect(RemoteFileDropCoordinator.handle(pasteboard, for: tab, isPaste: true, window: nil) { inserted.append($0) })
        await RemoteFileDropCoordinator.lastCopy?.value
        #expect(seams.failures.isEmpty, "\(seams.failures)")
        let pasted = try #require(inserted.first)
        #expect(inserted.count == 1)
        #expect(!pasted.hasSuffix(" "))
        let remotePath = pasted.hasPrefix("'") ? String(pasted.dropFirst().dropLast()) : pasted
        #expect(pasted == PastedImage.quoted(remotePath))
        #expect(URL(fileURLWithPath: remotePath).deletingLastPathComponent().lastPathComponent.hasPrefix("cherry-drop."))
        #expect(URL(fileURLWithPath: remotePath).lastPathComponent.range(of: #"^\d{8}-\d{6}-[0-9a-f]{8}\.png$"#, options: .regularExpression) != nil)
        // The fake Mac is this Mac: the copy is here too, the same bytes.
        #expect(try Data(contentsOf: URL(fileURLWithPath: remotePath)) == pastedPNG)
        #expect(mac.calls.contains { $0.contains("scp") && $0.contains("-t") })
        // Saved in the paste cache first.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: seams.directory.path))?.count == 1)
        try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: remotePath).deletingLastPathComponent().path)

        // Dropped image data: the same, inserted as a drop inserts paths.
        inserted.removeAll()
        #expect(RemoteFileDropCoordinator.handle(pasteboard, for: tab, isPaste: false, window: nil) { inserted.append($0) })
        await RemoteFileDropCoordinator.lastCopy?.value
        #expect(inserted.count == 1 && inserted[0].hasSuffix(".png "))
        try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: String(inserted[0].dropLast())).deletingLastPathComponent().path)

        // A Mac that cannot be reached: said so, nothing pasted.
        inserted.removeAll()
        mac.set("offline", true)
        #expect(RemoteFileDropCoordinator.handle(pasteboard, for: tab, isPaste: true, window: nil) { inserted.append($0) })
        await RemoteFileDropCoordinator.lastCopy?.value
        mac.set("offline", false)
        #expect(inserted.isEmpty)
        #expect(seams.failures.count == 1 && seams.failures[0].hasPrefix("The image was not copied to Studio"))
    } catch {
        workspace.closeAllSessions(intent: .windowClosedEndingSessions)
        seams.restore()
        await mac.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosedEndingSessions)
    seams.restore()
    await mac.tearDown()
}

@Test(.enabled(if: portsRealHostEnabled))
@MainActor func RemoteDeviceRealHostControlVPutsTheImageOnTheDevicesClipboardOrPastesItsPath() async throws {
    let mac = try FakeRemoteMac()
    let seams = Seams(mac)
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    let workspace = TerminalWorkspace(
        projectRoot: mac.projectKey, createInitialSession: false,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
    )
    let pasteboard = imagePasteboard()
    defer { pasteboard.releaseGlobally() }
    var toasts: [ProjectWindowToast] = []
    RemoteClipboardImagePaste.showToast = { toast, _ in toasts.append(toast) }
    let clipboard = mac.hostDirectory.appendingPathComponent("clipboard.png")
    let scripts = mac.hostDirectory.appendingPathComponent("osascript-calls")
    do {
        let agent = workspace.addAgentSession(
            agent: AgentToolDefinition(name: "Claude", command: "/bin/cat"), projectRoot: mac.projectKey
        )
        let terminal = workspace.addSession(title: "Remote")
        // Its program (the agent) runs there, in front.
        try await mac.waitFor("the agent in front there") {
            RemoteClipboardImagePaste.foregroundIsAgent(agent.hostReportedSession, kind: .agent)
        }
        var keys = 0
        var inserted: [String] = []
        // A terminal tab of the device: Ctrl+V is the shell's.
        #expect(!RemoteClipboardImagePaste.handle(pasteboard, for: terminal, window: nil, sendControlV: { keys += 1 }) { inserted.append($0) })
        // Text on the pasteboard: the key goes on as it is.
        let text = NSPasteboard(name: NSPasteboard.Name("CherryTests.RemotePaste.\(UUID().uuidString)"))
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("hello", forType: .string)
        #expect(!RemoteClipboardImagePaste.handle(text, for: agent, window: nil, sendControlV: { keys += 1 }) { inserted.append($0) })

        // The image goes to the device's clipboard, then Ctrl+V; keys typed
        // meanwhile are held and follow it, in order.
        var sent: [String] = []
        let took = RemoteClipboardImagePaste.handle(
            pasteboard, for: agent, window: nil,
            sendControlV: { keys += 1; sent.append("^V") },
            insert: { inserted.append($0) },
            replay: { sent.append($0.characters ?? "?") }
        )
        #expect(took)
        #expect(RemoteClipboardImagePaste.holdsKeys(for: agent.id))
        #expect(!RemoteClipboardImagePaste.holdsKeys(for: terminal.id))
        // A second Ctrl+V meanwhile is not taken again.
        #expect(!RemoteClipboardImagePaste.handle(pasteboard, for: agent, window: nil, sendControlV: { keys += 1 }) { inserted.append($0) })
        for character in ["a", "b"] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
            ))
            RemoteClipboardImagePaste.hold(event, for: agent.id)
        }
        await RemoteClipboardImagePaste.lastPaste?.value
        #expect(seams.failures.isEmpty, "\(seams.failures)")
        #expect(sent == ["^V", "a", "b"])
        #expect(!RemoteClipboardImagePaste.holdsKeys(for: agent.id))
        #expect(keys == 1)
        #expect(inserted.isEmpty)
        #expect(toasts.isEmpty)
        #expect(try Data(contentsOf: clipboard) == pastedPNG)
        let ran = contents(scripts)
        #expect(ran.contains("set the clipboard to (read (POSIX file \"") && ran.contains("as «class PNGf»)"))
        #expect(ran.contains("clipboard info for «class PNGf»"))

        // Nobody logged in there: osascript fails; the path is pasted and a
        // toast says why.
        try FileManager.default.removeItem(at: clipboard)
        mac.set("no-gui", true)
        #expect(RemoteClipboardImagePaste.handle(pasteboard, for: agent, window: nil, sendControlV: { keys += 1 }) { inserted.append($0) })
        await RemoteClipboardImagePaste.lastPaste?.value
        #expect(keys == 1)
        let path = try #require(inserted.first)
        #expect(inserted.count == 1)
        let remotePath = path.hasPrefix("'") ? String(path.dropFirst().dropLast()) : path
        #expect(try Data(contentsOf: URL(fileURLWithPath: remotePath)) == pastedPNG)
        #expect(!FileManager.default.fileExists(atPath: clipboard.path))
        #expect(toasts.map(\.title) == ["Pasted the image’s path on Studio"])
        #expect(toasts.first?.message?.contains("-10810") == true)
        mac.set("no-gui", false)

        // The Mac cannot be reached for the copy: Ctrl+V goes on anyway,
        // and a toast says why.
        inserted.removeAll()
        toasts.removeAll()
        mac.set("offline", true)
        #expect(RemoteClipboardImagePaste.handle(pasteboard, for: agent, window: nil, sendControlV: { keys += 1 }) { inserted.append($0) })
        await RemoteClipboardImagePaste.lastPaste?.value
        mac.set("offline", false)
        #expect(keys == 2)
        #expect(inserted.isEmpty)
        #expect(toasts.map(\.title) == ["The image was not copied to Studio"])

        // Past its deadline: Ctrl+V goes on, and a late result is ignored.
        toasts.removeAll()
        let savedDeadline = RemoteClipboardImagePaste.deadline
        RemoteClipboardImagePaste.deadline = 0
        #expect(RemoteClipboardImagePaste.handle(pasteboard, for: agent, window: nil, sendControlV: { keys += 1 }) { inserted.append($0) })
        try await mac.waitFor("the deadline") { keys == 3 }
        await RemoteClipboardImagePaste.lastPaste?.value
        RemoteClipboardImagePaste.deadline = savedDeadline
        #expect(keys == 3)
        #expect(inserted.isEmpty)
        #expect(toasts.first?.message?.contains("took longer") == true)
    } catch {
        workspace.closeAllSessions(intent: .windowClosedEndingSessions)
        seams.restore()
        await mac.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosedEndingSessions)
    seams.restore()
    await mac.tearDown()
}

// MARK: - Ports of device tabs

@MainActor
private final class NoLocalServices: ServiceDetecting {
    var asked: [[InspectableProcess]] = []
    func detectServices(processes: [InspectableProcess], includeUnattributed: Bool) async throws -> [ServiceRecord] {
        asked.append(processes)
        return []
    }
}

@Test(.enabled(if: portsRealHostEnabled))
@MainActor func RemoteDeviceRealHostReportsForwardsAndOpensTheDevicesPorts() async throws {
    let mac = try FakeRemoteMac()
    let seams = Seams(mac)
    try Data().write(to: mac.root.appendingPathComponent("masters"))
    let sockets = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: sockets.deletingLastPathComponent()) }
    let ssh = mac.bin.appendingPathComponent("ssh").path
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets }, sshExecutable: { _ in ssh }, startTimeout: 10, healthCheckInterval: 3_600, idleStopDelay: 0.2
    ))
    let shell = mac.shell
    let forwards = RemotePortForwards(masters: manager, shell: { shell })
    RemotePortForwards.shared = forwards
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    let workspace = TerminalWorkspace(
        projectRoot: mac.projectKey, createInitialSession: false,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
    )
    let defaultsName = "CherryTests.RemotePorts.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    let socket = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))/control.sock")
    let local = NoLocalServices()
    let detector = DeviceServiceDetector(
        device: { _ in RemoteDevice(id: mac.deviceID, name: "Studio", sshDestination: mac.name) },
        scanner: { _ in RemotePortScanner(deviceName: "Studio", destination: mac.name, remoteHostPath: nil, shell: { shell }) },
        forwards: { forwards }
    )
    let server = CherryControlServer(
        workspace: workspace, socketURL: socket, agentSettings: AgentSettings(defaults: defaults),
        serviceDetector: local, remoteServiceDetector: detector
    )
    var serverPID: Int32?
    func cleanUp() async {
        server.stop()
        forwards.releaseAll()
        manager.stopAll()
        if let serverPID { kill(serverPID, SIGKILL) }
        workspace.closeAllSessions(intent: .windowClosedEndingSessions)
        seams.restore()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
        await mac.tearDown()
    }
    do {
        server.start()
        // A web server in a tab of the device.
        let tab = workspace.addSession(title: "Server")
        try await mac.waitFor("the tab's session there") { tab.remoteProgramProcessID != nil }
        #expect(tab.hostedProgramProcessID == nil)
        let remotePID = try #require(tab.remoteProgramProcessID)
        let port = try #require(RemotePortForwards.unusedLocalPort())
        try await tab.sendControlInput(Data("/usr/bin/python3 -m http.server \(port) --bind 127.0.0.1\n".utf8), raw: false)
        let scanner = RemotePortScanner(deviceName: "Studio", destination: mac.name, remoteHostPath: nil, shell: { shell })
        var report: RemotePortReport?
        try await mac.waitFor("the port there", timeout: 30) {
            report = try? await scanner.ports(of: [remotePID])
            return report?.ports(of: remotePID).contains { $0.port == port } == true
        }
        // Its listener is a child of the tab's shell, there.
        let listener = try #require(report?.ports(of: remotePID).first { $0.port == port })
        serverPID = listener.pid
        #expect(listener.pid != remotePID)
        #expect(listener.host == "127.0.0.1")
        #expect(mac.calls.contains { $0.hasSuffix("-- \(mac.name) sh -s") })

        // MCP: the device reports it, labelled with the Mac and its URL
        // there; listing forwards nothing.
        let tabID = tab.id.uuidString
        func processPorts() async throws -> [ServiceRecord] {
            let response = try await Task.detached {
                try CherryControlClient(socketURL: socket).send(.getProcessPorts(.init(processID: tabID)))
            }.value
            guard case .getProcessPorts(let result)? = response.result else {
                throw HostedSessionError.message("Expected getProcessPorts, got \(String(describing: response))")
            }
            return result.services
        }
        let listed = try await processPorts()
        let service = try #require(listed.first)
        #expect(listed.count == 1)
        #expect(service.port == port)
        #expect(service.machine == "Studio")
        #expect(service.remoteURL == "http://localhost:\(port)")
        #expect(service.url == "http://localhost:\(port)")
        #expect(service.forwardedFrom == nil)
        #expect(service.forwardError == nil)
        #expect(service.pid == nil)
        #expect(service.processID == tab.id.uuidString)
        _ = try await Task.detached {
            try CherryControlClient(socketURL: socket).send(.servicesList(.init()))
        }.value
        #expect(forwards.forwards.isEmpty)
        let forwardsLog = mac.root.appendingPathComponent("forwards")
        #expect(contents(forwardsLog).isEmpty)
        // This Mac's detector was not given the device tab (no local pid).
        #expect(local.asked.allSatisfy { $0.isEmpty })

        // A click on its URL in the tab: forwarded (to This Mac's loopback
        // only), opened here, said so.
        var opened: [URL] = []
        var toasts: [ProjectWindowToast] = []
        RemoteURLOpening.opener = { opened.append($0) }
        RemoteURLOpening.showToast = { toast, _ in toasts.append(toast) }
        #expect(RemoteURLOpening.open("http://localhost:\(port)/docs/?q=1", for: tab, window: nil))
        await RemoteURLOpening.lastOpen?.value
        let clicked = try #require(forwards.forwards(of: tab.id).first { $0.remoteHost == "localhost" })
        #expect(opened.map(\.absoluteString) == ["http://127.0.0.1:\(clicked.localPort)/docs/?q=1"])
        #expect(toasts.map(\.title) == ["Forwarded from Studio"])
        let controlPath = try #require(manager.controlPathIfUp(for: mac.name))
        #expect(contents(forwardsLog).contains("forward \(controlPath) 127.0.0.1:\(clicked.localPort):localhost:\(port)"))
        // Listed again: the forward there is reported, none is added.
        let again = try #require(try await processPorts().first)
        #expect(again.url == clicked.localURL)
        #expect(again.forwardedFrom == "Studio")
        #expect(forwards.forwards.count == 1)
        // An HTTP probe (an explicit request) forwards the port it probes.
        let probe = try await Task.detached {
            try CherryControlClient(socketURL: socket).send(.waitForBoundPort(.init(
                processID: tabID, port: port, timeoutMilliseconds: 300, probeHTTP: true
            )))
        }.value
        _ = probe
        let probed = try #require(forwards.forwards(of: tab.id).first { $0.remoteHost == "127.0.0.1" })
        let forward = probed
        #expect(contents(forwardsLog).contains("forward \(controlPath) \(probed.specification)"))
        // Another URL, or a tab of This Mac: opened as usual.
        #expect(!RemoteURLOpening.open("https://example.com/", for: tab, window: nil))
        let thisMac = TerminalWorkspace(projectRoot: NSTemporaryDirectory(), createInitialSession: false)
        let localTab = thisMac.addSession(title: "Local")
        #expect(!RemoteURLOpening.open("http://localhost:\(port)/", for: localTab, window: nil))
        thisMac.closeAllSessions(intent: .windowClosed)
        // A port that cannot be forwarded: said so, nothing opened.
        try Data().write(to: mac.root.appendingPathComponent("forward-fails"))
        #expect(RemoteURLOpening.open("http://localhost:\(port + 1)/", for: tab, window: nil))
        await RemoteURLOpening.lastOpen?.value
        try FileManager.default.removeItem(at: mac.root.appendingPathComponent("forward-fails"))
        #expect(opened.count == 1)
        #expect(toasts.last?.title == "Couldn’t open localhost:\(port + 1) of Studio")

        // The tab closes: its forwards are cancelled.
        workspace.close(tab, allowEmptyWorkspace: true, intent: .userClosedTab)
        #expect(forwards.forwards.isEmpty)
        try await mac.waitFor("the forwards cancelled") {
            let log = contents(forwardsLog)
            return log.contains("cancel \(controlPath) \(forward.specification)") && log.contains("cancel \(controlPath) \(clicked.specification)")
        }
        try await mac.waitFor("the web server gone with its session") { kill(listener.pid, 0) != 0 }
        serverPID = nil
    } catch {
        await cleanUp()
        throw error
    }
    await cleanUp()
}

@Test(.enabled(if: portsRealHostEnabled))
@MainActor func RemoteDeviceRealHostForwardsAPortThroughTheSSHMaster() async throws {
    let environment = ProcessInfo.processInfo.environment
    let sockets = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: sockets.deletingLastPathComponent()) }
    let ssh: String
    let destination: String
    var fake: FakeRemoteMac?
    let loopback = environment["CHERRY_TEST_LOOPBACK_SSH"]?.nilIfEmpty
    if let loopback {
        // A real sshd on 127.0.0.1 (Scripts/test-remote-mac-loopback).
        ssh = loopback
        destination = environment["CHERRY_TEST_LOOPBACK_DESTINATION"]?.nilIfEmpty ?? "loopback"
    } else {
        let mac = try FakeRemoteMac(name: "forwards", startsDaemon: false)
        fake = mac
        try Data().write(to: mac.root.appendingPathComponent("masters"))
        ssh = mac.bin.appendingPathComponent("ssh").path
        destination = "forwards"
    }
    // Masters start as the app starts them: ClearAllForwardings=yes, which
    // clears forwards given at the start and not those asked for later.
    #expect(HostSSHMasterManager.masterArguments(destination: destination, controlPath: "/x").contains("ClearAllForwardings=yes"))
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets }, sshExecutable: { _ in ssh }, startTimeout: 20, healthCheckInterval: 3_600, idleStopDelay: 0.2
    ))
    let shell = RemoteDeviceShell(sshExecutable: ssh, environment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()])
    let forwards = RemotePortForwards(masters: manager, shell: { shell })
    // "Their" side: a page served on the loopback (the remote Mac is this one).
    let site = FileManager.default.temporaryDirectory.appendingPathComponent("ch-site-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    try "hello-forward".write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let remotePort = try #require(RemotePortForwards.unusedLocalPort())
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-m", "http.server", String(remotePort), "--bind", "127.0.0.1", "--directory", site.path]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    func cleanUp() async {
        forwards.releaseAll()
        manager.stopAll()
        if server.isRunning { kill(server.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: site)
        if let fake { await fake.tearDown() }
    }
    func fetch(_ port: Int) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: URL(string: "http://127.0.0.1:\(port)/")!) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    do {
        try server.run()
        let owner = UUID()
        let forward = try await forwards.forward(
            remotePort: remotePort, remoteHost: "127.0.0.1", destination: destination, machine: "Loopback", owner: owner
        )
        #expect(forward.remotePort == remotePort)
        #expect(forward.localPort != remotePort)
        let controlPath = try #require(manager.controlPathIfUp(for: destination))
        if let fake {
            let log = fake.root.appendingPathComponent("forwards")
            #expect(contents(log).contains("forward \(controlPath) \(forward.specification)"))
        } else {
            // Through the forward: the page served there.
            var page: String?
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                page = await fetch(forward.localPort)
                if page != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(page == "hello-forward")
        }
        // The same port again: the same forward.
        let again = try await forwards.forward(
            remotePort: remotePort, remoteHost: "127.0.0.1", destination: destination, machine: "Loopback", owner: UUID()
        )
        #expect(again == forward)
        // Released by both: cancelled.
        forwards.release(owner: owner)
        #expect(forwards.forwards.count == 1)
        forwards.releaseAll()
        #expect(forwards.forwards.isEmpty)
        if let fake {
            let log = fake.root.appendingPathComponent("forwards")
            try await fake.waitFor("the cancel") { contents(log).contains("cancel \(controlPath) \(forward.specification)") }
        } else {
            var stillServed = true
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if await fetch(forward.localPort) == nil { stillServed = false; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(!stillServed)
        }
        // A master that stops takes its forwards with it.
        _ = try await forwards.forward(
            remotePort: remotePort, remoteHost: "127.0.0.1", destination: destination, machine: "Loopback", owner: owner
        )
        #expect(forwards.forwards.count == 1)
        manager.stopAll()
        let deadline = Date().addingTimeInterval(10)
        while !forwards.forwards.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(forwards.forwards.isEmpty)
    } catch {
        await cleanUp()
        throw error
    }
    await cleanUp()
}

@Test(.enabled(if: portsRealHostEnabled))
@MainActor func RemoteDeviceRealHostForwardsMadeWhileTheirTabClosesAreCancelledAndKeepOtherLeases() async throws {
    let mac = try FakeRemoteMac(name: "racing", startsDaemon: false)
    try mac.addMac("other", host: "link")
    try Data().write(to: mac.root.appendingPathComponent("masters"))
    let sockets = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: sockets.deletingLastPathComponent()) }
    let ssh = mac.bin.appendingPathComponent("ssh").path
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets }, sshExecutable: { _ in ssh }, startTimeout: 10, healthCheckInterval: 3_600, idleStopDelay: 0.2
    ))
    let shell = mac.shell
    let forwards = RemotePortForwards(masters: manager, shell: { shell })
    let log = mac.root.appendingPathComponent("forwards")
    func cleanUp() async {
        forwards.releaseAll()
        manager.stopAll()
        await mac.tearDown()
    }
    do {
        // A tab closes while its forward is being made: the forward, once
        // made, is cancelled and the master's lease let go.
        let closing = UUID()
        let made = Task { @MainActor in
            try await forwards.forward(remotePort: 3000, destination: "racing", machine: "Racing", owner: closing)
        }
        while !forwards.isMaking("racing") { await Task.yield() }
        forwards.release(owner: closing)
        let forward = try await made.value
        #expect(forwards.forwards.isEmpty)
        #expect(forwards.forwards(of: closing).isEmpty)
        try await mac.waitFor("the orphan forward cancelled") { contents(log).contains("cancel") && contents(log).contains(forward.specification) }
        #expect(manager.status(of: "racing")?.leases == 0)
        // A tab of the same Mac asking again later gets a forward of its own.
        let reopened = UUID()
        let fresh = try await forwards.forward(remotePort: 3000, destination: "racing", machine: "Racing", owner: reopened)
        #expect(forwards.forwards(of: reopened) == [fresh])

        // Another tab (of another Mac) closing while a forward of this one
        // is being made takes no lease from it.
        let waiting = UUID()
        let other = Task { @MainActor in
            try await forwards.forward(remotePort: 4000, destination: "other", machine: "Other", owner: waiting)
        }
        while !forwards.isMaking("other") { await Task.yield() }
        forwards.release(owner: reopened)
        let otherForward = try await other.value
        #expect(forwards.forwards(of: waiting) == [otherForward])
        #expect(manager.status(of: "other")?.leases == 1)
        #expect(manager.status(of: "racing")?.leases == 0)
    } catch {
        await cleanUp()
        throw error
    }
    await cleanUp()
}

// MARK: - The fake Mac's stop leaves nothing running

@Test(.enabled(if: portsRealHostEnabled))
@MainActor func RemoteDeviceRealHostFakeMacStopRefusesConnectionsAndEndsALateDaemon() async throws {
    let mac = try FakeRemoteMac(name: "stopping", startsDaemon: false)
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let socket = mac.socket.path
    func running() -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "serve --socket \(socket)"]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }
    var late: Process?
    do {
        let stop = Process()
        stop.executableURL = repository.appendingPathComponent("Scripts/fake-remote-mac")
        stop.arguments = ["stop", mac.root.path]
        stop.standardOutput = FileHandle.nullDevice
        try stop.run()
        // A gateway that was already running starts a daemon there while
        // the stop runs.
        try await Task.sleep(for: .milliseconds(150))
        let daemon = Process()
        daemon.executableURL = mac.binaries.appendingPathComponent("cherry-host")
        daemon.arguments = ["serve", "--socket", socket]
        daemon.environment = ["HOME": mac.home.path, "CHERRY_HOST_SOCKET": socket, "PATH": "/usr/bin:/bin"]
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        late = daemon
        await Task.detached { stop.waitUntilExit() }.value
        #expect(stop.terminationStatus == 0)
        // The stop saw it and ended it.
        try await mac.waitFor("the late daemon ended", timeout: 5) { !daemon.isRunning }
        #expect(!running())
        // And the shim refuses every connection from now on.
        let refused = await mac.shell.run("echo HELLO\n", on: mac.name)
        #expect(refused.status == 255)
        #expect(refused.standardError.contains("stopped"))
        #expect(!refused.standardOutput.contains("HELLO"))
    } catch {
        if let late, late.isRunning { kill(late.processIdentifier, SIGKILL) }
        await mac.tearDown()
        throw error
    }
    if let late, late.isRunning { kill(late.processIdentifier, SIGKILL) }
    await mac.tearDown()
}
