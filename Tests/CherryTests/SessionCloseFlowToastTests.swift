import AppKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// Detaching a tab, or closing one that leaves its program running, asks
// nothing: the window's toast says where it went, with Reopen
// (docs/specs/multiplexer-default.md, "Close intents"). A close that stops a
// program at work asks first. Against the fake `cherry control`
// (FakeControlHelper) and test registries: no window comes on screen, and no
// toast reaches VoiceOver or a real timer.

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

/// A project window that never comes on screen.
@MainActor
private func testWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    return window
}

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = try #require(url.path.withCString { realpath($0, nil) })
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// A clock the test moves, and the checks toasts scheduled on it.
@MainActor
private final class ManualClock {
    let start = Date(timeIntervalSince1970: 1_000)
    private(set) var now: Date
    private var scheduled: [(at: Date, work: @MainActor () -> Void)] = []

    init() { now = start }

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

/// A window's chrome whose toasts keep time on `clock` (never dismissing by
/// themselves without one) and announce into `announced`.
@MainActor
private func quietChromeState(
    clock: ManualClock? = nil,
    announced: Recorder<[String]> = Recorder([])
) -> ProjectWindowChromeState {
    let schedule: ProjectWindowToasts.Scheduler
    if let clock {
        schedule = clock.schedule
    } else {
        schedule = { _, _ in }
    }
    return ProjectWindowChromeState(toasts: ProjectWindowToasts(
        now: { clock?.now ?? Date() },
        schedule: schedule,
        announce: { announced.value.append($0) },
        voiceOverEnabled: { false }
    ))
}

/// Toasts on `clock`, whatever VoiceOver does on this Mac.
@MainActor
private func manualToasts(
    _ clock: ManualClock,
    announced: Recorder<[String]> = Recorder([])
) -> ProjectWindowToasts {
    ProjectWindowToasts(
        now: { clock.now },
        schedule: clock.schedule,
        announce: { announced.value.append($0) },
        voiceOverEnabled: { false }
    )
}

/// Makes `tab`'s host report a job in its shell's foreground.
@MainActor
private func makeBusy(_ tab: TerminalSession, harness: PersistentHarness) async throws {
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let info = try #require(harness.hosting.sessionInfo(sessionID))
    harness.fake.connections.last?.push(.event(.changed(HostedSessionInfo(
        id: info.id, name: info.name, cwd: info.cwd, pid: info.pid,
        foreground: HostedSessionForeground(pid: 99, name: "sleep"), owner: info.owner, tags: info.tags
    ))))
    #expect(await harness.fake.wait { tab.hasRunningProcess() })
}

/// A project window of `root` that never comes on screen, as the app opens
/// one (`ProjectWindowRegistry.projectWindowOpener`).
@MainActor
private func openRepositoryWindow(
    _ root: String,
    harness: PersistentHarness,
    registry: ProjectWindowRegistry,
    window: NSWindow,
    chromeState: ProjectWindowChromeState
) -> RepositoryWorkspace {
    let repository = RepositoryWorkspace(
        projectRoot: root,
        backendPolicy: harness.policy,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    #expect(registry.register(
        window: window, projectRoot: root, workspace: repository.activeWorkspace, repository: repository,
        noteStore: nil, todoStore: nil, chromeState: chromeState
    ))
    return repository
}

@MainActor
private func sidebarName(of session: TerminalSession) -> String {
    SidebarSessionLabel.label(for: session, pathDisplayMode: TerminalSettings.shared.sidebarTerminalPathDisplayMode).title
}

private let backgroundSessionsLine = "Open or end it from Background Sessions in the Cherry menu bar icon."
private let persistentSessionsLine = "Attach to it again from File › Persistent Sessions."

// MARK: - Detaching, and closing without asking

@Test @MainActor func detachingAnAgentClosesItsTabAtOnceAndSaysSoInAToast() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "npm", arguments: "run dev"),
        projectRoot: harness.project.path
    )
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    for tab in [anchor, command, agent] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let agentSession = try #require(agent.persistentSession?.sessionID)
    let agentName = sidebarName(of: agent)
    let announced = Recorder<[String]>([])
    let chromeState = quietChromeState(announced: announced)

    SessionCloseCoordinator.detach(agent, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry())
    // No question: the tab closed at once, its agent still running.
    #expect(chromeState.pendingTabClose == nil)
    #expect(workspace.session(withID: agent.id) == nil)
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "\(agentName) is running in the background")
    // Only the name is cut short when the title does not fit.
    #expect(toast.name == agentName)
    #expect(toast.predicate == " is running in the background")
    #expect(toast.message == backgroundSessionsLine)
    #expect(toast.action?.title == "Reopen")
    #expect(announced.value == ["\(agentName) is running in the background. \(backgroundSessionsLine)"])

    // ⌘D on a running command: the same, and its toast replaces the agent's.
    let commandName = sidebarName(of: command)
    workspace.select(command)
    SessionCloseCoordinator.detachSelectedTabOrWindow(
        workspace: workspace, repository: nil, chromeState: chromeState, window: ClosingWindow(),
        registry: ProjectWindowRegistry()
    )
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    #expect(chromeState.toasts.current?.title == "\(commandName) is running in the background")
    #expect(announced.value.count == 2)

    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.sessions.contains { $0.id == agentSession && $0.isRunning })
}

@Test @MainActor func closingARunningAgentAsksAndClosingItStopsItOnceItsUndoRunsOut() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    for tab in [anchor, agent] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let agentSession = try #require(agent.persistentSession?.sessionID)
    let agentName = sidebarName(of: agent)
    let clock = ManualClock()
    let chromeState = quietChromeState(clock: clock)

    // Closing a tab ends its session: "Close “Claude”?" asks first.
    SessionCloseCoordinator.close(agent, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry())
    let request = try #require(chromeState.pendingTabClose)
    #expect(request.sessionID == agent.id)
    #expect(workspace.session(withID: agent.id) != nil)
    #expect(chromeState.toasts.current == nil)
    let question = try #require(SessionCloseCoordinator.question(for: request))
    #expect(question.messageText == "Close “\(sidebarName(of: agent))”?")

    // Answered Close: the tab closes, and its toast offers Undo; the agent
    // stops once that can no longer be undone.
    SessionCloseCoordinator.answerTabClose(.close, to: request, chromeState: chromeState)
    #expect(chromeState.pendingTabClose == nil)
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "Closed \(agentName)")
    #expect(toast.action?.title == "Undo")
    #expect(toast.action?.shortcut == "⌘Z")
    #expect(harness.hosting.isEnding(agentSession))
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    clock.advance(by: ProjectWindowToasts.lifetime)
    #expect(chromeState.toasts.current == nil)
    #expect(await harness.fake.wait { harness.requestIDs("kill") == [agentSession] })
}

@Test @MainActor func everyDetachShowsAToastAndOnlyAProgramAtWorkMakesACloseAsk() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let idle = workspace.addSession(title: "Idle")
    let busy = workspace.addSession(title: "Busy")
    let closedIdle = workspace.addSession(title: "Closed")
    for tab in [anchor, idle, busy, closedIdle] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let idleSession = try #require(idle.persistentSession?.sessionID)
    let closedSession = try #require(closedIdle.persistentSession?.sessionID)
    let closedName = sidebarName(of: closedIdle)
    let chromeState = quietChromeState()
    let registry = ProjectWindowRegistry()

    // An idle shell detached on purpose: its toast says where it went.
    let idleName = sidebarName(of: idle)
    SessionCloseCoordinator.detach(idle, in: workspace, chromeState: chromeState, registry: registry)
    #expect(workspace.session(withID: idle.id) == nil)
    #expect(chromeState.toasts.current?.title == "\(idleName) is running in the background")
    chromeState.toasts.dismiss()

    // An idle shell closed: no question; its toast offers Undo, and it
    // ends once that can no longer be undone (here, its window closing).
    SessionCloseCoordinator.close(closedIdle, in: workspace, chromeState: chromeState, registry: registry)
    #expect(chromeState.pendingTabClose == nil)
    #expect(workspace.session(withID: closedIdle.id) == nil)
    #expect(chromeState.toasts.current?.title == "Closed \(closedName)")
    #expect(!harness.requestIDs("kill").contains(closedSession))
    chromeState.closedTabs.endAll()
    #expect(chromeState.toasts.current == nil)
    #expect(await harness.fake.wait { harness.requestIDs("kill").contains(closedSession) })

    // A shell running a job in its foreground, as its host reports it:
    // closing it asks, naming the job, and Detach Instead keeps it.
    try await makeBusy(busy, harness: harness)
    SessionCloseCoordinator.close(busy, in: workspace, chromeState: chromeState, registry: registry)
    let request = try #require(chromeState.pendingTabClose)
    let question = try #require(SessionCloseCoordinator.question(for: request))
    #expect(question.informativeText == "sleep is running. Closing the tab stops it.")
    #expect(question.canDetach)
    let busyName = sidebarName(of: busy)
    SessionCloseCoordinator.answerTabClose(.detach, to: request, chromeState: chromeState)
    #expect(workspace.session(withID: busy.id) == nil)
    #expect(chromeState.toasts.current?.title == "\(busyName) is running in the background")
    chromeState.toasts.dismiss()

    // A native tab cannot detach, and its close stops its program: nothing
    // to say (whether it asked first or not).
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addSession(title: "Native")
    harness.settings.value.persistLocalSessions = true
    #expect(!native.isPersistentLocalSession)
    #expect(!SessionCloseCoordinator.canDetach(native))
    SessionCloseCoordinator.detach(native, in: workspace, chromeState: chromeState, registry: registry)
    #expect(workspace.session(withID: native.id) != nil)
    #expect(ClosedTabNotice.make(for: native, policy: workspace.backendPolicy) == nil)
    SessionCloseCoordinator.closeTab(native, in: workspace, chromeState: chromeState, registry: registry)
    #expect(workspace.session(withID: native.id) == nil)
    #expect(chromeState.toasts.current == nil)
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    #expect(!harness.requestIDs("kill").contains(idleSession))
}

// MARK: - Reopen

@Test @MainActor func reopenBringsADetachedAgentsSessionBackAsItsOwnTab() async throws {
    let harness = try PersistentHarness()
    let project = harness.project.path
    let repository = RepositoryWorkspace(
        projectRoot: project,
        backendPolicy: harness.policy,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let window = testWindow()
    let chromeState = quietChromeState()
    defer {
        registry.unregister(window: window, projectRoot: project)
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    #expect(registry.register(
        window: window, projectRoot: project, workspace: repository.activeWorkspace, repository: repository,
        noteStore: nil, todoStore: nil, chromeState: chromeState
    ))
    let workspace = repository.activeWorkspace
    // The window's default shell.
    #expect(await harness.fake.wait { harness.creates().count == 1 })
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: project
    )
    #expect(await harness.waitUntilAttached(agent))
    let agentSession = try #require(agent.persistentSession?.sessionID)

    // ⌘D: the window's registry is its repository's.
    SessionCloseCoordinator.detachSelectedTabOrWindow(
        workspace: workspace, repository: repository, chromeState: chromeState, window: window
    )
    #expect(workspace.session(withID: agent.id) == nil)
    #expect(harness.hosting.owningTab(of: agentSession) == nil)
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.action?.title == "Reopen")

    // Reopen: adopted again as the tab it was started for, selected.
    chromeState.toasts.performAction(of: toast.id)
    #expect(chromeState.toasts.current == nil)
    #expect(await harness.fake.wait { workspace.session(withID: agent.id) != nil })
    let reopened = try #require(workspace.session(withID: agent.id))
    #expect(reopened.kind == .agent)
    #expect(reopened.isPersistentLocalSession)
    #expect(reopened.hostedAttachment == nil)
    #expect(reopened.persistentSession?.sessionID == agentSession)
    #expect(harness.hosting.owningTab(of: agentSession) === reopened)
    #expect(workspace.selectedSessionID == agent.id)
    #expect(harness.creates().count == 2)
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func reopenAttachesASessionTheClosedTabDidNotOwnAgain() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))
    // Sessions the CLI made: one runs a job in its shell, one sits idle.
    let busy = HostedSessionInfo(
        id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72,
        foreground: HostedSessionForeground(pid: 73, name: "top")
    )
    let idle = HostedSessionInfo(id: "session-idle", name: "Idle CLI", cwd: harness.project.path, pid: 74)
    harness.fake.sessions.append(contentsOf: [busy, idle])
    _ = try await harness.control.list()
    let chromeState = quietChromeState()
    let registry = ProjectWindowRegistry()

    func attach(_ info: HostedSessionInfo) async throws -> TerminalSession {
        let tab = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: info)))
        #expect(!tab.isPersistentLocalSession)
        #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach \(info.id) ") } })
        return tab
    }

    // Closing only disconnects: no question, a toast that says where to
    // find it.
    let tab = try await attach(busy)
    SessionCloseCoordinator.close(tab, in: workspace, chromeState: chromeState, registry: registry)
    #expect(chromeState.pendingTabClose == nil)
    #expect(workspace.session(withID: tab.id) == nil)
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "CLI is running in the background")
    #expect(toast.message == persistentSessionsLine)
    #expect(toast.action?.title == "Reopen")

    // Reopen: attached again, in this window.
    chromeState.toasts.performAction(of: toast.id)
    #expect(await harness.fake.wait { workspace.sessions.contains { $0.hostedAttachment?.sessionID == "session-cli" } })
    let reattached = try #require(workspace.sessions.first { $0.hostedAttachment?.sessionID == "session-cli" })
    #expect(!reattached.isPersistentLocalSession)
    #expect(workspace.selectedSessionID == reattached.id)

    // An idle one closes with only its Undo; detached, it says where it
    // went.
    let idleTab = try await attach(idle)
    SessionCloseCoordinator.close(idleTab, in: workspace, chromeState: chromeState, registry: registry)
    #expect(workspace.session(withID: idleTab.id) == nil)
    #expect(chromeState.toasts.current?.title == "Closed Idle CLI")
    #expect(chromeState.toasts.current?.action?.title == "Undo")
    chromeState.toasts.dismiss()
    let detachedTab = try await attach(idle)
    SessionCloseCoordinator.detach(detachedTab, in: workspace, chromeState: chromeState, registry: registry)
    #expect(workspace.session(withID: detachedTab.id) == nil)
    #expect(chromeState.toasts.current?.title == "Idle CLI is running in the background")
    #expect(chromeState.toasts.current?.message == persistentSessionsLine)
    chromeState.toasts.dismiss()
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.requests("remove").isEmpty)

    // Closed again, then the CLI's session ends and goes before Reopen:
    // nothing to attach to, so no tab.
    let target = try #require(ClosedTabNotice.reopenTarget(for: reattached, in: workspace.projectRoot))
    SessionCloseCoordinator.close(reattached, in: workspace, chromeState: chromeState, registry: registry)
    #expect(chromeState.toasts.current?.action != nil)
    harness.fake.sessions.removeAll { $0.id == "session-cli" }
    let tabs = workspace.sessions.map(\.id)
    let reopened = await SessionCloseCoordinator.reopen(
        target, hosting: harness.hosting, into: workspace, chromeState: chromeState, registry: registry
    )
    #expect(reopened == nil)
    #expect(workspace.sessions.map(\.id) == tabs)
}

// MARK: - The window's last tab

@Test @MainActor func commandDOnALastTabClosesTheWindowAndToastsTheWindowActiveLast() async throws {
    let harness = try PersistentHarness()
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    // Test windows never come on screen; these are minimized.
    let minimized = Recorder<[NSWindow]>([])
    registry.windowIsOnScreen = { window in !minimized.value.contains { $0 === window } }
    let closing = harness.workspace()
    let window = ClosingWindow()
    let chromeState = quietChromeState()
    let otherRoots = [try temporaryDirectory("cherry-toast-other"), try temporaryDirectory("cherry-toast-other")]
    let others = otherRoots.map {
        TerminalWorkspace(projectRoot: $0.path, createInitialSession: false, backendPolicy: harness.policy)
    }
    let otherWindows = [testWindow(), testWindow()]
    let otherChromeStates = [quietChromeState(), quietChromeState()]
    defer {
        registry.unregister(window: window, projectRoot: harness.project.path)
        for (index, root) in otherRoots.enumerated() {
            registry.unregister(window: otherWindows[index], projectRoot: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        closing.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    #expect(registry.register(
        window: window, projectRoot: harness.project.path, workspace: closing,
        noteStore: nil, todoStore: nil, chromeState: chromeState
    ))
    for index in others.indices {
        #expect(registry.register(
            window: otherWindows[index], projectRoot: otherRoots[index].path, workspace: others[index],
            noteStore: nil, todoStore: nil, chromeState: otherChromeStates[index]
        ))
    }
    /// `other` was active, then the closing window.
    func activate(_ other: Int) {
        for (root, workspace, state) in [
            (otherRoots[other].path, others[other], otherChromeStates[other]),
            (harness.project.path, closing, chromeState),
        ] {
            registry.activateWindow(projectRoot: root, workspace: workspace, noteStore: nil, todoStore: nil, chromeState: state)
        }
    }
    /// Opens an agent as the closing window's last tab and detaches it with ⌘D.
    func closeLastAgent(_ name: String) async -> String {
        let agent = closing.addAgentSession(
            agent: AgentToolDefinition(name: name, command: name.lowercased()), projectRoot: harness.project.path
        )
        #expect(await harness.waitUntilAttached(agent))
        let agentName = sidebarName(of: agent)
        SessionCloseCoordinator.detachSelectedTabOrWindow(
            workspace: closing, repository: nil, chromeState: chromeState, window: window, registry: registry
        )
        // No question: the tab closed, then its window.
        #expect(chromeState.pendingTabClose == nil)
        #expect(closing.sessions.isEmpty)
        #expect(chromeState.toasts.current == nil)
        return agentName
    }

    activate(1)
    let agentName = await closeLastAgent("Claude")
    #expect(window.closeRequests == 1)
    #expect(otherChromeStates[0].toasts.current == nil)
    let toast = try #require(otherChromeStates[1].toasts.current)
    #expect(toast.title == "\(agentName) is running in the background")
    #expect(toast.message == backgroundSessionsLine)
    #expect(toast.action?.title == "Reopen")
    otherChromeStates[1].toasts.dismiss()

    // The other one was active since: it gets the next toast.
    activate(0)
    _ = await closeLastAgent("Gemini")
    #expect(window.closeRequests == 2)
    #expect(otherChromeStates[0].toasts.current != nil)
    #expect(otherChromeStates[1].toasts.current == nil)
    otherChromeStates[0].toasts.dismiss()

    // A minimized window is passed over: nobody would see its toast.
    minimized.value = [otherWindows[0]]
    _ = await closeLastAgent("Amp")
    #expect(otherChromeStates[0].toasts.current == nil)
    #expect(otherChromeStates[1].toasts.current != nil)
    otherChromeStates[1].toasts.dismiss()
    minimized.value = []

    // With no other project window open, nothing is shown.
    for (index, root) in otherRoots.enumerated() {
        registry.unregister(window: otherWindows[index], projectRoot: root.path)
    }
    _ = await closeLastAgent("Codex")
    #expect(window.closeRequests == 4)
    #expect(otherChromeStates.allSatisfy { $0.toasts.current == nil })
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
}

// MARK: - The toast

@Test func aToastsLifetimeStopsWhileThePointerRestsOnIt() {
    let shown = Date(timeIntervalSince1970: 1_000)
    var lifetime = ToastLifetime(lifetime: 6, shownAt: shown)
    #expect(lifetime.deadline == shown + 6)
    #expect(!lifetime.isExpired(at: shown + 5.9))
    #expect(lifetime.isExpired(at: shown + 6))

    // Hovered 2 s in: it waits for as long as the pointer stays.
    lifetime.pause(at: shown + 2)
    #expect(lifetime.deadline == nil)
    #expect(!lifetime.isExpired(at: shown + 100))
    lifetime.pause(at: shown + 20)
    #expect(lifetime.remaining == 4)
    // The pointer left: the 4 s it had left.
    lifetime.resume(at: shown + 30)
    #expect(lifetime.deadline == shown + 34)
    lifetime.resume(at: shown + 31)
    #expect(lifetime.deadline == shown + 34)

    // Left with less than the grace after a hover: it gets the grace.
    lifetime.pause(at: shown + 33.5)
    lifetime.resume(at: shown + 40)
    #expect(lifetime.deadline == shown + 40 + ToastLifetime.graceAfterHover)
}

@Test @MainActor func aToastDismissesItselfAfterItsLifetimeUnlessThePointerRestsOnIt() {
    let clock = ManualClock()
    let announced = Recorder<[String]>([])
    let toasts = manualToasts(clock, announced: announced)
    #expect(ProjectWindowToasts.lifetime == 6)

    let first = ProjectWindowToast(title: "Claude is running in the background", message: backgroundSessionsLine)
    toasts.show(first)
    #expect(announced.value == ["Claude is running in the background. \(backgroundSessionsLine)"])
    clock.advance(by: 5.9)
    #expect(toasts.current?.id == first.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)

    let hovered = ProjectWindowToast(title: "Hovered")
    toasts.show(hovered)
    let pointerOver = Recorder(true)
    toasts.setPointerProbe(for: hovered.id) { pointerOver.value }
    clock.advance(by: 2)
    toasts.setHovering(true, id: hovered.id)
    clock.advance(by: 30)
    #expect(toasts.current?.id == hovered.id)
    // Another toast's hover changes nothing.
    toasts.setHovering(false, id: first.id)
    clock.advance(by: 30)
    #expect(toasts.current?.id == hovered.id)
    pointerOver.value = false
    toasts.setHovering(false, id: hovered.id)
    clock.advance(by: 3.9)
    #expect(toasts.current?.id == hovered.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)
    #expect(announced.value.count == 2)
}

@Test @MainActor func aNewToastReplacesTheOneShownAndKeepsItsOwnTime() {
    let clock = ManualClock()
    let announced = Recorder<[String]>([])
    let toasts = manualToasts(clock, announced: announced)
    let first = ProjectWindowToast(title: "First")
    let second = ProjectWindowToast(title: "Second", message: "Line")
    toasts.show(first)
    clock.advance(by: 4)
    toasts.show(second)
    #expect(toasts.current?.id == second.id)
    #expect(announced.value == ["First", "Second. Line"])

    // The first one's time runs out: the second stays for its own 6 s.
    clock.advance(by: 2)
    #expect(toasts.current?.id == second.id)
    // Dismissing the first one (gone already) leaves it.
    toasts.dismiss(id: first.id)
    #expect(toasts.current?.id == second.id)
    clock.advance(by: 3.9)
    #expect(toasts.current?.id == second.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)

    // Dismissed by hand: nothing left to expire.
    toasts.show(first)
    toasts.dismiss(id: first.id)
    #expect(toasts.current == nil)
    clock.advance(by: 10)
    #expect(toasts.current == nil)
}

@Test @MainActor func aToastsActionDismissesItThenActs() {
    let performed = Recorder(0)
    let toasts = ProjectWindowToasts(schedule: { _, _ in }, announce: { _ in }, voiceOverEnabled: { false })
    let toast = ProjectWindowToast(
        title: "Claude is running in the background",
        action: .init(title: "Reopen") { performed.value += 1 }
    )
    toasts.show(toast)
    toasts.performAction(of: UUID())
    #expect(performed.value == 0)
    #expect(toasts.current?.id == toast.id)
    toasts.performAction(of: toast.id)
    #expect(performed.value == 1)
    #expect(toasts.current == nil)
    toasts.performAction(of: toast.id)
    #expect(performed.value == 1)

    // A toast without an action has nothing to perform.
    let plain = ProjectWindowToast(title: "Plain")
    toasts.show(plain)
    toasts.performAction(of: plain.id)
    #expect(toasts.current?.id == plain.id)
}

@Test @MainActor func aToastWhosePointerLeftUnnoticedGetsItsTimeBack() {
    let clock = ManualClock()
    let toasts = manualToasts(clock)
    let toast = ProjectWindowToast(title: "Claude is running in the background")
    toasts.show(toast)
    let pointerOver = Recorder(true)
    toasts.setPointerProbe(for: toast.id) { pointerOver.value }
    clock.advance(by: 1)
    toasts.setHovering(true, id: toast.id)
    // The pointer rests on it: it stays, and looks again each second.
    clock.advance(by: 20)
    #expect(toasts.current?.id == toast.id)

    // The pointer went while the window was not key: no hover exit comes.
    // Within a second the toast sees it, and has the 5 s it had left.
    pointerOver.value = false
    clock.advance(by: ProjectWindowToasts.hoverRecheckInterval)
    #expect(toasts.current?.id == toast.id)
    clock.advance(by: 4.9)
    #expect(toasts.current?.id == toast.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)

    // A toast whose view is gone (nothing to ask) counts as left too.
    let other = ProjectWindowToast(title: "Other")
    toasts.show(other)
    toasts.setHovering(true, id: other.id)
    clock.advance(by: ProjectWindowToasts.hoverRecheckInterval)
    clock.advance(by: ProjectWindowToasts.lifetime - 0.1)
    #expect(toasts.current?.id == other.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)
}

@Test @MainActor func aToastStaysLongerWhileVoiceOverRuns() {
    #expect(ProjectWindowToasts.lifetime(voiceOverEnabled: false) == 6)
    #expect(ProjectWindowToasts.lifetime(voiceOverEnabled: true) == ProjectWindowToasts.voiceOverLifetime)
    #expect(ProjectWindowToasts.voiceOverLifetime >= 5 * ProjectWindowToasts.lifetime)

    // Read as each toast is shown.
    let clock = ManualClock()
    let voiceOver = Recorder(true)
    let toasts = ProjectWindowToasts(
        now: { clock.now }, schedule: clock.schedule, announce: { _ in },
        voiceOverEnabled: { voiceOver.value }
    )
    let toast = ProjectWindowToast(title: "Claude is running in the background")
    toasts.show(toast)
    clock.advance(by: ProjectWindowToasts.voiceOverLifetime - 0.1)
    #expect(toasts.current?.id == toast.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)
    voiceOver.value = false
    toasts.show(toast)
    clock.advance(by: ProjectWindowToasts.lifetime)
    #expect(toasts.current == nil)
}

@Test @MainActor func aLongToastStaysTwiceAsLongWithOrWithoutVoiceOver() {
    #expect(ProjectWindowToasts.lifetime(of: .long, voiceOverEnabled: false) == 12)
    #expect(ProjectWindowToasts.lifetime(of: .long, voiceOverEnabled: true) == ProjectWindowToasts.longVoiceOverLifetime)
    #expect(ProjectWindowToasts.longLifetime == 2 * ProjectWindowToasts.lifetime)
    #expect(ProjectWindowToasts.longVoiceOverLifetime > ProjectWindowToasts.voiceOverLifetime)
    #expect(ProjectWindowToasts.lifetime(voiceOverEnabled: false) == ProjectWindowToasts.lifetime(of: .standard, voiceOverEnabled: false))

    let clock = ManualClock()
    let voiceOver = Recorder(false)
    let toasts = ProjectWindowToasts(
        now: { clock.now }, schedule: clock.schedule, announce: { _ in },
        voiceOverEnabled: { voiceOver.value }
    )
    let long = ProjectWindowToast(title: "2 sessions are still running in the background", actions: [], length: .long)
    toasts.show(long)
    clock.advance(by: ProjectWindowToasts.lifetime)
    #expect(toasts.current?.id == long.id)
    clock.advance(by: ProjectWindowToasts.longLifetime - ProjectWindowToasts.lifetime - 0.1)
    #expect(toasts.current?.id == long.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)

    voiceOver.value = true
    toasts.show(long)
    clock.advance(by: ProjectWindowToasts.longVoiceOverLifetime - 0.1)
    #expect(toasts.current?.id == long.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)
}

@Test @MainActor func aToastWithSeveralActionsPerformsTheOneClickedAndSaysWhenItGoes() {
    let clock = ManualClock()
    let toasts = manualToasts(clock)
    let performed = Recorder<[String]>([])
    let dismissed = Recorder(0)
    func make() -> ProjectWindowToast {
        ProjectWindowToast(
            title: "2 sessions are still running in the background",
            message: "From tabs or windows you closed.",
            actions: [
                .init(title: "Reopen") { performed.value.append("Reopen") },
                .init(title: "End…") { performed.value.append("End…") },
            ],
            length: .long,
            onDismiss: { dismissed.value += 1 }
        )
    }
    let toast = make()
    #expect(toast.actions.map(\.title) == ["Reopen", "End…"])
    #expect(toast.action?.title == "Reopen")
    toasts.show(toast)

    // No such action, or another toast's: nothing happens.
    toasts.performAction(of: toast.id, at: 2)
    toasts.performAction(of: UUID(), at: 1)
    #expect(toasts.current?.id == toast.id)
    #expect(dismissed.value == 0)
    // The second button: it goes (which it says first), then acts.
    toasts.performAction(of: toast.id, at: 1)
    #expect(performed.value == ["End…"])
    #expect(dismissed.value == 1)
    #expect(toasts.current == nil)

    // Its dismiss button, and its time running out, say so too.
    let second = make()
    toasts.show(second)
    toasts.dismiss(id: second.id)
    #expect(dismissed.value == 2)
    let third = make()
    toasts.show(third)
    clock.advance(by: ProjectWindowToasts.longLifetime)
    #expect(toasts.current == nil)
    #expect(dismissed.value == 3)

    // Replaced by another toast: it did not go by itself, so it says nothing.
    toasts.show(make())
    toasts.show(ProjectWindowToast(title: "Claude is running in the background"))
    #expect(dismissed.value == 3)
    #expect(performed.value == ["End…"])
}

/// The launch notice's kind of toast: nobody asked for it.
@MainActor
private func unpromptedToast(dismissed: Recorder<Int>) -> ProjectWindowToast {
    ProjectWindowToast(
        title: "1 session is still running in the background",
        message: "From a tab or window you closed.",
        actions: [],
        length: .long,
        isUnprompted: true,
        onDismiss: { dismissed.value += 1 }
    )
}

@Test @MainActor func anUnpromptedToastsTimeRunsOnlyWhileItsWindowIsKeyInTheActiveApp() {
    let clock = ManualClock()
    let toasts = manualToasts(clock)
    let dismissed = Recorder(0)
    let attended = Recorder(true)

    // Seen for 2 s, then the user goes to another app (or window): its time
    // stops, however long they stay away.
    let notice = unpromptedToast(dismissed: dismissed)
    toasts.show(notice)
    toasts.setAttentionProbe(for: notice.id) { attended.value }
    clock.advance(by: 2)
    attended.value = false
    toasts.setAttended(false, id: notice.id)
    clock.advance(by: 600)
    #expect(toasts.current?.id == notice.id)
    #expect(dismissed.value == 0)
    // Back: it stays for the 10 s it had left, then goes (and says so).
    attended.value = true
    toasts.setAttended(true, id: notice.id)
    clock.advance(by: ProjectWindowToasts.longLifetime - 2 - 0.1)
    #expect(toasts.current?.id == notice.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)
    #expect(dismissed.value == 1)

    // Shown while Cherry is in the background (its view says so as it
    // appears), and AppKit's word that the window became key again does not
    // come: a second later the toast sees it, and has all of its time.
    let unseen = unpromptedToast(dismissed: dismissed)
    toasts.show(unseen)
    toasts.setAttentionProbe(for: unseen.id) { attended.value }
    attended.value = false
    toasts.setAttended(false, id: unseen.id)
    clock.advance(by: 60)
    #expect(toasts.current?.id == unseen.id)
    attended.value = true
    clock.advance(by: ProjectWindowToasts.hoverRecheckInterval)
    clock.advance(by: ProjectWindowToasts.longLifetime - 0.1)
    #expect(toasts.current?.id == unseen.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)
    #expect(dismissed.value == 2)

    // It stopped being seen without AppKit saying so: when its time runs
    // out it looks, and stays until it is seen again, then for the grace.
    let unnoticed = unpromptedToast(dismissed: dismissed)
    toasts.show(unnoticed)
    toasts.setAttentionProbe(for: unnoticed.id) { attended.value }
    attended.value = false
    clock.advance(by: ProjectWindowToasts.longLifetime)
    #expect(toasts.current?.id == unnoticed.id)
    #expect(dismissed.value == 2)
    attended.value = true
    clock.advance(by: ProjectWindowToasts.hoverRecheckInterval)
    clock.advance(by: ToastLifetime.graceAfterHover - 0.1)
    #expect(toasts.current?.id == unnoticed.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)
    #expect(dismissed.value == 3)

    // A toast after what the user just did keeps its time either way.
    let closed = ProjectWindowToast(title: "Claude is running in the background")
    toasts.show(closed)
    toasts.setAttentionProbe(for: closed.id) { false }
    toasts.setAttended(false, id: closed.id)
    clock.advance(by: ProjectWindowToasts.lifetime)
    #expect(toasts.current == nil)
}

@Test @MainActor func anUnpromptedToastWaitsForTheToastShownAndComesBackAfterOneShownOverIt() {
    let clock = ManualClock()
    let announced = Recorder<[String]>([])
    let toasts = manualToasts(clock, announced: announced)
    let dismissed = Recorder(0)
    let reopened = Recorder(0)
    let closedTitle = "Claude is running in the background"

    // A closed tab's toast shows when the notice is ready: the notice waits,
    // unannounced, and the tab's toast keeps its Reopen and its own time.
    let closed = ProjectWindowToast(title: closedTitle, action: .init(title: "Reopen") { reopened.value += 1 })
    toasts.show(closed)
    clock.advance(by: 2)
    let notice = unpromptedToast(dismissed: dismissed)
    toasts.show(notice)
    #expect(toasts.current?.id == closed.id)
    #expect(announced.value == [closedTitle])
    clock.advance(by: ProjectWindowToasts.lifetime - 2 - 0.1)
    #expect(toasts.current?.id == closed.id)
    // Once it goes, the notice comes up with all of its time.
    clock.advance(by: 0.1)
    #expect(toasts.current?.id == notice.id)
    #expect(announced.value == [closedTitle, notice.announcement])
    #expect(dismissed.value == 0)

    // A tab closed while it shows: that tab's toast goes over it, and the
    // notice, set aside (not dismissed), comes back once it goes, even by
    // its Reopen, with the 8 s it had left.
    clock.advance(by: 4)
    let second = ProjectWindowToast(title: "server is running in the background", action: .init(title: "Reopen") {
        reopened.value += 1
    })
    toasts.show(second)
    #expect(toasts.current?.id == second.id)
    #expect(dismissed.value == 0)
    clock.advance(by: 3)
    // Another tab's toast replaces that one; the notice still waits.
    let third = ProjectWindowToast(title: "worker is running in the background", action: .init(title: "Reopen") {
        reopened.value += 1
    })
    toasts.show(third)
    #expect(toasts.current?.id == third.id)
    toasts.performAction(of: third.id)
    #expect(reopened.value == 1)
    #expect(toasts.current?.id == notice.id)
    #expect(dismissed.value == 0)
    clock.advance(by: ProjectWindowToasts.longLifetime - 4 - 0.1)
    #expect(toasts.current?.id == notice.id)
    clock.advance(by: 0.1)
    #expect(toasts.current == nil)
    #expect(dismissed.value == 1)

    // Nothing waits any more.
    toasts.show(closed)
    toasts.dismiss(id: closed.id)
    #expect(toasts.current == nil)
    #expect(dismissed.value == 1)
}

@Test @MainActor func aToastRisesAboveThePanesBottomBars() {
    let pane = CGSize(width: 1000, height: 600)
    // Where the bars sit.
    #expect(ProjectWindowToastOverlay.bottomInset(above: [], in: pane) == 14)
    // "Command exited … [Restart]": 36 tall, centered 14 above the bottom.
    let bar = CGRect(x: 330, y: 600 - 14 - 36, width: 340, height: 36)
    #expect(ProjectWindowToastOverlay.bottomInset(above: [bar], in: pane) == CGFloat(14 + 36 + 8))
    // Split panes: above the higher of two.
    let taller = CGRect(x: 100, y: 600 - 14 - 50, width: 400, height: 50)
    #expect(ProjectWindowToastOverlay.bottomInset(above: [bar, taller], in: pane) == CGFloat(14 + 50 + 8))
    // A bar beside its column (the toast is 460 wide, from 270 to 730).
    let aside = CGRect(x: 20, y: 600 - 14 - 36, width: 240, height: 36)
    #expect(ProjectWindowToastOverlay.bottomInset(above: [aside], in: pane) == 14)
    // A narrow pane: the toast spans it, less 16 on each side.
    let narrow = CGSize(width: 300, height: 400)
    let edgeBar = CGRect(x: 0, y: 400 - 14 - 36, width: 20, height: 36)
    #expect(ProjectWindowToastOverlay.bottomInset(above: [edgeBar], in: narrow) == CGFloat(14 + 36 + 8))
}

// MARK: - Tabs closed together

@Test func tabsClosedTogetherShareOneNotice() throws {
    let local = HostedSessionAttachment(
        host: .local, hostID: "host-a", sessionID: "session-cli", name: "CLI",
        remoteWorkingDirectory: "/", executablePath: "/usr/bin/true"
    )
    let own = [
        ClosedTabNotice(tabName: "Claude", reopen: .backgroundSession(id: "s-1")),
        ClosedTabNotice(tabName: "Explore", reopen: .backgroundSession(id: "s-2")),
    ]
    #expect(ClosedTabNotice.combining([]) == nil)
    #expect(ClosedTabNotice.combining([own[0]]) == own[0])
    let both = try #require(ClosedTabNotice.combining(own))
    #expect(both.title == "2 tabs are running in the background")
    #expect(both.subject == "2 tabs")
    #expect(both.message == "Open or end them from Background Sessions in the Cherry menu bar icon.")
    #expect(both.reopen == [.backgroundSession(id: "s-1"), .backgroundSession(id: "s-2")])

    let attached = ClosedTabNotice(tabName: "CLI", reopen: .attach(local, worktreeRoot: "/work"))
    let twoAttached = try #require(ClosedTabNotice.combining([attached, attached]))
    #expect(twoAttached.message == "Attach to them again from File › Persistent Sessions.")
    let mixed = try #require(ClosedTabNotice.combining(own + [attached]))
    #expect(mixed.title == "3 tabs are running in the background")
    #expect(mixed.message == "Find them in Background Sessions in the Cherry menu bar icon, or in File › Persistent Sessions.")
    #expect(mixed.reopen.count == 3)
    // A tab closed while its session's Create was under way has nothing to
    // reopen, and still counts.
    let creating = ClosedTabNotice(tabName: "Build", reopen: nil)
    #expect(creating.message == ClosedTabNotice.backgroundSessionsMessage)
    #expect(ClosedTabNotice.combining([creating, own[0]])?.reopen == [.backgroundSession(id: "s-1")])
}

@Test @MainActor func closeSplitGroupSaysWhichPanesStop() {
    let policy = SessionBackendPolicy(settings: { .defaults })
    func native() -> TerminalSession {
        TerminalSession(title: "zsh", subtitle: "", tint: .systemOrange, launchShell: false, kind: .terminal)
    }
    func attached(_ id: String) -> TerminalSession {
        TerminalSession(
            title: "CLI", subtitle: "", tint: .systemOrange, launchShell: false, kind: .terminal,
            hostedAttachment: HostedSessionAttachment(
                host: .local, hostID: "host-a", sessionID: id, name: "CLI",
                remoteWorkingDirectory: "/", executablePath: "/usr/bin/true"
            )
        )
    }
    let stops = SessionCloseCoordinator.splitGroupCloseAlert(for: [native(), native()], policy: policy)
    #expect(stops.messageText == "Close Split Group?")
    #expect(stops.informativeText == "This will stop and close 2 terminal panes.")
    // Native panes cannot detach.
    #expect(stops.buttons.map(\.title) == ["Close Split Group", "Cancel"])
    #expect(stops.alertStyle == .warning)
    #expect(SessionCloseCoordinator.splitGroupCloseAnswer(for: .alertFirstButtonReturn, detachOffered: false) == .close)
    #expect(SessionCloseCoordinator.splitGroupCloseAnswer(for: .alertSecondButtonReturn, detachOffered: false) == .cancel)
    #expect(SessionCloseCoordinator.splitGroupCloseAnswer(for: .alertSecondButtonReturn, detachOffered: true) == .detach)
    #expect(SessionCloseCoordinator.splitGroupCloseAnswer(for: .alertThirdButtonReturn, detachOffered: true) == .cancel)
    let keeps = SessionCloseCoordinator.splitGroupCloseAlert(for: [attached("a"), attached("b")], policy: policy)
    #expect(keeps.informativeText == "This will close 2 terminal panes. Their programs keep running in the background.")
    #expect(keeps.alertStyle == .informational)
    // Detaching would do what closing does.
    #expect(keeps.buttons.map(\.title) == ["Close Split Group", "Cancel"])
    let one = SessionCloseCoordinator.splitGroupCloseAlert(for: [native(), attached("a")], policy: policy)
    #expect(one.informativeText
        == "This will close 2 terminal panes and stop 1 of them. The other one keeps running in the background.")
    let two = SessionCloseCoordinator.splitGroupCloseAlert(for: [native(), attached("a"), attached("b")], policy: policy)
    #expect(two.informativeText
        == "This will close 3 terminal panes and stop 1 of them. The others keep running in the background.")
}

@Test @MainActor func detachingASplitGroupSaysSoInOneToast() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let left = workspace.addSession(title: "Left")
    let right = workspace.addSession(title: "Right")
    for tab in [anchor, left, right] {
        #expect(await harness.waitUntilAttached(tab))
    }
    workspace.select(left)
    #expect(workspace.splitActiveTerminal(with: right))
    let group = try #require(workspace.splitGroup(containing: left.id))
    let chromeState = quietChromeState()
    // Close Split Group… offers Detach Instead for the persistent panes.
    #expect(SessionCloseCoordinator.canDetachInstead([left, right], policy: workspace.backendPolicy))
    #expect(SessionCloseCoordinator.splitGroupCloseAlert(for: [left, right], policy: workspace.backendPolicy)
        .buttons.map(\.title) == ["Close Split Group", "Detach Instead", "Cancel"])

    // Detach Instead: one toast for the two, busy or not.
    try await makeBusy(left, harness: harness)
    SessionCloseCoordinator.closeTabs(
        [left, right], in: workspace, chromeState: chromeState, intent: .userDetachedTab, registry: ProjectWindowRegistry()
    ) {
        workspace.closeSplitGroup(id: group.id, intent: .userDetachedTab)
    }
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "2 tabs are running in the background")
    #expect(toast.action?.title == "Reopen")
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func detachingAnAgentGroupShowsAToastWhoseReopenBringsThemAllBack() async throws {
    let harness = try PersistentHarness()
    let project = harness.project.path
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let window = testWindow()
    let chromeState = quietChromeState()
    let repository = openRepositoryWindow(project, harness: harness, registry: registry, window: window, chromeState: chromeState)
    defer {
        registry.unregister(window: window, projectRoot: project)
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let workspace = repository.activeWorkspace
    #expect(await harness.fake.wait { harness.creates().count == 1 })
    let parent = workspace.addAgentSession(agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: project)
    let child = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: "codex"), projectRoot: project, parentAgentID: parent.id
    )
    for tab in [parent, child] {
        #expect(await harness.waitUntilAttached(tab))
    }
    #expect(workspace.descendantAgentSessions(of: parent).map(\.id) == [child.id])

    // "Close Agent Group?" → Detach Parent and Sub-Agents.
    let group = [parent] + workspace.descendantAgentSessions(of: parent)
    #expect(SessionCloseCoordinator.canDetachInstead(group, policy: workspace.backendPolicy))
    SessionCloseCoordinator.closeTabs(group, in: workspace, chromeState: chromeState, intent: .userDetachedTab, registry: registry) {
        workspace.closeAgentGroup(parent, intent: .userDetachedTab)
    }
    #expect(workspace.session(withID: parent.id) == nil)
    #expect(workspace.session(withID: child.id) == nil)
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "2 tabs are running in the background")
    #expect(toast.message == "Open or end them from Background Sessions in the Cherry menu bar icon.")

    chromeState.toasts.performAction(of: toast.id)
    #expect(await harness.fake.wait {
        workspace.session(withID: parent.id) != nil && workspace.session(withID: child.id) != nil
    })
    #expect(workspace.session(withID: parent.id)?.kind == .agent)
    #expect(workspace.session(withID: child.id)?.isPersistentLocalSession == true)
    #expect(harness.creates().count == 3)
    #expect(harness.fake.requests("kill").isEmpty)

    // ⌘D on the parent: only its tab goes, its sub-agent stays (promoted),
    // and the toast names the parent.
    let reopenedParent = try #require(workspace.session(withID: parent.id))
    let reopenedChild = try #require(workspace.session(withID: child.id))
    let parentName = sidebarName(of: reopenedParent)
    workspace.select(reopenedParent)
    SessionCloseCoordinator.detachSelectedTabOrWindow(
        workspace: workspace, repository: repository, chromeState: chromeState, window: window
    )
    #expect(workspace.session(withID: parent.id) == nil)
    #expect(workspace.session(withID: child.id) === reopenedChild)
    #expect(reopenedChild.parentAgentID == nil)
    #expect(chromeState.toasts.current?.title == "\(parentName) is running in the background")
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func reopenOnTheToastAnotherWindowShowsBringsTheTabBackInItsOwnProject() async throws {
    let harness = try PersistentHarness()
    let project = harness.project.path
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.windowIsOnScreen = { _ in true }
    // Window B, another project, stays open.
    let otherRoot = try temporaryDirectory("cherry-toast-reopen-other")
    let other = TerminalWorkspace(projectRoot: otherRoot.path, createInitialSession: false, backendPolicy: harness.policy)
    let otherWindow = testWindow()
    let otherChromeState = quietChromeState()
    #expect(registry.register(
        window: otherWindow, projectRoot: otherRoot.path, workspace: other,
        noteStore: nil, todoStore: nil, chromeState: otherChromeState
    ))
    // Window A, this project, closes with its last tab, then opens again
    // when asked (as the app's `openWindow`).
    var windows: [(window: NSWindow, repository: RepositoryWorkspace)] = []
    var opened: [String?] = []
    func openA() -> RepositoryWorkspace {
        let window = ClosingWindow()
        let repository = openRepositoryWindow(
            project, harness: harness, registry: registry, window: window, chromeState: quietChromeState()
        )
        windows.append((window, repository))
        return repository
    }
    registry.projectWindowOpener = { root in
        opened.append(root)
        _ = openA()
    }
    defer {
        for (window, repository) in windows {
            registry.unregister(window: window, projectRoot: project)
            repository.closeAllSessions(intent: .windowClosed)
        }
        registry.unregister(window: otherWindow, projectRoot: otherRoot.path)
        other.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: otherRoot)
    }
    // A CLI session a tab attaches to without owning it.
    let cli = HostedSessionInfo(
        id: "session-cli", name: "CLI", cwd: project, pid: 72,
        foreground: HostedSessionForeground(pid: 73, name: "top")
    )
    harness.fake.sessions.append(cli)
    _ = try await harness.control.list()

    /// Closes the window A has open.
    func closeA() {
        guard let (window, repository) = windows.last else { return }
        registry.unregister(window: window, projectRoot: project)
        repository.closeAllSessions(intent: .windowClosed)
    }
    /// Opens A with `makeLastTab` as its only tab, detaches it with ⌘D (the
    /// window closes), and clicks Reopen on B's toast.
    func closeLastTabAndReopen(_ makeLastTab: (TerminalWorkspace) async throws -> TerminalSession) async throws -> RepositoryWorkspace {
        closeA()
        let repository = openA()
        let workspace = repository.activeWorkspace
        let tab = try await makeLastTab(workspace)
        for shell in workspace.sessions where shell !== tab {
            workspace.close(shell, intent: .windowClosedEndingSessions)
        }
        #expect(workspace.sessions.map(\.id) == [tab.id])
        registry.activateWindow(projectRoot: otherRoot.path, workspace: other, noteStore: nil, todoStore: nil, chromeState: otherChromeState)
        let (window, _) = try #require(windows.last)
        SessionCloseCoordinator.detachSelectedTabOrWindow(
            workspace: workspace, repository: repository, chromeState: nil, window: window, registry: registry
        )
        #expect(workspace.sessions.isEmpty)
        #expect((window as? ClosingWindow)?.closeRequests == 1)
        let toast = try #require(otherChromeState.toasts.current)
        closeA()
        let count = windows.count
        otherChromeState.toasts.performAction(of: toast.id)
        #expect(await harness.fake.wait { windows.count > count })
        return try #require(windows.last?.repository)
    }

    // This app's own agent: back in A's window, opened again.
    var agentID: UUID?
    var agentSessionID: String?
    let reopenedA = try await closeLastTabAndReopen { workspace in
        let agent = workspace.addAgentSession(agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: project)
        #expect(await harness.waitUntilAttached(agent))
        agentID = agent.id
        agentSessionID = agent.persistentSession?.sessionID
        return agent
    }
    let agent = try #require(agentID)
    #expect(await harness.fake.wait { reopenedA.activeWorkspace.session(withID: agent) != nil })
    #expect(other.session(withID: agent) == nil)
    #expect(opened.count == 1)

    // A session the tab did not own: the same.
    let reopenedAgain = try await closeLastTabAndReopen { workspace in
        let tab = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: cli)))
        #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach session-cli ") } })
        return tab
    }
    #expect(await harness.fake.wait {
        reopenedAgain.activeWorkspace.sessions.contains { $0.hostedAttachment?.sessionID == "session-cli" }
    })
    #expect(!other.sessions.contains { $0.hostedAttachment?.sessionID == "session-cli" })
    #expect(opened.count == 2)
    #expect(reopenedAgain.activeWorkspace.sessions.contains { $0.hostedAttachment?.sessionID == "session-cli" && !$0.isPersistentLocalSession })
    // Only the default shells closed here were ended.
    let agentSession = try #require(agentSessionID)
    #expect(!harness.requestIDs("kill").contains(agentSession))
    #expect(!harness.requestIDs("kill").contains("session-cli"))
}
