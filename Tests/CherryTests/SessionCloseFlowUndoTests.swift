import AppKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// ⌘Z after a tab close or detach (docs/specs/multiplexer-default.md,
// "Undoing a close or detach"): the tab comes back where it was, with the
// same session and no new Create, for as long as its toast would stay; a
// closed tab's session ends once that runs out, or at once when its window
// closes or Cherry quits. Against the fake `cherry control`
// (FakeControlHelper); no window comes on screen, and no toast reaches
// VoiceOver or a real timer.

// MARK: - Helpers

/// Records `performClose` instead of closing.
@MainActor
private final class ClosingWindow: NSWindow {
    var closeRequests = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
    }

    override func performClose(_ sender: Any?) {
        closeRequests += 1
    }
}

/// A view that takes the keyboard, as the terminal or the sidebar does.
private final class KeyView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// A clock the test moves, and the checks scheduled on it.
@MainActor
private final class ManualClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000)
    private var scheduled: [(at: Date, work: @MainActor () -> Void)] = []

    var schedule: ProjectWindowToasts.Scheduler {
        { [unowned self] delay, work in scheduled.append((now.addingTimeInterval(delay), work)) }
    }

    /// Moves the clock on by `seconds`, running what falls due, in order.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        while let next = scheduled.enumerated().filter({ $0.element.at <= now }).min(by: { $0.element.at < $1.element.at }) {
            scheduled.remove(at: next.offset)
            next.element.work()
        }
    }
}

/// A window's chrome whose toasts and closed tabs keep time on `clock`
/// (never running out by themselves without one) and announce nothing.
@MainActor
private func windowChrome(clock: ManualClock? = nil, voiceOver: Bool = false) -> ProjectWindowChromeState {
    let schedule: ProjectWindowToasts.Scheduler
    if let clock {
        schedule = clock.schedule
    } else {
        schedule = { _, _ in }
    }
    return ProjectWindowChromeState(toasts: ProjectWindowToasts(
        now: { clock?.now ?? Date() },
        schedule: schedule,
        announce: { _ in },
        voiceOverEnabled: { voiceOver }
    ))
}

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = try #require(url.path.withCString { realpath($0, nil) })
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

@MainActor
private func sidebarName(of session: TerminalSession) -> String {
    SidebarSessionLabel.label(for: session, pathDisplayMode: TerminalSettings.shared.sidebarTerminalPathDisplayMode).title
}

/// Waits (polling the main loop) until `condition` holds; false after
/// `timeout`.
@MainActor
private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A session this app (CherryTests) started for tab `tab` of `project`,
/// before this run (an orphan scan may adopt it).
private func ownSession(_ id: String, tab: UUID = UUID(), project: String, command: String) -> HostedSessionInfo {
    HostedSessionInfo(
        id: id, name: command, cwd: project, pid: 300, owner: "CherryTests",
        tags: [
            PersistentSessionTag.tab: tab.uuidString,
            PersistentSessionTag.kind: "command",
            PersistentSessionTag.command: command,
            PersistentSessionTag.project: project,
        ],
        createdAt: 1_700_000_000_000
    )
}

/// A closed tab for the history's timing and names alone: nothing comes
/// back or ends with it.
private func syntheticTab(_ name: String) -> ClosedTab {
    ClosedTab(
        record: WorkspaceSessionRecord(id: UUID(), kind: .terminal, title: name, workingDirectory: "/"),
        name: name,
        binding: HostedSessionAttachment(
            host: .local, hostID: "host", sessionID: "session-\(name)", name: name,
            remoteWorkingDirectory: "/", executablePath: "/usr/bin/false"
        ),
        ownsSession: false,
        placement: ClosedTabPlacement(sessionIndex: 0, display: nil, wasSelected: false, subAgentIDs: [])
    )
}

// MARK: - Undoing a close

@Test @MainActor func commandWLeavesAPersistentTabsSessionRunningAndCommandZBringsTheTabBackWhereItWas() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let storeDirectory = try temporaryDirectory("cherry-undo-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let registry = ProjectWindowRegistry()
    registry.setWorkspaceStateStoreForTesting(store)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let first = workspace.addSession(title: "First")
    let middle = workspace.addSession(title: "Middle")
    let last = workspace.addSession(title: "Last")
    for tab in [first, middle, last] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let middleSession = try #require(middle.persistentSession?.sessionID)
    let middleName = sidebarName(of: middle)
    let order = workspace.sessions.map(\.id)
    let display = workspace.terminalDisplayItems
    let creates = harness.creates().count
    let clock = ManualClock()
    let chromeState = windowChrome(clock: clock)
    let window = ClosingWindow()
    workspace.select(middle)

    // ⌘W: the tab goes, its adapter stops, and its toast offers Undo.
    SessionCloseCoordinator.closeSelectedTabOrWindow(
        workspace: workspace, repository: nil, chromeState: chromeState, window: window, registry: registry
    )
    #expect(window.closeRequests == 0)
    #expect(workspace.session(withID: middle.id) == nil)
    #expect(!middle.isRunning)
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "Closed \(middleName)")
    #expect(toast.action?.title == "Undo")
    #expect(toast.action?.shortcut == "⌘Z")
    #expect(chromeState.closedTabs.undoManager.canUndo)
    #expect(chromeState.closedTabs.undoManager.undoMenuItemTitle == "Undo Close Tab")
    // Its session runs on meanwhile, as good as ended for everything else,
    // and recorded as one to end should Cherry exit first.
    #expect(harness.hosting.isEnding(middleSession))
    #expect(harness.hosting.hasDeferredEnds)
    #expect(store.loadSessionsToEnd().map(\.id) == [middle.id])
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.sessions.contains { $0.id == middleSession && $0.isRunning })

    // ⌘Z: the same tab where it was, attached to the same session again.
    #expect(chromeState.closedTabs.undoLatest())
    #expect(chromeState.toasts.current == nil)
    #expect(workspace.sessions.map(\.id) == order)
    #expect(workspace.terminalDisplayItems == display)
    #expect(workspace.selectedSessionID == middle.id)
    let reopened = try #require(workspace.session(withID: middle.id))
    #expect(reopened !== middle)
    #expect(reopened.kind == .terminal)
    #expect(reopened.title == "Middle")
    #expect(reopened.isPersistentLocalSession)
    #expect(reopened.persistentSession?.sessionID == middleSession)
    #expect(harness.hosting.owningTab(of: middleSession) === reopened)
    #expect(!harness.hosting.isEnding(middleSession))
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(store.loadSessionsToEnd().isEmpty)
    #expect(!chromeState.closedTabs.undoManager.canUndo)
    #expect(await harness.waitUntilAttached(reopened))
    #expect(harness.creates().count == creates)
    // Its undo window running out later ends nothing.
    clock.advance(by: 60)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.requests("remove").isEmpty)
}

@Test @MainActor func aClosedTabsSessionEndsWhenItsUndoRunsOutWhichWaitsWhileItsToastIsHoveredOrItsWindowIsNotKey() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let storeDirectory = try temporaryDirectory("cherry-undo-expiry-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let registry = ProjectWindowRegistry()
    registry.setWorkspaceStateStoreForTesting(store)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let anchor = workspace.addSession(title: "Anchor")
    let hovered = workspace.addSession(title: "Hovered")
    let unseen = workspace.addSession(title: "Unseen")
    let forgotten = workspace.addSession(title: "Forgotten")
    for tab in [anchor, hovered, unseen, forgotten] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let hoveredSession = try #require(hovered.persistentSession?.sessionID)
    let unseenSession = try #require(unseen.persistentSession?.sessionID)
    let forgottenSession = try #require(forgotten.persistentSession?.sessionID)
    let clock = ManualClock()
    let chromeState = windowChrome(clock: clock)

    SessionCloseCoordinator.close(hovered, in: workspace, chromeState: chromeState, registry: registry)
    let hoveredToast = try #require(chromeState.toasts.current)
    clock.advance(by: 5)
    #expect(harness.hosting.hasDeferredEnds)
    // The pointer rests on its toast: its time stops, the entry's too.
    chromeState.toasts.setHovering(true, id: hoveredToast.id)
    clock.advance(by: 30)
    #expect(harness.hosting.hasDeferredEnds)
    #expect(chromeState.toasts.current?.id == hoveredToast.id)
    // It leaves with a second to go: a grace to finish reading.
    chromeState.toasts.setHovering(false, id: hoveredToast.id)
    clock.advance(by: ToastLifetime.graceAfterHover - 0.1)
    #expect(harness.hosting.hasDeferredEnds)
    clock.advance(by: 0.1)
    // Run out: the toast goes, and the session ends as a close ends it.
    #expect(chromeState.toasts.current == nil)
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(!chromeState.closedTabs.undoLatest())
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(hoveredSession) })
    #expect(harness.requestIDs("kill") == [hoveredSession])
    // Ended: no longer one to end at the next launch.
    #expect(await eventually { store.loadSessionsToEnd().isEmpty })

    // While its window is not key in the active app, nobody sees its toast:
    // the time of both stops.
    SessionCloseCoordinator.close(unseen, in: workspace, chromeState: chromeState, registry: registry)
    let unseenToast = try #require(chromeState.toasts.current)
    chromeState.closedTabs.setAttended(false)
    chromeState.toasts.setAttended(false, id: unseenToast.id)
    clock.advance(by: 50)
    #expect(harness.hosting.hasDeferredEnds)
    #expect(chromeState.toasts.current?.id == unseenToast.id)
    chromeState.closedTabs.setAttended(true)
    chromeState.toasts.setAttended(true, id: unseenToast.id)
    clock.advance(by: ProjectWindowToasts.lifetime - 0.1)
    #expect(harness.hosting.hasDeferredEnds)
    clock.advance(by: 0.1)
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(chromeState.toasts.current == nil)
    #expect(await harness.fake.wait { harness.requestIDs("kill") == [hoveredSession, unseenSession] })

    // For a few seconds at most: its program runs on meanwhile, and nothing else
    // shows it. A detach's time, whose session nothing ends, stays stopped.
    SessionCloseCoordinator.close(forgotten, in: workspace, chromeState: chromeState, registry: registry)
    chromeState.closedTabs.setAttended(false)
    chromeState.closedTabs.record([syntheticTab("Detached")], action: .detach, workspace: workspace, repository: nil)
    #expect(chromeState.closedTabs.entries.count == 2)
    clock.advance(by: ClosedTabHistory.longestUnattendedWait - 0.1)
    #expect(harness.hosting.hasDeferredEnds)
    clock.advance(by: 0.1)
    clock.advance(by: ProjectWindowToasts.lifetime - 0.1)
    #expect(harness.hosting.hasDeferredEnds)
    clock.advance(by: 0.1)
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(chromeState.closedTabs.entries.map(\.action) == [.detach])
    #expect(await harness.fake.wait {
        harness.requestIDs("kill") == [hoveredSession, unseenSession, forgottenSession]
    })
    clock.advance(by: 600)
    #expect(chromeState.closedTabs.entries.map(\.action) == [.detach])
}

@Test @MainActor func severalClosesComeBackLatestFirstEachOnItsOwnTimeAndThoseRunOutDropOut() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let a = workspace.addSession(title: "A")
    let b = workspace.addSession(title: "B")
    let c = workspace.addSession(title: "C")
    for tab in [anchor, a, b, c] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let sessions = try [a, b, c].map { try #require($0.persistentSession?.sessionID) }
    let clock = ManualClock()
    let chromeState = windowChrome(clock: clock)
    let registry = ProjectWindowRegistry()

    // Closed two seconds apart: each newer toast replaces the one shown.
    SessionCloseCoordinator.close(a, in: workspace, chromeState: chromeState, registry: registry)
    clock.advance(by: 2)
    SessionCloseCoordinator.close(b, in: workspace, chromeState: chromeState, registry: registry)
    clock.advance(by: 2)
    SessionCloseCoordinator.close(c, in: workspace, chromeState: chromeState, registry: registry)
    #expect(chromeState.toasts.current?.title == "Closed \(sidebarName(of: c))")
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    // A's time was not reset when its toast was replaced: it runs out first.
    clock.advance(by: 2)
    #expect(chromeState.closedTabs.entries.count == 2)
    #expect(await harness.fake.wait { harness.requestIDs("kill") == [sessions[0]] })

    // ⌘Z: C, then B, each back where it was; then nothing is left.
    #expect(chromeState.closedTabs.undoLatest())
    #expect(workspace.sessions.map(\.id) == [anchor.id, c.id])
    #expect(workspace.selectedSessionID == c.id)
    #expect(chromeState.closedTabs.undoLatest())
    #expect(workspace.sessions.map(\.id) == [anchor.id, b.id, c.id])
    #expect(workspace.selectedSessionID == b.id)
    #expect(!chromeState.closedTabs.undoLatest())
    #expect(workspace.session(withID: b.id)?.persistentSession?.sessionID == sessions[1])
    #expect(workspace.session(withID: c.id)?.persistentSession?.sessionID == sessions[2])
    clock.advance(by: 60)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.requestIDs("kill") == [sessions[0]])
}

@Test @MainActor func anEntryLastsAsLongAsItsToastWouldLongerWithVoiceOverAndNamesItsUndo() {
    let workspace = TerminalWorkspace(createInitialSession: false)
    for voiceOver in [false, true] {
        let clock = ManualClock()
        let chromeState = windowChrome(clock: clock, voiceOver: voiceOver)
        let history = chromeState.closedTabs
        let lifetime = ProjectWindowToasts.lifetime(voiceOverEnabled: voiceOver)
        #expect(lifetime == (voiceOver ? ProjectWindowToasts.voiceOverLifetime : ProjectWindowToasts.lifetime))

        // Nothing closed: Undo is off.
        #expect(!history.undoManager.canUndo)
        #expect(!history.undoManager.canRedo)
        #expect(history.undoManager.undoMenuItemTitle == "Undo")

        history.record([syntheticTab("One")], action: .close, workspace: workspace, repository: nil)
        #expect(history.undoManager.undoMenuItemTitle == "Undo Close Tab")
        history.record([syntheticTab("Two"), syntheticTab("Three")], action: .close, workspace: workspace, repository: nil)
        #expect(history.undoManager.undoMenuItemTitle == "Undo Close Tabs")
        history.record([syntheticTab("Four")], action: .detach, workspace: workspace, repository: nil)
        #expect(history.undoManager.undoMenuItemTitle == "Undo Detach Tab")
        #expect(history.undoManager.canUndo)
        #expect(!history.undoManager.canRedo)

        clock.advance(by: lifetime - 0.5)
        #expect(history.entries.count == 3)
        clock.advance(by: 0.5)
        #expect(history.entries.isEmpty)
        #expect(!history.undoManager.canUndo)
    }
}

@Test @MainActor func commandZAttachesAgainToASessionTheClosedTabDidNotOwn() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))
    // A session the CLI made: the tab only attaches to it.
    let cli = HostedSessionInfo(id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72)
    harness.fake.sessions.append(cli)
    _ = try await harness.control.list()
    let attachCalls = { harness.attachCalls.filter { $0.contains("attach session-cli ") }.count }
    let tab = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: cli)))
    #expect(!tab.isPersistentLocalSession)
    #expect(await harness.fake.wait { attachCalls() == 1 })
    let order = workspace.sessions.map(\.id)
    let chromeState = windowChrome()

    // Closing it only disconnects: nothing waits to end.
    SessionCloseCoordinator.close(tab, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry())
    #expect(workspace.session(withID: tab.id) == nil)
    #expect(chromeState.toasts.current?.title == "Closed CLI")
    #expect(!harness.hosting.hasDeferredEnds)

    #expect(chromeState.closedTabs.undoLatest())
    #expect(workspace.sessions.map(\.id) == order)
    let reattached = try #require(workspace.session(withID: tab.id))
    #expect(!reattached.isPersistentLocalSession)
    #expect(reattached.hostedAttachment?.sessionID == "session-cli")
    #expect(reattached.title == "CLI")
    #expect(await harness.fake.wait { attachCalls() == 2 })
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.requests("remove").isEmpty)
}

@Test @MainActor func commandZBringsAClosedTabBackAsItsSessionsOwnEvenWhenAnotherTabAttachedToIt() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let closed = workspace.addSession(title: "Closed")
    for tab in [anchor, closed] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let sessionID = try #require(closed.persistentSession?.sessionID)
    let attachment = try #require(closed.persistentSession)
    let chromeState = windowChrome()
    SessionCloseCoordinator.close(closed, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry())
    #expect(harness.hosting.isEnding(sessionID))

    // Attached meanwhile (as File › Persistent Sessions did): not its owner.
    let attached = workspace.attachHostedSession(attachment)
    #expect(!attached.isPersistentLocalSession)
    #expect(attached.hostedAttachment?.sessionID == sessionID)

    // ⌘Z: the closed tab comes back as its session's own, which no longer
    // ends; the attached tab stays attached.
    #expect(chromeState.closedTabs.undoLatest())
    let back = try #require(workspace.session(withID: closed.id))
    #expect(back !== attached)
    #expect(back.persistentSession?.sessionID == sessionID)
    #expect(harness.hosting.owningTab(of: sessionID) === back)
    #expect(!harness.hosting.isEnding(sessionID))
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(workspace.session(withID: attached.id) != nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func commandZDoesNotBringBackACommandTabWhoseCommandWasStartedAgain() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))
    let server = ProjectCommandDefinition(name: "server", command: "npm", arguments: "run dev")
    let chromeState = windowChrome()
    let registry = ProjectWindowRegistry()

    // Closed, then started again (the sidebar's Start, MCP start_process):
    // the command runs in a new tab. ⌘Z would make two tabs run it (a
    // server's port clashes): the closed tab stays closed, and its
    // session ends.
    let closed = workspace.addCommandSession(command: server, projectRoot: harness.project.path)
    #expect(await harness.waitUntilAttached(closed))
    let closedSession = try #require(closed.persistentSession?.sessionID)
    SessionCloseCoordinator.closeTab(closed, in: workspace, chromeState: chromeState, registry: registry)
    #expect(harness.hosting.isEnding(closedSession))
    let started = workspace.addCommandSession(command: server, projectRoot: harness.project.path)
    #expect(started.id != closed.id)
    #expect(await harness.waitUntilAttached(started))
    #expect(!chromeState.closedTabs.undoLatest())
    #expect(workspace.sessions.filter { $0.commandName == "server" }.map(\.id) == [started.id])
    #expect(workspace.commandSession(named: "server") === started)
    #expect(await harness.fake.wait { harness.requestIDs("kill") == [closedSession] })

    // Detached, then started again: its session stays in the background.
    let detached = started
    let detachedSession = try #require(detached.persistentSession?.sessionID)
    SessionCloseCoordinator.detach(detached, in: workspace, chromeState: chromeState, registry: registry)
    let again = workspace.addCommandSession(command: server, projectRoot: harness.project.path)
    #expect(await harness.waitUntilAttached(again))
    #expect(!chromeState.closedTabs.undoLatest())
    #expect(workspace.sessions.filter { $0.commandName == "server" }.map(\.id) == [again.id])
    try await Task.sleep(for: .milliseconds(200))
    #expect(!harness.requestIDs("kill").contains(detachedSession))
    #expect(harness.fake.sessions.contains { $0.id == detachedSession && $0.isRunning })
}

// MARK: - Undoing a detach

@Test @MainActor func commandZBringsADetachedPaneBackIntoItsSplitWithItsSession() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let left = workspace.addSession(title: "Left")
    #expect(await harness.waitUntilAttached(anchor))
    #expect(await harness.waitUntilAttached(left))
    let right = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(await harness.waitUntilAttached(right))
    let third = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(await harness.waitUntilAttached(third))
    let group = try #require(workspace.splitGroup(containing: left.id))
    workspace.setSplitGroupWidthWeights(id: group.id, weights: [0.5, 0.3, 0.2])
    let weights = try #require(workspace.splitGroup(id: group.id)).widthWeights
    let rightSession = try #require(right.persistentSession?.sessionID)
    let order = workspace.sessions.map(\.id)
    let display = workspace.terminalDisplayItems
    let creates = harness.creates().count
    let chromeState = windowChrome()
    let registry = ProjectWindowRegistry()
    workspace.select(right)

    // ⌘D on the middle pane: its toast offers Reopen, which ⌘Z also does.
    SessionCloseCoordinator.detachSelectedTabOrWindow(
        workspace: workspace, repository: nil, chromeState: chromeState, window: ClosingWindow(), registry: registry
    )
    #expect(workspace.splitGroup(id: group.id)?.paneSessionIDs == [left.id, third.id])
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "\(sidebarName(of: right)) is running in the background")
    #expect(toast.action?.title == "Reopen")
    #expect(toast.action?.shortcut == "⌘Z")
    #expect(chromeState.closedTabs.undoManager.undoMenuItemTitle == "Undo Detach Tab")
    // A detach waits for nothing to end.
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(!harness.hosting.isEnding(rightSession))

    #expect(chromeState.closedTabs.undoLatest())
    #expect(workspace.sessions.map(\.id) == order)
    #expect(workspace.terminalDisplayItems == display)
    let restored = try #require(workspace.splitGroup(id: group.id))
    #expect(restored.paneSessionIDs == [left.id, right.id, third.id])
    #expect(restored.widthWeights == weights)
    #expect(restored.activeSessionID == right.id)
    #expect(workspace.selectedSessionID == right.id)
    let reopened = try #require(workspace.session(withID: right.id))
    #expect(reopened.persistentSession?.sessionID == rightSession)
    #expect(await harness.waitUntilAttached(reopened))

    // A split of two collapses when one pane closes; undone, the split is
    // made again, with its id and weights.
    workspace.select(third)
    let thirdSession = try #require(third.persistentSession?.sessionID)
    SessionCloseCoordinator.detach(third, in: workspace, chromeState: chromeState, registry: registry)
    workspace.select(reopened)
    SessionCloseCoordinator.close(reopened, in: workspace, chromeState: chromeState, registry: registry)
    #expect(workspace.splitGroup(id: group.id) == nil)
    #expect(workspace.terminalDisplayItems == [.single(anchor.id), .single(left.id)])
    #expect(chromeState.closedTabs.undoLatest())
    #expect(workspace.splitGroup(id: group.id)?.paneSessionIDs == [left.id, right.id])
    #expect(chromeState.closedTabs.undoLatest())
    #expect(workspace.splitGroup(id: group.id)?.paneSessionIDs == [left.id, right.id, third.id])
    #expect(workspace.splitGroup(id: group.id)?.widthWeights == weights)
    #expect(workspace.session(withID: third.id)?.persistentSession?.sessionID == thirdSession)
    #expect(harness.creates().count == creates)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func aSplitGroupClosedTogetherComesBackWholeWithOneUndo() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let before = workspace.addSession(title: "Before")
    let left = workspace.addSession(title: "Left")
    #expect(await harness.waitUntilAttached(before))
    #expect(await harness.waitUntilAttached(left))
    let right = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(await harness.waitUntilAttached(right))
    let after = workspace.addSession(title: "After")
    #expect(await harness.waitUntilAttached(after))
    let group = try #require(workspace.splitGroup(containing: left.id))
    let display = workspace.terminalDisplayItems
    let panes = [left, right]
    let chromeState = windowChrome()

    // Close Split Group… answered Close: one entry, one toast, one ⌘Z.
    SessionCloseCoordinator.closeTabs(panes, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry()) {
        workspace.closeSplitGroup(id: group.id)
    }
    #expect(workspace.sessions.map(\.id) == [before.id, after.id])
    #expect(chromeState.toasts.current?.title == "Closed 2 tabs")
    #expect(chromeState.closedTabs.undoManager.undoMenuItemTitle == "Undo Close Tabs")
    #expect(chromeState.closedTabs.undoLatest())
    #expect(workspace.terminalDisplayItems == display)
    #expect(workspace.splitGroup(id: group.id)?.paneSessionIDs == [left.id, right.id])
    #expect(!harness.hosting.hasDeferredEnds)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func undoingAParentAgentsDetachPutsItsSubAgentsBackUnderIt() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let claude = AgentToolDefinition(name: "Claude", command: "claude")
    let anchor = workspace.addSession(title: "Anchor")
    let parent = workspace.addAgentSession(agent: claude, projectRoot: harness.project.path)
    let children = [
        workspace.addAgentSession(agent: claude, projectRoot: harness.project.path, parentAgentID: parent.id),
        workspace.addAgentSession(agent: claude, projectRoot: harness.project.path, parentAgentID: parent.id),
    ]
    for tab in [anchor, parent] + children {
        #expect(await harness.waitUntilAttached(tab))
    }
    let order = workspace.sessions.map(\.id)
    let chromeState = windowChrome()

    // Detached alone, its sub-agents stay, as top-level agents.
    SessionCloseCoordinator.detach(parent, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry())
    #expect(workspace.session(withID: parent.id) == nil)
    #expect(children.allSatisfy { $0.parentAgentID == nil })

    #expect(chromeState.closedTabs.undoLatest())
    #expect(workspace.sessions.map(\.id) == order)
    let reopened = try #require(workspace.session(withID: parent.id))
    #expect(reopened.kind == .agent)
    #expect(reopened.agentName == "Claude")
    #expect(children.allSatisfy { $0.parentAgentID == parent.id })
    #expect(workspace.childAgentSessions(of: reopened).map(\.id) == children.map(\.id))
}

// MARK: - What cannot be undone

@Test @MainActor func nativeClosesAndMCPClosesEndAtOnceAndCannotBeUndone() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let viaMCP = workspace.addSession(title: "MCP")
    #expect(await harness.waitUntilAttached(anchor))
    #expect(await harness.waitUntilAttached(viaMCP))
    let mcpSession = try #require(viaMCP.persistentSession?.sessionID)
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "cat", command: "/bin/cat"), projectRoot: harness.project.path
    )
    harness.settings.value.persistLocalSessions = true
    #expect(native.isRunning)
    let chromeState = windowChrome()

    // A native tab's program stops with its tab: nothing to bring back.
    SessionCloseCoordinator.closeTab(native, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry())
    #expect(workspace.session(withID: native.id) == nil)
    #expect(!native.isRunning)
    #expect(chromeState.closedTabs.entries.isEmpty)
    #expect(chromeState.toasts.current == nil)
    #expect(!chromeState.closedTabs.undoLatest())

    // MCP `close_process` never asks, and ends the session at once.
    workspace.close(viaMCP, intent: .mcpClose)
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(chromeState.closedTabs.entries.isEmpty)
    #expect(await harness.fake.wait { harness.requestIDs("kill") == [mcpSession] })
}

@Test @MainActor func aWindowsLastTabClosedWithCommandWEndsAtOnceWithItsWindow() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let only = workspace.addSession(title: "Only")
    #expect(await harness.waitUntilAttached(only))
    let session = try #require(only.persistentSession?.sessionID)
    let chromeState = windowChrome()
    let window = ClosingWindow()

    SessionCloseCoordinator.closeSelectedTabOrWindow(
        workspace: workspace, repository: nil, chromeState: chromeState, window: window, registry: ProjectWindowRegistry()
    )
    #expect(window.closeRequests == 1)
    #expect(workspace.sessions.isEmpty)
    #expect(chromeState.closedTabs.entries.isEmpty)
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(await harness.fake.wait { harness.requestIDs("kill") == [session] })
}

// MARK: - Nothing else takes a closed tab's session meanwhile

@Test @MainActor func aClosedTabsSessionIsHiddenFromBackgroundSessionsTheLaunchNoticeAndOrphanAdoption() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = harness.project.path
    let storeDirectory = try temporaryDirectory("cherry-undo-hidden-store")
    let otherStoreDirectory = try temporaryDirectory("cherry-undo-hidden-other-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let registry = ProjectWindowRegistry()
    registry.setWorkspaceStateStoreForTesting(store)
    let suite = "CherryTests.UndoNotice.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let closedTabID = UUID()
    let closedInfo = ownSession("s-closed", tab: closedTabID, project: root, command: "worker")
    let orphanInfo = ownSession("s-orphan", project: root, command: "watcher")
    harness.fake.sessions.append(contentsOf: [closedInfo, orphanInfo])
    _ = try await harness.control.list()
    let workspace = harness.workspace()
    let window = ClosingWindow()
    let chromeState = windowChrome()
    #expect(registry.register(
        window: window, projectRoot: root, workspace: workspace, noteStore: nil, todoStore: nil, chromeState: chromeState
    ))
    let model = BackgroundSessionsModel(localSessions: harness.hosting, registry: registry)
    var opened: RepositoryWorkspace?
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: root)
        workspace.closeAllSessions(intent: .windowClosed)
        opened?.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: storeDirectory)
        try? FileManager.default.removeItem(at: otherStoreDirectory)
    }
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))
    // The worker's session becomes the tab it was started for, a command.
    let worker = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: closedInfo)), info: closedInfo)
    #expect(worker.id == closedTabID)
    #expect(worker.isPersistentLocalSession)
    #expect(worker.kind == .command)
    #expect(await harness.waitUntilAttached(worker))

    // Closing a running command asks first; the answer is Close.
    SessionCloseCoordinator.close(worker, in: workspace, chromeState: chromeState, registry: registry)
    if let request = chromeState.pendingTabClose {
        SessionCloseCoordinator.answerTabClose(.close, to: request, chromeState: chromeState)
    }
    #expect(workspace.session(withID: closedTabID) == nil)
    #expect(harness.hosting.isEnding("s-closed"))

    // Background Sessions lists the orphan only, and so the launch notice
    // names only it.
    model.refresh()
    #expect(model.sessions.map(\.id) == ["s-orphan"])
    let notice = BackgroundSessionsNotice(
        model: model, registry: registry, isEnabled: { true }, defaults: defaults, canPresent: { _ in true },
        settleDelay: .zero, restoreWait: .seconds(10), retryDelay: 0.05, retries: 2
    )
    notice.launchWindowsOpened()
    #expect(await eventually {
        if case .shown = notice.phase { return true }
        return false
    })
    if case .shown(let content) = notice.phase {
        #expect(content.sessionIDs == ["s-orphan"])
    }

    // Persistent Sessions → Attach would not make it a tab's own, and the
    // sheet does not attach it at all: it says it is ending.
    #expect(!harness.hosting.canAdopt(try #require(harness.hosting.sessionInfo("s-closed"))))
    let hostID = try #require(harness.control.hostID)
    #expect(model.isEnding(closedInfo, hostID: hostID))
    #expect(model.ownershipLabel(for: closedInfo, hostID: hostID) == "Ending")
    #expect(!model.isEnding(orphanInfo, hostID: hostID))

    // A window of the project that opens now adopts the orphan, not it.
    let repository = RepositoryWorkspace(
        projectRoot: root,
        backendPolicy: harness.policy,
        stateStore: WorkspaceStateStore(directory: otherStoreDirectory),
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    opened = repository
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await eventually { harness.hosting.owningTab(of: "s-orphan") != nil })
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.hosting.owningTab(of: "s-closed") == nil)
    #expect(!repository.activeWorkspace.sessions.contains { $0.id == closedTabID })

    // Nor would the next launch: the closed tab is recorded as one whose
    // session is to end.
    let criteria = OrphanedSessionCriteria(
        owner: "CherryTests", savedState: nil, sessionsToEnd: store.loadSessionsToEnd(), createdBefore: Date()
    )
    #expect(criteria.orphanTabID(of: closedInfo) == nil)
    #expect(criteria.orphanTabID(of: orphanInfo) != nil)
    #expect(harness.fake.requests("kill").isEmpty)
}

// MARK: - A window close or quit ends them

/// A confirmed quit's teardown steps that only wait for the endings.
@MainActor
private func quitSteps(_ harness: PersistentHarness, events: Recorder<[String]>) -> QuitTeardownSteps {
    QuitTeardownSteps(
        takeWindowsOffScreen: { events.value.append("off screen") },
        waitForLaunches: { _ in },
        waitForEnds: { timeout in
            events.value.append("ends")
            _ = await harness.hosting.waitForPendingEnds(timeout: timeout)
        },
        sleep: { _ in events.value.append("sleep") }
    )
}

@Test @MainActor func aQuitKeepingSessionsStillEndsTheSessionsOfTabsClosedJustBefore() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let registry = ProjectWindowRegistry()
    let window = ClosingWindow()
    let chromeState = windowChrome()
    defer {
        registry.cancelTermination()
        registry.unregister(window: window, projectRoot: harness.project.path)
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    #expect(registry.register(
        window: window, projectRoot: harness.project.path, workspace: workspace,
        noteStore: nil, todoStore: nil, chromeState: chromeState
    ))
    let kept = workspace.addSession(title: "Kept")
    let closed = workspace.addSession(title: "Closed")
    for tab in [kept, closed] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let closedSession = try #require(closed.persistentSession?.sessionID)
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .terminateNow)

    SessionCloseCoordinator.close(closed, in: workspace, chromeState: chromeState, registry: registry)
    #expect(harness.hosting.hasDeferredEnds)
    // Keep Running would quit at once; the closed tab's session must end
    // first, so the quit takes its time.
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .finish(.appQuit))

    let events = Recorder<[String]>([])
    var replied = false
    CherryAppDelegate.tearDownForQuit(intent: .appQuit, registry: registry, steps: quitSteps(harness, events: events)) {
        events.value.append("reply")
        replied = true
    }
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(chromeState.closedTabs.entries.isEmpty)
    #expect(await harness.fake.wait { replied })
    #expect(events.value == ["off screen", "ends", "reply"])
    #expect(harness.requestIDs("kill") == [closedSession])
    #expect(harness.requestIDs("remove") == [closedSession])
    // The kept tab's session runs on.
    #expect(kept.isRunning)
}

@Test @MainActor func aWindowClosingEndsTheSessionsOfItsTabsClosedJustBefore() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let window = ClosingWindow()
    let chromeState = windowChrome()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let kept = workspace.addSession(title: "Kept")
    let closed = workspace.addSession(title: "Closed")
    let detached = workspace.addSession(title: "Detached")
    for tab in [kept, closed, detached] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let keptSession = try #require(kept.persistentSession?.sessionID)
    let closedSession = try #require(closed.persistentSession?.sessionID)
    let detachedSession = try #require(detached.persistentSession?.sessionID)
    let registry = ProjectWindowRegistry()
    SessionCloseCoordinator.close(closed, in: workspace, chromeState: chromeState, registry: registry)
    SessionCloseCoordinator.detach(detached, in: workspace, chromeState: chromeState, registry: registry)
    #expect(chromeState.closedTabs.entries.count == 2)

    // Closed without its question (nothing asked): the window keeps its
    // sessions, but the one closed with ⌘W ends, and nothing is left to undo.
    let delegate = ProjectWindowCloseDelegate(window: window)
    delegate.workspace = workspace
    delegate.chromeState = chromeState
    delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    #expect(workspace.sessions.isEmpty)
    #expect(chromeState.closedTabs.entries.isEmpty)
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(await harness.fake.wait { harness.requestIDs("remove") == [closedSession] })
    #expect(harness.requestIDs("kill") == [closedSession])
    #expect(harness.fake.sessions.contains { $0.id == keptSession && $0.isRunning })
    #expect(harness.fake.sessions.contains { $0.id == detachedSession && $0.isRunning })
}

// MARK: - Where ⌘Z goes

@Test @MainActor func commandZActsOnClosedTabsOnlyWhileNoTextViewHasTheKeyboard() throws {
    // The decision.
    #expect(ClosedTabUndoRouting.actsOnClosedTabs(firstResponder: nil))
    #expect(ClosedTabUndoRouting.actsOnClosedTabs(firstResponder: KeyView()))
    #expect(!ClosedTabUndoRouting.actsOnClosedTabs(firstResponder: NSTextView()))
    let fieldEditor = NSTextView()
    fieldEditor.isFieldEditor = true
    #expect(!ClosedTabUndoRouting.actsOnClosedTabs(firstResponder: fieldEditor))
    #expect(!ClosedTabUndoRouting.actsOnClosedTabs(firstResponder: NSTextField()))

    // ⌘Z is taken before the terminal sees it, unless a text view has the
    // keyboard; ⌘⇧Z (Redo) is left alone.
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "z", modifiers: .command) == .undoClosedTab)
    #expect(AppShortcutMonitor.shortcutAction(
        charactersIgnoringModifiers: "z", modifiers: .command, textHasKeyboard: true
    ) == nil)
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "Z", modifiers: [.command, .shift]) == nil)

    // Edit › Undo: the window's delegate hands AppKit the closed tabs while
    // the terminal (or the sidebar) has the keyboard, else the window's own
    // undo manager, whose typing never meets the closed tabs.
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled, .closable],
        backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    let chromeState = windowChrome()
    let delegate = ProjectWindowCloseDelegate(window: window)
    delegate.chromeState = chromeState
    window.delegate = delegate
    let terminal = KeyView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let text = NSTextView(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
    text.allowsUndo = true
    window.contentView?.addSubview(terminal)
    window.contentView?.addSubview(text)
    let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

    #expect(window.makeFirstResponder(text))
    let textUndo = try #require(window.undoManager)
    #expect(textUndo !== chromeState.closedTabs.undoManager)
    #expect(text.undoManager === textUndo)
    textUndo.groupsByEvent = false
    textUndo.beginUndoGrouping()
    textUndo.registerUndo(withTarget: text) { _ in }
    textUndo.setActionName("Typing")
    textUndo.endUndoGrouping()
    #expect(window.validateMenuItem(undoItem))
    #expect(undoItem.title == "Undo Typing")

    #expect(window.makeFirstResponder(terminal))
    #expect(window.undoManager === chromeState.closedTabs.undoManager)
    // Nothing closed: Undo is off here, whatever the text view could undo.
    #expect(!window.validateMenuItem(undoItem))
    #expect(undoItem.title == "Undo")
    let workspace = TerminalWorkspace(createInitialSession: false)
    chromeState.closedTabs.record([syntheticTab("Shell")], action: .close, workspace: workspace, repository: nil)
    #expect(window.validateMenuItem(undoItem))
    #expect(undoItem.title == "Undo Close Tab")

    // Back in the text view: its own undo, as it was.
    #expect(window.makeFirstResponder(text))
    #expect(window.undoManager === textUndo)
    #expect(window.validateMenuItem(undoItem))
    #expect(undoItem.title == "Undo Typing")
    #expect(textUndo.canUndo)
    #expect(chromeState.closedTabs.entries.count == 1)
    window.delegate = nil
}
