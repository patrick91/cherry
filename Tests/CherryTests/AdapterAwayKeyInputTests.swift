import AppKit
import Foundation
import Testing
@testable import Cherry

// Keys typed into a persistent tab while its attach adapter is away
// (docs/specs/multiplexer-default.md): the adapter ended and is launched
// again with backoff, or reconnects to its host by itself. The surface's
// process takes no keys then; the window's key monitor sends them through
// the host. Against the fake `cherry control` (FakeControlHelper) and
// attach adapter (HostedSessionFakeCLI).

/// What the fake host was asked to type, in order.
private func typedThroughHost(_ harness: PersistentHarness) -> [String] {
    harness.fake.requests("send_input").compactMap { request in
        request.string("data").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }
}

private func keyDown(
    _ characters: String,
    ignoringModifiers: String? = nil,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters,
        isARepeat: false,
        keyCode: keyCode
    ))
}

@Test @MainActor func keysTypedWhileAPersistentTabsAdapterIsLaunchedAgainReachTheProgramThroughTheHost() async throws {
    var configuration = PersistentHarness.fastConfiguration
    // The adapter is launched again only after the test.
    configuration.reconnectDelay = (30, 30)
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    defer {
        container.detachActiveSession()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(tab))
    container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
    #expect(tab.ghosttyBridge.isNativePTYBacked)

    // The adapter runs: its surface's Ghostty takes the keys.
    #expect(!tab.keyboardInputGoesThroughHost)
    #expect(!container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("l", keyCode: 37)))

    // The daemon went away under the adapter; it is launched again later.
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    let call = try #require(harness.attachCalls.first)
    try Data(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":"connection lost"}"#.utf8)
        .write(to: try harness.statusFile(of: call))
    tab.ingestNativeChildExit(exitCode: 1)
    #expect(tab.isRunning)
    #expect(tab.keyboardInputGoesThroughHost)
    // The ended adapter's surface still shows the last screen.
    #expect(tab.ghosttyBridge.isNativePTYBacked)

    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("l", keyCode: 37)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("s", keyCode: 1)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("\r", keyCode: 36)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("\u{03}", ignoringModifiers: "c", keyCode: 8, modifiers: .control)))
    // Command shortcuts stay the menu's.
    #expect(!container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("w", keyCode: 13, modifiers: .command)))
    #expect(await harness.fake.wait { typedThroughHost(harness).joined() == "ls\r\u{03}" })
    #expect(harness.attachCalls.count == 1)
}

@Test @MainActor func keysTypedWhileAPersistentTabsAdapterReconnectsByItselfReachTheProgramThroughTheHost() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    defer {
        container.detachActiveSession()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(tab))
    container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    let call = try #require(harness.attachCalls.first)

    // The adapter reports it reconnects to its host (the daemon restarted):
    // it discards what it is typed meanwhile.
    try HostedSessionFakeCLI.writeStatus(
        HostedSessionFakeCLI.attachedStatus(reconnecting: true), to: try harness.statusFile(of: call)
    )
    #expect(await harness.fake.wait { tab.adapterLiveStatus?.reconnecting == true })
    #expect(tab.keyboardInputGoesThroughHost)
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("y", keyCode: 16)))
    #expect(await harness.fake.wait { typedThroughHost(harness) == ["y"] })

    // Attached again: the surface takes the keys.
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(), to: try harness.statusFile(of: call))
    #expect(await harness.fake.wait { tab.adapterLiveStatus?.reconnecting == false })
    #expect(!tab.keyboardInputGoesThroughHost)
    #expect(!container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("n", keyCode: 45)))
    try await Task.sleep(for: .milliseconds(200))
    #expect(typedThroughHost(harness) == ["y"])
}

@Test func keysForTheHostWhileAnAdapterIsAwayAreEncodedAsATerminalWould() {
    func encode(
        _ characters: String,
        ignoring: String? = nil,
        keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags = [],
        applicationCursorKeys: Bool = false
    ) -> String? {
        HostRoutedKeyEncoder.data(
            keyCode: keyCode,
            modifiers: modifiers,
            characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters,
            usesApplicationCursorKeys: applicationCursorKeys,
            isEnhancedKeyboardProtocolActive: false,
            keyboardProtocolFlags: 0,
            sendsModifiedArrowKeys: false
        ).map { String(decoding: $0, as: UTF8.self) }
    }
    #expect(encode("a", keyCode: 0) == "a")
    #expect(encode("A", ignoring: "a", keyCode: 0, .shift) == "A")
    #expect(encode("é", keyCode: 14) == "é")
    #expect(encode("\r", keyCode: 36) == "\r")
    #expect(encode("\u{03}", keyCode: 76) == "\r")
    #expect(encode("\t", keyCode: 48) == "\t")
    #expect(encode("\u{7F}", keyCode: 51) == "\u{7F}")
    #expect(encode("\u{1B}", keyCode: 53) == "\u{1B}")
    #expect(encode("\u{03}", ignoring: "c", keyCode: 8, .control) == "\u{03}")
    #expect(encode("\u{04}", ignoring: "d", keyCode: 2, .control) == "\u{04}")
    #expect(encode("\u{1B}", ignoring: "[", keyCode: 33, .control) == "\u{1B}")
    // Arrows, Home and End in either cursor key mode; the others.
    #expect(encode("\u{F701}", keyCode: 125, [.numericPad, .function]) == "\u{1B}[B")
    #expect(encode("\u{F701}", keyCode: 125, [.numericPad, .function], applicationCursorKeys: true) == "\u{1B}OB")
    #expect(encode("\u{F729}", keyCode: 115, .function) == "\u{1B}[H")
    #expect(encode("\u{F72B}", keyCode: 119, .function, applicationCursorKeys: true) == "\u{1B}OF")
    #expect(encode("\u{F728}", keyCode: 117, .function) == "\u{1B}[3~")
    #expect(encode("\u{F72C}", keyCode: 116, .function) == "\u{1B}[5~")
    #expect(encode("\u{F72D}", keyCode: 121, .function) == "\u{1B}[6~")
    // Command shortcuts are the menu's.
    #expect(encode("w", keyCode: 13, .command) == nil)
    #expect(encode("v", keyCode: 9, .command) == nil)
    #expect(encode("\u{F704}", keyCode: 122, [.function, .command]) == nil)
}

/// `HostRoutedKeyEncoder.data` for a key event, as text (nil: not encoded).
private func encoded(
    _ characters: String,
    ignoring: String? = nil,
    keyCode: UInt16,
    _ modifiers: NSEvent.ModifierFlags = [],
    applicationCursorKeys: Bool = false,
    kittyFlags: Int = 0,
    optionAsAlt: HostRoutedKeyEncoder.OptionAsAlt = .both
) -> String? {
    HostRoutedKeyEncoder.data(
        keyCode: keyCode,
        modifiers: modifiers,
        characters: characters,
        charactersIgnoringModifiers: ignoring ?? characters,
        usesApplicationCursorKeys: applicationCursorKeys,
        isEnhancedKeyboardProtocolActive: kittyFlags > 0,
        keyboardProtocolFlags: kittyFlags,
        sendsModifiedArrowKeys: false,
        optionAsAlt: optionAsAlt
    ).map { String(decoding: $0, as: UTF8.self) }
}

@Test func functionKeysForTheHostWhileAnAdapterIsAwayAreXtermsSequences() {
    // F1–F4 are SS3, the others `CSI n ~`, as a terminal types them.
    let plain: [(UInt16, String)] = [
        (122, "\u{1B}OP"), (120, "\u{1B}OQ"), (99, "\u{1B}OR"), (118, "\u{1B}OS"),
        (96, "\u{1B}[15~"), (97, "\u{1B}[17~"), (98, "\u{1B}[18~"), (100, "\u{1B}[19~"),
        (101, "\u{1B}[20~"), (109, "\u{1B}[21~"), (103, "\u{1B}[23~"), (111, "\u{1B}[24~"),
    ]
    for (keyCode, sequence) in plain {
        #expect(encoded("\u{F704}", keyCode: keyCode, .function) == sequence, "key code \(keyCode)")
    }
    // With modifiers, xterm's parameter: 1 + Shift 1, Option 2, Control 4.
    #expect(encoded("\u{F704}", keyCode: 122, [.function, .shift]) == "\u{1B}[1;2P")
    #expect(encoded("\u{F707}", keyCode: 118, [.function, .control, .shift]) == "\u{1B}[1;6S")
    #expect(encoded("\u{F708}", keyCode: 96, [.function, .control]) == "\u{1B}[15;5~")
    #expect(encoded("\u{F70F}", keyCode: 111, [.function, .option]) == "\u{1B}[24;3~")
    // In either cursor key mode.
    #expect(encoded("\u{F704}", keyCode: 122, .function, applicationCursorKeys: true) == "\u{1B}OP")
    // Beyond F12: no encoding here.
    #expect(encoded("\u{F710}", keyCode: 105, .function) == nil)
}

@Test func modifiedNavigationKeysForTheHostWhileAnAdapterIsAwayCarryTheirModifiers() {
    let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
    #expect(encoded("\u{F700}", keyCode: 126, arrows.union(.shift)) == "\u{1B}[1;2A")
    #expect(encoded("\u{F702}", keyCode: 123, arrows.union(.control)) == "\u{1B}[1;5D")
    #expect(encoded("\u{F703}", keyCode: 124, arrows.union([.control, .shift])) == "\u{1B}[1;6C")
    #expect(encoded("\u{F701}", keyCode: 125, arrows.union([.option, .shift])) == "\u{1B}[1;4B")
    #expect(encoded("\u{F700}", keyCode: 126, arrows.union([.option, .control])) == "\u{1B}[1;7A")
    // The same in application cursor keys mode: only unmodified ones change.
    #expect(encoded("\u{F702}", keyCode: 123, arrows.union(.control), applicationCursorKeys: true) == "\u{1B}[1;5D")
    #expect(encoded("\u{F702}", keyCode: 123, arrows, applicationCursorKeys: true) == "\u{1B}OD")
    #expect(encoded("\u{F729}", keyCode: 115, [.function, .shift]) == "\u{1B}[1;2H")
    #expect(encoded("\u{F72B}", keyCode: 119, [.function, .control]) == "\u{1B}[1;5F")
    #expect(encoded("\u{F729}", keyCode: 115, .function, applicationCursorKeys: true) == "\u{1B}OH")
    #expect(encoded("\u{F72C}", keyCode: 116, [.function, .shift]) == "\u{1B}[5;2~")
    #expect(encoded("\u{F72D}", keyCode: 121, [.function, .control]) == "\u{1B}[6;5~")
    #expect(encoded("\u{F728}", keyCode: 117, [.function, .control]) == "\u{1B}[3;5~")
    #expect(encoded("\u{F728}", keyCode: 117, [.function, .option]) == "\u{1B}[3;3~")
}

@Test func controlAndOptionCombinationsForTheHostWhileAnAdapterIsAwayAreNotLost() {
    // Control+Option as Alt: ESC, then the Control byte.
    #expect(encoded("\u{02}", ignoring: "b", keyCode: 11, [.control, .option]) == "\u{1B}\u{02}")
    #expect(encoded("\u{1B}", ignoring: "[", keyCode: 33, [.control, .option]) == "\u{1B}\u{1B}")
    // Option not as Alt: the Control byte alone.
    #expect(encoded("\u{02}", ignoring: "b", keyCode: 11, [.control, .option], optionAsAlt: .neither) == "\u{02}")
    // Control with the symbols a terminal has a C0 byte for, and others as typed.
    #expect(encoded("/", keyCode: 44, .control) == "\u{1F}")
    #expect(encoded("?", ignoring: "?", keyCode: 44, [.control, .shift]) == "\u{7F}")
    #expect(encoded("8", keyCode: 28, .control) == "\u{7F}")
    #expect(encoded("@", ignoring: "@", keyCode: 19, [.control, .shift]) == "\u{00}")
    #expect(encoded("1", keyCode: 18, .control) == "1")
    #expect(encoded(".", keyCode: 47, .control) == ".")
    // A non-Latin layout: Control and the key where A is.
    #expect(encoded("ф", keyCode: 0, .control) == "\u{01}")
    // Return, Tab and Backspace with modifiers.
    #expect(encoded("\r", keyCode: 36, .control) == "\r")
    #expect(encoded("\r", keyCode: 36, .option) == "\u{1B}\r")
    #expect(encoded("\r", keyCode: 36, .option, optionAsAlt: .neither) == "\r")
    #expect(encoded("\r", keyCode: 36, .control, kittyFlags: 1) == "\u{1B}[13;5u")
    #expect(encoded("\t", keyCode: 48, .control) == "\t")
    #expect(encoded("\t", keyCode: 48, .option) == "\u{1B}\t")
    #expect(encoded("\u{7F}", keyCode: 51, .control) == "\u{08}")
    #expect(encoded("\u{7F}", keyCode: 51, [.control, .option]) == "\u{1B}\u{08}")
    #expect(encoded("\u{7F}", keyCode: 51, .control, kittyFlags: 1) == "\u{1B}[127;5u")
    #expect(encoded("\u{7F}", keyCode: 51, .shift) == "\u{7F}")
    // Cherry's own Option encodings are unchanged.
    #expect(encoded("\u{7F}", keyCode: 51, .option) == "\u{1B}\u{7F}")
    #expect(encoded("\u{F702}", keyCode: 123, [.numericPad, .function, .option]) == "\u{1B}b")
}

@Test func optionActsAsAltForTheHostWhileAnAdapterIsAwayAsTheSurfacesSettingSays() {
    // Option+B: `∫` composed, `ESC b` as Alt (Ghostty's macos-option-as-alt).
    #expect(encoded("∫", ignoring: "b", keyCode: 11, .option) == "\u{1B}b")
    #expect(encoded("ı", ignoring: "B", keyCode: 11, [.option, .shift]) == "\u{1B}B")
    #expect(encoded("∫", ignoring: "b", keyCode: 11, .option, optionAsAlt: .neither) == "∫")
    // A dead key (Option+E) composes nothing yet: as Alt it is `ESC e`.
    #expect(encoded("", ignoring: "e", keyCode: 14, .option) == "\u{1B}e")
    #expect(encoded("", ignoring: "e", keyCode: 14, .option, optionAsAlt: .neither) == nil)
    // Only the configured side: the event's device flags say which.
    let leftOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
    let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
    #expect(encoded("∫", ignoring: "b", keyCode: 11, leftOption, optionAsAlt: .left) == "\u{1B}b")
    #expect(encoded("∫", ignoring: "b", keyCode: 11, rightOption, optionAsAlt: .left) == "∫")
    #expect(encoded("∫", ignoring: "b", keyCode: 11, rightOption, optionAsAlt: .right) == "\u{1B}b")
    // Option+digits keep typing what the layout composes (Cherry's own).
    #expect(encoded("¡", ignoring: "1", keyCode: 18, .option) == "¡")

    #expect(HostRoutedKeyEncoder.OptionAsAlt(configValue: nil) == .both)
    #expect(HostRoutedKeyEncoder.OptionAsAlt(configValue: "true") == .both)
    #expect(HostRoutedKeyEncoder.OptionAsAlt(configValue: "false") == .neither)
    #expect(HostRoutedKeyEncoder.OptionAsAlt(configValue: "left") == .left)
    #expect(HostRoutedKeyEncoder.OptionAsAlt(configValue: " Right ") == .right)
    #expect(!HostRoutedKeyEncoder.OptionAsAlt.both.applies(to: .control))
}

@Test @MainActor func keysTypedWhileAnAdapterIsAwayUseTheCursorKeyModeTheHostReports() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    defer {
        container.detachActiveSession()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(tab))
    container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    let call = try #require(harness.attachCalls.first)
    let sessionID = try #require(tab.persistentSession?.sessionID)

    // `less` runs, with application cursor keys on; the host reports it.
    harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(.changed(HostedSessionInfo(
        id: sessionID, name: "Shell", cwd: harness.project.path, pid: 42, clients: 1,
        alternateScreen: true, kittyKeyboardFlags: 0, applicationCursorKeys: true
    ))))
    #expect(await harness.fake.wait { tab.usesApplicationCursorKeys })

    // Its adapter reconnects: the keys go through the host, in that mode.
    try HostedSessionFakeCLI.writeStatus(
        HostedSessionFakeCLI.attachedStatus(reconnecting: true), to: try harness.statusFile(of: call)
    )
    #expect(await harness.fake.wait { tab.keyboardInputGoesThroughHost })
    let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("\u{F701}", keyCode: 125, modifiers: arrows)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("\u{F72B}", keyCode: 119, modifiers: .function)))
    // Keys it used to lose: a function key and a modified arrow.
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("\u{F708}", keyCode: 96, modifiers: .function)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(
        try keyDown("\u{F702}", keyCode: 123, modifiers: arrows.union(.control))
    ))
    #expect(await harness.fake.wait { typedThroughHost(harness).count == 4 })
    #expect(typedThroughHost(harness) == ["\u{1B}OB", "\u{1B}OF", "\u{1B}[15~", "\u{1B}[1;5D"])

    // The program left that mode (back at a prompt): `ESC [ A`.
    harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(.changed(HostedSessionInfo(
        id: sessionID, name: "Shell", cwd: harness.project.path, pid: 42, clients: 1,
        alternateScreen: false, kittyKeyboardFlags: 0, applicationCursorKeys: false
    ))))
    #expect(await harness.fake.wait { !tab.usesApplicationCursorKeys })
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("\u{F700}", keyCode: 126, modifiers: arrows)))
    #expect(await harness.fake.wait { typedThroughHost(harness).last == "\u{1B}[A" })
}

@Test func keysTheKittyProtocolEncodesDifferentlyGoAsTheSurfaceTypesThemWhileAnAdapterIsAway() {
    // Escape is `CSI 27 u`, so a program can tell it from a sequence.
    #expect(encoded("\u{1B}", keyCode: 53, kittyFlags: 1) == "\u{1B}[27u")
    #expect(encoded("\u{1B}", keyCode: 53, .shift, kittyFlags: 1) == "\u{1B}[27;2u")
    #expect(encoded("\u{1B}", keyCode: 53, kittyFlags: 0) == "\u{1B}")
    // Control with a key: `CSI code ; m u`, the key's unshifted character.
    #expect(encoded("\u{03}", ignoring: "c", keyCode: 8, .control, kittyFlags: 1) == "\u{1B}[99;5u")
    #expect(encoded("\u{01}", ignoring: "A", keyCode: 0, [.control, .shift], kittyFlags: 1) == "\u{1B}[97;6u")
    #expect(encoded("\u{1B}", ignoring: "[", keyCode: 33, .control, kittyFlags: 1) == "\u{1B}[91;5u")
    #expect(encoded(" ", keyCode: 49, .control, kittyFlags: 1) == "\u{1B}[32;5u")
    #expect(encoded("1", keyCode: 18, .control, kittyFlags: 1) == "\u{1B}[49;5u")
    // The unshifted character, when the event says it (Shift+2 types @).
    let controlShift2 = HostRoutedKeyEncoder.data(
        keyCode: 19, modifiers: [.control, .shift], characters: "\u{00}", charactersIgnoringModifiers: "@",
        unshiftedCharacters: "2", usesApplicationCursorKeys: false, isEnhancedKeyboardProtocolActive: true,
        keyboardProtocolFlags: 1, sendsModifiedArrowKeys: false
    ).map { String(decoding: $0, as: UTF8.self) }
    #expect(controlShift2 == "\u{1B}[50;6u")
    // A non-Latin layout: its own character, as Ghostty's surface sends it.
    #expect(encoded("ф", keyCode: 0, .control, kittyFlags: 1) == "\u{1B}[1092;5u")
    // Option as Alt, alone or with Control.
    #expect(encoded("∫", ignoring: "b", keyCode: 11, .option, kittyFlags: 1) == "\u{1B}[98;3u")
    #expect(encoded("ı", ignoring: "B", keyCode: 11, [.option, .shift], kittyFlags: 1) == "\u{1B}[98;4u")
    #expect(encoded("\u{02}", ignoring: "b", keyCode: 11, [.control, .option], kittyFlags: 1) == "\u{1B}[98;7u")
    // Option that composes types what it composed; text and Shift text are text.
    #expect(encoded("∫", ignoring: "b", keyCode: 11, .option, kittyFlags: 1, optionAsAlt: .neither) == "∫")
    #expect(encoded("a", keyCode: 0, kittyFlags: 1) == "a")
    #expect(encoded("A", keyCode: 0, .shift, kittyFlags: 1) == "A")
    // Return, Tab and Backspace: legacy bytes without modifiers, `CSI u` with.
    #expect(encoded("\r", keyCode: 36, kittyFlags: 1) == "\r")
    #expect(encoded("\t", keyCode: 48, kittyFlags: 1) == "\t")
    #expect(encoded("\u{7F}", keyCode: 51, kittyFlags: 1) == "\u{7F}")
    #expect(encoded("\r", keyCode: 36, .option, kittyFlags: 1) == "\u{1B}[13;3u")
    // F1, F2 and F4 are `CSI P`…, F3 `CSI 13 ~`; F5 and above as in xterm.
    #expect(encoded("\u{F704}", keyCode: 122, .function, kittyFlags: 1) == "\u{1B}[P")
    #expect(encoded("\u{F705}", keyCode: 120, .function, kittyFlags: 1) == "\u{1B}[Q")
    #expect(encoded("\u{F706}", keyCode: 99, .function, kittyFlags: 1) == "\u{1B}[13~")
    #expect(encoded("\u{F707}", keyCode: 118, .function, kittyFlags: 1) == "\u{1B}[S")
    #expect(encoded("\u{F704}", keyCode: 122, [.function, .control], kittyFlags: 1) == "\u{1B}[1;5P")
    #expect(encoded("\u{F706}", keyCode: 99, [.function, .shift], kittyFlags: 1) == "\u{1B}[13;2~")
    #expect(encoded("\u{F708}", keyCode: 96, .function, kittyFlags: 1) == "\u{1B}[15~")
    // Arrows: as in xterm (their cursor key mode is CSI under the protocol).
    #expect(encoded("\u{F702}", keyCode: 123, [.numericPad, .function, .control], kittyFlags: 1) == "\u{1B}[1;5D")
    #expect(encoded("\u{F701}", keyCode: 125, [.numericPad, .function], kittyFlags: 1) == "\u{1B}[B")
}

@Test @MainActor func keysTypedWhileAnAdapterIsAwayFollowTheKittyFlagsTheHostReports() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    defer {
        container.detachActiveSession()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(tab))
    container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    let call = try #require(harness.attachCalls.first)
    let sessionID = try #require(tab.persistentSession?.sessionID)

    // A program uses the kitty keyboard protocol (and has DECCKM on, which
    // the protocol overrides for cursor keys); the host reports it.
    harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(.changed(HostedSessionInfo(
        id: sessionID, name: "Shell", cwd: harness.project.path, pid: 42, clients: 1,
        alternateScreen: true, kittyKeyboardFlags: 1, applicationCursorKeys: true
    ))))
    #expect(await harness.fake.wait { tab.isEnhancedKeyboardProtocolActive })

    // Its adapter reconnects: the keys go through the host, as Ghostty's
    // surface would have typed them.
    try HostedSessionFakeCLI.writeStatus(
        HostedSessionFakeCLI.attachedStatus(reconnecting: true), to: try harness.statusFile(of: call)
    )
    #expect(await harness.fake.wait { tab.keyboardInputGoesThroughHost })
    let controlC = try keyDown("\u{03}", ignoringModifiers: "c", keyCode: 8, modifiers: .control)
    // The key's own unshifted character (layout dependent): its code.
    let controlCCode = try #require(controlC.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value)
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("\u{1B}", keyCode: 53)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(controlC))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("\u{F706}", keyCode: 99, modifiers: .function)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(
        try keyDown("\u{F701}", keyCode: 125, modifiers: [.numericPad, .function])
    ))
    #expect(await harness.fake.wait { typedThroughHost(harness).count == 4 })
    #expect(typedThroughHost(harness) == ["\u{1B}[27u", "\u{1B}[\(controlCCode);5u", "\u{1B}[13~", "\u{1B}[B"])
}
