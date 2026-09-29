import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import Testing
@testable import Cherry

// Restarting a native tab runs `reset()` (clearing the old launch) and then
// `startShell()`, whose relaunch rebuilds the surface with fresh options.
// `reset()` must not rebuild the surface itself: after a `cd` (OSC 7) or a
// command edit the options differ, and a rebuild there spawns an extra copy of
// the shell or command that the relaunch then kills again.
@Test @MainActor func nativeRestartSpawnsTheChildOnlyFromTheRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-native-relaunch-\(UUID().uuidString)")
    let launchDirectory = root.appendingPathComponent("launch")
    let changedDirectory = root.appendingPathComponent("changed")
    try FileManager.default.createDirectory(at: launchDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: changedDirectory, withIntermediateDirectories: true)
    let session = TerminalSession(
        title: "Shell", subtitle: "", tint: .systemBlue, workingDirectory: launchDirectory.path
    )
    defer {
        session.stop()
        session.releaseGhosttyBridge()
        try? FileManager.default.removeItem(at: root)
    }
    let bridge = session.ghosttyBridge

    func waitForLeader(otherThan previous: pid_t? = nil) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let leader = bridge.nativeSessionLeaderPID(), leader != previous { return leader }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HostedSessionError.message("The native shell did not start")
    }

    let leader = try await waitForLeader()
    // The shell reported a new directory, so fresh options would now differ.
    session.ingestNativeWorkingDirectory(changedDirectory.path)
    bridge.reset()
    #expect(bridge.nativeSessionLeaderPID() == leader)
    #expect(kill(leader, 0) == 0)

    session.restart()
    #expect(session.state == .live)
    #expect(bridge.terminalView.configuration.workingDirectory == changedDirectory.path)
    let relaunched = try await waitForLeader(otherThan: leader)
    #expect(kill(relaunched, 0) == 0)
}

// A bridge builds its surface once it has a controller, from the options it
// has then. It once got the controller first, so every bridge built a surface
// with the view's default options (an EXEC surface of Ghostty's default
// command: the user's login shell), then replaced it with the tab's in the same
// main-thread turn: a login shell started and killed for each tab, and the
// freed surface's queued messages could reach the replacement.
@Test @MainActor func aNewNativeTabBuildsOnlyItsOwnSurface() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-native-first-surface-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let session = TerminalSession(title: "Shell", subtitle: "", tint: .systemBlue, workingDirectory: directory.path)
    defer {
        session.stop()
        session.releaseGhosttyBridge()
        try? FileManager.default.removeItem(at: directory)
    }
    #expect(session.usesNativePTYBackend)
    let view = session.ghosttyBridge.terminalView
    #expect(view.surfaceBuildCount == 1)
    guard case .exec = view.configuration.backend else {
        Issue.record("A native tab's surface is an EXEC surface")
        return
    }
    #expect(view.configuration.workingDirectory == directory.path)
    #expect(view.configuration.execCommand != nil)
}

// A tab that runs nothing gets an in-memory surface, which is built only in a
// window: detached, its bridge builds none, and so starts no process.
@Test @MainActor func aBridgeOfATabThatRunsNothingStartsNoProcess() {
    let session = TerminalSession(title: "Idle", subtitle: "", tint: .systemBlue, launchShell: false)
    defer { session.releaseGhosttyBridge() }
    #expect(!session.usesNativePTYBackend)
    let view = session.ghosttyBridge.terminalView
    #expect(view.surfaceBuildCount == 0)
    if case .exec = view.configuration.backend {
        Issue.record("A tab that runs nothing has an in-memory surface")
    }
}
