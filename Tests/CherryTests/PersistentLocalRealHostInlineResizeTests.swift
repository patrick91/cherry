import AppKit
import Foundation
import Testing
@testable import Cherry

// An inline TUI (Ink's log-update, Claude Code's renderer) on the primary
// screen, resized in a persistent tab and in a native one: the persistent
// tab, whose screen the attach adapter streams and repaints from the host,
// ends with the screen and scrollback the native tab has. Gated like the
// other real-host tests (CHERRY_TEST_HOST_INTEGRATION=1, Scripts/build-host
// debug).

private let inlineResizeRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

private let inlineMimic = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/inline-tui-mimic.py")

/// The lines of a terminal's text, trailing blanks dropped, without what
/// differs between the tabs by design: login(1)'s banner (a native tab runs
/// its command through it) and how many redraws the mimic made (a
/// persistent tab's first size is its attach's).
private func inlineLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n").map {
        $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "generation [0-9]+", with: "generation", options: .regularExpression)
    }
    lines.removeAll { $0.hasPrefix("Last login:") }
    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines
}

/// The sizes the mimic logged ("ROWSxCOLS"), in order.
private func mimicSizes(_ log: URL) -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
}

@MainActor
private struct InlineTab {
    let tab: TerminalSession
    let log: URL
    let persistent: Bool
}

@MainActor
private func startInlineTabs(
    _ host: RealLocalHost, _ workspace: TerminalWorkspace, mode: String, history: Int
) async throws -> [InlineTab] {
    var tabs: [InlineTab] = []
    for persistent in [true, false] {
        host.settings.value.persistLocalSessions = persistent
        let log = host.root.appendingPathComponent("mimic-\(mode)-\(persistent ? "persistent" : "native").log")
        let start = host.root.appendingPathComponent("start-\(mode)-\(persistent ? "persistent" : "native")")
        let tab = workspace.addCommandSession(
            command: ProjectCommandDefinition(
                name: "\(mode)-\(persistent ? "persistent" : "native")",
                command: "/usr/bin/python3",
                arguments: "'\(inlineMimic.path)' \(mode) \(history) '\(log.path)' '\(start.path)'"
            ),
            projectRoot: host.home.path
        )
        #expect(tab.isPersistentLocalSession == persistent)
        host.show(tab)
        // It draws once its tab has the window's size: a persistent tab's
        // program starts at the size of its Create.
        try await host.waitFor("the \(mode) tab to take its window's size (persistent \(persistent))") {
            guard tab.state == .live, let metrics = tab.ghosttyBridge.gridMetrics else { return false }
            guard persistent else { return true }
            guard tab.adapterLiveStatus?.followsProgram == true, let id = tab.persistentSession?.sessionID,
                  let info = try await host.hostSession(id) else { return false }
            return info.cols == Int(metrics.columns) && info.rows == Int(metrics.rows)
        }
        FileManager.default.createFile(atPath: start.path, contents: nil)
        try await host.waitFor("the \(mode) mimic to draw (persistent \(persistent))") {
            tab.state == .live
                && (!persistent || tab.adapterLiveStatus?.followsProgram == true)
                && inlineLines(host.screen(tab)).contains { $0.hasPrefix("LIVE footer two") }
        }
        tabs.append(InlineTab(tab: tab, log: log, persistent: persistent))
    }
    return tabs
}

/// Resizes every tab's window to `height` points and waits until each
/// mimic redrew for its surface's new rows.
@MainActor
private func resizeInlineTabs(_ host: RealLocalHost, _ tabs: [InlineTab], height: Double) async throws {
    for entry in tabs {
        host.resize(entry.tab, to: NSSize(width: 800, height: height))
    }
    for entry in tabs {
        try await host.waitFor("the mimic to redraw at \(height) points (persistent \(entry.persistent))") {
            guard let metrics = entry.tab.ghosttyBridge.gridMetrics else { return false }
            return mimicSizes(entry.log).last == "\(metrics.rows)x\(metrics.columns)"
        }
    }
    // The persistent tab's replacement and anything after it.
    try await Task.sleep(for: .milliseconds(500))
}

@Test(.enabled(if: inlineResizeRealHostEnabled))
@MainActor func PersistentLocalRealHostInlineTUIResizesAsInANativeTab() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    do {
        for mode in ["ink", "claude", "claude-cursor"] {
            let tabs = try await startInlineTabs(host, workspace, mode: mode, history: 120)
            for height in [500.0, 260, 640, 300, 900, 500] {
                try await resizeInlineTabs(host, tabs, height: height)
                let persistent = inlineLines(host.screen(tabs[0].tab))
                let native = inlineLines(host.screen(tabs[1].tab))
                #expect(persistent == native, "\(mode) after \(height) points")
            }
        }
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

/// A restored persistent tab whose window shows another tab attaches in
/// the background at the size its window's terminal has (not Ghostty's
/// default for a surface no view shows), so its session is resized once,
/// from the size it had when Cherry quit (a full-screen window) to the
/// window's; shown, it is not resized again. Its screen and scrollback are
/// then the native tab's after the same sizes: the gap a TUI's own redraw
/// leaves is the one it leaves in a native tab. Each adapter starts with its
/// terminal at another size, as Ghostty gives a new surface's child at
/// first (800×600 pixels; resized about 25 ms later, which the adapter
/// usually, not always, starts after): the sessions never see that size.
@Test(.enabled(if: inlineResizeRealHostEnabled))
@MainActor func PersistentLocalRealHostRestoredInlineTUIAttachesAtItsWindowsSizeAsANativeTabWouldShowIt() async throws {
    let host = try await RealLocalHost(adapterTerminalStartsAt: (rows: 16, columns: 45))
    let project = host.home.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStateStore(directory: host.root.appendingPathComponent("Workspaces", isDirectory: true))
    let control = host.control
    let restorer = WorkspaceSessionRestorers.hostedByDefault(localSessions: host.hosting, control: { _ in control })
    let queue = RestoredTabLaunchQueue()
    var repositories: [RepositoryWorkspace] = []
    func makeRepository() -> RepositoryWorkspace {
        let repository = RepositoryWorkspace(
            projectRoot: project.path, backendPolicy: host.policy, stateStore: store,
            sessionRestorer: restorer, autoStartCommands: { _ in [] }, restoredTabLaunchQueue: queue
        )
        repositories.append(repository)
        return repository
    }
    func tearDown() async {
        for repository in repositories { repository.closeAllSessions(intent: .windowClosed) }
        await host.tearDown()
    }
    let window = NSSize(width: 800, height: 500)
    let fullScreen = NSSize(width: 1400, height: 1000)
    do {
        // The last run: the window shows its shell, then a new tab runs the
        // mimic. Created while the shell is on screen, its session starts
        // at the shell's grid (not a default its adapter then resizes), so
        // the mimic draws once, at the window's size. Then the window goes
        // full screen, and Cherry quits keeping the session.
        let first = makeRepository()
        first.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await first.waitForPendingRestores()
        let shell = try #require(first.activeWorkspace.sessions.first)
        host.show(shell)
        try await host.waitFor("the shell to be on screen") { shell.mountedTerminalGrid != nil }
        let grid = try #require(shell.mountedTerminalGrid)
        let windowSize = "\(grid.rows)x\(grid.columns)"
        let log = host.root.appendingPathComponent("restored.log")
        let mimic = first.activeWorkspace.addCommandSession(
            command: ProjectCommandDefinition(
                name: "mimic", command: "/usr/bin/python3",
                arguments: "'\(inlineMimic.path)' claude-cursor 120 '\(log.path)'"
            ),
            projectRoot: project.path
        )
        #expect(mimic.isPersistentLocalSession)
        host.show(mimic)
        try await host.waitFor("the mimic to draw") {
            mimic.adapterLiveStatus?.followsProgram == true
                && inlineLines(host.screen(mimic)).contains { $0.hasPrefix("LIVE footer two") }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(mimicSizes(log) == [windowSize])
        host.resize(mimic, to: fullScreen)
        try await host.waitFor("the mimic to redraw full screen") { mimicSizes(log).count == 2 }
        let fullScreenSize = mimicSizes(log)[1]
        // The shell tab is selected when the window comes back.
        first.activeWorkspace.select(shell)
        first.flushPersistentState()
        first.closeAllSessions(intent: .appQuit)

        // Relaunch: the window shows the shell; the mimic's tab, not shown,
        // waits in the queue until the shell is on screen.
        queue.holdBackgroundTabs(atMost: 60)
        let second = makeRepository()
        second.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await second.waitForPendingRestores()
        let restoredShell = try #require(second.activeWorkspace.session(withID: shell.id))
        let restored = try #require(second.activeWorkspace.session(withID: mimic.id))
        #expect(second.activeWorkspace.selectedSession === restoredShell)
        host.show(restoredShell)
        host.resize(restoredShell, to: window)
        // At the window's grid, not only on screen: until Ghostty reports
        // the view's size, the surface has the grid it was built at.
        try await host.waitFor("the shell to be on screen at the window's grid") {
            restoredShell.mountedTerminalGrid == grid
        }
        #expect(restored.isAwaitingDeferredLaunch)
        queue.releaseBackgroundTabs()
        try await host.waitFor("the mimic's tab to attach in the background") {
            restored.adapterLiveStatus?.followsProgram == true && mimicSizes(log).count >= 3
        }
        #expect(restored.mountedTerminalSize == nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(mimicSizes(log) == [windowSize, fullScreenSize, windowSize])
        // Shown, at the size it attached at: no other resize.
        host.show(restored)
        host.resize(restored, to: window)
        try await host.waitFor("the restored tab's screen") {
            inlineLines(host.screen(restored)).contains { $0.hasPrefix("LIVE footer two") }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(mimicSizes(log) == [windowSize, fullScreenSize, windowSize])

        // A native tab given the same sizes shows the same screen and
        // scrollback.
        host.settings.value.persistLocalSessions = false
        let nativeLog = host.root.appendingPathComponent("native.log")
        let native = second.activeWorkspace.addCommandSession(
            command: ProjectCommandDefinition(
                name: "native", command: "/usr/bin/python3",
                arguments: "'\(inlineMimic.path)' claude-cursor 120 '\(nativeLog.path)'"
            ),
            projectRoot: project.path
        )
        #expect(!native.isPersistentLocalSession)
        host.show(native)
        try await host.waitFor("the native mimic to draw") { mimicSizes(nativeLog).count == 1 }
        host.resize(native, to: fullScreen)
        try await host.waitFor("the native mimic to redraw full screen") { mimicSizes(nativeLog).count == 2 }
        host.resize(native, to: window)
        try await host.waitFor("the native mimic to redraw in the window") { mimicSizes(nativeLog).count == 3 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(mimicSizes(nativeLog) == mimicSizes(log))
        #expect(inlineLines(host.screen(restored)) == inlineLines(host.screen(native)))
    } catch {
        await tearDown()
        throw error
    }
    await tearDown()
}

/// A launch releases the restored tabs no window shows once its windows are
/// up (`RestoredTabLaunchQueue.releaseBackgroundTabs`), and a tiling window
/// manager may re-tile a new window after that (AeroSpace re-tiles one 90 to
/// 290 ms after its terminal is first laid out). Such a tab attaches in the
/// background once its window's grid settled (`TerminalWindowGridWait`), at
/// that grid: its program, an inline TUI, sees the size it had when Cherry
/// quit and then the window's final one, never the window's first grid, and
/// nothing more when the tab is shown.
@Test(.enabled(if: inlineResizeRealHostEnabled))
@MainActor func PersistentLocalRealHostRestoredBackgroundTabAttachesAtTheGridItsWindowSettlesAt() async throws {
    let host = try await RealLocalHost(adapterTerminalStartsAt: (rows: 16, columns: 45))
    let project = host.home.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStateStore(directory: host.root.appendingPathComponent("Workspaces", isDirectory: true))
    let control = host.control
    let restorer = WorkspaceSessionRestorers.hostedByDefault(localSessions: host.hosting, control: { _ in control })
    let queue = RestoredTabLaunchQueue()
    var waiting = host.policy
    // A quiet period far longer than the test's own steps take, so a CI
    // runner that stalls between showing the window and re-tiling it does
    // not make the first grid look settled.
    waiting.windowGridWait = TerminalWindowGridWait(
        quietPeriod: .milliseconds(1_500), maximumWait: .seconds(8), maximumSettlingWait: .seconds(10)
    )
    var repositories: [RepositoryWorkspace] = []
    func makeRepository(_ policy: SessionBackendPolicy) -> RepositoryWorkspace {
        let repository = RepositoryWorkspace(
            projectRoot: project.path, backendPolicy: policy, stateStore: store,
            sessionRestorer: restorer, autoStartCommands: { _ in [] }, restoredTabLaunchQueue: queue
        )
        repositories.append(repository)
        return repository
    }
    func tearDown() async {
        for repository in repositories { repository.closeAllSessions(intent: .windowClosed) }
        await host.tearDown()
    }
    let firstFrame = NSSize(width: 800, height: 500)
    let tiled = NSSize(width: 560, height: 800)
    do {
        // The last run: the mimic runs in its window, which then goes full
        // screen, and Cherry quits keeping its session with the shell
        // selected.
        let first = makeRepository(host.policy)
        first.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await first.waitForPendingRestores()
        let shell = try #require(first.activeWorkspace.sessions.first)
        host.show(shell)
        try await host.waitFor("the shell to be on screen") { shell.mountedTerminalGrid != nil }
        let firstGrid = try #require(shell.mountedTerminalGrid)
        let log = host.root.appendingPathComponent("background.log")
        let mimic = first.activeWorkspace.addCommandSession(
            command: ProjectCommandDefinition(
                name: "mimic", command: "/usr/bin/python3",
                arguments: "'\(inlineMimic.path)' claude-cursor 120 '\(log.path)'"
            ),
            projectRoot: project.path
        )
        #expect(mimic.isPersistentLocalSession)
        host.show(mimic)
        try await host.waitFor("the mimic to draw") {
            mimic.adapterLiveStatus?.followsProgram == true
                && inlineLines(host.screen(mimic)).contains { $0.hasPrefix("LIVE footer two") }
        }
        host.resize(mimic, to: NSSize(width: 1400, height: 1000))
        try await host.waitFor("the mimic to redraw full screen") { mimicSizes(log).count == 2 }
        let lastRun = mimicSizes(log)
        #expect(lastRun.first == "\(firstGrid.rows)x\(firstGrid.columns)")
        first.activeWorkspace.select(shell)
        first.flushPersistentState()
        first.closeAllSessions(intent: .appQuit)

        // Relaunch: the window comes up at its first frame showing the
        // shell; the launch then releases the mimic's tab, and the window
        // manager re-tiles the window in two steps.
        queue.holdBackgroundTabs(atMost: 60)
        let second = makeRepository(waiting)
        second.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await second.waitForPendingRestores()
        let restoredShell = try #require(second.activeWorkspace.session(withID: shell.id))
        let restored = try #require(second.activeWorkspace.session(withID: mimic.id))
        #expect(second.activeWorkspace.selectedSession === restoredShell)
        host.show(restoredShell, size: firstFrame)
        try await host.waitFor("the shell to be on screen at the window's first grid") {
            restoredShell.mountedTerminalGrid == firstGrid
        }
        #expect(restored.isAwaitingDeferredLaunch)
        queue.releaseBackgroundTabs()
        try await Task.sleep(for: .milliseconds(150))
        host.resize(restoredShell, to: NSSize(width: tiled.width, height: 720))
        try await Task.sleep(for: .milliseconds(20))
        host.resize(restoredShell, to: tiled)
        try await host.waitFor("the shell to take the tiled grid") {
            restoredShell.mountedTerminalGrid.map { $0 != firstGrid && $0.columns < firstGrid.columns } ?? false
        }
        let tiledGrid = try #require(restoredShell.mountedTerminalGrid)
        let tiledSize = "\(tiledGrid.rows)x\(tiledGrid.columns)"
        try await host.waitFor("the mimic's tab to attach in the background") {
            restored.adapterLiveStatus?.followsProgram == true && mimicSizes(log).count >= 3
        }
        #expect(restored.mountedTerminalSize == nil)
        // Past the adapter's interim terminal size, and anything after.
        try await Task.sleep(for: .milliseconds(700))
        #expect(mimicSizes(log) == lastRun + [tiledSize])
        // Shown in its window, at the size it attached at: no other resize.
        host.show(restored, size: tiled)
        try await host.waitFor("the restored tab's screen") {
            inlineLines(host.screen(restored)).contains { $0.hasPrefix("LIVE footer two") }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(restored.mountedTerminalGrid == tiledGrid)
        #expect(mimicSizes(log) == lastRun + [tiledSize])
    } catch {
        await tearDown()
        throw error
    }
    await tearDown()
}

/// A window going into or out of full screen lays its views out on the way
/// (`TerminalWindowSettling`, between AppKit's `will` and `did`
/// notifications, which the test posts for its own window: no Space
/// changes). The persistent tab's adapter holds its resizes meanwhile, so
/// the session is resized once each time, to the size the window settled
/// at, and the inline TUI's screen and scrollback end as a native tab's
/// given only those sizes.
@Test(.enabled(if: inlineResizeRealHostEnabled))
@MainActor func PersistentLocalRealHostFullScreenTransitionsResizeTheSessionOnlyToTheSizeTheWindowSettlesAt() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    do {
        let tabs = try await startInlineTabs(host, workspace, mode: "claude-cursor", history: 120)
        let persistent = tabs[0]
        #expect(persistent.persistent)
        let window = try #require(persistent.tab.ghosttyBridge.terminalView.window)
        for (sizes, starts, ends) in [
            (
                [NSSize(width: 900, height: 560), NSSize(width: 1100, height: 760), NSSize(width: 1300, height: 900)],
                NSWindow.willEnterFullScreenNotification,
                NSWindow.didEnterFullScreenNotification
            ),
            (
                [NSSize(width: 1000, height: 700), NSSize(width: 800, height: 500)],
                NSWindow.willExitFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ),
        ] {
            let before = mimicSizes(persistent.log)
            NotificationCenter.default.post(name: starts, object: window)
            #expect(TerminalWindowSettling.shared.isSettling(window))
            for size in sizes {
                host.resize(persistent.tab, to: size)
                // Longer than the adapter's own coalescing of resizes.
                try await Task.sleep(for: .milliseconds(150))
            }
            #expect(mimicSizes(persistent.log) == before, "resized during \(starts.rawValue)")
            let metrics = try #require(persistent.tab.ghosttyBridge.gridMetrics)
            let settled = "\(metrics.rows)x\(metrics.columns)"
            NotificationCenter.default.post(name: ends, object: window)
            #expect(!TerminalWindowSettling.shared.isSettling(window))
            try await host.waitFor("the mimic to redraw at the settled size \(settled)") {
                mimicSizes(persistent.log).last == settled
            }
            try await Task.sleep(for: .milliseconds(500))
            #expect(mimicSizes(persistent.log) == before + [settled])
            // A native tab given the size the window settled at shows the
            // same screen and scrollback.
            host.resize(tabs[1].tab, to: sizes.last!)
            try await host.waitFor("the native mimic to redraw at \(settled)") {
                mimicSizes(tabs[1].log).last == settled
            }
            try await Task.sleep(for: .milliseconds(500))
            #expect(inlineLines(host.screen(persistent.tab)) == inlineLines(host.screen(tabs[1].tab)))
        }
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

/// A new window's first tab exists before its window lays it out, at the
/// window's first frame, and a tiling window manager moves the window soon
/// after (AeroSpace re-tiles a new window 90 to 290 ms after its terminal is
/// first laid out); a window restored into full screen passes through sizes
/// on the way (`TerminalWindowSettling`). The tab's Create waits for its
/// window's grid to settle (`TerminalWindowGridWait`), so its program starts
/// at the size the window settles at and is never resized: not 120x32, not
/// the window's first grid, and no SIGWINCH once it runs. Each adapter
/// starts with its terminal at another size, as Ghostty starts a new
/// surface's child (`adapterTerminalStartsAt`), which the session never
/// sees either.
@Test(.enabled(if: inlineResizeRealHostEnabled))
@MainActor func PersistentLocalRealHostNewWindowsFirstTabsProgramSeesOnlyTheGridItsWindowSettlesAt() async throws {
    let host = try await RealLocalHost(adapterTerminalStartsAt: (rows: 16, columns: 45))
    var policy = host.policy
    policy.windowGridWait = .standard
    var workspaces: [TerminalWorkspace] = []
    var holds: [@MainActor () -> Void] = []
    func tearDown() async {
        holds.forEach { $0() }
        for workspace in workspaces { workspace.closeAllSessions(intent: .windowClosed) }
        await host.tearDown()
    }
    do {
        for fullScreen in [false, true] {
            let label = fullScreen ? "full-screen" : "tiled"
            let workspace = TerminalWorkspace(projectRoot: host.home.path, createInitialSession: false, backendPolicy: policy)
            workspaces.append(workspace)
            let log = host.root.appendingPathComponent("first-tab-\(label).log")
            let tab = workspace.addCommandSession(
                command: ProjectCommandDefinition(
                    name: "first-\(label)", command: "/usr/bin/python3",
                    arguments: "'\(inlineMimic.path)' claude-cursor 40 '\(log.path)'"
                ),
                projectRoot: host.home.path
            )
            #expect(tab.isPersistentLocalSession)
            // Its window lays it out a moment later.
            try await Task.sleep(for: .milliseconds(60))
            host.show(tab)
            if fullScreen {
                let window = try #require(tab.ghosttyBridge.terminalView.window)
                holds.append(TerminalWindowSettling.shared.hold(window))
            }
            try await host.waitFor("the \(label) tab to be laid out") { tab.mountedTerminalGrid != nil }
            if fullScreen {
                for size in [NSSize(width: 900, height: 600), NSSize(width: 1100, height: 750), NSSize(width: 1300, height: 900)] {
                    try await Task.sleep(for: .milliseconds(200))
                    host.resize(tab, to: size)
                }
                try await Task.sleep(for: .milliseconds(100))
                holds.removeLast()()
            } else {
                // The window manager's re-tile, in two steps.
                try await Task.sleep(for: .milliseconds(150))
                host.resize(tab, to: NSSize(width: 560, height: 720))
                try await Task.sleep(for: .milliseconds(20))
                host.resize(tab, to: NSSize(width: 560, height: 800))
            }
            try await host.waitFor("the \(label) mimic to draw") {
                tab.adapterLiveStatus?.followsProgram == true
                    && inlineLines(host.screen(tab)).contains { $0.hasPrefix("LIVE footer two") }
            }
            let metrics = try #require(tab.ghosttyBridge.gridMetrics)
            // Past the adapter's interim terminal size, and anything after.
            try await Task.sleep(for: .milliseconds(700))
            #expect(mimicSizes(log) == ["\(metrics.rows)x\(metrics.columns)"], "\(label)")
            let sessionID = try #require(tab.persistentSession?.sessionID)
            let info = try #require(try await host.hostSession(sessionID))
            #expect(info.cols == Int(metrics.columns), "\(label)")
            #expect(info.rows == Int(metrics.rows), "\(label)")
        }
    } catch {
        await tearDown()
        throw error
    }
    await tearDown()
}
