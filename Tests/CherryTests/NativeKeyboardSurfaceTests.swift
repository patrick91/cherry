import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import Cherry

// What a program reads for the keys an agent's composer cares about, typed
// into a native tab down the real key path: an NSEvent through
// NSApp.sendEvent to the window, the libghostty-spm key handler (the text it
// gives Ghostty with each key), Ghostty's encoder, the PTY. In every
// keyboard mode a program sets, with Cherry's keyboard configuration
// (`TerminalSettings.nativeUserKeyboardConfig`, set here: a test never reads
// the user's own Ghostty files). Each key's characters are those AppKit
// gives a hardware event for it on this Mac's keyboard layout. And what
// Cherry's host-routed encoder types for the same key while a persistent
// tab's adapter is away (`HostRoutedKeyEncoder`), which matches the surface
// but for the differences each case lists.

private let keyLoggerAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// A keyboard mode, as a program sets it.
private struct KeyboardMode {
    var name: String
    /// What the program writes to set the mode, and to undo it.
    var set: String
    var unset: String
    /// The mode as the host reports it: the kitty keyboard protocol's
    /// flags, and modifyOtherKeys at level 2.
    var kittyFlags = 0
    var modifyOtherKeys = false
}

/// The modes, in the order the program sets them (each undoes the one
/// before). The expected bytes below are in this order.
private let keyboardModes: [KeyboardMode] = [
    KeyboardMode(name: "legacy", set: "", unset: ""),
    KeyboardMode(name: "kitty disambiguate (CSI > 1 u)", set: "\u{1B}[>1u", unset: "\u{1B}[<u", kittyFlags: 1),
    // What Claude Code writes in a terminal it knows has extended keys: a
    // pop, a push of 5 (disambiguate and alternate keys), modifyOtherKeys 2.
    // The kitty flags win over modifyOtherKeys.
    KeyboardMode(
        name: "Claude Code (CSI < u, CSI > 5 u, CSI > 4;2 m)",
        set: "\u{1B}[<u\u{1B}[>5u\u{1B}[>4;2m",
        unset: "\u{1B}[<u\u{1B}[>4m",
        kittyFlags: 5,
        modifyOtherKeys: true
    ),
    KeyboardMode(name: "modifyOtherKeys 2 (CSI > 4;2 m)", set: "\u{1B}[>4;2m", unset: "\u{1B}[>4m", modifyOtherKeys: true),
]

/// The translated hardware event for `keyCode` with `flags`, as this Mac's
/// keyboard layout gives it.
private func translatedEvent(keyCode: UInt16, flags: CGEventFlags) -> NSEvent? {
    guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: keyCode, keyDown: true)
    else { return nil }
    event.flags = flags
    return NSEvent(cgEvent: event)
}

/// Whether the keys the cases name by letter (C, keyCode 8, and J, 38)
/// type a lowercase Latin letter, the same with Control: the expected bytes
/// are worked out from those letters.
private let latinLetterKeys = [UInt16(8), 38].allSatisfy { keyCode in
    guard let plain = translatedEvent(keyCode: keyCode, flags: [])?.characters,
          let control = translatedEvent(keyCode: keyCode, flags: .maskControl)?.charactersIgnoringModifiers,
          let letter = plain.unicodeScalars.first?.value
    else { return false }
    return plain.unicodeScalars.count == 1 && (0x61...0x7A).contains(letter) && control == plain
}

/// `keyCode` with `modifiers` as the keyboard sends it: the characters AppKit
/// translates a hardware event to on this Mac's layout, and the side bit of
/// each modifier (NX_DEVICELSHIFTKEYMASK 0x2, NX_DEVICELCTLKEYMASK 0x1,
/// NX_DEVICELALTKEYMASK 0x20). `extra`: flags AppKit adds for the key
/// (`.numericPad` for the keypad and arrows, `.function` for arrows and
/// function keys).
private func hardwareKey(
    _ name: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], extra: NSEvent.ModifierFlags = []
) throws -> TypedKey {
    var flags = CGEventFlags()
    var sides: UInt = 0
    if modifiers.contains(.shift) { flags.insert(.maskShift); sides |= 0x2 }
    if modifiers.contains(.control) { flags.insert(.maskControl); sides |= 0x1 }
    if modifiers.contains(.option) { flags.insert(.maskAlternate); sides |= 0x20 }
    let translated = try #require(translatedEvent(keyCode: keyCode, flags: flags))
    return TypedKey(
        name: name, characters: translated.characters ?? "",
        charactersIgnoringModifiers: translated.charactersIgnoringModifiers ?? "", keyCode: keyCode,
        modifiers: NSEvent.ModifierFlags(rawValue: modifiers.union(extra).rawValue | sides)
    )
}

/// A key and what the program reads for it in each of `keyboardModes`.
/// `hostDiffers`: the modes (indices) in which the host-routed encoder types
/// something else for it, each a known difference.
private struct KeyCase {
    var key: TypedKey
    var expected: [String]
    var hostDiffers: Set<Int> = []
}

private func csi(_ body: String) -> String { "\u{1B}[" + body }

/// The keys typed, and what Ghostty types for each with Cherry's default
/// keyboard configuration (`shift+tab=csi:Z`, `macos-option-as-alt = true`):
/// as Ghostty's macOS app types them, Shift+Tab aside.
@MainActor
private func defaultKeyCases() throws -> [KeyCase] {
    let c = try hardwareKey("c", keyCode: 8)
    let shiftC = try hardwareKey("Shift+C", keyCode: 8, .shift)
    let controlC = try hardwareKey("Ctrl+C", keyCode: 8, .control)
    let controlJ = try hardwareKey("Ctrl+J", keyCode: 38, .control)
    // The letters these keys type on this layout (C and J on an ANSI one),
    // for the bytes Control and Shift make of them.
    let letterC = try #require(c.characters.unicodeScalars.first?.value)
    let letterJ = try #require(controlJ.charactersIgnoringModifiers.unicodeScalars.first?.value)
    let shiftedC = try #require(shiftC.characters.unicodeScalars.first?.value)
    func control(_ letter: UInt32) -> String { String(UnicodeScalar(UInt8(letter - 0x60))) }
    func controlKey(_ letter: UInt32) -> [String] {
        [control(letter), csi("\(letter);5u"), csi("\(letter);5u"), csi("27;5;\(letter)~")]
    }
    let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
    return [
        KeyCase(key: try hardwareKey("Return", keyCode: 36), expected: ["\r", "\r", "\r", "\r"]),
        // The host types Cherry's own CR in legacy mode.
        KeyCase(
            key: try hardwareKey("Shift+Return", keyCode: 36, .shift),
            expected: [csi("27;2;13~"), csi("13;2u"), csi("13;2u"), csi("27;2;13~")], hostDiffers: [0]
        ),
        KeyCase(
            key: try hardwareKey("Ctrl+Return", keyCode: 36, .control),
            expected: [csi("27;5;13~"), csi("13;5u"), csi("13;5u"), csi("27;5;13~")], hostDiffers: [0]
        ),
        KeyCase(
            key: try hardwareKey("Option+Return", keyCode: 36, .option),
            expected: ["\u{1B}\r", csi("13;3u"), csi("13;3u"), csi("27;3;13~")]
        ),
        KeyCase(key: try hardwareKey("Tab", keyCode: 48), expected: ["\t", "\t", "\t", "\t"]),
        // The host types `CSI 9;2u` under the kitty protocol.
        KeyCase(
            key: try hardwareKey("Shift+Tab", keyCode: 48, .shift), expected: Array(repeating: csi("Z"), count: 4),
            hostDiffers: [1, 2]
        ),
        KeyCase(key: try hardwareKey("Backspace", keyCode: 51), expected: ["\u{7F}", "\u{7F}", "\u{7F}", "\u{7F}"]),
        KeyCase(
            key: try hardwareKey("Shift+Backspace", keyCode: 51, .shift),
            expected: ["\u{7F}", csi("127;2u"), csi("127;2u"), csi("27;2;127~")]
        ),
        KeyCase(
            key: try hardwareKey("Ctrl+Backspace", keyCode: 51, .control),
            expected: ["\u{08}", csi("127;5u"), csi("127;5u"), "\u{08}"]
        ),
        KeyCase(
            key: try hardwareKey("Option+Backspace", keyCode: 51, .option),
            expected: ["\u{1B}\u{7F}", csi("127;3u"), csi("127;3u"), csi("27;3;127~")]
        ),
        KeyCase(key: try hardwareKey("Escape", keyCode: 53), expected: ["\u{1B}", csi("27u"), csi("27u"), "\u{1B}"]),
        // The host types a bare ESC in legacy mode.
        KeyCase(
            key: try hardwareKey("Shift+Escape", keyCode: 53, .shift),
            expected: [csi("27;2;27~"), csi("27;2u"), csi("27;2u"), csi("27;2;27~")], hostDiffers: [0]
        ),
        KeyCase(
            key: try hardwareKey("Keypad Enter", keyCode: 76, extra: .numericPad),
            expected: ["\r", csi("57414u"), csi("57414u"), "\r"]
        ),
        KeyCase(
            key: try hardwareKey("Shift+Keypad Enter", keyCode: 76, .shift, extra: .numericPad),
            expected: ["\r", csi("57414;2u"), csi("57414;2u"), "\r"]
        ),
        KeyCase(key: controlJ, expected: controlKey(letterJ)),
        // Ghostty's own binding on macOS, `alt+left=esc:b`, in every mode;
        // the host types `CSI 1;3D` where it takes arrows to be modified.
        KeyCase(
            key: try hardwareKey("Option+Left", keyCode: 123, .option, extra: arrows),
            expected: Array(repeating: "\u{1B}b", count: 4), hostDiffers: [1, 2, 3]
        ),
        KeyCase(key: try hardwareKey("Up", keyCode: 126, extra: arrows), expected: Array(repeating: csi("A"), count: 4)),
        KeyCase(key: try hardwareKey("F1", keyCode: 122, extra: .function), expected: ["\u{1B}OP", csi("P"), csi("P"), "\u{1B}OP"]),
        KeyCase(key: controlC, expected: controlKey(letterC)),
        // The host types Control+C's byte in legacy mode, and no alternate
        // key.
        KeyCase(
            key: try hardwareKey("Ctrl+Shift+C", keyCode: 8, [.control, .shift]),
            expected: [
                csi("\(letterC);6u"), csi("\(letterC);6u"), csi("\(letterC):\(shiftedC);6u"), csi("27;6;\(shiftedC)~"),
            ],
            hostDiffers: [0, 2]
        ),
        KeyCase(key: c, expected: Array(repeating: c.characters, count: 4)),
        KeyCase(
            key: shiftC,
            expected: [shiftC.characters, shiftC.characters, shiftC.characters, csi("27;2;\(shiftedC)~")]
        ),
        KeyCase(
            key: try hardwareKey("Option+C", keyCode: 8, .option),
            expected: ["\u{1B}" + c.characters, csi("\(letterC);3u"), csi("\(letterC);3u"), csi("27;3;\(letterC)~")]
        ),
    ]
}

private func escaped(_ data: Data) -> String {
    data.map { byte -> String in
        switch byte {
        case 0x1B: "ESC "
        case 0x0D: "\\r "
        case 0x0A: "\\n "
        case 0x09: "\\t "
        case 0x20: "SP "
        case 0x21...0x7E: String(UnicodeScalar(byte))
        default: String(format: "\\x%02x ", byte)
        }
    }.joined().trimmingCharacters(in: .whitespaces)
}

private func hex(_ text: String) -> String {
    Data(text.utf8).map { String(format: "%02x", $0) }.joined()
}

/// What the host-routed encoder types for `key` in `mode`, as
/// `sendKeyThroughHostWhileAdapterIsAway` asks it (a program not in the
/// alternate screen, normal cursor keys).
@MainActor
private func hostBytes(_ key: TypedKey, in mode: KeyboardMode, optionAsAlt: HostRoutedKeyEncoder.OptionAsAlt) throws -> Data {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: 0, windowNumber: 0, context: nil,
        characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false,
        keyCode: key.keyCode
    ))
    let enhanced = mode.kittyFlags != 0
    let modifyOtherKeys = mode.modifyOtherKeys && !enhanced
    return HostRoutedKeyEncoder.data(
        keyCode: event.keyCode,
        modifiers: event.modifierFlags,
        characters: event.characters,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
        unshiftedCharacters: enhanced || modifyOtherKeys ? event.characters(byApplyingModifiers: []) : nil,
        typedText: modifyOtherKeys ? HostRoutedKeyEncoder.surfaceText(for: event, optionAsAlt: optionAsAlt) : nil,
        usesApplicationCursorKeys: false,
        isEnhancedKeyboardProtocolActive: enhanced,
        sendsModifiedArrowKeys: enhanced,
        modifyOtherKeys: modifyOtherKeys,
        optionAsAlt: optionAsAlt
    ) ?? Data()
}

/// Types every key of `cases` in every keyboard mode into a native tab
/// whose surface has `configuration`, and expects what the program reads to
/// be each case's bytes, and what the host-routed encoder types to be the
/// same but in the modes the case lists.
@MainActor
private func expectKeys(
    _ cases: [KeyCase], configuration: [(String, String)], label: String, stage: KeyPathStage, in directory: URL
) async throws {
    TerminalSettings.nativeUserKeyboardConfig = configuration
    let project = directory.appendingPathComponent(label, isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let workspace = TerminalWorkspace(projectRoot: project.path, createInitialSession: false, launchBackend: .nativePTY)
    defer {
        stage.container.detachActiveSession()
        workspace.closeAllSessions(intent: .windowClosed)
    }
    // One step per key and mode: the first key of a mode undoes the mode
    // before it and sets its own.
    var steps: [String] = []
    for (index, mode) in keyboardModes.enumerated() {
        for position in cases.indices {
            let modeBytes = position > 0 ? "" : (index > 0 ? keyboardModes[index - 1].unset : "") + mode.set
            steps.append(hex(modeBytes))
        }
    }
    let script = try KeyLogger.write(to: project)
    let log = project.appendingPathComponent("keys.log")
    let command = "/usr/bin/python3 -I '\(script.path)' '\(log.path)' " + steps.map { "'\($0)'" }.joined(separator: " ")
    let tab = workspace.addSession(title: "Keys (\(label))", command: command)
    stage.show(tab)
    #expect(tab.ghosttyBridge.isNativePTYBacked)
    #expect(stage.focus(tab))
    let screen: @MainActor () -> String = { tab.ghosttyBridge.readNativeScreenText() ?? "" }

    var step = 0
    for mode in keyboardModes {
        for keyCase in cases {
            // The first step waits for the program to start.
            try await poll("step \(step) of the key logger (\(label), \(mode.name))", timeout: step == 0 ? 60 : 20) {
                screen().contains("STEP_\(step)_READY")
            }
            try stage.type(keyCase.key)
            try stage.type(.z)
            let logged = step
            try await poll("the key logger to log step \(logged) (\(label), \(mode.name), \(keyCase.key))", timeout: 20) {
                KeyLogger.read(log)[logged] != nil
            }
            step += 1
        }
    }

    let optionAsAlt = HostRoutedKeyEncoder.OptionAsAlt(configValue: configuration.last { $0.0 == "macos-option-as-alt" }?.1)
    let read = KeyLogger.read(log)
    step = 0
    for (index, mode) in keyboardModes.enumerated() {
        for keyCase in cases {
            var bytes = Data()
            let logged = Array((read[step] ?? "").utf8)
            for offset in stride(from: 0, to: logged.count - 1, by: 2) {
                bytes.append(UInt8(String(decoding: logged[offset...offset + 1], as: UTF8.self), radix: 16) ?? 0)
            }
            // The step's terminator.
            if bytes.last == UInt8(ascii: "z") { bytes.removeLast() }
            let expected = Data(keyCase.expected[index].utf8)
            #expect(
                bytes == expected,
                "\(label), \(mode.name), \(keyCase.key): read \(escaped(bytes)), expected \(escaped(expected))"
            )
            let host = try hostBytes(keyCase.key, in: mode, optionAsAlt: optionAsAlt)
            if keyCase.hostDiffers.contains(index) {
                #expect(host != expected, "\(label), \(mode.name), \(keyCase.key): the host types it as the surface")
            } else {
                #expect(
                    host == expected,
                    "\(label), \(mode.name), \(keyCase.key): the host types \(escaped(host)), the surface \(escaped(expected))"
                )
            }
            step += 1
        }
    }
}

@Test(.enabled(if: keyLoggerAvailable && latinLetterKeys), .timeLimit(.minutes(5)))
@MainActor func nativeKeyboardSurfaceTypesKeysAsGhosttyInEveryKeyboardMode() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeKeyboardSurface-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = TerminalSettings.nativeUserKeyboardConfig
    // One stage for the test: the test app is never active, and AppKit
    // keeps sending key events to the window it made key first.
    let stage = KeyPathStage()
    defer {
        stage.cleanUp()
        TerminalSettings.nativeUserKeyboardConfig = original
        try? FileManager.default.removeItem(at: directory)
    }
    let defaults = try defaultKeyCases()
    func replacing(_ name: String, with expected: [String], hostDiffers: Set<Int>) -> [KeyCase] {
        defaults.map { $0.key.name == name ? KeyCase(key: $0.key, expected: expected, hostDiffers: hostDiffers) : $0 }
    }

    // No configuration of the user's: Cherry's defaults. Shift+Return is
    // Ghostty's own, `CSI 13;2u` under the kitty protocol (not a bare CR,
    // which Claude Code takes as Return).
    try await expectKeys(
        defaults, configuration: TerminalSettings.parseUserGhosttyKeyboardConfig(""),
        label: "no-user-config", stage: stage, in: directory
    )
    // The user's own Shift+Return binding wins in every mode (on the
    // surface only: the host types no binding of the user's).
    try await expectKeys(
        replacing("Shift+Return", with: Array(repeating: "\n", count: 4), hostDiffers: [0, 1, 2, 3]),
        configuration: TerminalSettings.parseUserGhosttyKeyboardConfig("keybind = shift+enter=text:\\n"),
        label: "user-shift-enter", stage: stage, in: directory
    )
    // Option not as Alt: Option composes text (Option+C is `ç` on a US
    // layout), and Return, Backspace and Left keep it as a modifier. The
    // host types a bare CR for Option+Return in legacy mode.
    let optionC = try #require(defaults.first { $0.key.name == "Option+C" }?.key)
    let notAlt = defaults.map { keyCase -> KeyCase in
        switch keyCase.key.name {
        case "Option+C": KeyCase(key: optionC, expected: Array(repeating: optionC.characters, count: 4))
        case "Option+Return": KeyCase(key: keyCase.key, expected: keyCase.expected, hostDiffers: [0])
        default: keyCase
        }
    }
    try await expectKeys(
        notAlt, configuration: TerminalSettings.parseUserGhosttyKeyboardConfig("macos-option-as-alt = false"),
        label: "option-not-alt", stage: stage, in: directory
    )
    // Without Cherry's configuration: Ghostty's Shift+Tab, `CSI 9;2u` under
    // the kitty protocol (not a bare tab) and `CSI 27;2;9~` under
    // modifyOtherKeys 2, which the host types as `CSI Z`. Without
    // `macos-option-as-alt` Ghostty decides by the keyboard layout, so no
    // Option key here.
    try await expectKeys(
        replacing("Shift+Tab", with: [csi("Z"), csi("9;2u"), csi("9;2u"), csi("27;2;9~")], hostDiffers: [3])
            .filter { !$0.key.name.hasPrefix("Option+") },
        configuration: [], label: "bare-ghostty", stage: stage, in: directory
    )
}

/// A hardware key's event, as AppKit gives it to the surface.
private func keyEvent(_ key: TypedKey) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: 0, windowNumber: 0, context: nil,
        characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false,
        keyCode: key.keyCode
    ))
}

@Test(.enabled(if: latinLetterKeys))
@MainActor func nativeKeyboardTextIsWhatGhosttysAppGivesGhostty() throws {
    // No text for a control character or a function key, Control's letter
    // without Control: `filteredCharacters` (what libghostty-spm gives
    // Ghostty) and `surfaceText` (what the host-routed encoder takes the
    // surface to type).
    let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
    for key in [
        try hardwareKey("Return", keyCode: 36),
        try hardwareKey("Shift+Return", keyCode: 36, .shift),
        try hardwareKey("Ctrl+Return", keyCode: 36, .control),
        try hardwareKey("Tab", keyCode: 48),
        try hardwareKey("Shift+Tab", keyCode: 48, .shift),
        try hardwareKey("Backspace", keyCode: 51),
        try hardwareKey("Escape", keyCode: 53),
        try hardwareKey("Keypad Enter", keyCode: 76, extra: .numericPad),
        try hardwareKey("Up", keyCode: 126, extra: arrows),
        try hardwareKey("F1", keyCode: 122, extra: .function),
        try hardwareKey("F13", keyCode: 105, extra: .function),
        try hardwareKey("Ctrl+F13", keyCode: 105, .control, extra: .function),
    ] {
        let event = try keyEvent(key)
        #expect(event.filteredCharacters == nil, "\(key)")
        #expect(HostRoutedKeyEncoder.surfaceText(for: event, optionAsAlt: .both) == nil, "\(key)")
    }
    let c = try hardwareKey("c", keyCode: 8)
    for (key, text) in [
        (try hardwareKey("Ctrl+C", keyCode: 8, .control), c.characters),
        (try hardwareKey("Ctrl+Shift+C", keyCode: 8, [.control, .shift]), c.characters.uppercased()),
        (c, c.characters),
    ] {
        let event = try keyEvent(key)
        #expect(event.filteredCharacters == text, "\(key)")
        #expect(HostRoutedKeyEncoder.surfaceText(for: event, optionAsAlt: .both) == text, "\(key)")
    }

    // A lone control character while an input method composes is the
    // input method's (Ghostty's `shouldSuppressComposingControlInput`).
    #expect(TerminalInputText.isComposingControlInput("\n", composing: true))
    #expect(TerminalInputText.isComposingControlInput("\u{08}", composing: true))
    #expect(!TerminalInputText.isComposingControlInput("\n", composing: false))
    #expect(!TerminalInputText.isComposingControlInput("あ", composing: true))
    #expect(!TerminalInputText.isComposingControlInput("\u{7F}", composing: true))
    #expect(!TerminalInputText.isComposingControlInput("\n\n", composing: true))
    #expect(!TerminalInputText.isComposingControlInput(nil, composing: true))
}
