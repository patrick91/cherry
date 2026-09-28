import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import Cherry

// ⌘V and Edit › Paste of images and copied files into a tab of This Mac,
// end to end: a real Ghostty surface in a window, the window's key monitor
// and the surface's own paste (its `super+v` binding and `paste:`), with a
// private pasteboard in place of the general one (`TerminalClipboard`,
// the container's `pasteboard`). What reaches the program is read from the
// surface: its pty echoes what it is typed. No test here touches
// NSPasteboard.general.

private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!

/// A window showing one tab, a private pasteboard for its surfaces and a
/// cache folder of its own for pasted images.
@MainActor
private final class PasteStage {
    let window: NSWindow
    let container: GhosttyTerminalContainerView
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CherryTests.PasteKeys.\(UUID().uuidString)"))
    /// With a space, as the real one has.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CherryPasteKeys-\(UUID().uuidString.prefix(8))/Pasted Images", isDirectory: true)
    private let savedDirectory = LocalImagePaste.directory
    private let savedPasteboard = TerminalClipboard.pasteboard

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        window.contentView = container
        let pasteboard = pasteboard
        TerminalClipboard.pasteboard = { pasteboard }
        let directory = directory
        LocalImagePaste.directory = { directory }
        pasteboard.clearContents()
        window.orderFrontRegardless()
    }

    func show(_ tab: TerminalSession) {
        container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
    }

    func cleanUp() {
        container.detachActiveSession()
        window.close()
        TerminalClipboard.pasteboard = savedPasteboard
        LocalImagePaste.directory = savedDirectory
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    /// The saved images, by the folder's path as the paste names it (a
    /// listing resolves /var to /private/var).
    var saved: [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".png") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// ⌘V as the keyboard sends it to the app: through its event monitors,
    /// then the window.
    func commandV() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        ))
        NSApp.sendEvent(event)
    }

    /// Edit › Paste: `paste:` to the window's first responder, up the
    /// responder chain.
    func menuPaste() -> Bool {
        window.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: nil) ?? false
    }

    func putImage() {
        pasteboard.clearContents()
        pasteboard.setData(onePixelPNG, forType: .png)
    }

    /// What a screenshot tool's Copy puts there: the image's file and its
    /// data, no text.
    func putScreenshotToolCopy(_ file: URL) {
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.addTypes([.png], owner: nil)
        pasteboard.setData(onePixelPNG, forType: .png)
    }

    func putText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The surface's text with its lines joined (a long path wraps).
@MainActor
private func screen(_ tab: TerminalSession) -> String {
    (tab.ghosttyBridge.readNativeScreenText() ?? "").replacingOccurrences(of: "\n", with: "")
}

@MainActor
private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

@Test @MainActor func RemoteDevicePasteOfAnImageIntoAPersistentTabOfThisMacPastesItsSavedPath() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let stage = PasteStage()
    defer {
        stage.cleanUp()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(tab))
    stage.show(tab)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    #expect(tab.ghosttyBridge.isNativePTYBacked)
    #expect(stage.window.makeFirstResponder(tab.ghosttyBridge.terminalView))
    #expect(await waitFor { screen(tab).contains("Attached") })

    // ⌘V of a screenshot (image data alone): saved, its quoted path typed.
    stage.putImage()
    try stage.commandV()
    #expect(await waitFor { stage.saved.count == 1 })
    let first = try #require(stage.saved.first)
    #expect(try Data(contentsOf: first) == onePixelPNG)
    #expect(await waitFor { screen(tab).contains("'\(first.path)'") })

    // A screenshot tool's copy (the image's file and data, no text): the
    // file's path, not nothing.
    let shot = stage.directory.deletingLastPathComponent().appendingPathComponent("CleanShot 2026.png")
    try onePixelPNG.write(to: shot)
    stage.putScreenshotToolCopy(shot)
    try stage.commandV()
    #expect(await waitFor { screen(tab).contains("'\(shot.path)'") })
    #expect(stage.saved.count == 1)

    // Edit › Paste of an image: the same as ⌘V.
    stage.putImage()
    #expect(stage.menuPaste())
    #expect(await waitFor { stage.saved.count == 2 })
    let second = try #require(stage.saved.first { $0 != first })
    #expect(await waitFor { screen(tab).contains("'\(second.path)'") })

    // Text pastes as text, from the key and the menu (the surface's paste).
    stage.putText("plain-words-by-key")
    try stage.commandV()
    #expect(await waitFor { screen(tab).contains("plain-words-by-key") })
    stage.putText("plain-words-by-menu")
    #expect(stage.menuPaste())
    #expect(await waitFor { screen(tab).contains("plain-words-by-menu") })
    #expect(stage.saved.count == 2)
}

@Test @MainActor func RemoteDevicePasteReachesTheTerminalWhenAViewInsideItHasTheKeyboard() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let stage = PasteStage()
    defer {
        stage.cleanUp()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(tab))
    stage.show(tab)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    #expect(await waitFor { screen(tab).contains("Attached") })

    // An input view inside the terminal's (as an input method may add)
    // has the keyboard.
    final class InnerView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
    let terminalView = tab.ghosttyBridge.terminalView
    let inner = InnerView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    terminalView.addSubview(inner)
    defer { inner.removeFromSuperview() }
    #expect(stage.window.makeFirstResponder(inner))
    #expect(GhosttyTerminalContainerView.terminalHasKeyboard(inner, terminalView: terminalView))
    #expect(GhosttyTerminalContainerView.terminalHasKeyboard(terminalView, terminalView: terminalView))
    #expect(!GhosttyTerminalContainerView.terminalHasKeyboard(stage.container, terminalView: terminalView))
    #expect(!GhosttyTerminalContainerView.terminalHasKeyboard(nil, terminalView: terminalView))

    stage.putImage()
    try stage.commandV()
    #expect(await waitFor { stage.saved.count == 1 })
    let file = try #require(stage.saved.first)
    #expect(await waitFor { screen(tab).contains("'\(file.path)'") })
}

@Test @MainActor func RemoteDevicePasteOfAnImageIntoANativeTabPastesItsSavedPath() async throws {
    let project = FileManager.default.temporaryDirectory
        .appendingPathComponent("CherryPasteNative-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let workspace = TerminalWorkspace(projectRoot: project.path, createInitialSession: false, launchBackend: .nativePTY)
    let stage = PasteStage()
    defer {
        stage.cleanUp()
        workspace.closeAllSessions(intent: .windowClosed)
        try? FileManager.default.removeItem(at: project)
    }
    // `cat` in a pty: what the tab is typed is echoed on its screen.
    let tab = workspace.addSession(title: "Cat", command: "printf 'ready\\n'; exec cat")
    stage.show(tab)
    #expect(tab.ghosttyBridge.isNativePTYBacked)
    #expect(tab.persistentSession == nil)
    #expect(stage.window.makeFirstResponder(tab.ghosttyBridge.terminalView))
    #expect(await waitFor(10) { screen(tab).contains("ready") })

    stage.putImage()
    try stage.commandV()
    #expect(await waitFor { stage.saved.count == 1 })
    let first = try #require(stage.saved.first)
    #expect(await waitFor { screen(tab).contains("'\(first.path)'") })

    stage.putImage()
    #expect(stage.menuPaste())
    #expect(await waitFor { stage.saved.count == 2 })
    let second = try #require(stage.saved.first { $0 != first })
    #expect(await waitFor { screen(tab).contains("'\(second.path)'") })
}

@Test @MainActor func RemoteDevicePasteOfCopiedFilesWithoutTextPastesTheirPaths() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CherryTests.PasteFiles.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CherryPasteFiles-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let savedDirectory = LocalImagePaste.directory
    LocalImagePaste.directory = { directory }
    defer {
        LocalImagePaste.directory = savedDirectory
        try? FileManager.default.removeItem(at: directory)
    }
    let shot = URL(fileURLWithPath: "/tmp/cherry paste/shot.png")
    let other = URL(fileURLWithPath: "/tmp/cherry-paste/b.png")

    // File URLs written alone carry no text: a terminal would paste nothing.
    pasteboard.clearContents()
    pasteboard.writeObjects([shot as NSURL, other as NSURL])
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(LocalImagePaste.text(for: pasteboard) == "'/tmp/cherry paste/shot.png' /tmp/cherry-paste/b.png")

    // With the image's data too (a screenshot tool's copy): the file.
    pasteboard.clearContents()
    pasteboard.writeObjects([shot as NSURL])
    pasteboard.addTypes([.png], owner: nil)
    pasteboard.setData(onePixelPNG, forType: .png)
    #expect(LocalImagePaste.text(for: pasteboard) == "'/tmp/cherry paste/shot.png'")
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    // Finder's copy carries the names as text: pasted as before.
    pasteboard.clearContents()
    pasteboard.writeObjects([shot as NSURL])
    pasteboard.addTypes([.string], owner: nil)
    pasteboard.setString("shot.png", forType: .string)
    #expect(LocalImagePaste.text(for: pasteboard) == nil)
}
