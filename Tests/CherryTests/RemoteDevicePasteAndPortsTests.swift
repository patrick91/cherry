import AppKit
import CherryControl
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing
@testable import Cherry

// Pasted images (in any tab) and the pure parts of phase 4a of devices
// (docs/specs/remote-devices.md): `cherry-host ports` answers, forwards'
// arguments, localhost URLs of a device tab. What runs through a fake
// remote Mac is in RemoteDeviceRealHostPortsAndPasteTests. No test here
// touches the general pasteboard: each makes its own, with a unique name.

private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!

/// A small RGB image as TIFF (what a screenshot's pasteboard also offers).
private func tiffImage() throws -> Data {
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 3,
        hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    return try #require(rep.tiffRepresentation)
}

private final class PrivatePasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CherryTests.Paste.\(UUID().uuidString)"))
    /// A cache folder of its own, with a space as the real one has.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CherryPasteTests-\(UUID().uuidString.prefix(8))/Pasted Images", isDirectory: true)

    init() { pasteboard.clearContents() }

    func cleanUp() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    var saved: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
    }
}

@Test @MainActor func RemoteDevicePasteOfAnImageAlonePastesItsSavedPathQuotedAndBracketed() throws {
    let board = PrivatePasteboard()
    defer { board.cleanUp() }
    board.pasteboard.setData(onePixelPNG, forType: .png)

    #expect(PastedContent(pasteboard: board.pasteboard) == .image(onePixelPNG))
    // Bracketed while the program asks for it (a host-routed tab), quoted:
    // the folder's name has a space.
    let bracketed = try #require(TerminalPasteboardContent.pasteData(
        from: board.pasteboard, imageDirectory: board.directory, bracketing: { _ in true }
    ))
    let file = try #require(board.saved.first)
    let expected = board.directory.appendingPathComponent(file.lastPathComponent).path
    #expect(String(decoding: bracketed, as: UTF8.self) == "\u{1B}[200~'\(expected)'\u{1B}[201~")
    #expect(try Data(contentsOf: file) == onePixelPNG)
    #expect(file.lastPathComponent.range(of: #"^\d{8}-\d{6}-[0-9a-f]{8}\.png$"#, options: .regularExpression) != nil)
    let plain = try #require(TerminalPasteboardContent.pasteData(
        from: board.pasteboard, imageDirectory: board.directory, bracketing: { _ in false }
    ))
    #expect(String(decoding: plain, as: UTF8.self).hasPrefix("'\(board.directory.path)/"))
    #expect(!String(decoding: plain, as: UTF8.self).contains("\u{1B}"))

    // ⌘V on a native surface: the quoted path goes to the tab's paste,
    // which the surface brackets as the program asks.
    let savedDirectory = LocalImagePaste.directory
    defer { LocalImagePaste.directory = savedDirectory }
    LocalImagePaste.directory = { board.directory }
    var inserted: [String] = []
    #expect(LocalImagePaste.handle(board.pasteboard) { inserted.append($0) })
    #expect(inserted.count == 1)
    let path = try #require(inserted.first.map { String($0.dropFirst().dropLast()) })
    #expect(inserted[0] == "'\(path)'")
    #expect(path.hasPrefix(board.directory.path + "/"))
    #expect(FileManager.default.fileExists(atPath: path))
    // A simple path is pasted as it is.
    #expect(PastedImage.quoted("/tmp/x/20260101-000000-abcdef01.png") == "/tmp/x/20260101-000000-abcdef01.png")
    #expect(PastedImage.quoted("/tmp/it's here.png") == "'/tmp/it'\\''s here.png'")
}

@Test @MainActor func RemoteDevicePasteOfTIFFImageDataIsConvertedToPNG() throws {
    let board = PrivatePasteboard()
    defer { board.cleanUp() }
    board.pasteboard.setData(try tiffImage(), forType: .tiff)
    let png = try #require(PastedContent(pasteboard: board.pasteboard).image)
    #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
}

@Test @MainActor func RemoteDevicePasteOfTextWithAnImagePastesTheText() throws {
    let board = PrivatePasteboard()
    defer { board.cleanUp() }
    board.pasteboard.declareTypes([.string, .png], owner: nil)
    board.pasteboard.setString("echo hi", forType: .string)
    board.pasteboard.setData(onePixelPNG, forType: .png)

    #expect(PastedContent(pasteboard: board.pasteboard) == .text)
    let savedDirectory = LocalImagePaste.directory
    defer { LocalImagePaste.directory = savedDirectory }
    LocalImagePaste.directory = { board.directory }
    #expect(!LocalImagePaste.handle(board.pasteboard) { _ in Issue.record("inserted") })
    let data = try #require(TerminalPasteboardContent.pasteData(
        from: board.pasteboard, imageDirectory: board.directory, bracketing: { _ in false }
    ))
    #expect(String(decoding: data, as: UTF8.self) == "echo hi")
    #expect(board.saved.isEmpty)
    // A device tab's paste of it is text too: nothing to copy.
    #expect(RemoteFileDrop.content(from: board.pasteboard, preferringText: true) == nil)
}

@Test @MainActor func RemoteDevicePasteOfFileURLsKeepsTheFileBehaviour() throws {
    let board = PrivatePasteboard()
    defer { board.cleanUp() }
    // Finder puts the file, its name (as text) and its icon (TIFF) on the
    // pasteboard.
    let file = URL(fileURLWithPath: "/tmp/cherry paste/shot.png")
    board.pasteboard.clearContents()
    board.pasteboard.writeObjects([file as NSURL])
    board.pasteboard.addTypes([.string, .tiff], owner: nil)
    board.pasteboard.setString("shot.png", forType: .string)
    board.pasteboard.setData(try tiffImage(), forType: .tiff)

    #expect(PastedContent(pasteboard: board.pasteboard) == .files([file]))
    let savedDirectory = LocalImagePaste.directory
    defer { LocalImagePaste.directory = savedDirectory }
    LocalImagePaste.directory = { board.directory }
    #expect(!LocalImagePaste.handle(board.pasteboard) { _ in Issue.record("inserted") })
    // This Mac's host-routed paste pastes the text, as before.
    #expect(TerminalPasteboardContent.pasteText(from: board.pasteboard, imageDirectory: board.directory) == "shot.png")
    #expect(board.saved.isEmpty)
    // A device tab asks about the file, as before (not an image copy).
    #expect(RemoteFileDrop.content(from: board.pasteboard, preferringText: true) == .files([file]))
    #expect(RemoteFileDrop.content(from: board.pasteboard, preferringText: false) == .files([file]))
}

@Test @MainActor func RemoteDevicePastedImagesOlderThanAWeekArePruned() throws {
    let board = PrivatePasteboard()
    defer { board.cleanUp() }
    let directory = board.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    func file(_ name: String, age: TimeInterval) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try onePixelPNG.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }
    let old = try file("20200101-000000-00000000.png", age: 8 * 24 * 3600)
    let recent = try file("20200101-000000-11111111.png", age: 6 * 24 * 3600)
    let notOurs = directory.appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: notOurs)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 24 * 3600)], ofItemAtPath: notOurs.path)

    // Saving the next image prunes the folder.
    let saved = try PastedImageStore.save(onePixelPNG, in: directory, now: now)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: notOurs.path))
    #expect(FileManager.default.fileExists(atPath: saved.path))
    // Later, the recent one goes too.
    #expect(PastedImageStore.prune(directory, now: now.addingTimeInterval(2 * 24 * 3600)).map(\.lastPathComponent)
        == [recent.lastPathComponent])
    // The default folder is the app's cache.
    #expect(PastedImageStore.defaultDirectory.path.hasSuffix("/Library/Caches/\(CherryAppIdentity.current.applicationSupportName)/Pasted Images"))
}

@Test @MainActor func RemoteDeviceClipboardSetterScriptAndOutcomes() throws {
    let script = RemoteClipboardSetter.script(path: #"/var/t/cherry-drop.1/it's "x".png"#)
    #expect(script.contains(#"POSIX file "/var/t/cherry-drop.1/it'\''s \"x\".png""#))
    #expect(script.contains("as «class PNGf»"))
    #expect(script.contains("clipboard info for «class PNGf»"))
    // It runs under sh as written (a syntax check).
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/bin/sh")
    check.arguments = ["-n", "-c", script]
    try check.run()
    check.waitUntilExit()
    #expect(check.terminationStatus == 0)

    func output(_ out: String, _ status: Int32 = 0, _ errors: String = "") -> RemoteDeviceShell.Output {
        RemoteDeviceShell.Output(status: status, standardOutput: out, standardError: errors)
    }
    #expect(RemoteClipboardSetter.outcome(of: output("CHERRY-CLIPBOARD=ok\n"), machine: "Studio") == .set)
    #expect(RemoteClipboardSetter.outcome(of: output("CHERRY-CLIPBOARD=failed execution error (-10810) \n"), machine: "Studio")
        == .failed("execution error (-10810)"))
    guard case .failed(let unreachable) = RemoteClipboardSetter.outcome(
        of: output("", 255, "ssh: connect to host studio port 22: Connection timed out"), machine: "Studio"
    ) else {
        Issue.record("not failed")
        return
    }
    #expect(unreachable.hasPrefix("Could not reach Studio"))
    let toast = RemoteClipboardImagePaste.fallbackToast(machine: "Studio", reason: "no GUI session")
    #expect(toast.title == "Pasted the image’s path on Studio")
    #expect(toast.message?.contains("(no GUI session)") == true)
}

@Test @MainActor func RemoteDevicePortsReportParsingAndScript() throws {
    let script = RemotePortScanner.script(pids: [42, 7], remoteHostPath: "~/Library/Application Support/cherry-host/bin/b/cherry-host")
    #expect(script.contains("exec \"$host\" ports --json 42 7"))
    #expect(script.contains("printf '%s\\n' 'CHERRY-PORTS 1'"))
    #expect(RemotePortScanner.script(pids: [1], remoteHostPath: nil).contains("host=cherry-host"))

    func output(_ text: String, _ status: Int32 = 0, _ errors: String = "") -> RemoteDeviceShell.DataOutput {
        RemoteDeviceShell.DataOutput(status: status, standardOutput: Data(text.utf8), standardError: errors)
    }
    let report = try RemotePortScanner.parse(output("""
    CHERRY-PORTS 1
    {"version":1,"processes":[{"pid":42,"alive":true,"ports":[{"port":3000,"host":"127.0.0.1","pid":43,"command":"node"},{"port":3000,"host":"::1","pid":43}]},{"pid":7,"alive":false,"ports":[]}]}
    """), machine: "Studio")
    #expect(report.ports(of: 42).map(\.port) == [3000, 3000])
    #expect(report.ports(of: 42).first?.command == "node")
    #expect(report.ports(of: 7).isEmpty)
    #expect(report.ports(of: 99).isEmpty)
    // An older cherry-host, an unreachable Mac, another version.
    #expect(throws: RemoteProjectError.self) {
        try RemotePortScanner.parse(output("CHERRY-PORTS 1\n", 2, "error: unrecognized subcommand 'ports'"), machine: "Studio")
    }
    do {
        _ = try RemotePortScanner.parse(output("", 255, "ssh: connect to host studio port 22: Connection timed out"), machine: "Studio")
        Issue.record("parsed")
    } catch let error as RemoteProjectError {
        guard case .unreachable = error else { Issue.record("\(error)"); return }
    }
    #expect(throws: RemoteProjectError.self) {
        try RemotePortScanner.parse(output("CHERRY-PORTS 1\n{\"version\":2,\"processes\":[]}"), machine: "Studio")
    }
    // Where a forward reaches a port there.
    #expect(DeviceServiceDetector.forwardHost(forListenerHosts: ["127.0.0.1", "::1"]) == "localhost")
    #expect(DeviceServiceDetector.forwardHost(forListenerHosts: ["127.0.0.1"]) == "127.0.0.1")
    #expect(DeviceServiceDetector.forwardHost(forListenerHosts: ["::1"]) == "::1")
    #expect(DeviceServiceDetector.forwardHost(forListenerHosts: ["*"]) == "localhost")
}

@Test @MainActor func RemoteDeviceForwardArgumentsAndLocalhostURLs() throws {
    let forward = RemotePortForward(destination: "studio", machine: "Studio", remoteHost: "localhost", remotePort: 3000, localPort: 52011)
    // Bound to This Mac's loopback explicitly, whatever GatewayPorts says,
    // and masters run with GatewayPorts=no.
    #expect(forward.specification == "127.0.0.1:52011:localhost:3000")
    #expect(forward.localURL == "http://127.0.0.1:52011")
    #expect(HostSSHMasterManager.masterArguments(destination: "studio", controlPath: "/t/s").contains("GatewayPorts=no"))
    #expect(forward.label == "Forwarded from Studio")
    #expect(RemotePortForwards.commandArguments("forward", forward: forward, controlPath: "/t/s%1") == [
        "-o", "ControlPath=/t/s%%1", "-o", "BatchMode=yes", "-O", "forward", "-L", "127.0.0.1:52011:localhost:3000", "--", "studio",
    ])
    let v6 = RemotePortForward(destination: "studio", machine: "Studio", remoteHost: "::1", remotePort: 5173, localPort: 5000)
    #expect(v6.specification == "127.0.0.1:5000:[::1]:5173")

    func target(_ string: String) -> String? {
        URL(string: string).flatMap(RemoteURLOpening.loopbackTarget(of:)).map { "\($0.remoteHost) \($0.port)" }
    }
    #expect(target("http://localhost:3000/app?x=1#top") == "localhost 3000")
    #expect(target("http://127.0.0.1:8000") == "127.0.0.1 8000")
    #expect(target("http://0.0.0.0:5173/") == "localhost 5173")
    #expect(target("http://[::1]:4000/") == "::1 4000")
    #expect(target("https://localhost/") == "localhost 443")
    #expect(target("http://localhost/") == "localhost 80")
    #expect(target("http://127.1.2.3:9000/") == "127.1.2.3 9000")
    #expect(target("http://[::]:4000/") == "localhost 4000")
    #expect(target("https://example.com:3000/") == nil)
    #expect(target("file:///tmp/x") == nil)
    #expect(target("http://192.168.1.2:3000/") == nil)
    // Names that only look like the loopback, and other schemes: no.
    #expect(target("http://127.evil.example.com:3000/") == nil)
    #expect(target("http://127.0.0.1.nip.io:3000/") == nil)
    #expect(target("http://localhost.evil.example:3000/") == nil)
    #expect(target("http://0x7f.0.0.1:3000/") == nil)
    #expect(target("http://[::ffff:127.0.0.1]:3000/") == nil)
    #expect(target("ws://localhost:3000/") == nil)
    #expect(target("ftp://localhost:21/") == nil)

    // Opened where the forward listens (127.0.0.1: `localhost` may try ::1).
    let url = try #require(URL(string: "http://localhost:3000/app?x=1#top"))
    #expect(RemoteURLOpening.forwardedURL(url, localPort: 52011)?.absoluteString == "http://127.0.0.1:52011/app?x=1#top")
    #expect(RemoteURLOpening.forwardedURL(try #require(URL(string: "http://127.0.0.1:8000/")), localPort: 5)?.absoluteString
        == "http://127.0.0.1:5/")
    #expect(RemoteURLOpening.forwardedURL(try #require(URL(string: "http://0.0.0.0:8000")), localPort: 5)?.absoluteString
        == "http://127.0.0.1:5")
    #expect(RemoteURLOpening.forwardedURL(try #require(URL(string: "http://[::1]:8000/a")), localPort: 5)?.absoluteString
        == "http://127.0.0.1:5/a")
    let toast = RemoteURLOpening.forwardedToast(forward)
    #expect(toast.title == "Forwarded from Studio")
    #expect(toast.message == "localhost:3000 on Studio opens here as 127.0.0.1:52011.")

    // A free port on This Mac's loopback.
    let port = try #require(RemotePortForwards.unusedLocalPort())
    #expect((1024...65_535).contains(port))

    // A record of another Mac's service carries the Mac, and decodes
    // without the new fields from an older app.
    let record = ServiceRecord(
        processID: "p", processName: "server", kind: "command", pid: nil, port: 3000, host: "127.0.0.1",
        url: "http://localhost:52011", attribution: .processTree, protocolGuess: "http", readiness: .bound,
        lastSeenAt: Date(timeIntervalSince1970: 0), commandName: "server", agentName: nil,
        machine: "Studio", remoteURL: "http://localhost:3000", forwardedFrom: "Studio", forwardError: nil
    )
    let encoded = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(ServiceRecord.self, from: encoded) == record)
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for key in ["machine", "remoteURL", "forwardedFrom", "forwardError"] { object[key] = nil }
    let old = try JSONDecoder().decode(ServiceRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.machine == nil && old.forwardedFrom == nil)
}

@Test @MainActor func RemoteDeviceControlVTakesOverOnlyWhileTheAgentIsInFront() {
    func info(pid: UInt32 = 100, foreground: HostedSessionForeground?, running: Bool = true) -> HostedSessionInfo {
        HostedSessionInfo(id: "s", name: "Claude", cwd: "/", state: running ? .running : .exited, pid: pid, foreground: foreground)
    }
    // A known agent in front, in an agent tab or a terminal.
    #expect(RemoteClipboardImagePaste.foregroundIsAgent(info(foreground: .init(pid: 120, name: "claude")), kind: .agent))
    #expect(RemoteClipboardImagePaste.foregroundIsAgent(info(foreground: .init(pid: 120, name: "codex")), kind: .terminal))
    // An agent tab's own program in front (the agent it runs, whatever its name).
    #expect(RemoteClipboardImagePaste.foregroundIsAgent(info(foreground: .init(pid: 100, name: "node")), kind: .agent))
    // An editor the agent opened, or a shell's command: not the agent.
    #expect(!RemoteClipboardImagePaste.foregroundIsAgent(info(foreground: .init(pid: 130, name: "vim")), kind: .agent))
    #expect(!RemoteClipboardImagePaste.foregroundIsAgent(info(foreground: .init(pid: 100, name: "zsh")), kind: .terminal))
    // Not known, or not running.
    #expect(!RemoteClipboardImagePaste.foregroundIsAgent(info(foreground: nil), kind: .agent))
    #expect(!RemoteClipboardImagePaste.foregroundIsAgent(info(foreground: .init(pid: 100, name: "claude"), running: false), kind: .agent))
    #expect(!RemoteClipboardImagePaste.foregroundIsAgent(nil, kind: .agent))
}

@Test @MainActor func RemoteDeviceKeyMonitorRoutesPasteAndControlVOnNativeSurfaces() {
    typealias View = GhosttyTerminalContainerView
    func route(_ modifiers: NSEvent.ModifierFlags, _ characters: String?, holds: Bool = false) -> View.NativeKeyRoute {
        View.nativeKeyRoute(modifiers: modifiers, charactersIgnoringModifiers: characters, holdsKeys: holds)
    }
    #expect(route(.command, "v") == .paste)
    #expect(route([.command, .shift], "V") == .paste)
    #expect(route(.control, "v") == .controlV)
    // Arrow-like flags a key event carries are not held modifiers.
    #expect(route([.control, .numericPad, .function], "v") == .controlV)
    #expect(route([.control, .shift], "v") == .other)
    #expect(route([.control, .option], "v") == .other)
    #expect(route([.command, .control], "v") == .other)
    #expect(route([], "v") == .other)
    #expect(route(.control, "c") == .other)
    // While a Ctrl+V's image goes to another Mac: keys are held, Command
    // shortcuts are not.
    #expect(route([], "a", holds: true) == .hold)
    #expect(route(.control, "c", holds: true) == .hold)
    #expect(route(.command, "w", holds: true) == .other)
    #expect(route(.command, "v", holds: true) == .paste)
    #expect(View.isPasteShortcut(modifiers: .command, charactersIgnoringModifiers: "V"))
    #expect(!View.isPasteShortcut(modifiers: [.command, .option], charactersIgnoringModifiers: "v"))
    #expect(View.isControlV(modifiers: .control, charactersIgnoringModifiers: "V"))
    #expect(!View.isControlV(modifiers: .command, charactersIgnoringModifiers: "v"))
}

@MainActor
private final class OpenURLDelegate: TerminalSurfaceOpenURLDelegate {
    var handles: Bool
    var asked: [String] = []
    init(handles: Bool) { self.handles = handles }
    func terminalShouldHandleOpenURL(_ url: String) -> Bool {
        asked.append(url)
        return handles
    }
}

@MainActor
private final class PlainDelegate: TerminalSurfaceViewDelegate {}

@Test @MainActor func RemoteDeviceGhosttyOpenURLAsksTheDelegateBeforeOpeningItself() throws {
    let url = "http://localhost:3000/x"
    func action(_ text: String, tag: ghostty_action_tag_e = GHOSTTY_ACTION_OPEN_URL) -> (ghostty_action_s, UnsafeMutablePointer<CChar>) {
        let buffer = strdup(text)!
        var action = ghostty_action_s()
        action.tag = tag
        action.action.open_url = ghostty_action_open_url_s(
            kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: UnsafePointer(buffer), len: UInt(strlen(buffer))
        )
        return (action, buffer)
    }
    let (open, buffer) = action(url)
    defer { free(buffer) }
    // The delegate opens it: true, so Ghostty does not open it too.
    let taking = OpenURLDelegate(handles: true)
    #expect(TerminalCallbacks.openURL(open, bridge: TerminalCallbackBridge(delegate: taking)))
    #expect(taking.asked == [url])
    // It leaves it to Ghostty, or does not open URLs at all: false.
    let leaving = OpenURLDelegate(handles: false)
    #expect(!TerminalCallbacks.openURL(open, bridge: TerminalCallbackBridge(delegate: leaving)))
    #expect(leaving.asked == [url])
    let plain = PlainDelegate()
    #expect(!TerminalCallbacks.openURL(open, bridge: TerminalCallbackBridge(delegate: plain)))
    // Another action is never taken for a URL.
    let (other, otherBuffer) = action(url, tag: GHOSTTY_ACTION_RING_BELL)
    defer { free(otherBuffer) }
    #expect(!TerminalCallbacks.openURL(other, bridge: TerminalCallbackBridge(delegate: taking)))

    // Cherry's delegate: a tab of This Mac leaves every URL to Ghostty.
    let workspace = TerminalWorkspace(projectRoot: NSTemporaryDirectory(), createInitialSession: false)
    let tab = workspace.addSession(title: "Local")
    #expect(!tab.ghosttyBridge.terminalShouldHandleOpenURL(url))
    workspace.closeAllSessions(intent: .windowClosed)
}
