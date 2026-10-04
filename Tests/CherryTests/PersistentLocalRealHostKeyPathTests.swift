import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import Cherry

// Keys typed into a persistent tab, down the real key path: an NSEvent
// through NSApp.sendEvent to the window, Cherry's key monitors, the Ghostty
// surface's encoder, the attach adapter, the daemon and the holder, to the
// program's PTY. What the program reads is compared with what a native tab's
// program reads for the same keys in every keyboard mode a program can set
// (the holder's terminal tracks the modes, and the surface must see them
// too, or its encoder would type something the program does not expect), and
// tmux's prefix key detaches it. Gated like the other real-host suites:
// CHERRY_TEST_HOST_INTEGRATION=1 and the Rust helpers built
// (Scripts/build-host debug). tmux runs on a private socket with no
// configuration file of the user's (`-f` a file of the test's own).

private let keyPathRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"
    && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// A key as the keyboard sends it to the app.
struct TypedKey: CustomStringConvertible {
    var name: String
    var characters: String
    var charactersIgnoringModifiers: String
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags = []

    var description: String { name }

    static let controlB = TypedKey(name: "Ctrl+B", characters: "\u{02}", charactersIgnoringModifiers: "b", keyCode: 11, modifiers: .control)
    static let controlSpace = TypedKey(name: "Ctrl+Space", characters: "\u{00}", charactersIgnoringModifiers: " ", keyCode: 49, modifiers: .control)
    static let d = TypedKey(name: "d", characters: "d", charactersIgnoringModifiers: "d", keyCode: 2)
    static let z = TypedKey(name: "z", characters: "z", charactersIgnoringModifiers: "z", keyCode: 6)
    static let up = TypedKey(name: "Up", characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", keyCode: 126, modifiers: [.numericPad, .function])
    static let escape = TypedKey(name: "Escape", characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", keyCode: 53)
    static let controlReturn = TypedKey(name: "Ctrl+Return", characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36, modifiers: .control)
    static let keypadOne = TypedKey(name: "Keypad 1", characters: "1", charactersIgnoringModifiers: "1", keyCode: 83, modifiers: .numericPad)
}

/// A titled window showing one tab, whose surface has the keyboard; keys
/// are typed into it as the keyboard would. One stage per test: the test
/// app is never active, and AppKit keeps sending key events to the window
/// it made key first.
@MainActor
final class KeyPathStage {
    let window: NSWindow
    let container: GhosttyTerminalContainerView

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
    }

    func show(_ tab: TerminalSession) {
        container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
        window.makeKeyAndOrderFront(nil)
    }

    /// Gives the tab's surface the keyboard.
    func focus(_ tab: TerminalSession) -> Bool {
        window.makeFirstResponder(tab.ghosttyBridge.terminalView)
    }

    /// `key` as the keyboard sends it: through the app's event monitors,
    /// then the window (key equivalents first, then the first responder).
    func type(_ key: TypedKey) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false, keyCode: key.keyCode
        ))
        NSApp.sendEvent(event)
    }

    func cleanUp() {
        container.detachActiveSession()
        window.close()
    }
}

/// A tmux on a private socket, with a configuration file of its own.
struct PrivateTmux {
    let executable: String
    let socket: String
    let configuration: String

    /// The tmux on this Mac, if any (CI runners may have none).
    static var installed: String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { "\($0)/tmux" }
            + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/run/current-system/sw/bin/tmux",
               "/etc/profiles/per-user/\(NSUserName())/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `directory`: private to the test, and short enough for a socket.
    init?(in directory: URL, name: String = "tmux", configuration lines: [String] = []) throws {
        guard let executable = Self.installed else { return nil }
        self.executable = executable
        socket = directory.appendingPathComponent("\(name).sock").path
        let file = directory.appendingPathComponent("\(name).conf")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        configuration = file.path
    }

    /// The command that starts session `t`, attached, in a terminal.
    var newSessionCommand: String {
        "SHELL=/bin/sh \(executable) -S \(socket) -f \(configuration) new -s t"
    }

    /// The sessions and how many clients each has, as `name:clients` lines.
    func sessions() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-S", socket, "ls", "-F", "#{session_name}:#{session_attached}"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func killServer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-S", socket, "kill-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// A program that reads its terminal raw and logs what it reads: for each
/// step, it writes the step's bytes (the keyboard modes it sets), says
/// `STEP_<n>_READY`, and logs everything it reads until a `z`, as
/// `<n> <hex>` lines. `ALL_STEPS_DONE` after the last step.
enum KeyLogger {
    static let script = #"""
    import os, sys, tty
    log = open(sys.argv[1], "ab", buffering=0)
    steps = [bytes.fromhex(step) for step in sys.argv[2:]]
    tty.setraw(0)
    for index, mode in enumerate(steps):
        os.write(1, mode + b"STEP_%d_READY\r\n" % index)
        read = b""
        while not read.endswith(b"z"):
            chunk = os.read(0, 1024)
            if not chunk:
                sys.exit(0)
            read += chunk
        log.write(b"%d %s\n" % (index, read.hex().encode()))
    os.write(1, b"ALL_STEPS_DONE\r\n")
    os.read(0, 1)
    """#

    /// The keyboard modes each step sets, as a program does.
    static let modes: [(name: String, bytes: String)] = [
        ("legacy", ""),
        ("application cursor keys (DECCKM) and keypad (DECKPAM)", "\u{1B}[?1h\u{1B}="),
        ("normal cursor keys and keypad (DECKPNM)", "\u{1B}[?1l\u{1B}>"),
        ("modifyOtherKeys 2", "\u{1B}[>4;2m"),
        ("modifyOtherKeys reset", "\u{1B}[>4m"),
        ("kitty push 1 (disambiguate)", "\u{1B}[>1u"),
        ("kitty pop", "\u{1B}[<u"),
        ("kitty set 1", "\u{1B}[=1;1u"),
        ("kitty set 0", "\u{1B}[=0;1u"),
    ]

    static let keys: [TypedKey] = [.controlB, .controlSpace, .d, .up, .keypadOne, .controlReturn, .escape, .z]

    /// The command that runs the logger for every step in `modes`.
    static func command(script: URL, log: URL) -> String {
        let hex = modes.map { Data($0.bytes.utf8).map { String(format: "%02x", $0) }.joined() }
        // An empty step is an empty argument.
        return "/usr/bin/python3 \(script.path) \(log.path) " + hex.map { "'\($0)'" }.joined(separator: " ")
    }

    static func write(to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("keylogger.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// What the program read at each step, as hex.
    static func read(_ log: URL) -> [Int: String] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        var steps: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let index = Int(parts[0]) else { continue }
            steps[index] = String(parts[1])
        }
        return steps
    }

    /// Types every key at every step into the tab `stage` shows (only `z`
    /// at steps `steps` leaves out); returns what the program read, by
    /// step. `screen`: where the program's output shows.
    @MainActor
    static func run(
        _ tab: TerminalSession, stage: KeyPathStage, log: URL, keys: [TypedKey] = keys,
        steps: Set<Int>? = nil,
        screen: @escaping @MainActor () async throws -> String
    ) async throws -> [Int: String] {
        for index in modes.indices {
            try await poll("step \(index) of the key logger") { try await screen().contains("STEP_\(index)_READY") }
            for key in steps.map({ $0.contains(index) }) ?? true ? keys : [.z] { try stage.type(key) }
            try await poll("the key logger to log step \(index)") { KeyLogger.read(log)[index] != nil }
        }
        try await poll("the key logger's end") { try await screen().contains("ALL_STEPS_DONE") }
        return read(log)
    }
}

@MainActor
func poll(_ description: String, timeout: TimeInterval = 15, _ predicate: @MainActor () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw HostedSessionError.message("Timed out waiting for \(description)")
}

private func hex(_ text: String) -> String {
    Data(text.utf8).map { String(format: "%02x", $0) }.joined()
}

/// Every step of the key logger, as a native tab's program reads its keys.
@MainActor
private func nativeKeyBytes(in directory: URL, stage: KeyPathStage) async throws -> [Int: String] {
    let project = directory.appendingPathComponent("native", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let workspace = TerminalWorkspace(projectRoot: project.path, createInitialSession: false, launchBackend: .nativePTY)
    defer {
        stage.container.detachActiveSession()
        workspace.closeAllSessions(intent: .windowClosed)
    }
    let script = try KeyLogger.write(to: directory)
    let log = directory.appendingPathComponent("native.log")
    let tab = workspace.addSession(title: "Native keys", command: KeyLogger.command(script: script, log: log))
    stage.show(tab)
    #expect(tab.ghosttyBridge.isNativePTYBacked)
    #expect(tab.persistentSession == nil)
    #expect(stage.focus(tab))
    return try await KeyLogger.run(tab, stage: stage, log: log) { tab.ghosttyBridge.readNativeScreenText() ?? "" }
}

@Test(.enabled(if: keyPathRealHostEnabled))
@MainActor func PersistentLocalRealHostKeysReachTheProgramAsInANativeTabInEveryKeyboardMode() async throws {
    var configuration = PersistentLocalSessions.Configuration()
    // Once lost, the adapter stays lost for the test.
    configuration.reconnectDelay = (120, 120)
    let host = try await RealLocalHost(configuration: configuration)
    let workspace = host.workspace()
    let stage = KeyPathStage()
    func cleanUp() async {
        stage.cleanUp()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
    }
    do {
        let native = try await nativeKeyBytes(in: host.root, stage: stage)
        let script = try KeyLogger.write(to: host.root)

        // The surface's encoder, through the attach adapter.
        let attachedLog = host.root.appendingPathComponent("attached.log")
        let tab = workspace.addSession(title: "Keys", command: "exec " + KeyLogger.command(script: script, log: attachedLog))
        #expect(tab.isPersistentLocalSession)
        stage.show(tab)
        try await host.waitFor("the tab to attach to its session") {
            tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackend && !tab.readsContentFromHost
        }
        #expect(stage.focus(tab))
        let attached = try await KeyLogger.run(tab, stage: stage, log: attachedLog) { host.screen(tab) }
        for (index, mode) in KeyLogger.modes.enumerated() {
            #expect(attached[index] == native[index], "\(mode.name): persistent \(attached[index] ?? "-"), native \(native[index] ?? "-")")
        }
        // Ctrl+B is 0x02 and Ctrl+Space NUL wherever the kitty keyboard
        // protocol and modifyOtherKeys 2 are off; `CSI 27;5;98~` under
        // modifyOtherKeys 2 (Ghostty encodes Control keys with it since
        // 3c47ca159368), `CSI 98;5u` under the kitty protocol.
        let legacyPrefix = "0200" + hex("d")
        for index in [0, 1, 2, 4, 6, 8] {
            #expect(attached[index]?.hasPrefix(legacyPrefix) == true, "\(KeyLogger.modes[index].name): \(attached[index] ?? "-")")
        }
        #expect(
            attached[3]?.hasPrefix(hex("\u{1B}[27;5;98~\u{1B}[27;5;32~d")) == true,
            "\(KeyLogger.modes[3].name): \(attached[3] ?? "-")"
        )
        for index in [5, 7] {
            #expect(attached[index]?.hasPrefix(hex("\u{1B}[98;5u")) == true, "\(KeyLogger.modes[index].name): \(attached[index] ?? "-")")
        }
        #expect(attached[1]?.contains(hex("\u{1B}OA")) == true)
        #expect(attached[0]?.contains(hex("\u{1B}[A")) == true)

        // Without an adapter the host types the keys, in the modes it
        // reports (kitty flags and DECCKM).
        let awayLog = host.root.appendingPathComponent("away.log")
        let away = workspace.addSession(title: "Away", command: "exec " + KeyLogger.command(script: script, log: awayLog))
        stage.show(away)
        try await host.waitFor("the second tab to attach") {
            away.persistentSession != nil && away.state == .live && away.usesNativePTYBackend && !away.readsContentFromHost
        }
        try await host.waitFor("the first step") { host.screen(away).contains("STEP_0_READY") }
        try await loseAdapter(of: away, host: host)
        #expect(stage.focus(away))
        let awayKeys: [TypedKey] = [.controlB, .controlSpace, .d, .up, .escape, .z]
        // The surface keeps the last screen it had: the steps show in the
        // host's.
        let binding = try #require(away.persistentSession)
        let routed = try await KeyLogger.run(away, stage: stage, log: awayLog, keys: awayKeys, steps: [0, 1, 2, 5, 6, 7, 8]) {
            try await host.hosting.screen(of: binding).text
        }
        let expected: [Int: String] = [
            0: "0200" + hex("d\u{1B}[A\u{1B}z"),
            1: "0200" + hex("d\u{1B}OA\u{1B}z"),
            2: "0200" + hex("d\u{1B}[A\u{1B}z"),
            5: hex("\u{1B}[98;5u\u{1B}[32;5ud\u{1B}[A\u{1B}[27uz"),
            6: "0200" + hex("d\u{1B}[A\u{1B}z"),
            7: hex("\u{1B}[98;5u\u{1B}[32;5ud\u{1B}[A\u{1B}[27uz"),
            8: "0200" + hex("d\u{1B}[A\u{1B}z"),
        ]
        for (index, bytes) in expected {
            #expect(routed[index] == bytes, "\(KeyLogger.modes[index].name) through the host: \(routed[index] ?? "-")")
        }
    } catch {
        await cleanUp()
        throw error
    }
    await cleanUp()
}

@Test(.enabled(if: keyPathRealHostEnabled))
@MainActor func PersistentLocalRealHostTmuxPrefixThenDDetachesIt() async throws {
    var configuration = PersistentLocalSessions.Configuration()
    // Once lost, the adapter stays lost for the test.
    configuration.reconnectDelay = (120, 120)
    let host = try await RealLocalHost(shellPath: "/bin/zsh", configuration: configuration)
    let workspace = host.workspace()
    let stage = KeyPathStage()
    var servers: [PrivateTmux] = []
    func cleanUp() async {
        for server in servers { server.killServer() }
        stage.cleanUp()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
    }
    do {
        guard let defaults = try PrivateTmux(in: host.root, name: "b"),
              let spacePrefix = try PrivateTmux(in: host.root, name: "s", configuration: [
                  // The prefix many configurations choose instead.
                  "unbind C-b", "set -g prefix C-Space", "bind C-Space send-prefix",
                  // Extended keys on, for a terminal that has them.
                  "set -g extended-keys on", "set -as terminal-features 'xterm*:extkeys'",
              ])
        else {
            print("No tmux on this Mac: nothing to detach")
            await cleanUp()
            return
        }
        servers = [defaults, spacePrefix]

        func detach(_ tmux: PrivateTmux, prefix: TypedKey, throughHost: Bool) async throws {
            let tab = workspace.addSession(title: "tmux")
            stage.show(tab)
            try await host.waitFor("the tab to attach to its session") {
                tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackend && !tab.readsContentFromHost
            }
            #expect(stage.focus(tab))
            tab.send(text: tmux.newSessionCommand + "\n")
            try await host.waitFor("tmux's status line") { host.screen(tab).contains("[t] 0:") }
            try await host.waitFor("tmux's client") { tmux.sessions() == ["t:1"] }
            let binding = try #require(tab.persistentSession)
            if throughHost {
                try await loseAdapter(of: tab, host: host)
                #expect(stage.focus(tab))
            }
            try stage.type(prefix)
            try stage.type(.d)
            try await host.waitFor("tmux to detach (\(prefix), through the host: \(throughHost))") {
                tmux.sessions() == ["t:0"]
            }
            if throughHost {
                try await host.waitFor("tmux's detach message in the host's screen") {
                    try await host.hosting.screen(of: binding).text.contains("[detached (from session t)]")
                }
            } else {
                try await host.waitFor("tmux's detach message") { host.screen(tab).contains("[detached (from session t)]") }
            }
            tmux.killServer()
        }

        try await detach(defaults, prefix: .controlB, throughHost: false)
        try await detach(spacePrefix, prefix: .controlSpace, throughHost: false)
        try await detach(defaults, prefix: .controlB, throughHost: true)
        try await detach(spacePrefix, prefix: .controlSpace, throughHost: true)

        // Ctrl+B, then d, is not a detach where another key is the prefix
        // (as in a configuration with `prefix C-Space`): tmux gives Ctrl+B
        // to the program in its pane.
        let other = workspace.addSession(title: "tmux")
        stage.show(other)
        try await host.waitFor("the tab to attach to its session") {
            other.persistentSession != nil && other.state == .live && other.usesNativePTYBackend && !other.readsContentFromHost
        }
        #expect(stage.focus(other))
        other.send(text: spacePrefix.newSessionCommand + "\n")
        try await host.waitFor("tmux's status line") { host.screen(other).contains("[t] 0:") }
        try await host.waitFor("tmux's client") { spacePrefix.sessions() == ["t:1"] }
        try stage.type(.controlB)
        try stage.type(.d)
        try await host.waitFor("the d in the pane") { host.screen(other).contains("$ d") }
        #expect(spacePrefix.sessions() == ["t:1"])
    } catch {
        await cleanUp()
        throw error
    }
    await cleanUp()
}

@Test func appKitNumericPadFlagIsNotNumLock() {
    // Arrow keys carry `.numericPad`; it must not reach Ghostty as Num Lock,
    // or the kitty keyboard protocol encodes Up as `CSI 1;129A`.
    let mods = TerminalInputModifiers(from: [.numericPad, .function])
    #expect(!mods.contains(.num))
    #expect(TerminalInputModifiers(from: [.numericPad, .shift]) == [.shift])
}
