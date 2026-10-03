import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// A new persistent tab's Create starts its program at the terminal grid of
// the window that shows the tab, once that grid settled
// (`TerminalWindowGridWait`, `TerminalWindowGrid`): a new window's first tab
// is laid out at the window's first frame and a tiling window manager may
// then move the window, so the Create waits until the grid stayed the same
// for a while (bounded), and takes it.

// MARK: - When a Create takes its window's grid

private let standardLike = TerminalWindowGridWait(
    quietPeriod: .milliseconds(300), maximumWait: .seconds(1), maximumSettlingWait: .seconds(3)
)
private let origin = ContinuousClock.now
private func at(_ milliseconds: Int) -> ContinuousClock.Instant { origin + .milliseconds(milliseconds) }
private let settledGrid = TerminalViewportSize(columns: 65, rows: 63)

@Test func persistentLocalWindowGridIsTakenOnceItStayedTheSameForItsQuietPeriod() {
    // A window whose grid settled long ago (a new tab in a window that is
    // open): at once.
    let old = TerminalWindowGridWait.Observation(grid: settledGrid, since: at(-5_000), settling: false)
    #expect(standardLike.decision(for: old, startedAt: at(0), now: at(0)) == .take)
    // A new window's terminal, laid out a moment ago: once its grid stayed
    // the same for the quiet period.
    let fresh = TerminalWindowGridWait.Observation(grid: settledGrid, since: at(100), settling: false)
    #expect(standardLike.decision(for: fresh, startedAt: at(0), now: at(150)) == .wait(until: at(400)))
    #expect(standardLike.decision(for: fresh, startedAt: at(0), now: at(399)) == .wait(until: at(400)))
    #expect(standardLike.decision(for: fresh, startedAt: at(0), now: at(400)) == .take)
}

@Test func persistentLocalWindowGridWaitGivesUpAfterItsMaximumWait() {
    // No terminal of the window was laid out yet.
    #expect(standardLike.decision(for: nil, startedAt: at(0), now: at(10)) == .wait(until: at(1_000)))
    #expect(standardLike.decision(for: nil, startedAt: at(0), now: at(1_000)) == .giveUp)
    // A grid that keeps changing is not waited for longer.
    let changing = TerminalWindowGridWait.Observation(grid: settledGrid, since: at(900), settling: false)
    #expect(standardLike.decision(for: changing, startedAt: at(0), now: at(950)) == .wait(until: at(1_000)))
    #expect(standardLike.decision(for: changing, startedAt: at(0), now: at(1_000)) == .giveUp)
}

@Test func persistentLocalWindowGridWaitsLongerForASettlingWindow() {
    // A window going into full screen (or back into it at launch).
    let settling = TerminalWindowGridWait.Observation(grid: settledGrid, since: at(-5_000), settling: true)
    #expect(standardLike.decision(for: settling, startedAt: at(0), now: at(1_500)) == .wait(until: at(3_000)))
    #expect(standardLike.decision(for: settling, startedAt: at(0), now: at(3_000)) == .giveUp)
    // Settled: its new grid once that stayed for the quiet period, within
    // the settling window's limit.
    let settled = TerminalWindowGridWait.Observation(grid: settledGrid, since: at(1_600), settling: false)
    #expect(standardLike.decision(for: settled, startedAt: at(0), now: at(1_700), sawSettling: true) == .wait(until: at(1_900)))
    #expect(standardLike.decision(for: settled, startedAt: at(0), now: at(1_900), sawSettling: true) == .take)
    // A wait that never saw it settle keeps the usual limit.
    #expect(standardLike.decision(for: settled, startedAt: at(0), now: at(1_700)) == .giveUp)
}

@Test func persistentLocalWindowGridWaitRemembersAWindowItSawSettling() {
    var waiting = TerminalWindowGridWait.Waiting(standardLike, startedAt: at(0))
    let settling = TerminalWindowGridWait.Observation(grid: settledGrid, since: at(-5_000), settling: true)
    #expect(waiting.decide(settling, now: at(100)) == .wait(until: at(3_000)))
    // Settled since: the settling window's limit still holds.
    let settled = TerminalWindowGridWait.Observation(grid: settledGrid, since: at(1_600), settling: false)
    #expect(waiting.decide(settled, now: at(1_700)) == .wait(until: at(1_900)))
    #expect(waiting.observation == settled)
    #expect(waiting.nextLook(waitingUntil: at(1_900), now: at(1_700)) == at(1_715))
    #expect(waiting.nextLook(waitingUntil: at(1_900), now: at(1_890)) == at(1_900))
    #expect(waiting.decide(settled, now: at(1_900)) == .take)
}

@Test func persistentLocalWindowGridPrefersTheTabsOwnTerminalThenItsWindowsThenItsOwnGrid() {
    let own = TerminalViewportSize(columns: 80, rows: 40)
    let window = TerminalViewportSize(columns: 160, rows: 40)
    let tab = TerminalViewportSize(columns: 120, rows: 32)
    #expect(TerminalWindowGridWait.grid(own: own, window: window, tab: tab) == own)
    #expect(TerminalWindowGridWait.grid(own: nil, window: window, tab: tab) == window)
    #expect(TerminalWindowGridWait.grid(own: nil, window: nil, tab: tab) == tab)
}

@Test @MainActor func persistentLocalWindowGridChangesItsTimeOnlyWithItsGridOrItsWindow() {
    let windowGrid = TerminalWindowGrid()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    other.isReleasedWhenClosed = false
    #expect(windowGrid.observation() == nil)
    windowGrid.note(settledGrid, size: CGSize(width: 600, height: 1_000), in: window, now: at(0))
    // Another tab shown at the grid the window has: only the size it was
    // shown at is new.
    windowGrid.note(settledGrid, size: CGSize(width: 603, height: 1_000), in: window, now: at(500))
    #expect(windowGrid.observation(isSettling: { _ in false }) == .init(grid: settledGrid, since: at(0), settling: false))
    #expect(windowGrid.record?.size == CGSize(width: 603, height: 1_000))
    let wider = TerminalViewportSize(columns: 100, rows: 63)
    windowGrid.note(wider, size: CGSize(width: 900, height: 1_000), in: window, now: at(600))
    #expect(windowGrid.observation(isSettling: { _ in false }) == .init(grid: wider, since: at(600), settling: false))
    #expect(windowGrid.record?.size == CGSize(width: 900, height: 1_000))
    windowGrid.note(wider, size: CGSize(width: 900, height: 1_000), in: other, now: at(700))
    var asked: NSWindow?
    #expect(windowGrid.observation(isSettling: { asked = $0; return true }) == .init(grid: wider, since: at(700), settling: true))
    #expect(asked === other)
}

// MARK: - Creates through the app's tabs

/// Windows showing tabs, as a project window's terminal pane does.
@MainActor
private final class TabWindows {
    private var shown: [(window: NSWindow, container: GhosttyTerminalContainerView)] = []

    @discardableResult
    func show(_ session: TerminalSession, size: NSSize) -> NSWindow {
        let container = GhosttyTerminalContainerView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
        window.orderFrontRegardless()
        shown.append((window, container))
        return window
    }

    /// Its window moves to `size` (a tiling window manager re-tiling it).
    func resize(_ window: NSWindow, to size: NSSize) {
        guard let entry = shown.first(where: { $0.window === window }) else {
            Issue.record("The window is not shown")
            return
        }
        window.setContentSize(size)
        entry.container.layoutSubtreeIfNeeded()
    }

    func closeAll() {
        for entry in shown {
            entry.container.detachActiveSession()
            entry.window.close()
        }
        shown.removeAll()
    }
}

/// What a Create asked for: its grid and cell pixels.
private func createdGrid(_ create: FakeControlHelper.Request) -> (grid: TerminalViewportSize?, cell: TerminalCellSize?) {
    let grid = (create.json["cols"] as? Int).flatMap { columns in
        (create.json["rows"] as? Int).map { TerminalViewportSize(columns: columns, rows: $0) }
    }
    let cell = (create.json["cell_width"] as? Int).flatMap { width in
        (create.json["cell_height"] as? Int).flatMap { TerminalCellSize(width: width, height: $0) }
    }
    return (grid, cell)
}

@MainActor
private func gridWorkspace(_ harness: PersistentHarness, wait: TerminalWindowGridWait?) -> TerminalWorkspace {
    var policy = harness.policy
    policy.windowGridWait = wait
    return TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: policy)
}

@Test @MainActor func persistentLocalWindowGridNewWindowsFirstTabIsCreatedAtTheGridItsWindowSettlesAt() async throws {
    let harness = try PersistentHarness()
    // A quiet period far longer than the test's own steps take, so a CI
    // runner that stalls between showing the window and re-tiling it does
    // not make the first grid look settled (CI took the first grid at 250 ms).
    let workspace = gridWorkspace(harness, wait: TerminalWindowGridWait(
        quietPeriod: .milliseconds(1_500), maximumWait: .seconds(8), maximumSettlingWait: .seconds(10)
    ))
    let windows = TabWindows()
    defer {
        windows.closeAll()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // The window's first tab exists at once; its window lays it out a
    // moment later, at the window's first frame.
    let tab = workspace.addSession(title: "First")
    #expect(tab.isPersistentLocalSession)
    try await Task.sleep(for: .milliseconds(150))
    #expect(harness.creates().isEmpty)
    let window = windows.show(tab, size: NSSize(width: 1_000, height: 700))
    #expect(await harness.fake.wait { tab.mountedTerminalGrid != nil })
    let first = try #require(tab.mountedTerminalGrid)
    // A window manager re-tiles the window in two steps.
    try await Task.sleep(for: .milliseconds(120))
    #expect(harness.creates().isEmpty)
    windows.resize(window, to: NSSize(width: 560, height: 800))
    try await Task.sleep(for: .milliseconds(20))
    windows.resize(window, to: NSSize(width: 560, height: 900))
    #expect(await harness.fake.wait { tab.mountedTerminalGrid.map { $0 != first && $0.rows > first.rows } ?? false })
    let settled = try #require(tab.mountedTerminalGrid)
    // The pixels its terminal reports at that grid (its in-memory terminal
    // takes the grid a moment after the view).
    #expect(await harness.fake.wait { tab.terminalCell(forGrid: settled) != nil })
    let cell = try #require(tab.terminalCell(forGrid: settled))

    #expect(await harness.waitUntilAttached(tab))
    let creates = harness.creates()
    #expect(creates.count == 1)
    let created = createdGrid(try #require(creates.first))
    #expect(created.grid == settled)
    #expect(created.cell == cell)
    // Its adapter attaches at that grid too.
    #expect(tab.mountedTerminalGrid == settled)
}

@Test @MainActor func persistentLocalWindowGridNewTabInAnOpenWindowIsCreatedAtOnce() async throws {
    let harness = try PersistentHarness()
    // A quiet period no test waits out.
    let workspace = gridWorkspace(harness, wait: TerminalWindowGridWait(
        quietPeriod: .seconds(30), maximumWait: .seconds(60), maximumSettlingWait: .seconds(60)
    ))
    let windows = TabWindows()
    defer {
        windows.closeAll()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // The window has shown its grid for a while.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let grid = TerminalViewportSize(columns: 97, rows: 29)
    workspace.windowGrid.note(grid, size: CGSize(width: 800, height: 500), in: window, now: .now - .seconds(31))

    let tab = workspace.addSession(title: "New")
    #expect(await harness.waitUntilAttached(tab, timeout: 10))
    #expect(createdGrid(try #require(harness.creates().first)).grid == grid)
}

@Test @MainActor func persistentLocalWindowGridTabClosedWhileItsWindowSettlesCreatesNothing() async throws {
    let harness = try PersistentHarness()
    let workspace = gridWorkspace(harness, wait: TerminalWindowGridWait(
        // A maximum wait a CI stall before the close cannot use up; the
        // check after the close outlasts it, so a Create would show.
        quietPeriod: .milliseconds(200), maximumWait: .seconds(2), maximumSettlingWait: .seconds(3)
    ))
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Gone")
    try await Task.sleep(for: .milliseconds(100))
    workspace.close(tab, allowEmptyWorkspace: true)
    try await Task.sleep(for: .milliseconds(2_500))
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func persistentLocalWindowGridTabNoWindowShowsIsCreatedAtItsOwnGridAfterTheMaximumWait() async throws {
    let harness = try PersistentHarness()
    let workspace = gridWorkspace(harness, wait: TerminalWindowGridWait(
        quietPeriod: .milliseconds(100), maximumWait: .milliseconds(1_500), maximumSettlingWait: .seconds(3)
    ))
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let added = ContinuousClock.now
    let tab = workspace.addSession(title: "Unseen")
    #expect(await harness.fake.wait { !harness.creates().isEmpty })
    #expect(ContinuousClock.now - added >= .milliseconds(1_500))
    #expect(createdGrid(try #require(harness.creates().first)).grid == TerminalViewportSize(columns: 120, rows: 32))
    #expect(await harness.waitUntilAttached(tab))

    // Without a wait (no window shows a test's workspace), at once.
    let unwaited = gridWorkspace(harness, wait: nil)
    defer { unwaited.closeAllSessions(intent: .windowClosed) }
    let quick = ContinuousClock.now
    _ = unwaited.addSession(title: "Quick")
    #expect(await harness.fake.wait { harness.creates().count == 2 })
    // Well short of the waited tab's 1.5 s, with room for a slow runner.
    #expect(ContinuousClock.now - quick < .milliseconds(1_000))
}

@Test @MainActor func persistentLocalWindowGridWaitsForASettlingWindowAndTakesTheGridItSettlesAt() async throws {
    let harness = try PersistentHarness()
    let workspace = gridWorkspace(harness, wait: TerminalWindowGridWait(
        quietPeriod: .milliseconds(150), maximumWait: .milliseconds(400), maximumSettlingWait: .seconds(5)
    ))
    let windows = TabWindows()
    var endHold: (@MainActor () -> Void)?
    defer {
        endHold?()
        windows.closeAll()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Full screen")
    let window = windows.show(tab, size: NSSize(width: 700, height: 500))
    // The window goes (back) into full screen: its views pass through
    // sizes on the way, longer than the usual wait.
    endHold = TerminalWindowSettling.shared.hold(window)
    #expect(await harness.fake.wait { tab.mountedTerminalGrid != nil })
    for height in [600.0, 750, 900] {
        windows.resize(window, to: NSSize(width: 900, height: height))
        try await Task.sleep(for: .milliseconds(250))
    }
    #expect(harness.creates().isEmpty)
    let settled = try #require(tab.mountedTerminalGrid)
    endHold?()
    endHold = nil
    #expect(await harness.waitUntilAttached(tab))
    #expect(createdGrid(try #require(harness.creates().first)).grid == settled)
}

@Test @MainActor func persistentLocalWindowGridDeviceWindowsFirstTabIsCreatedThereAtTheGridItsWindowSettlesAt() async throws {
    // Another Mac's host (an in-process fake `cherry control` for
    // `ssh:studio`): its Create goes over SSH, by the same rule.
    let fake = FakeControlHelper()
    let cli = try HostedSessionFakeCLI()
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    let host = try HostedSessionHost.ssh("studio")
    let executable = cli.executable
    let control = HostControl(
        host: host,
        clientProvider: { HostedSessionClient(executableURL: executable, loginEnvironment: { _ in .init(environment: [:]) }) },
        hostStore: hostStore,
        masters: disabledSSHMasters,
        launcher: fake.launcher,
        localHostUnavailableReason: nil,
        configuration: .fastTests
    )
    let hosting = PersistentHostSessions.remote(
        profile: .remote(host: host, displayName: "Studio"),
        installationID: UUID(),
        remoteShell: "/bin/zsh",
        control: { control },
        installationUnavailableReason: { nil },
        status: PersistentSessionsStatus(),
        instanceLock: nil,
        terminalColors: { nil },
        configuration: .remote
    )
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let workspace = TerminalWorkspace(
        projectRoot: key, createInitialSession: false,
        backendPolicy: .remote(
            hosting, settings: { .defaults }, hostReconnects: nil,
            windowGridWait: TerminalWindowGridWait(
                // Far longer than the test's own steps (see the first-tab test).
                quietPeriod: .milliseconds(1_500), maximumWait: .seconds(8), maximumSettlingWait: .seconds(10)
            )
        )
    )
    let windows = TabWindows()
    defer {
        windows.closeAll()
        workspace.closeAllSessions(intent: .windowClosed)
        control.disconnect()
        cli.cleanUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let tab = workspace.addSession(title: "Studio")
    #expect(tab.persistentHosting === hosting)
    try await Task.sleep(for: .milliseconds(100))
    let window = windows.show(tab, size: NSSize(width: 1_000, height: 700))
    #expect(await fake.wait { tab.mountedTerminalGrid != nil })
    let first = try #require(tab.mountedTerminalGrid)
    try await Task.sleep(for: .milliseconds(120))
    #expect(fake.requests("create").isEmpty)
    windows.resize(window, to: NSSize(width: 600, height: 900))
    #expect(await fake.wait { tab.mountedTerminalGrid.map { $0 != first } ?? false })
    let settled = try #require(tab.mountedTerminalGrid)
    #expect(await fake.wait { !fake.requests("create").isEmpty })
    let creates = fake.requests("create")
    #expect(creates.count == 1)
    #expect(createdGrid(try #require(creates.first)).grid == settled)
}

@Test @MainActor func persistentLocalWindowGridTabThatKeepsItsSessionStopsWaitingAndCreatesIt() async throws {
    let harness = try PersistentHarness()
    let workspace = gridWorkspace(harness, wait: TerminalWindowGridWait(
        quietPeriod: .seconds(30), maximumWait: .seconds(60), maximumSettlingWait: .seconds(60)
    ))
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // The window's grid changed a moment ago.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let grid = TerminalViewportSize(columns: 88, rows: 30)
    workspace.windowGrid.note(grid, size: CGSize(width: 800, height: 500), in: window)
    let tab = workspace.addSession(title: "Detached")
    try await Task.sleep(for: .milliseconds(150))
    #expect(harness.creates().isEmpty)
    // Detached (or closed keeping its session) while it waits: its saved
    // record names the session its Create makes, which is made now, at the
    // window's grid, and left running.
    tab.stop(keepingSession: true)
    #expect(await harness.fake.wait { !harness.creates().isEmpty })
    #expect(createdGrid(try #require(harness.creates().first)).grid == grid)
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.fake.requests("kill").isEmpty)
}

// MARK: - Restored tabs no window shows

private func restoredTerminal(_ title: String, sessionID: String, root: String) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: title,
        launchWorkingDirectory: root, workingDirectory: root, projectRoot: root,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true)
    )
}

private func runningSession(_ id: String, _ record: WorkspaceSessionRecord, pid: UInt32) -> HostedSessionInfo {
    HostedSessionInfo(id: id, name: record.title, cwd: record.workingDirectory, pid: pid, owner: "CherryTests",
                      tags: [PersistentSessionTag.tab: record.id.uuidString])
}

/// The grid the `--size-file` of an attach adapter's call names now.
private func sizeFileGrid(_ call: String) -> TerminalViewportSize? {
    let arguments = call.split(separator: " ").map(String.init)
    guard let index = arguments.firstIndex(of: "--size-file"), index + 1 < arguments.count,
          let data = FileManager.default.contents(atPath: arguments[index + 1]),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let columns = json["cols"] as? Int, let rows = json["rows"] as? Int
    else { return nil }
    return TerminalViewportSize(columns: columns, rows: rows)
}

/// A launch restores a window's tabs; the one it shows attaches at once, and
/// the others, which no window shows, once the launch released them
/// (`RestoredTabLaunchQueue.releaseBackgroundTabs`) and their window's grid
/// settled (`TerminalWindowGridWait`): a tiling window manager re-tiles the
/// new window after the release, and the background tab's surface (its
/// adapter's size file) takes the grid the window settles at, not the one it
/// had first.
@Test @MainActor func persistentLocalWindowGridRestoredTabNoWindowShowsAttachesAtTheGridItsWindowSettlesAt() async throws {
    let harness = try PersistentHarness()
    let workspace = gridWorkspace(harness, wait: TerminalWindowGridWait(
        // Far longer than the test's own steps (see the first-tab test).
        quietPeriod: .milliseconds(1_500), maximumWait: .seconds(8), maximumSettlingWait: .seconds(10)
    ))
    let queue = RestoredTabLaunchQueue()
    queue.interval = 0.01
    workspace.restoredTabLaunchQueue = queue
    let windows = TabWindows()
    defer {
        windows.closeAll()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let root = harness.project.path
    let shownRecord = restoredTerminal("Shown", sessionID: "s-shown", root: root)
    let hiddenRecord = restoredTerminal("Hidden", sessionID: "s-hidden", root: root)
    harness.fake.sessions = [runningSession("s-shown", shownRecord, pid: 1), runningSession("s-hidden", hiddenRecord, pid: 2)]
    queue.holdBackgroundTabs(atMost: 60)
    let result = await harness.restorer(WorkspaceRestoreRequest(
        repositoryRoot: root, worktreeRoot: root, records: [shownRecord, hiddenRecord], workspace: workspace
    ))
    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(
        root: root, sessions: [shownRecord, hiddenRecord], selectedSessionID: shownRecord.id
    ))
    let shown = try #require(workspace.session(withID: shownRecord.id))
    let hidden = try #require(workspace.session(withID: hiddenRecord.id))
    // The window comes up at its first frame, and the launch's windows are
    // up: the background tabs may go.
    let window = windows.show(shown, size: NSSize(width: 1_000, height: 700))
    #expect(await harness.fake.wait { shown.mountedTerminalGrid != nil && workspace.windowGrid.record != nil })
    let first = try #require(shown.mountedTerminalGrid)
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach s-shown ") } })
    queue.releaseBackgroundTabs()
    // A window manager re-tiles the window in two steps.
    try await Task.sleep(for: .milliseconds(150))
    windows.resize(window, to: NSSize(width: 560, height: 800))
    try await Task.sleep(for: .milliseconds(20))
    windows.resize(window, to: NSSize(width: 560, height: 900))
    #expect(await harness.fake.wait { shown.mountedTerminalGrid.map { $0 != first && $0.rows > first.rows } ?? false })
    let settled = try #require(shown.mountedTerminalGrid)
    #expect(!harness.attachCalls.contains { $0.contains("attach s-hidden ") })
    #expect(queue.pendingTabs.map(\.id) == [hiddenRecord.id])

    #expect(await harness.fake.wait(timeout: 10) { harness.attachCalls.contains { $0.contains("attach s-hidden ") } })
    #expect(hidden.mountedTerminalSize == nil)
    let call = try #require(harness.attachCalls.first { $0.contains("attach s-hidden ") })
    #expect(await harness.fake.wait { sizeFileGrid(call) == settled })
    let metrics = try #require(hidden.ghosttyBridge.gridMetrics)
    #expect(TerminalViewportSize(columns: Int(metrics.columns), rows: Int(metrics.rows)) == settled)
}

/// Background tabs whose window shows no terminal (its grid unknown) wait
/// only as long as the wait allows, and the tabs of one window give up
/// together, not one maximum wait after another.
@Test @MainActor func persistentLocalWindowGridRestoredTabsOfAWindowWithNoGridAttachTogetherAfterTheMaximumWait() async throws {
    let harness = try PersistentHarness()
    let workspace = gridWorkspace(harness, wait: TerminalWindowGridWait(
        quietPeriod: .milliseconds(100), maximumWait: .milliseconds(1_200), maximumSettlingWait: .seconds(3)
    ))
    let queue = RestoredTabLaunchQueue()
    queue.interval = 0.01
    workspace.restoredTabLaunchQueue = queue
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let root = harness.project.path
    let records = (1...3).map { restoredTerminal("Tab \($0)", sessionID: "s-tab-\($0)", root: root) }
    harness.fake.sessions = records.enumerated().map { runningSession("s-tab-\($0.offset + 1)", $0.element, pid: UInt32($0.offset + 1)) }
    queue.holdBackgroundTabs(atMost: 60)
    let result = await harness.restorer(WorkspaceRestoreRequest(
        repositoryRoot: root, worktreeRoot: root, records: records, workspace: workspace
    ))
    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(
        root: root, sessions: records, selectedSessionID: records[0].id
    ))
    // The selected tab goes at once (no window lays it out here).
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach s-tab-1 ") } })
    let background = ["attach s-tab-2 ", "attach s-tab-3 "]
    let released = ContinuousClock.now
    queue.releaseBackgroundTabs()
    #expect(await harness.fake.wait(timeout: 10) { harness.attachCalls.contains { $0.contains(background[0]) || $0.contains(background[1]) } })
    #expect(ContinuousClock.now - released >= .milliseconds(1_200))
    #expect(await harness.fake.wait(timeout: 10) { background.allSatisfy { tab in harness.attachCalls.contains { $0.contains(tab) } } })
    // Together: one maximum wait after another would take twice as long.
    #expect(ContinuousClock.now - released < .milliseconds(2_400))
}
