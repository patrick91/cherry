import AppKit

/// When the launch's front window first takes keys (`LaunchTimeline`'s
/// "interactive" phase): the app is active, a project window is key, and its
/// first responder is the selected tab's terminal, which has a surface to
/// take them. Checked on every turn of the main run loop from the app's init
/// until then (at most `LaunchTimeline.window`), only while the launch is
/// logged.
///
/// With `CHERRY_LAUNCH_KEY_PROBE` set to a single letter (a measurement,
/// never set by the app), it then types that letter into the window as a
/// key event the app handles like any other (`NSApp.postEvent`, after a
/// Ctrl-U that clears the prompt line), logs "key echo" once a terminal of
/// that window shows it after a prompt, and clears the line again (or logs
/// "key echo missing" with the last lines shown, after 3 s). With
/// `CHERRY_LAUNCH_KEY_PROBE_AT=key-window` it types it as soon as a launch
/// window is key, still off screen with no terminal (the keys a user types
/// right after launching): it must still reach the terminal.
@MainActor
enum LaunchInteractivity {
    private static var observer: CFRunLoopObserver?
    private static var probe: KeyProbe?
    private static var didLogActive = false
    private static var didLogKeyWindow = false

    private struct KeyProbe {
        let letter: Character
        weak var window: NSWindow?
        let postedAt: Date
    }

    private static var probesAtKeyWindow: Bool {
        ProcessInfo.processInfo.environment["CHERRY_LAUNCH_KEY_PROBE_AT"] == "key-window"
    }

    /// Starts watching (the app, once, from its init).
    static func start() {
        guard LaunchTimeline.isEnabled, observer == nil else { return }
        let activities = CFRunLoopActivity.beforeSources.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, _ in
            MainActor.assumeIsolated { check() }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func stop() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
    }

    private static func check() {
        guard LaunchTimeline.isLogging() else { return stop() }
        // Milestones on the way: the app active (keys come to it), a window
        // key (keys typed into a launch window still off screen are held for
        // it, `HiddenWindowKeyHold`).
        if !didLogActive, NSApp?.isActive == true {
            didLogActive = true
            LaunchTimeline.mark("app active")
        }
        if !didLogKeyWindow, let key = NSApp?.keyWindow {
            didLogKeyWindow = true
            LaunchTimeline.mark("key window \(key.identifier?.rawValue ?? "?") alpha=\(key.alphaValue)")
            if probesAtKeyWindow { startKeyProbe(in: key) }
        }
        guard let app = NSApp, app.isActive, let window = app.keyWindow,
              let session = ProjectWindowRegistry.shared.keyWindowWorkspace?.selectedSession,
              let bridge = session.loadedGhosttyBridge,
              window.firstResponder === bridge.terminalView,
              bridge.terminalView.hasSurface
        else { return }
        stop()
        LaunchTimeline.mark("interactive win=\(window.windowNumber) alpha=\(window.alphaValue) \(session.title)")
        if !probesAtKeyWindow { startKeyProbe(in: window) }
    }

    private static func startKeyProbe(in window: NSWindow) {
        guard probe == nil, let value = ProcessInfo.processInfo.environment["CHERRY_LAUNCH_KEY_PROBE"],
              value.count == 1, let letter = value.first, letter.isLetter, letter.isLowercase,
              let keyCode = Self.keyCodes[letter]
        else { return }
        probe = KeyProbe(letter: letter, window: window, postedAt: Date())
        // Ctrl-U first: whatever a previous run left on the prompt line goes.
        postKey("\u{15}", ignoringModifiers: "u", keyCode: 32, modifiers: .control, in: window)
        postKey(String(letter), ignoringModifiers: String(letter), keyCode: keyCode, in: window)
        LaunchTimeline.mark("key posted \(letter) alpha=\(window.alphaValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                guard let probe = Self.probe, probe.window === window else { return }
                Self.probe = nil
                let bridge = ProjectWindowRegistry.shared.keyWindowWorkspace?.selectedSession?.loadedGhosttyBridge
                let lines = bridge?.terminalView.readViewportText()?
                    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.suffix(2) ?? []
                LaunchTimeline.mark("key echo missing: \(lines.joined(separator: " | "))")
            }
        }
    }

    /// A rendered frame of `bridge`'s surface: logs the probe's echo once a
    /// terminal of the probe's window shows it after a prompt (`%`, `$`, `#`
    /// or `>` and a space), then erases it.
    static func noteFrame(of bridge: GhosttySessionBridge) {
        guard let probe, let window = probe.window, bridge.terminalView.window === window,
              let text = bridge.terminalView.readViewportText()
        else { return }
        let echoed = text.split(separator: "\n").contains { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.last == probe.letter else { return false }
            let prompt = line.dropLast()
            return prompt.hasSuffix("% ") || prompt.hasSuffix("$ ") || prompt.hasSuffix("# ") || prompt.hasSuffix("> ")
        }
        guard echoed else { return }
        self.probe = nil
        let elapsed = Int((Date().timeIntervalSince(probe.postedAt) * 1_000).rounded())
        LaunchTimeline.mark("key echo \(probe.letter) after \(elapsed)ms")
        // Leaves the prompt as it was for the next launch.
        postKey("\u{15}", ignoringModifiers: "u", keyCode: 32, modifiers: .control, in: window)
    }

    private static func postKey(
        _ characters: String,
        ignoringModifiers: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: ignoringModifiers,
                isARepeat: false,
                keyCode: keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// ANSI virtual key codes of the letters the probe may type.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
}
