import AppKit
import Foundation
import Testing
@testable import Cherry

// Where the quit confirmation sheet goes, and its one answer
// (CherryAppDelegate.applicationShouldTerminate): the sheet must sit on a
// project window the user can see, and a sheet whose window closes first
// cancels the quit rather than leave AppKit waiting for a reply.

@MainActor
private func makeWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: true
    )
    window.isReleasedWhenClosed = false
    return window
}

/// Waits (briefly) for `condition`: the window-close observer runs on the
/// main queue.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test @MainActor func theQuitConfirmationGoesOnAProjectWindowNeverTheMenuBarPanel() {
    let keyProject = makeWindow()
    let activeProject = makeWindow()
    let menuBarPanel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.nonactivatingPanel],
        backing: .buffered,
        defer: true
    )

    // The key window is a project window: the sheet goes there.
    #expect(CherryAppDelegate.quitConfirmationParent(
        keyWindow: keyProject, keyWindowIsProjectWindow: true, activeProjectWindow: activeProject
    ) === keyProject)
    // Quit from the menu bar panel (it is key): the active project's window.
    #expect(CherryAppDelegate.quitConfirmationParent(
        keyWindow: menuBarPanel, keyWindowIsProjectWindow: false, activeProjectWindow: activeProject
    ) === activeProject)
    // No key window (the app is in the background or hidden).
    #expect(CherryAppDelegate.quitConfirmationParent(
        keyWindow: nil, keyWindowIsProjectWindow: false, activeProjectWindow: activeProject
    ) === activeProject)
    // No project window open: nil, and the confirmation is app-modal.
    #expect(CherryAppDelegate.quitConfirmationParent(
        keyWindow: menuBarPanel, keyWindowIsProjectWindow: false, activeProjectWindow: nil
    ) == nil)
}

@Test @MainActor func closingTheQuitConfirmationsWindowFirstCancelsTheQuitOnce() async {
    let parent = makeWindow()
    let other = makeWindow()
    let answers = Recorder<[Bool]>([])
    let answer = QuitConfirmationAnswer(parent: parent) { answers.value.append($0) }

    // Another window closing is no answer.
    other.close()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(answers.value.isEmpty)
    #expect(!answer.isResolved)

    // The sheet's window closes before the sheet was answered: the quit is
    // cancelled (AppKit gets its reply) ...
    parent.close()
    #expect(await eventually { answers.value == [false] })
    #expect(answer.isResolved)
    // ... and the sheet ending with its window answers nothing more.
    answer.resolve(true)
    #expect(answers.value == [false])
}

@Test @MainActor func theQuitConfirmationsSheetAnswersOnceEvenIfItsWindowClosesAfterward() async {
    let parent = makeWindow()
    let answers = Recorder<[Bool]>([])
    let answer = QuitConfirmationAnswer(parent: parent) { answers.value.append($0) }

    answer.resolve(true)
    #expect(answers.value == [true])
    // The quit tears windows down: that close is no second answer.
    parent.close()
    try? await Task.sleep(for: .milliseconds(100))
    answer.resolve(false)
    #expect(answers.value == [true])
}
