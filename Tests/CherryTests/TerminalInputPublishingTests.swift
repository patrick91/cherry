import AppKit
import Combine
import Foundation
import Testing
@testable import Cherry

// A keystroke that changes nothing a view shows publishes nothing: every
// view observing the tab (the pane, its context bar, the sidebar row) would
// otherwise re-render once per key (about 1.75 ms of main thread a key).

@MainActor
private final class PublishCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    init(_ session: TerminalSession) {
        subscription = session.objectWillChange.sink { [weak self] _ in
            self?.count += 1
        }
    }
}

@MainActor
private func makeTab(kind: TerminalSession.SessionKind = .terminal) -> TerminalSession {
    TerminalSession(
        title: "Keys",
        subtitle: "zsh login shell",
        tint: .systemBlue,
        workingDirectory: NSHomeDirectory(),
        launchShell: false,
        kind: kind,
        agentName: kind == .agent ? "Claude" : nil,
        attentionObservationDirectoryProvider: { nil }
    )
}

/// A typed key: AppKit's keyboard path (`terminalWillSendHostInput`, with
/// the key's event) and the programmatic one (`noteInputBurst`, as MCP input
/// and the bridge's key overrides take).
@MainActor
private func type(_ key: String, into session: TerminalSession) {
    session.noteNativeHostInput(event: keyDown(key))
    session.noteTestingInput(Data(key.utf8))
}

/// The key-down event AppKit gives the terminal view for `key`.
@MainActor
private func keyDown(_ key: String) -> NSEvent? {
    let keyCodes: [String: UInt16] = ["a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "\r": 36, "\u{1B}[B": 125]
    let characters = key == "\u{1B}[B" ? String(UnicodeScalar(NSDownArrowFunctionKey)!) : key
    return NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: key == "\u{1B}[B" ? [.numericPad, .function] : [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCodes[key] ?? 0
    )
}

/// Lets work a keystroke started on a later main-actor turn run (it would
/// publish then, not while the key is handled).
@MainActor
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(50))
}

@Test @MainActor func aKeystrokeThatChangesNothingPublishesNothing() async throws {
    let session = makeTab()
    defer { session.stop() }
    // The first key sets where the output was when input last came.
    type("a", into: session)
    #expect(session.lastInputOutputVersion == session.outputVersion)
    #expect(session.currentAttentionScreenTag == nil)

    try await settle()
    let counter = PublishCounter(session)
    for key in ["b", "c", "\r", "\u{1B}[B"] {
        type(key, into: session)
    }
    #expect(counter.count == 0)
    try await settle()
    #expect(counter.count == 0)
}

/// Output the tab takes is counted on a later main-actor turn.
@MainActor
private func ingestOutput(_ text: String, into session: TerminalSession) async throws {
    let before = session.outputVersion
    session.ingestTestingData(Data(text.utf8))
    let deadline = Date().addingTimeInterval(5)
    while session.outputVersion == before, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.outputVersion != before)
}

@Test @MainActor func aKeystrokeStillPublishesWhatItChanges() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-keystroke-publish-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = TerminalSession(
        title: "Keys",
        subtitle: "",
        tint: .systemBlue,
        launchShell: false,
        attentionObservationDirectoryProvider: { nil },
        attentionCorrectionDirectoryProvider: { directory }
    )
    defer { session.stop() }
    type("a", into: session)

    // Output since the last key: the next key moves the baseline, once.
    try await ingestOutput("output\r\n", into: session)
    let counter = PublishCounter(session)
    type("b", into: session)
    #expect(session.lastInputOutputVersion == session.outputVersion)
    let afterBaseline = counter.count
    #expect(afterBaseline > 0)
    type("c", into: session)
    #expect(counter.count == afterBaseline)

    // A tagged screen: the next key clears the tag, once.
    _ = try session.captureAttentionCorrection(.blockedOrError)
    #expect(session.currentAttentionScreenTag == .blockedOrError)
    let afterTag = counter.count
    type("d", into: session)
    #expect(session.currentAttentionScreenTag == nil)
    #expect(counter.count > afterTag)
    let afterClear = counter.count
    type("e", into: session)
    #expect(counter.count == afterClear)
}

/// An agent tab's keys also update its draft (from the AppKit event, or
/// the bytes) and schedule an attention observation, debounced: neither
/// publishes per key.
@Test @MainActor func anAgentsKeystrokeThatChangesNothingPublishesNothing() async throws {
    let session = makeTab(kind: .agent)
    defer { session.stop() }
    type("a", into: session)
    // The observation that follows the first key (its first prediction).
    let deadline = Date().addingTimeInterval(5)
    while session.attentionClassifierPrediction == nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    try #require(session.attentionClassifierPrediction != nil)

    let counter = PublishCounter(session)
    for key in ["b", "c", "d", "e", "b", "c", "d", "e"] {
        // AppKit's path alone, then the programmatic one alone.
        session.noteNativeHostInput(event: keyDown(key))
        session.noteTestingInput(Data(key.utf8))
    }
    #expect(counter.count == 0)
    try await settle()
    #expect(counter.count == 0)

    // The debounced observation after the keys: at most its new
    // prediction (its timings moved on), however many keys came.
    try await Task.sleep(for: .milliseconds(1_300))
    #expect(counter.count <= 1)
}

@Test @MainActor func theContextBarsContentStaysEqualAcrossKeystrokes() async throws {
    let session = makeTab()
    defer { session.stop() }
    let before = TerminalContextBarContent(session: session)
    type("a", into: session)
    try await ingestOutput("output\r\n", into: session)
    type("b", into: session)
    // The bar is not re-rendered: it is given equal content.
    #expect(TerminalContextBarContent(session: session) == before)
    #expect(before.displayPath == "~")
    #expect(before.sessionLabel == "Keys")

    session.ingestNativeWorkingDirectory(NSHomeDirectory() + "/project")
    let moved = TerminalContextBarContent(session: session)
    #expect(moved != before)
    #expect(moved.displayPath == "~/project")
}
