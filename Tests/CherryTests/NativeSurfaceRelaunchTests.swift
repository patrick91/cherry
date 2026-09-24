import AppKit
import Darwin
import Foundation
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
