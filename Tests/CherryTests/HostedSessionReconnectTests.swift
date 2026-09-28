import AppKit
import Combine
import Foundation
import Testing
@testable import Cherry

// Tabs attached to an SSH host's sessions whose adapter gave up wait for
// their host (`HostedReconnects`) and reconnect once it answers.

/// An SSH host `devbox` answered by a fake control helper, its tabs' fake
/// adapters, and the reconnects under test.
@MainActor
private final class SSHReconnectHarness {
    let cli: HostedSessionFakeCLI
    let remote: FakeControlHelper
    let devbox: HostedSessionHost
    let control: HostControl
    let reconnects: HostedReconnects
    let workspace: TerminalWorkspace
    private let defaults: UserDefaults
    private let suite: String
    private var windows: [(NSWindow, GhosttyTerminalContainerView)] = []

    init(
        sessions: [String] = ["session-123"],
        delay: (initial: TimeInterval, maximum: TimeInterval) = (0.05, 0.2),
        controlConfiguration: HostControl.Configuration = .fastTests,
        hostReconnectsInPolicy: Bool = true
    ) throws {
        cli = try HostedSessionFakeCLI()
        remote = FakeControlHelper(sessions: sessions.map { hostedSession($0) })
        devbox = try .ssh("devbox")
        let isolated = try makeIsolatedHostedSessionHostStore()
        defaults = isolated.defaults
        suite = isolated.suite
        let control = makeFakeHostControl(
            remote, host: devbox, hostStore: isolated.store, configuration: controlConfiguration
        )
        self.control = control
        var configuration = HostedReconnects.Configuration()
        configuration.delay = delay
        reconnects = HostedReconnects(
            configuration: configuration,
            control: { _ in control },
            controls: { [control] },
            monitorsSystem: false
        )
        var policy = SessionBackendPolicy.native
        if hostReconnectsInPolicy { policy.hostReconnects = reconnects }
        workspace = TerminalWorkspace(createInitialSession: false, backendPolicy: policy)
    }

    /// A tab attached to `sessionID` on devbox, shown in a window so that
    /// its adapter launches.
    func attach(_ sessionID: String) -> TerminalSession {
        let session = workspace.attachHostedSession(HostedSessionAttachment(
            host: devbox, hostID: "host-a", sessionID: sessionID,
            name: sessionID, remoteWorkingDirectory: "/remote", executablePath: cli.executable.path
        ))
        let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
        windows.append((window, container))
        return session
    }

    func launches(of sessionID: String) -> [String] {
        cli.calls.filter { $0.contains(" attach \(sessionID) ") }
    }

    func waitForLaunches(of sessionID: String, _ count: Int) async throws -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let launches = launches(of: sessionID)
            if launches.count >= count { return launches }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HostedSessionError.message("\(sessionID)'s adapter did not launch \(count) times")
    }

    /// The adapter of `launch` ends with `status` (its status file), and
    /// the tab hears it exited.
    func end(_ session: TerminalSession, launch: String, status: String) throws {
        let file = try #require(HostedSessionFakeCLI.statusFile(of: launch))
        try HostedSessionFakeCLI.writeStatus(status, to: file)
        session.ingestNativeChildExit(exitCode: 1)
    }

    func cleanUp() {
        workspace.closeAllSessions()
        for (window, container) in windows {
            container.detachActiveSession()
            window.close()
        }
        control.disconnect()
        cli.cleanUp()
        defaults.removePersistentDomain(forName: suite)
    }
}

private let lostConnection =
    #"{"outcome":"disconnected","exit_code":null,"signal":null,"message":"connection lost; could not reconnect within 30 s"}"#
private let unreachable =
    #"{"outcome":"failed","exit_code":null,"signal":null,"message":"ssh: connect to host devbox port 22: Network is unreachable"}"#

@Test @MainActor func HostedSessionSSHTabWaitsForItsHostAndReconnectsOnceItAnswers() async throws {
    let harness = try SSHReconnectHarness()
    defer { harness.cleanUp() }
    let session = harness.attach("session-123")
    let first = try await harness.waitForLaunches(of: "session-123", 1)[0]

    // The host is unreachable: the adapter gave up, and the tab waits.
    harness.remote.launchFailure = "ssh: connect to host devbox port 22: Network is unreachable"
    try harness.end(session, launch: first, status: lostConnection)
    #expect(session.isWaitingForHost)
    #expect(session.state == .disconnected)
    #expect(harness.reconnects.waitingCounts == [harness.devbox.id: 1])
    #expect(HostedConnectionBarState(
        isRunning: session.isRunning, status: session.hostedAttachmentStatus, removedFromHost: false,
        canClose: true, waitingForHost: session.isWaitingForHost
    ) == HostedConnectionBarState(isRunning: false, status: nil, removedFromHost: false, canClose: true, waitingForHost: true))
    // It probes with backoff while the host does not answer, and launches
    // no adapter meanwhile.
    #expect(await harness.remote.wait { (harness.reconnects.probeCounts[harness.devbox.id] ?? 0) >= 3 })
    #expect(harness.launches(of: "session-123").count == 1)
    #expect(session.isWaitingForHost)

    // It answers: the adapter launches again, and the tab no longer waits.
    harness.remote.launchFailure = nil
    let second = try await harness.waitForLaunches(of: "session-123", 2)[1]
    #expect(!session.isWaitingForHost)
    #expect(session.hostedAttachmentStatus == .active)
    #expect(harness.reconnects.waitingCounts.isEmpty)

    // An adapter that could not attach (ssh could not reach the host) waits
    // too, and comes back the same way.
    try harness.end(session, launch: second, status: unreachable)
    #expect(session.isWaitingForHost)
    _ = try await harness.waitForLaunches(of: "session-123", 3)
    #expect(!session.isWaitingForHost)
}

@Test @MainActor func HostedSessionSSHTabsOfOneHostShareOneProbe() async throws {
    // A long backoff: only the trigger probes.
    let harness = try SSHReconnectHarness(sessions: ["s1", "s2", "s3"], delay: (600, 600))
    defer { harness.cleanUp() }
    let tabs = ["s1", "s2", "s3"].map { harness.attach($0) }
    var firsts: [String] = []
    for id in ["s1", "s2", "s3"] {
        firsts.append(try await harness.waitForLaunches(of: id, 1)[0])
    }
    for (tab, launch) in zip(tabs, firsts) {
        try harness.end(tab, launch: launch, status: lostConnection)
    }
    #expect(tabs.allSatisfy { $0.isWaitingForHost })
    #expect(harness.reconnects.waitingCounts == [harness.devbox.id: 3])
    #expect(HostedReconnects.waitingText(count: 3, host: harness.devbox) == "3 tabs waiting for devbox")
    #expect(HostedReconnects.waitingText(count: 1, host: harness.devbox) == "1 tab waiting for devbox")
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.reconnects.probeCounts[harness.devbox.id] == nil)
    #expect(harness.remote.launches.isEmpty)

    // The network came back: one probe, over one connection, for all three.
    harness.reconnects.networkBecameAvailable()
    for id in ["s1", "s2", "s3"] {
        _ = try await harness.waitForLaunches(of: id, 2)
    }
    #expect(tabs.allSatisfy { !$0.isWaitingForHost })
    #expect(harness.reconnects.probeCounts[harness.devbox.id] == 1)
    #expect(harness.remote.launches.count == 1)
}

@Test @MainActor func HostedSessionWakeRetriesWaitingTabsAndLeasedControlsAtOnce() async throws {
    var slow = HostControl.Configuration.fastTests
    slow.reconnectDelay = (.seconds(600), .seconds(600))
    let harness = try SSHReconnectHarness(delay: (600, 600), controlConfiguration: slow)
    defer { harness.cleanUp() }
    let session = harness.attach("session-123")
    let first = try await harness.waitForLaunches(of: "session-123", 1)[0]
    try harness.end(session, launch: first, status: lostConnection)
    #expect(session.isWaitingForHost)

    // A restore waiting for the host keeps its control leased; it failed
    // once and waits ten minutes to try again.
    harness.remote.launchFailure = "ssh: connect to host devbox port 22: Network is unreachable"
    let available = Recorder(false)
    let subscription = harness.control.availability().sink { available.value = true }
    defer { subscription.cancel() }
    #expect(await harness.remote.wait {
        if case .waitingToReconnect = harness.control.state { return true }
        return false
    })
    harness.remote.launchFailure = nil

    // The Mac wakes: both try now, not at their next backoff step.
    harness.reconnects.systemDidWake()
    _ = try await harness.waitForLaunches(of: "session-123", 2)
    #expect(await harness.remote.wait { available.value })
    #expect(!session.isWaitingForHost)
    #expect(harness.control.state == .connected)
}

@Test @MainActor func HostedSessionSSHTabStopsWaitingWhenReconnectingCannotHelp() async throws {
    let harness = try SSHReconnectHarness(sessions: ["kept", "gone", "moved", "detached", "final"])
    defer { harness.cleanUp() }

    // The adapter said connecting again can never resolve its ending (the
    // host no longer has the session): the tab does not wait.
    let final = harness.attach("final")
    let finalLaunch = try await harness.waitForLaunches(of: "final", 1)[0]
    try harness.end(final, launch: finalLaunch, status: #"{"outcome":"failed","exit_code":null,"signal":null,"message":"the host no longer has session final","reconnectable":false}"#)
    #expect(!final.isWaitingForHost)
    #expect(final.hostedAttachmentStatus == .failed("the host no longer has session final"))

    // A detach is never retried either.
    let detached = harness.attach("detached")
    let detachedLaunch = try await harness.waitForLaunches(of: "detached", 1)[0]
    try harness.end(detached, launch: detachedLaunch, status: #"{"outcome":"detached","exit_code":null,"signal":null,"message":null}"#)
    #expect(!detached.isWaitingForHost)

    // The host answers without the session: it is gone, and the tab says so.
    let gone = harness.attach("gone")
    let goneLaunch = try await harness.waitForLaunches(of: "gone", 1)[0]
    harness.remote.sessions.removeAll { $0.id == "gone" }
    try harness.end(gone, launch: goneLaunch, status: lostConnection)
    #expect(await harness.remote.wait { !gone.isWaitingForHost })
    #expect(gone.hostedAttachmentStatus == .failed("devbox no longer has this session."))
    #expect(harness.launches(of: "gone").count == 1)

    // Another identity answers for devbox (it was trusted as host-a).
    let moved = harness.attach("moved")
    let movedLaunch = try await harness.waitForLaunches(of: "moved", 1)[0]
    harness.control.disconnect()
    harness.remote.hostID = "host-b"
    try harness.end(moved, launch: movedLaunch, status: lostConnection)
    #expect(await harness.remote.wait { !moved.isWaitingForHost })
    #expect(harness.launches(of: "moved").count == 1)
    guard case .failed(let reason) = moved.hostedAttachmentStatus else {
        Issue.record("expected a failure, got \(String(describing: moved.hostedAttachmentStatus))")
        return
    }
    #expect(reason.contains("host-b"), "\(reason)")

    // A host of a protocol this app cannot use.
    let kept = harness.attach("kept")
    let keptLaunch = try await harness.waitForLaunches(of: "kept", 1)[0]
    harness.control.disconnect()
    harness.remote.hostID = "host-a"
    harness.remote.version = HostProtocol.version + 1
    try harness.end(kept, launch: keptLaunch, status: lostConnection)
    #expect(await harness.remote.wait { !kept.isWaitingForHost })
    #expect(harness.launches(of: "kept").count == 1)
    guard case .failed(let versionReason) = kept.hostedAttachmentStatus else {
        Issue.record("expected a failure, got \(String(describing: kept.hostedAttachmentStatus))")
        return
    }
    #expect(versionReason.contains("speaks protocol"), "\(versionReason)")
    #expect(harness.reconnects.waitingCounts.isEmpty)
}

@Test @MainActor func HostedSessionClosingOrStoppingAWaitingTabEndsItsWait() async throws {
    let harness = try SSHReconnectHarness(sessions: ["a", "b"], delay: (600, 600))
    defer { harness.cleanUp() }
    let a = harness.attach("a")
    let b = harness.attach("b")
    let aLaunch = try await harness.waitForLaunches(of: "a", 1)[0]
    let bLaunch = try await harness.waitForLaunches(of: "b", 1)[0]
    try harness.end(a, launch: aLaunch, status: lostConnection)
    try harness.end(b, launch: bLaunch, status: lostConnection)
    #expect(harness.reconnects.waitingCounts == [harness.devbox.id: 2])
    b.disconnectHostedSession()
    #expect(!b.isWaitingForHost)
    #expect(harness.reconnects.waitingCounts == [harness.devbox.id: 1])
    // Reconnect from the tab's bar ends the wait too: it launches now.
    a.reconnectHostedSession()
    #expect(!a.isWaitingForHost)
    #expect(harness.reconnects.waitingCounts.isEmpty)
    _ = try await harness.waitForLaunches(of: "a", 2)
    harness.reconnects.retryNow()
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.reconnects.probeCounts.isEmpty)
    #expect(harness.launches(of: "b").count == 1)
}

@Test @MainActor func HostedSessionWorkspaceWithoutReconnectsLeavesDisconnectedTabsAlone() async throws {
    let harness = try SSHReconnectHarness(hostReconnectsInPolicy: false)
    defer { harness.cleanUp() }
    let session = harness.attach("session-123")
    let first = try await harness.waitForLaunches(of: "session-123", 1)[0]
    try harness.end(session, launch: first, status: lostConnection)
    #expect(!session.isWaitingForHost)
    #expect(session.hostReconnects == nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.launches(of: "session-123").count == 1)
}

@Test @MainActor func HostedSessionRefusedSSHLoginsStopProbingUntilAWakeNetworkOrRetry() async throws {
    let harness = try SSHReconnectHarness()
    defer { harness.cleanUp() }
    let session = harness.attach("session-123")
    let first = try await harness.waitForLaunches(of: "session-123", 1)[0]
    // ssh cannot sign in: each probe would be another failed login.
    harness.remote.exitBeforeWelcome = "root@devbox: Permission denied (publickey).\n"
    try harness.end(session, launch: first, status: lostConnection)
    #expect(await harness.remote.wait { harness.reconnects.pausedReasons[harness.devbox.id] != nil })
    #expect(harness.reconnects.pausedReasons[harness.devbox.id]?.contains("Permission denied") == true)
    try await Task.sleep(for: .milliseconds(400))
    // One probe, not one every backoff step.
    #expect(harness.reconnects.probeCounts[harness.devbox.id] == 1)
    #expect(session.isWaitingForHost)
    // A network change tries once more (still refused: paused again).
    harness.reconnects.networkBecameAvailable()
    #expect(await harness.remote.wait { harness.reconnects.probeCounts[harness.devbox.id] == 2 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.reconnects.probeCounts[harness.devbox.id] == 2)
    // The key is fixed; Retry Now reconnects.
    harness.remote.exitBeforeWelcome = nil
    harness.reconnects.retryNow(harness.devbox)
    _ = try await harness.waitForLaunches(of: "session-123", 2)
    #expect(!session.isWaitingForHost)
    #expect(harness.reconnects.pausedReasons.isEmpty)
}
