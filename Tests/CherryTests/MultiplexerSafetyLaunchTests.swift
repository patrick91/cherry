import AppKit
import Foundation
import Testing
@testable import Cherry

// What a launch does for the safety of hosted-by-default tabs
// (docs/specs/multiplexer-default.md): it stops the SSH masters of app runs
// that ended, and a copy of the app that did not get the instance lock
// (`AppInstanceLock`) says once, on its first project window, that it leaves
// the persistent sessions alone. Nothing here takes the app's real lock or
// shows a real sheet: the lock's answer and the presenter are the tests'.

/// What the notice showed, and on which window.
@MainActor
private final class ShownNotices {
    var shown: [(content: InstanceLockNotice.Content, window: NSWindow)] = []
}

@MainActor
private func window() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    return window
}

/// Waits (polling the main loop) until `condition` holds; false after
/// `timeout`.
@MainActor
private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test func theInstanceLockNoticeExplainsWhyPersistentSessionsAreOffOnlyWhenTheyAre() throws {
    #expect(InstanceLockNotice.content(reason: nil) == nil)
    #expect(InstanceLockNotice.content(reason: "  \n") == nil)
    let reason = "Another copy of Cherry (process 42) is running with the same app data."
    let content = try #require(InstanceLockNotice.content(reason: reason))
    #expect(content.title == "Persistent sessions are off in this copy")
    #expect(content.message.hasPrefix(reason))
    #expect(content.message.contains("ordinary tabs"))

    // What the lock says for each outcome: only a copy that does not hold
    // it (another copy does, or it could not be taken) is told.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-notice-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("instance.lock")
    let first = AppInstanceLock(fileURL: url, applicationSupportName: "Test App")
    defer { first.release() }
    #expect(first.isHeld)
    #expect(InstanceLockNotice.content(reason: first.unavailableReason) == nil)
    let second = AppInstanceLock(fileURL: url, applicationSupportName: "Test App", quittingHolderWait: 0)
    let told = try #require(InstanceLockNotice.content(reason: second.unavailableReason))
    #expect(told.message.contains("Another copy of Test App"))
    let unsupported = AppInstanceLock(
        fileURL: directory.appendingPathComponent("unsupported.lock"), applicationSupportName: "Test App",
        lockCall: { _, _ in errno = ENOTSUP; return -1 }
    )
    #expect(InstanceLockNotice.content(reason: unsupported.unavailableReason) == nil)
}

@Test @MainActor func theInstanceLockNoticeIsShownOnceOnTheFirstProjectWindow() async throws {
    let shown = ShownNotices()
    let asked = Recorder(0)
    let notice = InstanceLockNotice(
        reason: {
            asked.value += 1
            return "Another copy of Cherry is running with the same app data."
        },
        canPresent: { _ in true },
        present: { content, window in shown.shown.append((content, window)) }
    )
    let first = window()
    let second = window()
    notice.projectWindowDidRegister(first)
    // Windows registering while it is being found out change nothing.
    notice.projectWindowDidRegister(second)
    #expect(await eventually { !shown.shown.isEmpty })
    #expect(notice.phase == .shown)
    notice.projectWindowDidRegister(second)
    notice.projectWindowDidRegister(first)
    try await Task.sleep(for: .milliseconds(100))
    #expect(shown.shown.count == 1)
    #expect(shown.shown.first?.window === first)
    #expect(shown.shown.first?.content.title == "Persistent sessions are off in this copy")
    #expect(asked.value == 1)
}

@Test @MainActor func aCopyThatHoldsTheInstanceLockShowsNoNotice() async throws {
    let shown = ShownNotices()
    let notice = InstanceLockNotice(
        reason: { nil },
        canPresent: { _ in true },
        present: { content, window in shown.shown.append((content, window)) }
    )
    notice.projectWindowDidRegister(window())
    #expect(await eventually { notice.phase == .notNeeded })
    notice.projectWindowDidRegister(window())
    try await Task.sleep(for: .milliseconds(100))
    #expect(shown.shown.isEmpty)
    #expect(notice.phase == .notNeeded)
}

@Test @MainActor func theInstanceLockNoticeWaitsForAWindowThatCanShowIt() async throws {
    let shown = ShownNotices()
    let offScreen = window()
    let fallback = window()
    let presentable = Recorder<Set<ObjectIdentifier>>([])
    let fallbackWindow = Recorder<NSWindow?>(nil)
    let notice = InstanceLockNotice(
        reason: { "Another copy of Cherry is running with the same app data." },
        fallbackWindow: { fallbackWindow.value },
        canPresent: { presentable.value.contains(ObjectIdentifier($0)) },
        present: { content, window in shown.shown.append((content, window)) },
        retryDelay: 0.05,
        retries: 3
    )

    // The window that registered is not on screen, and no other project
    // window is: after a few tries, it waits for the next one.
    notice.projectWindowDidRegister(offScreen)
    #expect(await eventually {
        if case .waitingForWindow = notice.phase { return true }
        return false
    })
    try await Task.sleep(for: .milliseconds(400))
    #expect(shown.shown.isEmpty)

    // Another project window registers and can show it.
    presentable.value.insert(ObjectIdentifier(fallback))
    notice.projectWindowDidRegister(fallback)
    #expect(shown.shown.count == 1)
    #expect(shown.shown.first?.window === fallback)
    #expect(notice.phase == .shown)

    // While it retries, another project window that comes on screen gets it.
    let retrying = InstanceLockNotice(
        reason: { "Another copy of Cherry is running with the same app data." },
        fallbackWindow: { fallbackWindow.value },
        canPresent: { presentable.value.contains(ObjectIdentifier($0)) },
        present: { content, window in shown.shown.append((content, window)) },
        retryDelay: 0.05,
        retries: 100
    )
    retrying.projectWindowDidRegister(offScreen)
    #expect(await eventually {
        if case .waitingForWindow = retrying.phase { return true }
        return false
    })
    fallbackWindow.value = fallback
    #expect(await eventually { retrying.phase == .shown })
    #expect(shown.shown.last?.window === fallback)
}

@Test @MainActor func launchStopsAbandonedSSHMastersAndOffersTheNoticeToProjectWindows() async throws {
    let registry = ProjectWindowRegistry()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-launch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false)
    let projectWindow = window()
    defer {
        registry.unregister(window: projectWindow, projectRoot: root.path)
        workspace.closeAllSessions(intent: .windowClosed)
        try? FileManager.default.removeItem(at: root)
    }
    // A project window SwiftUI restored before launch finished.
    #expect(registry.register(
        window: projectWindow, projectRoot: root.path, workspace: workspace,
        noteStore: nil, todoStore: nil, chromeState: nil
    ))

    let shown = ShownNotices()
    let notice = InstanceLockNotice(
        reason: { "Another copy of Cherry is running with the same app data." },
        canPresent: { _ in true },
        present: { content, window in shown.shown.append((content, window)) }
    )
    var sweeps = 0
    CherryAppDelegate.startLaunchHousekeeping(
        registry: registry,
        sweepSSHMasters: { sweeps += 1 },
        instanceLockNotice: notice
    )
    #expect(sweeps == 1)
    #expect(registry.instanceLockNotice === notice)
    #expect(await eventually { shown.shown.count == 1 })
    #expect(shown.shown.first?.window === projectWindow)

    // Installed once: a second call (there is none in the app) keeps it.
    let other = InstanceLockNotice(reason: { nil }, canPresent: { _ in true }, present: { _, _ in })
    registry.installInstanceLockNotice(other)
    #expect(registry.instanceLockNotice === notice)
    // A registry without one (tests, and the app before launch finished)
    // never asks the real lock.
    #expect(ProjectWindowRegistry().instanceLockNotice == nil)
}
