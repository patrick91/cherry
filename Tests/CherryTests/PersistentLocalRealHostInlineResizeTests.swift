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
/// leaves is the one it leaves in a native tab.
@Test(.enabled(if: inlineResizeRealHostEnabled))
@MainActor func PersistentLocalRealHostRestoredInlineTUIAttachesAtItsWindowsSizeAsANativeTabWouldShowIt() async throws {
    let host = try await RealLocalHost()
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
        try await host.waitFor("the shell to be on screen") { restoredShell.mountedTerminalSize != nil }
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
