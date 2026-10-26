import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// Closing one of several windows of a project (#22): what its question says,
// and what becomes of its saved tabs and frame. A window closed while another
// of its project stays open (or is still to open at launch) forgets them, and
// its kept sessions are Background Sessions'; the project's last window keeps
// them for the project; a quit keeps every window's. Against the fake
// `cherry control` (FakeControlHelper), private stores and defaults, and test
// registries: no window comes on screen or changes Spaces.

// MARK: - Helpers

/// Records `close()` and `performClose(_:)` instead of closing: the test
/// sends the close delegate `windowWillClose` itself, as AppKit would.
@MainActor
private final class ClosingWindow: NSWindow {
    var closeCount = 0
    var closeRequests = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
    }

    override func close() {
        closeCount += 1
    }

    override func performClose(_ sender: Any?) {
        closeRequests += 1
    }
}

/// The close delegate's sessions question, recorded and answered by the
/// test; `restore()` puts the app's back.
@MainActor
private final class Questions {
    private let askAboutSessions = ProjectWindowCloseDelegate.askAboutSessions
    private let sessionsKeptInBackground = ProjectWindowCloseDelegate.sessionsKeptInBackground
    private(set) var asked: [SessionTeardownQuestion] = []
    /// The sessions a Keep Running told the launch notice about, per answer.
    private(set) var keptInBackground: [[String]] = []
    private var pendingAnswer: (@MainActor (SessionTeardownAnswer, LocalSessionsOnQuit?) -> Void)?

    init() {
        ProjectWindowCloseDelegate.askAboutSessions = { [unowned self] question, _, answer in
            asked.append(question)
            pendingAnswer = answer
        }
        ProjectWindowCloseDelegate.sessionsKeptInBackground = { [unowned self] ids in
            keptInBackground.append(ids)
        }
    }

    func answer(_ answer: SessionTeardownAnswer) {
        let pending = pendingAnswer
        pendingAnswer = nil
        pending?(answer, nil)
    }

    func restore() {
        ProjectWindowCloseDelegate.askAboutSessions = askAboutSessions
        ProjectWindowCloseDelegate.sessionsKeptInBackground = sessionsKeptInBackground
    }
}

/// A project's windows, opened as the app opens them against `harness`'s
/// host: each claims its key in `registry`, restores and saves its tabs in
/// `store` and its frame in `frames`, and closes through its close delegate.
@MainActor
private final class ProjectWindows {
    struct Opened {
        let window: ClosingWindow
        let repository: RepositoryWorkspace
        let chromeState: ProjectWindowChromeState
        let delegate: ProjectWindowCloseDelegate

        @MainActor var workspace: TerminalWorkspace { repository.workspace }
    }

    let harness: PersistentHarness
    let root: URL
    let store: WorkspaceStateStore
    let frames: ProjectWindowFrameStore
    let registry = ProjectWindowRegistry()
    /// The windows put back into full screen as they opened.
    private(set) var enteredFullScreen: [NSWindow] = []
    private let storeDirectory: URL
    private let suite: String
    private var opened: [Opened] = []

    /// `atLaunch`: the registry reads the saved windows itself
    /// (`configureWorkspacePersistence`); else it saves to `store` from now.
    init(_ harness: PersistentHarness, name: String, atLaunch: Bool = false) throws {
        self.harness = harness
        root = try canonicalTemporaryDirectory(name)
        storeDirectory = try canonicalTemporaryDirectory(name + "-store")
        store = WorkspaceStateStore(directory: storeDirectory)
        suite = "CherryTests.\(name).\(UUID().uuidString)"
        frames = ProjectWindowFrameStore(defaults: try #require(UserDefaults(suiteName: suite)))
        registry.bringWindowForward = { _ in }
        registry.windowIsOnScreen = { _ in true }
        registry.windowRevealMaximumWait = nil
        registry.enterFullScreen = { [unowned self] window, done in
            enteredFullScreen.append(window)
            done()
        }
        registry.configureWindowFrames(frames)
        if !atLaunch { registry.setWorkspaceStateStoreForTesting(store) }
    }

    /// The project as its windows save it (`RepositoryWorkspace.repositoryRoot`).
    var key: String { repositoryKey(root) }

    /// The window `windowID` names (nil: the project's primary), as its
    /// binder opens it: it claims its key and begins restoring.
    func open(_ windowID: UUID? = nil) -> Opened {
        let repository = RepositoryWorkspace(
            projectRoot: root.path,
            windowID: windowID,
            backendPolicy: harness.policy,
            stateStore: store,
            sessionRestorer: harness.restorer,
            autoStartCommands: { _ in [] },
            restoredTabLaunchQueue: RestoredTabLaunchQueue()
        )
        let window = ClosingWindow()
        let chromeState = quietChromeState()
        #expect(registry.register(
            window: window, projectRoot: root.path, windowID: windowID,
            workspace: repository.workspace, repository: repository, todoStore: nil, chromeState: chromeState
        ))
        repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
        let delegate = ProjectWindowCloseDelegate(window: window)
        delegate.projectRoot = root.path
        delegate.workspace = repository.workspace
        delegate.repository = repository
        delegate.chromeState = chromeState
        window.delegate = delegate
        let opened = Opened(window: window, repository: repository, chromeState: chromeState, delegate: delegate)
        self.opened.append(opened)
        return opened
    }

    /// AppKit closes `opened`'s window, whose close was decided: its close
    /// delegate's `windowWillClose`.
    func didClose(_ opened: Opened) {
        opened.delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: opened.window))
    }

    /// The window's saved tabs, by tab id (nil: no file).
    func savedTabIDs(_ windowID: UUID? = nil) -> [UUID]? {
        store.flush()
        return store.load(repositoryRoot: key, windowID: windowID)?.worktrees.flatMap(\.sessions).map(\.id)
    }

    func hasStateFile(_ windowID: UUID? = nil) -> Bool {
        store.flush()
        return FileManager.default.fileExists(atPath: store.stateFileURL(repositoryRoot: key, windowID: windowID).path)
    }

    func cleanUp() {
        registry.cancelTermination()
        for opened in opened {
            registry.unregister(window: opened.window, projectRoot: root.path)
            opened.repository.closeAllSessions(intent: .windowClosed)
        }
        store.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@MainActor
private func sessionID(of tab: TerminalSession) throws -> String {
    try #require(tab.persistentSession?.sessionID)
}

private let backgroundSessionsLine = "Open or end it from Background Sessions in the Cherry menu bar icon."

// MARK: - The question

/// Closing a window while another of its project stays open keeps its
/// running sessions in Background Sessions only: its question says so, not
/// that its tabs come back. The project's last window asks as one window
/// did.
@Test @MainActor func closingAWindowWhoseProjectStaysOpenSaysItsSessionsGoToBackgroundSessions() async throws {
    let harness = try PersistentHarness()
    let questions = Questions()
    let project = try ProjectWindows(harness, name: "cherry-close-question")
    defer {
        questions.restore()
        project.cleanUp()
        harness.cleanUp()
    }
    let primary = project.open()
    let other = project.open(UUID())
    for opened in [primary, other] {
        let tab = try #require(opened.workspace.sessions.first)
        #expect(await harness.waitUntilAttached(tab))
        // A busy shell: idle ones are kept without a question.
        #expect(await harness.makeBusy(tab))
    }

    #expect(!project.registry.isLastWindowOfProject(other.window))
    #expect(!other.delegate.windowShouldClose(other.window))
    let question = try #require(questions.asked.last)
    #expect(!question.tabsComeBack)
    #expect(question.informativeText == "It keeps running after this window closes. "
        + "Open or end it from Background Sessions in the Cherry menu bar icon. "
        + "End Sessions stops its program.")
    questions.answer(.cancel)
    let second = other.workspace.addSession(title: "Second")
    #expect(await harness.waitUntilAttached(second))
    #expect(!other.delegate.windowShouldClose(other.window))
    #expect(questions.asked.last?.informativeText == "They keep running after this window closes. "
        + "Open or end them from Background Sessions in the Cherry menu bar icon. "
        + "End Sessions stops their programs.")
    questions.answer(.cancel)
    #expect(other.window.closeCount == 0)

    // The primary closed (keeping its session): the other window is the
    // project's last, and its question promises what its close does.
    project.didClose(primary)
    #expect(project.registry.isLastWindowOfProject(other.window))
    #expect(!other.delegate.windowShouldClose(other.window))
    let last = try #require(questions.asked.last)
    #expect(last.tabsComeBack)
    #expect(last.informativeText.hasPrefix(
        "They keep running after this window closes, and their tabs come back when you open \(project.root.lastPathComponent) again. "
    ))
    questions.answer(.cancel)
    // A quit's question is the same however many windows a project has, and
    // a window the registry does not know is its own project's last.
    let quit = SessionTeardownQuestion(teardown: .quit, summary: last.summary, projectName: nil, tabsComeBack: false)
    #expect(quit.informativeText.contains("their tabs come back when you open Cherry again"))
    #expect(project.registry.isLastWindowOfProject(testWindow()))
}

// MARK: - What a closed window leaves

/// A window closed while another of its project stays open forgets its
/// saved tabs and frame: its file and frame keys go, and the open window
/// list stops naming it. Keep Running leaves its sessions running (in
/// Background Sessions); End Sessions ends them.
@Test @MainActor func aWindowClosedWhileAnotherOfItsProjectStaysOpenForgetsItsTabsAndFrame() async throws {
    let harness = try PersistentHarness()
    let questions = Questions()
    let project = try ProjectWindows(harness, name: "cherry-close-forgets")
    defer {
        questions.restore()
        project.cleanUp()
        harness.cleanUp()
    }
    let keptID = UUID()
    let endedID = UUID()
    let primary = project.open()
    let kept = project.open(keptID)
    let ended = project.open(endedID)
    for opened in [primary, kept, ended] {
        let tab = try #require(opened.workspace.sessions.first)
        #expect(await harness.waitUntilAttached(tab))
        // A busy shell: idle ones are kept without a question.
        #expect(await harness.makeBusy(tab))
    }
    let keptSession = try sessionID(of: try #require(kept.workspace.sessions.first))
    let endedSession = try sessionID(of: try #require(ended.workspace.sessions.first))
    let root = project.root.path
    kept.window.setFrame(NSRect(x: 360, y: 200, width: 900, height: 560), display: false)
    project.frames.setFullScreen(true, projectRoot: root, windowID: keptID)
    #expect(project.frames.frameDescriptor(projectRoot: root, windowID: keptID) == kept.window.frameDescriptor)
    #expect(project.hasStateFile(keptID))
    #expect(project.registry.closedWindowState(
        of: ProjectWindowKey(root: root, windowID: keptID), repository: kept.repository
    ) == .forgotten)

    // Keep Running.
    #expect(!kept.delegate.windowShouldClose(kept.window))
    questions.answer(.keep)
    #expect(await eventually { kept.window.closeCount == 1 })
    project.didClose(kept)
    #expect(!project.hasStateFile(keptID))
    #expect(project.frames.frameDescriptor(projectRoot: root, windowID: keptID) == nil)
    #expect(!project.frames.isFullScreen(projectRoot: root, windowID: keptID))
    #expect(Set(project.store.loadOpenProjectWindows()) == [
        .primary(project.key), ProjectWindowValue(projectRoot: project.key, windowID: endedID)
    ])
    #expect(questions.keptInBackground == [[keptSession]])
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.sessions.contains { $0.id == keptSession && $0.isRunning })

    // End Sessions.
    #expect(!ended.delegate.windowShouldClose(ended.window))
    questions.answer(.end)
    #expect(await eventually { ended.window.closeCount == 1 })
    project.didClose(ended)
    #expect(await harness.fake.wait { harness.requestIDs("kill").contains(endedSession) })
    #expect(!harness.requestIDs("kill").contains(keptSession))
    #expect(!project.hasStateFile(endedID))
    #expect(project.store.loadOpenProjectWindows() == [.primary(project.key)])
    // The window left open is untouched.
    #expect(project.registry.hasWindow(.primary(project.key)))
    #expect(primary.workspace.sessions.count == 1)
}

/// File › New Window opens no other window of a project while its last
/// window asks to close or closes: the question promised that window's tabs
/// come back, which another window of the project opening meanwhile would
/// break (the close would forget them). A window that is not the last
/// promised nothing.
@Test @MainActor func newWindowOpensNoWindowOfAProjectWhileAWindowOfItAsksToClose() async throws {
    let harness = try PersistentHarness()
    let questions = Questions()
    let project = try ProjectWindows(harness, name: "cherry-close-new-window")
    defer {
        questions.restore()
        project.cleanUp()
        harness.cleanUp()
    }
    var opened: [ProjectWindowValue] = []
    project.registry.newProjectWindowOpener = { opened.append($0) }
    let primary = project.open()
    let tab = try #require(primary.workspace.sessions.first)
    #expect(await harness.waitUntilAttached(tab))
    #expect(await harness.makeBusy(tab))

    #expect(!primary.delegate.windowShouldClose(primary.window))
    #expect(try #require(questions.asked.last).tabsComeBack)
    #expect(!project.registry.canOpenAnotherWindow(from: primary.window))
    #expect(!project.registry.openAnotherWindow(from: primary.window))
    #expect(!project.registry.openAnotherWindow(from: nil))
    questions.answer(.cancel)
    #expect(project.registry.openAnotherWindow(from: primary.window))
    #expect(opened.count == 1)

    // Answered Keep Running: its tabs close first, then the window.
    #expect(!primary.delegate.windowShouldClose(primary.window))
    #expect(try #require(questions.asked.last).tabsComeBack)
    questions.answer(.keep)
    #expect(primary.repository.isTearingDown)
    #expect(!project.registry.openAnotherWindow(from: primary.window))
    #expect(opened.count == 1)
    #expect(await eventually { primary.window.closeCount == 1 })
    project.didClose(primary)
    // As promised, its tab comes back when the project opens again.
    #expect(project.savedTabIDs() == [tab.id])

    // Two windows: one asking to close is not the last.
    let reopened = project.open()
    let other = project.open(UUID())
    let otherTab = try #require(other.workspace.sessions.first)
    #expect(await harness.waitUntilAttached(otherTab))
    #expect(await harness.makeBusy(otherTab))
    #expect(!other.delegate.windowShouldClose(other.window))
    #expect(try #require(questions.asked.last).tabsComeBack == false)
    #expect(project.registry.openAnotherWindow(from: reopened.window))
    #expect(opened.count == 2)
    questions.answer(.cancel)
}

/// A project's commands run in one tab across its windows: a window closed
/// with Keep Running while another of its project stays open hands its
/// running command tabs to that window, with their sessions (no new
/// Create, no Kill), so a Start of the command there finds its tab, and
/// that window saves it (it comes back with that window). Its other kept
/// sessions go to Background Sessions as before.
@Test @MainActor func aWindowClosedKeepingSessionsHandsItsRunningCommandsToAnotherWindowOfItsProject() async throws {
    let harness = try PersistentHarness()
    let questions = Questions()
    let project = try ProjectWindows(harness, name: "cherry-close-hands-over-commands")
    defer {
        questions.restore()
        project.cleanUp()
        harness.cleanUp()
    }
    let command = ProjectCommandDefinition(name: "dev", command: "serve")
    let otherID = UUID()
    let opener = project.open()
    let other = project.open(otherID)
    let shell = try #require(opener.workspace.sessions.first)
    #expect(await harness.waitUntilAttached(shell))
    #expect(await harness.waitUntilAttached(try #require(other.workspace.sessions.first)))
    let dev = opener.workspace.addCommandSession(command: command, projectRoot: project.root.path, select: false)
    #expect(await harness.waitUntilAttached(dev))
    let devSession = try sessionID(of: dev)
    let shellSession = try sessionID(of: shell)
    let createsBefore = harness.creates().count

    #expect(!opener.delegate.windowShouldClose(opener.window))
    questions.answer(.keep)
    #expect(await eventually { opener.window.closeCount == 1 })
    project.didClose(opener)

    let handed = try #require(other.workspace.commandSession(named: "dev"))
    #expect(handed.id == dev.id)
    #expect(handed.persistentSession?.sessionID == devSession)
    #expect(harness.hosting.owningTab(of: devSession) === handed)
    #expect(other.workspace.selectedSession?.id != handed.id)
    #expect(harness.hosting.owningTab(of: shellSession) == nil)
    #expect(other.workspace.addCommandSession(command: command, projectRoot: project.root.path) === handed)
    #expect(await harness.fake.wait { project.savedTabIDs(otherID)?.contains(dev.id) == true })
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.creates().count == createsBefore)
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.sessions.contains { $0.id == devSession && $0.isRunning })
}

/// The project's primary window closed while another stays open: its file
/// is written empty (no tabs, saved now), never removed, so the next primary
/// window's look for orphans still knows when it was saved; its frame stays,
/// as the project opens there.
@Test @MainActor func closingThePrimaryWhileAnotherWindowStaysOpenEmptiesItsFile() async throws {
    let harness = try PersistentHarness()
    let project = try ProjectWindows(harness, name: "cherry-close-primary")
    defer {
        project.cleanUp()
        harness.cleanUp()
    }
    let otherID = UUID()
    let primary = project.open()
    let other = project.open(otherID)
    let primaryTab = try #require(primary.workspace.sessions.first)
    #expect(await harness.waitUntilAttached(primaryTab))
    #expect(await harness.waitUntilAttached(try #require(other.workspace.sessions.first)))
    primary.window.setFrame(NSRect(x: 120, y: 140, width: 800, height: 500), display: false)
    let frame = try #require(project.frames.frameDescriptor(projectRoot: project.root.path))

    let closedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    project.didClose(primary)
    let emptied = try #require(project.store.load(repositoryRoot: project.key))
    #expect(emptied.worktrees.isEmpty)
    #expect(emptied.windowID == nil)
    #expect(try #require(emptied.savedAt) >= closedAt)
    #expect(project.store.projectWindowsToReopen([.primary(project.key)]).isEmpty)
    #expect(project.frames.frameDescriptor(projectRoot: project.root.path) == frame)
    // Its session runs on; the other window and its file are untouched.
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.sessions.contains { $0.id == primaryTab.persistentSession?.sessionID && $0.isRunning })
    #expect(project.savedTabIDs(otherID) == other.workspace.sessions.map(\.id))
    #expect(project.store.loadOpenProjectWindows() == [ProjectWindowValue(projectRoot: project.key, windowID: otherID)])
}

/// The project's last window keeps its tabs for the project. Another window
/// closed last: its record becomes the primary's file (no `windowID`), its
/// own file goes, its frame and full screen move to the primary's keys, and
/// the project's next window, its primary, opens with its tabs at its frame.
/// The primary closed last keeps its own, as a project's one window did.
@Test @MainActor func theProjectsLastWindowKeepsItsTabsForTheProject() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let project = try ProjectWindows(harness, name: "cherry-close-last")
    defer {
        project.cleanUp()
        harness.cleanUp()
    }
    let root = project.root.path
    let otherID = UUID()
    let primary = project.open()
    let other = project.open(otherID)
    let otherTab = try #require(other.workspace.sessions.first)
    #expect(await harness.waitUntilAttached(try #require(primary.workspace.sessions.first)))
    #expect(await harness.waitUntilAttached(otherTab))
    let otherSession = try sessionID(of: otherTab)
    let otherFrame = NSRect(x: 360, y: 200, width: 900, height: 560)
    primary.window.setFrame(NSRect(x: 120, y: 140, width: 800, height: 500), display: false)
    other.window.setFrame(otherFrame, display: false)
    project.frames.setFullScreen(true, projectRoot: root, windowID: otherID)

    // The primary first (forgotten), then the other one, now the last.
    project.didClose(primary)
    #expect(project.registry.closedWindowState(
        of: ProjectWindowKey(root: root, windowID: otherID), repository: other.repository
    ) == .movedToPrimary(otherID))
    project.didClose(other)
    #expect(!project.hasStateFile(otherID))
    let moved = try #require(project.store.load(repositoryRoot: project.key))
    #expect(moved.windowID == nil)
    #expect(moved.worktrees.flatMap(\.sessions).map(\.id) == [otherTab.id])
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: project.store.stateFileURL(repositoryRoot: project.key)))
    #expect((json as? [String: Any])?["windowID"] == nil)
    #expect(project.frames.frameDescriptor(projectRoot: root, windowID: otherID) == nil)
    #expect(!project.frames.isFullScreen(projectRoot: root, windowID: otherID))
    #expect(project.frames.isFullScreen(projectRoot: root))
    #expect(project.store.loadOpenProjectWindows().isEmpty)
    #expect(harness.fake.sessions.contains { $0.id == otherSession && $0.isRunning })

    // The project opens again: its primary window, with those tabs, at that
    // frame, in full screen.
    let reopened = project.open()
    #expect(reopened.window.frame == otherFrame)
    #expect(project.enteredFullScreen.last === reopened.window)
    #expect(await harness.fake.wait { reopened.workspace.sessions.map(\.id) == [otherTab.id] })
    #expect(reopened.workspace.sessions.first?.persistentSession?.sessionID == otherSession)

    // The primary is the last: as a project's one window, it keeps them.
    project.didClose(reopened)
    #expect(project.savedTabIDs() == [otherTab.id])
    #expect(project.frames.frameDescriptor(projectRoot: root) != nil)
}

/// A quit keeps every window's saved tabs and frame, however many windows a
/// project has: windows that close while the app terminates change no file,
/// and the open window list keeps naming them.
@Test @MainActor func aQuitKeepsEveryWindowsSavedTabs() async throws {
    let harness = try PersistentHarness()
    let project = try ProjectWindows(harness, name: "cherry-close-quit")
    defer {
        project.cleanUp()
        harness.cleanUp()
    }
    let otherID = UUID()
    let primary = project.open()
    let other = project.open(otherID)
    for opened in [primary, other] {
        #expect(await harness.waitUntilAttached(try #require(opened.workspace.sessions.first)))
    }
    other.window.setFrame(NSRect(x: 360, y: 200, width: 900, height: 560), display: false)
    let primaryTabs = primary.workspace.sessions.map(\.id)
    let otherTabs = other.workspace.sessions.map(\.id)
    let windows = Set(project.store.loadOpenProjectWindows())
    #expect(windows == [.primary(project.key), ProjectWindowValue(projectRoot: project.key, windowID: otherID)])

    // The quit saves every window, then orders them out; any that closes
    // meanwhile is neither forgotten nor moved, though the other is open.
    project.registry.prepareForTermination()
    #expect(project.registry.closedWindowState(
        of: ProjectWindowKey(root: project.root.path, windowID: otherID), repository: other.repository
    ) == .leftAsSaved)
    project.didClose(other)
    project.didClose(primary)
    #expect(project.savedTabIDs(otherID) == otherTabs)
    #expect(project.savedTabIDs() == primaryTabs)
    #expect(Set(project.store.loadOpenProjectWindows()) == windows)
    #expect(project.frames.frameDescriptor(projectRoot: project.root.path, windowID: otherID) != nil)
}

/// At launch, a project window whose other window is still to open (it
/// has not registered) is not the project's last: its close forgets its
/// tabs and says so, and that window, once open, is the last.
@Test @MainActor func aWindowClosedBeforeAnotherOfItsProjectOpenedAtLaunchIsNotTheLast() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let questions = Questions()
    let project = try ProjectWindows(harness, name: "cherry-close-launch", atLaunch: true)
    defer {
        questions.restore()
        project.cleanUp()
        harness.cleanUp()
    }
    let otherID = UUID()
    let otherValue = ProjectWindowValue(projectRoot: project.key, windowID: otherID)
    func savedTab(_ title: String, sessionID: String) -> WorkspaceSessionRecord {
        WorkspaceSessionRecord(
            id: UUID(), kind: .terminal, title: title, titleSource: .system,
            workingDirectory: project.root.path, projectRoot: project.root.path,
            hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true)
        )
    }
    let primaryTab = savedTab("Primary", sessionID: "s-primary")
    let otherTab = savedTab("Other", sessionID: "s-other")
    for (windowID, tab) in [(nil, primaryTab), (otherID, otherTab)] as [(UUID?, WorkspaceSessionRecord)] {
        project.store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: project.key, activeWorktreeRoot: project.root.path,
            worktrees: [WorktreeStateRecord(root: project.root.path, sessions: [tab])],
            savedAt: Date(), windowID: windowID
        ))
    }
    project.store.saveOpenProjectWindows([.primary(project.key), otherValue], synchronously: true)
    harness.fake.sessions = [primaryTab, otherTab].map { tab in
        HostedSessionInfo(
            id: tab.hosted?.sessionID ?? "", name: tab.title, cwd: project.root.path, pid: 5, owner: "CherryTests",
            tags: [PersistentSessionTag.tab: tab.id.uuidString, PersistentSessionTag.project: project.root.path]
        )
    }
    let registry = project.registry
    var turns: [@MainActor () -> Void] = []
    registry.scheduleLaunchWindowTurn = { turns.append($0) }
    registry.configureWorkspacePersistence(store: project.store)
    let reopened = registry.takeProjectWindowsToReopen()
    #expect(reopened == [.primary(project.key), otherValue])
    var proceed: (@MainActor () -> Void)?
    var front: ProjectWindows.Opened?
    // Only the primary opens; the other window stays pending.
    registry.openLaunchWindows(reopened, beforeLaterWindows: { proceed = $0 }) { value in
        if value.isPrimary { front = project.open() }
    }
    let primary = try #require(front)
    #expect(registry.pendingLaunchWindows == [otherValue])
    #expect(await harness.fake.wait { primary.workspace.sessions.map(\.id) == [primaryTab.id] })
    let shell = primary.workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(shell))
    #expect(await harness.makeBusy(shell))

    #expect(!registry.isLastWindowOfProject(primary.window))
    #expect(!primary.delegate.windowShouldClose(primary.window))
    #expect(questions.asked.last?.tabsComeBack == false)
    questions.answer(.keep)
    #expect(await eventually { primary.window.closeCount == 1 })
    project.didClose(primary)
    let emptied = try #require(project.store.load(repositoryRoot: project.key))
    #expect(!emptied.hasSessions)
    #expect(project.savedTabIDs(otherID) == [otherTab.id])
    // Still to open, it is still saved as open.
    #expect(project.store.loadOpenProjectWindows() == [otherValue])

    // It opens: the project's last window, with its own tabs.
    let other = project.open(otherID)
    #expect(registry.pendingLaunchWindows.isEmpty)
    #expect(registry.isLastWindowOfProject(other.window))
    #expect(await harness.fake.wait { other.workspace.sessions.map(\.id) == [otherTab.id] })
    // The launch finishes (it has nothing left to open).
    #expect(await eventually { proceed != nil })
    let proceedNow = try #require(proceed)
    proceedNow()
    while !turns.isEmpty { turns.removeFirst()() }
}

/// A window of a device Cherry no longer knows keeps its saved tabs exactly
/// as saved: closing it, or another window of its project, changes no file
/// and no frame.
@Test @MainActor func aDeviceCherryNoLongerKnowsKeepsItsWindowsSavedTabs() async throws {
    let storeDirectory = try canonicalTemporaryDirectory("cherry-close-unknown-device")
    let suite = "CherryTests.UnknownDeviceWindowFrames.\(UUID().uuidString)"
    let frames = ProjectWindowFrameStore(defaults: try #require(UserDefaults(suiteName: suite)))
    let store = WorkspaceStateStore(directory: storeDirectory)
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let otherID = UUID()
    let hosting = RemoteDeviceStore.unavailableHosting(for: key, reason: "Not among your devices.", instanceLock: nil)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.windowRevealMaximumWait = nil
    registry.configureWindowFrames(frames)
    registry.setWorkspaceStateStoreForTesting(store)
    var opened: [(window: ClosingWindow, repository: RepositoryWorkspace, delegate: ProjectWindowCloseDelegate)] = []
    defer {
        for (window, repository, _) in opened {
            registry.unregister(window: window, projectRoot: key)
            repository.closeAllSessions(intent: .windowClosed)
        }
        store.flush()
        try? FileManager.default.removeItem(at: storeDirectory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    var saved: [UUID?: WorkspaceSessionRecord] = [:]
    for windowID in [nil, otherID] as [UUID?] {
        let record = WorkspaceSessionRecord(
            id: UUID(), kind: .terminal, title: "Shell", workingDirectory: "/Users/me/app", projectRoot: key,
            hosted: HostedSessionBindingRecord(host: "ssh:studio", hostID: "h", sessionID: "s-\(windowID?.uuidString ?? "primary")", owned: true),
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
        saved[windowID] = record
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: key, activeWorktreeRoot: key, worktrees: [WorktreeStateRecord(root: key, sessions: [record])],
            savedAt: Date(timeIntervalSince1970: 1_000), windowID: windowID
        ))
        let repository = RepositoryWorkspace(
            projectRoot: key,
            windowID: windowID,
            backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil),
            stateStore: store,
            sessionRestorer: RemoteDeviceStore.keepingRestorer,
            autoStartCommands: { _ in [] },
            restoredTabLaunchQueue: RestoredTabLaunchQueue()
        )
        let window = ClosingWindow()
        #expect(registry.register(
            window: window, projectRoot: key, windowID: windowID,
            workspace: repository.workspace, repository: repository, todoStore: nil, chromeState: nil
        ))
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await repository.waitForPendingRestores()
        let delegate = ProjectWindowCloseDelegate(window: window)
        delegate.projectRoot = key
        delegate.workspace = repository.workspace
        delegate.repository = repository
        window.delegate = delegate
        opened.append((window, repository, delegate))
    }
    #expect(opened.allSatisfy { $0.repository.remoteHosting == nil })
    opened[1].window.setFrame(NSRect(x: 360, y: 200, width: 900, height: 560), display: false)
    let otherFrame = try #require(frames.frameDescriptor(projectRoot: key, windowID: otherID))

    // The other window, then the primary, the last.
    for (window, repository, delegate) in opened.reversed() {
        #expect(registry.closedWindowState(of: try #require(registry.key(of: window)), repository: repository) == .leftAsSaved)
        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }
    store.flush()
    for windowID in [nil, otherID] as [UUID?] {
        let state = try #require(store.load(repositoryRoot: key, windowID: windowID))
        #expect(state.worktrees.flatMap(\.sessions).map(\.hosted) == [saved[windowID]?.hosted])
    }
    #expect(frames.frameDescriptor(projectRoot: key, windowID: otherID) == otherFrame)
}

// MARK: - Toasts

/// ⌘D on a window's last tab closes the window; when another window of its
/// project was active last, the toast goes there, and its Reopen brings the
/// session back into that window (the closed one forgot its tabs).
@Test @MainActor func closingTheLastTabOfOneWindowShowsItsToastInTheOther() async throws {
    let harness = try PersistentHarness()
    let project = try ProjectWindows(harness, name: "cherry-close-last-tab")
    defer {
        project.cleanUp()
        harness.cleanUp()
    }
    let otherID = UUID()
    let primary = project.open()
    let other = project.open(otherID)
    let tab = try #require(other.workspace.sessions.first)
    #expect(await harness.waitUntilAttached(try #require(primary.workspace.sessions.first)))
    #expect(await harness.waitUntilAttached(tab))
    let session = try sessionID(of: tab)
    let name = sidebarName(of: tab)
    let registry = project.registry
    registry.activateWindow(primary.window, workspace: primary.workspace, todoStore: nil, chromeState: primary.chromeState)
    registry.activateWindow(other.window, workspace: other.workspace, todoStore: nil, chromeState: other.chromeState)

    SessionCloseCoordinator.detachSelectedTabOrWindow(
        workspace: other.workspace, repository: other.repository, chromeState: other.chromeState,
        window: other.window, registry: registry
    )
    #expect(other.workspace.sessions.isEmpty)
    #expect(other.window.closeRequests == 1)
    #expect(other.chromeState.toasts.current == nil)
    let toast = try #require(primary.chromeState.toasts.current)
    #expect(toast.title == "\(name) is running in the background")
    #expect(toast.message == backgroundSessionsLine)
    #expect(toast.action?.title == "Reopen")
    // AppKit closes it: another window of its project stays open.
    project.didClose(other)
    #expect(!project.hasStateFile(otherID))

    primary.chromeState.toasts.performAction(of: toast.id)
    #expect(await harness.fake.wait { primary.workspace.session(withID: tab.id) != nil })
    #expect(harness.hosting.owningTab(of: session)?.id == tab.id)
    #expect(primary.workspace.selectedSessionID == tab.id)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
}
