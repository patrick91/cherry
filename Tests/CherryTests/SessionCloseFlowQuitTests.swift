import AppKit
import Foundation
import Testing
@testable import Cherry

// Closing a project window or quitting with local persistent sessions
// running asks once whether to keep them running or end them
// (docs/specs/multiplexer-default.md, "Quit and window close"): the
// decision, the question, the quit reasons that never ask, and the window
// close against the fake `cherry control` (FakeControlHelper).

// MARK: - The decision

@MainActor
private func summary(
    running: [Bool] = [],
    ended: Int = 0,
    nativeBusy: Int = 0
) -> SessionTeardownSummary {
    let sessions = running.enumerated().map { index, busy in
        SessionTeardownSummary.Session(
            id: UUID(), hostSessionID: "s-\(index)", title: "Tab \(index)", place: nil, isBusy: busy
        )
    }
    return SessionTeardownSummary(
        runningSessions: sessions.filter(\.isBusy) + sessions.filter { !$0.isBusy },
        persistentTabCount: running.count + ended,
        stoppedWhenKeeping: nativeBusy,
        stoppedWhenEnding: nativeBusy + running.filter { $0 }.count
    )
}

@Test @MainActor func aWindowCloseOrQuitAsksOnlyWhenSessionsRunAndThePreferenceAsks() {
    let cases: [(String, SessionTeardownSummary)] = [
        ("nothing", summary()),
        ("idle sessions", summary(running: [false, false])),
        ("busy sessions", summary(running: [true, false])),
        ("only ended persistent tabs", summary(ended: 2))
    ]
    for (name, base) in cases {
        for nativeBusy in [0, 1] {
            var summary = base
            summary.stoppedWhenKeeping = nativeBusy
            summary.stoppedWhenEnding = base.stoppedWhenEnding + nativeBusy
            let running = !summary.runningSessions.isEmpty
            for mayAsk in [true, false] {
                let label = Comment(rawValue: "\(name), native busy \(nativeBusy), may ask \(mayAsk)")
                let keeping: SessionTeardownConfirmation = nativeBusy > 0
                    ? .confirmStopping(count: nativeBusy, endsSessions: false)
                    : .none(endsSessions: false)

                // Asked only when sessions run, the preference asks, and
                // the quit is the user's.
                #expect(SessionTeardownConfirmation.decide(summary, preference: .ask, mayAsk: mayAsk)
                    == (mayAsk && running ? .askAboutSessions : keeping), label)
                #expect(SessionTeardownConfirmation.decide(summary, preference: .keep, mayAsk: mayAsk) == keeping, label)
                // Ending them stops the busy ones too; a log out, restart,
                // shut down or update keeps them whatever the preference.
                let ending: SessionTeardownConfirmation = summary.stoppedWhenEnding > 0
                    ? .confirmStopping(count: summary.stoppedWhenEnding, endsSessions: true)
                    : .none(endsSessions: true)
                #expect(SessionTeardownConfirmation.decide(summary, preference: .end, mayAsk: mayAsk)
                    == (mayAsk ? ending : keeping), label)
            }

            // A log out, restart or shut down keeps sessions and asks nothing
            // about them, but the system then ends their programs: busy ones
            // are confirmed with the native ones, whatever the preference.
            let loggingOut: SessionTeardownConfirmation = summary.stoppedWhenEnding > 0
                ? .confirmStopping(count: summary.stoppedWhenEnding, endsSessions: false)
                : .none(endsSessions: false)
            for preference in LocalSessionsOnQuit.allCases {
                #expect(
                    SessionTeardownConfirmation.decide(
                        summary, preference: preference, mayAsk: false, systemEndsSessions: true
                    ) == loggingOut,
                    Comment(rawValue: "\(name), native busy \(nativeBusy), log out, \(preference)")
                )
            }
        }
    }

    // Summaries of several windows add up, busy sessions first.
    let first = summary(running: [false])
    let second = summary(running: [true], ended: 1, nativeBusy: 2)
    let total = first + second
    #expect(total.runningSessions.map(\.id) == second.runningSessions.map(\.id) + first.runningSessions.map(\.id))
    #expect(total.persistentTabCount == 3)
    #expect(total.stoppedWhenKeeping == 2)
    #expect(total.stoppedWhenEnding == 3)
}

@Test func aQuitGoesOnAsItsDecisionAndAnswerSay() {
    var idle = SessionTeardownSummary()
    // Nothing to stop or end: quit at once, keeping what runs.
    #expect(SessionQuitPlan(.none(endsSessions: false), summary: idle) == .terminateNow)
    #expect(SessionQuitPlan(.none(endsSessions: true), summary: idle) == .terminateNow)
    // Ending sessions: idle persistent tabs, or only saved tabs no open tab
    // shows, are ended before the app goes.
    idle.persistentTabCount = 2
    #expect(SessionQuitPlan(.none(endsSessions: false), summary: idle) == .terminateNow)
    #expect(SessionQuitPlan(.none(endsSessions: true), summary: idle) == .finish(.appQuitEndingSessions))
    let savedOnly = SessionTeardownSummary(savedSessionsNotOpen: 1)
    #expect(SessionQuitPlan(.none(endsSessions: true), summary: savedOnly) == .finish(.appQuitEndingSessions))
    #expect(SessionQuitPlan(.none(endsSessions: false), summary: savedOnly) == .terminateNow)
    #expect((savedOnly + savedOnly).savedSessionsNotOpen == 2)
    // "Quit Cherry?" tears down with the intent the preference picked.
    #expect(SessionQuitPlan(.confirmStopping(count: 2, endsSessions: false), summary: idle)
        == .confirmStopping(count: 2, intent: .appQuit))
    #expect(SessionQuitPlan(.confirmStopping(count: 3, endsSessions: true), summary: idle)
        == .confirmStopping(count: 3, intent: .appQuitEndingSessions))
    #expect(SessionQuitPlan(.askAboutSessions, summary: idle) == .askAboutSessions)

    // Answered or confirmed: keeping sessions with no native program to
    // stop quits at once, as a quit with nothing running does; a native
    // program to stop, sessions to end, or sessions still being ended,
    // tear down and wait first.
    #expect(SessionQuitPlan.confirmed(.appQuit, nativeProgramsStopped: 0) == .terminateNow)
    #expect(SessionQuitPlan.confirmed(.appQuit, nativeProgramsStopped: 2) == .finish(.appQuit))
    #expect(SessionQuitPlan.confirmed(.appQuit, nativeProgramsStopped: 0, endingSessions: true) == .finish(.appQuit))
    #expect(SessionQuitPlan.confirmed(.appQuitEndingSessions, nativeProgramsStopped: 0) == .finish(.appQuitEndingSessions))
    #expect(SessionQuitPlan.confirmed(.appQuitEndingSessions, nativeProgramsStopped: 1) == .finish(.appQuitEndingSessions))

    // The question's answer closes with its intent; Cancel closes nothing.
    #expect(SessionTeardown.quit.intent(for: .keep) == .appQuit)
    #expect(SessionTeardown.quit.intent(for: .end) == .appQuitEndingSessions)
    #expect(SessionTeardown.quit.intent(for: .cancel) == nil)
    #expect(SessionTeardown.windowClose.intent(for: .keep) == .windowClosed)
    #expect(SessionTeardown.windowClose.intent(for: .end) == .windowClosedEndingSessions)
    #expect(SessionTeardown.windowClose.intent(for: .cancel) == nil)
    // Only those two end the sessions of saved tabs no open tab shows.
    #expect(SessionCloseIntent.allCases.filter(\.endsLocalSessions) == [.windowClosedEndingSessions, .appQuitEndingSessions])
    #expect(SessionCloseIntent.allCases.filter(\.isAppQuit) == [.appQuit, .appQuitEndingSessions])
}

// MARK: - The question

@Test @MainActor func theSessionsQuestionSaysWhatKeepingAndEndingDo() throws {
    let one = SessionTeardownSummary(
        runningSessions: [.init(id: UUID(), hostSessionID: "s-1", title: "zsh", place: "cherry", isBusy: false)],
        persistentTabCount: 1
    )
    let quit = SessionTeardownQuestion(teardown: .quit, summary: one, projectName: nil).makeAlert()
    #expect(quit.messageText == "Keep 1 session running in the background?")
    #expect(quit.informativeText == "It keeps running after Cherry quits, and its tab comes back when you open Cherry again. End Sessions stops its program.")
    #expect(quit.buttons.map(\.title) == ["Keep Running", "End Sessions", "Cancel"])
    #expect(!quit.buttons[0].hasDestructiveAction)
    #expect(quit.buttons[1].hasDestructiveAction)
    #expect(quit.buttons[0].keyEquivalent == "\r")
    #expect(quit.buttons[2].keyEquivalent == "\u{1b}")
    #expect(quit.showsSuppressionButton)
    #expect(quit.suppressionButton?.title == "Don't ask again")
    #expect(quit.alertStyle == .informational)
    #expect((quit.accessoryView as? NSTextField)?.stringValue == "• zsh — cherry")

    // Seven sessions, two busy, and a busy native tab, in a window.
    let many = SessionTeardownSummary(
        runningSessions: (0..<7).map { index in
            .init(id: UUID(), hostSessionID: nil, title: "Tab \(index)", place: nil, isBusy: index < 2)
        },
        persistentTabCount: 7,
        stoppedWhenKeeping: 1,
        stoppedWhenEnding: 3
    )
    let window = SessionTeardownQuestion(teardown: .windowClose, summary: many, projectName: "posthog")
    let alert = window.makeAlert()
    #expect(alert.messageText == "Keep 7 sessions running in the background?")
    #expect(alert.informativeText == "They keep running after this window closes, and their tabs come back when you open posthog again. Until then, open or end them from Background Sessions in the Cherry menu bar icon. End Sessions stops their programs.\n\nThis window has 1 other running process. It will be stopped.")
    #expect(alert.alertStyle == .warning)
    #expect(window.sessionList == """
    • Tab 0 (running)
    • Tab 1 (running)
    • Tab 2
    • Tab 3
    • Tab 4
    and 2 more
    """)

    var more = many
    more.stoppedWhenKeeping = 3
    #expect(SessionTeardownQuestion(teardown: .windowClose, summary: more, projectName: "posthog").informativeText
        .hasSuffix("This window has 3 other running processes. They will be stopped."))
    #expect(SessionTeardownQuestion(teardown: .quit, summary: more, projectName: nil).informativeText
        == "They keep running after Cherry quits, and their tabs come back when you open Cherry again. End Sessions stops their programs.\n\n3 other running processes will be stopped.")
    more.stoppedWhenKeeping = 1
    #expect(SessionTeardownQuestion(teardown: .quit, summary: more, projectName: nil).informativeText
        .hasSuffix("\n\n1 other running process will be stopped."))
    #expect(SessionTeardownQuestion(teardown: .windowClose, summary: one, projectName: "cherry").informativeText
        == "It keeps running after this window closes, and its tab comes back when you open cherry again. Until then, open or end it from Background Sessions in the Cherry menu bar icon. End Sessions stops its program.")
}

@Test func theSessionsQuestionsAnswerRemembersOnlyAChoice() {
    func answer(_ response: NSApplication.ModalResponse, _ suppressed: Bool) -> (SessionTeardownAnswer, LocalSessionsOnQuit?) {
        let answered = SessionTeardownQuestion.answer(for: response, suppressed: suppressed)
        return (answered.answer, answered.remember)
    }
    #expect(answer(.alertFirstButtonReturn, false) == (.keep, nil))
    #expect(answer(.alertSecondButtonReturn, false) == (.end, nil))
    #expect(answer(.alertThirdButtonReturn, false) == (.cancel, nil))
    #expect(answer(.cancel, false) == (.cancel, nil))
    // "Don't ask again" stores Keep Running or End Sessions, never Cancel.
    #expect(answer(.alertFirstButtonReturn, true) == (.keep, .keep))
    #expect(answer(.alertSecondButtonReturn, true) == (.end, .end))
    #expect(answer(.alertThirdButtonReturn, true) == (.cancel, nil))
    #expect(answer(.stop, true) == (.cancel, nil))
}

// MARK: - Quits that never ask

private func quitEvent(reason: OSType?, asParameter: Bool = false, enumerated: Bool = false) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor.appleEvent(
        withEventClass: AEEventClass(kCoreEventClass),
        eventID: AEEventID(kAEQuitApplication),
        targetDescriptor: nil,
        returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID)
    )
    if let reason {
        let descriptor = enumerated ? NSAppleEventDescriptor(enumCode: reason) : NSAppleEventDescriptor(typeCode: reason)
        if asParameter {
            event.setParam(descriptor, forKeyword: AEKeyword(kAEQuitReason))
        } else {
            event.setAttribute(descriptor, forKeyword: AEKeyword(kAEQuitReason))
        }
    }
    return event
}

@Test func quitReasonIsPowerOffForLogoutRestartAndShutdownAndUpdateWhenTheBundleWasReplaced() throws {
    func reason(
        _ event: NSAppleEventDescriptor?,
        launch: String? = "20260926120000.abc1234",
        disk: String? = "20260926120000.abc1234",
        announced: Bool = false,
        requested: Bool = false
    ) -> CherryAppDelegate.QuitReason {
        CherryAppDelegate.quitReason(
            appleEvent: event, launchBundleVersion: launch, diskBundleVersion: disk,
            powerOffAnnounced: announced, updateRequested: requested
        )
    }
    // Log out, restart and shut down, however the quit event says so.
    for code in [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown] {
        let label = Comment(rawValue: "reason \(code)")
        #expect(reason(quitEvent(reason: OSType(code))) == .powerOff, label)
        #expect(reason(quitEvent(reason: OSType(code), asParameter: true)) == .powerOff, label)
        #expect(reason(quitEvent(reason: OSType(code), enumerated: true)) == .powerOff, label)
    }
    // ⌘Q sends no event; the Dock and AppleScript send one without a reason.
    #expect(reason(nil) == .user)
    #expect(reason(quitEvent(reason: nil)) == .user)
    #expect(reason(quitEvent(reason: OSType(kAEQuitAll))) == .user)
    let open = NSAppleEventDescriptor.appleEvent(
        withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
    )
    open.setAttribute(NSAppleEventDescriptor(typeCode: OSType(kAERestart)), forKeyword: AEKeyword(kAEQuitReason))
    #expect(reason(open) == .user)
    // The system announced it (`willPowerOffNotification`): a quit event
    // that says no reason counts, never ⌘Q or a menu's Quit (no event),
    // which may come minutes after a log out another app cancelled.
    #expect(reason(quitEvent(reason: nil), announced: true) == .powerOff)
    #expect(reason(nil, announced: true) == .user)
    #expect(reason(open, announced: true) == .user)

    // The app on disk was replaced by another build while it ran, or an
    // updater asked.
    #expect(reason(nil, disk: "20260926130000.def5678") == .update)
    #expect(reason(nil, requested: true) == .update)
    // No bundle (`swift run`), or it was removed: nothing tells.
    #expect(reason(nil, launch: nil, disk: nil) == .user)
    #expect(reason(nil, disk: nil) == .user)

    // The version is read from the bundle on disk.
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Quit-\(UUID().uuidString).app")
    defer { try? FileManager.default.removeItem(at: bundle) }
    #expect(CherryAppDelegate.bundleVersionOnDisk(bundleURL: bundle) == nil)
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleVersion": "20260926120000.abc1234"], format: .xml, options: 0
    )
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    #expect(CherryAppDelegate.bundleVersionOnDisk(bundleURL: bundle) == "20260926120000.abc1234")
}

// MARK: - Closing a window

/// Counts closes instead of closing.
@MainActor
private final class ClosingWindow: NSWindow {
    var closeCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
    }

    override func close() {
        closeCount += 1
    }
}

/// The window close delegate's dialogs, recorded; restored by `restore()`.
@MainActor
private final class CloseDialogs {
    private let askAboutSessions = ProjectWindowCloseDelegate.askAboutSessions
    private let confirmStoppingProcesses = ProjectWindowCloseDelegate.confirmStoppingProcesses
    private let sessionsKeptInBackground = ProjectWindowCloseDelegate.sessionsKeptInBackground
    private(set) var questions: [SessionTeardownQuestion] = []
    /// The sessions a Keep Running told the launch notice about, per answer.
    private(set) var keptInBackground: [[String]] = []
    private(set) var stoppingCounts: [Int] = []
    private var pendingAnswer: (@MainActor (SessionTeardownAnswer, LocalSessionsOnQuit?) -> Void)?
    private var pendingResponse: (@MainActor (NSApplication.ModalResponse) -> Void)?

    init() {
        ProjectWindowCloseDelegate.askAboutSessions = { [unowned self] question, _, answer in
            self.questions.append(question)
            self.pendingAnswer = answer
        }
        ProjectWindowCloseDelegate.confirmStoppingProcesses = { [unowned self] _, count, answer in
            self.stoppingCounts.append(count)
            self.pendingResponse = answer
        }
        ProjectWindowCloseDelegate.sessionsKeptInBackground = { [unowned self] ids in
            self.keptInBackground.append(ids)
        }
    }

    /// Answers the sessions question on screen.
    func answer(_ answer: SessionTeardownAnswer, remember: LocalSessionsOnQuit? = nil) {
        let pending = pendingAnswer
        pendingAnswer = nil
        pending?(answer, remember)
    }

    /// Answers "Close window?" on screen.
    func respond(_ response: NSApplication.ModalResponse) {
        let pending = pendingResponse
        pendingResponse = nil
        pending?(response)
    }

    func restore() {
        ProjectWindowCloseDelegate.askAboutSessions = askAboutSessions
        ProjectWindowCloseDelegate.confirmStoppingProcesses = confirmStoppingProcesses
        ProjectWindowCloseDelegate.sessionsKeptInBackground = sessionsKeptInBackground
    }
}

@MainActor
private func closeDelegate(for window: NSWindow, workspace: TerminalWorkspace) -> ProjectWindowCloseDelegate {
    let delegate = ProjectWindowCloseDelegate(window: window)
    delegate.workspace = workspace
    return delegate
}

/// The window closed without its close confirmation (`window.close()`).
@MainActor
private func closeWithoutConfirmation(_ window: NSWindow, delegate: ProjectWindowCloseDelegate) {
    delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
}

@MainActor
private func sessionIDs(_ tabs: [TerminalSession]) throws -> [String] {
    try tabs.map { try #require($0.persistentSession?.sessionID) }
}

/// A workspace whose "Don't ask again" answers are recorded (and become the
/// harness's preference, as the app's settings do).
@MainActor
private func rememberingWorkspace(_ harness: PersistentHarness, remembered: Recorder<[LocalSessionsOnQuit]>) -> TerminalWorkspace {
    var policy = harness.policy
    let settings = harness.settings
    policy.rememberLocalSessionsOnQuit = { choice in
        remembered.value.append(choice)
        settings.value.localSessionsOnQuit = choice
    }
    return TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: policy)
}

@Test @MainActor func aWindowCloseAsksAboutItsRunningSessionsOnceAndKeepsThemOnKeepRunning() async throws {
    let harness = try PersistentHarness()
    let dialogs = CloseDialogs()
    let workspace = harness.workspace()
    defer {
        dialogs.restore()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let shell = workspace.addSession(title: "Shell")
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "npm", arguments: "run dev"),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(shell))
    #expect(await harness.waitUntilAttached(command))
    let window = ClosingWindow()
    let delegate = closeDelegate(for: window, workspace: workspace)

    #expect(!delegate.windowShouldClose(window))
    // Asked again while the question is up (a second click): one question.
    #expect(!delegate.windowShouldClose(window))
    #expect(dialogs.questions.count == 1)
    let question = try #require(dialogs.questions.first)
    #expect(question.teardown == .windowClose)
    #expect(question.projectName == harness.project.lastPathComponent)
    #expect(question.summary.runningSessions.map(\.id) == [command.id, shell.id])
    #expect(question.summary.runningSessions.map(\.isBusy) == [true, false])
    #expect(question.summary.runningSessions.map(\.hostSessionID) == (try sessionIDs([command, shell])))
    // Named as the sidebar names them.
    #expect(question.summary.runningSessions.map(\.title) == [command, shell].map {
        SidebarSessionLabel.label(for: $0, pathDisplayMode: TerminalSettings.shared.sidebarTerminalPathDisplayMode).title
    })
    #expect(question.summary.runningSessions.first?.title == "server")
    #expect(question.summary.stoppedWhenKeeping == 0)
    #expect(dialogs.stoppingCounts.isEmpty)
    #expect(workspace.sessions.count == 2)
    #expect(window.closeCount == 0)

    // Keep Running: the tabs close detaching; their sessions run on, and
    // the window closes.
    let kept = Set(try sessionIDs([command, shell]))
    dialogs.answer(.keep)
    #expect(workspace.sessions.isEmpty)
    #expect(workspace.closeAllIntent == .windowClosed)
    #expect(await harness.fake.wait { window.closeCount == 1 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.requests("remove").isEmpty)
    #expect(harness.fake.sessions.filter { kept.contains($0.id) && $0.isRunning }.count == 2)
    #expect(harness.settings.value.localSessionsOnQuit == .ask)
    // They are in the background now, which the user knows: the launch
    // notice does not name them.
    #expect(dialogs.keptInBackground.map(Set.init) == [kept])
    // Confirmed: closing now asks nothing more.
    #expect(delegate.windowShouldClose(window))
    #expect(dialogs.questions.count == 1)
}

@Test @MainActor func aWindowCloseEndingSessionsEndsThemAndRemembersDontAskAgain() async throws {
    let harness = try PersistentHarness()
    let dialogs = CloseDialogs()
    let remembered = Recorder<[LocalSessionsOnQuit]>([])
    var workspaces: [TerminalWorkspace] = []
    defer {
        dialogs.restore()
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    func openWindow(_ titles: [String], command: Bool = false) async throws -> (TerminalWorkspace, [TerminalSession]) {
        let workspace = rememberingWorkspace(harness, remembered: remembered)
        workspaces.append(workspace)
        var tabs = titles.map { workspace.addSession(title: $0) }
        if command {
            tabs.append(workspace.addCommandSession(
                command: ProjectCommandDefinition(name: "server", command: "serve"),
                projectRoot: harness.project.path
            ))
        }
        for tab in tabs {
            #expect(await harness.waitUntilAttached(tab))
        }
        return (workspace, tabs)
    }

    // End Sessions with "Don't ask again".
    let (workspace, tabs) = try await openWindow(["One", "Two"])
    let ended = try sessionIDs(tabs)
    let window = ClosingWindow()
    let delegate = closeDelegate(for: window, workspace: workspace)
    #expect(!delegate.windowShouldClose(window))
    #expect(dialogs.questions.count == 1)
    dialogs.answer(.end, remember: .end)
    #expect(workspace.closeAllIntent == .windowClosedEndingSessions)
    #expect(dialogs.keptInBackground.isEmpty)
    #expect(await harness.fake.wait { Set(harness.requestIDs("remove")).isSuperset(of: ended) })
    #expect(Set(harness.requestIDs("kill")) == Set(ended))
    #expect(remembered.value == [.end])
    #expect(await harness.fake.wait { window.closeCount == 1 })

    // The next window asks nothing and ends its sessions ...
    let (next, nextTabs) = try await openWindow(["Three"])
    let nextSession = try sessionIDs(nextTabs)
    let nextWindow = ClosingWindow()
    let nextDelegate = closeDelegate(for: nextWindow, workspace: next)
    #expect(nextDelegate.windowShouldClose(nextWindow))
    closeWithoutConfirmation(nextWindow, delegate: nextDelegate)
    #expect(next.closeAllIntent == .windowClosedEndingSessions)
    #expect(await harness.fake.wait { Set(harness.requestIDs("remove")).isSuperset(of: nextSession) })

    // ... and a busy one it would stop asks only "Close window?".
    let (busy, busyTabs) = try await openWindow([], command: true)
    let busySession = try sessionIDs(busyTabs)
    let busyWindow = ClosingWindow()
    let busyDelegate = closeDelegate(for: busyWindow, workspace: busy)
    #expect(!busyDelegate.windowShouldClose(busyWindow))
    #expect(dialogs.stoppingCounts == [1])
    dialogs.respond(.alertFirstButtonReturn)
    #expect(busy.closeAllIntent == .windowClosedEndingSessions)
    #expect(await harness.fake.wait { Set(harness.requestIDs("remove")).isSuperset(of: busySession) })
    #expect(await harness.fake.wait { busyWindow.closeCount == 1 })

    // Keep Running without asking.
    harness.settings.value.localSessionsOnQuit = .keep
    let (keeping, keepingTabs) = try await openWindow(["Four"], command: true)
    let keptSessions = try sessionIDs(keepingTabs)
    let keepingWindow = ClosingWindow()
    let keepingDelegate = closeDelegate(for: keepingWindow, workspace: keeping)
    #expect(keepingDelegate.windowShouldClose(keepingWindow))
    closeWithoutConfirmation(keepingWindow, delegate: keepingDelegate)
    #expect(keeping.closeAllIntent == .windowClosed)
    try await Task.sleep(for: .milliseconds(200))
    #expect(Set(harness.requestIDs("kill")).isDisjoint(with: keptSessions))
    #expect(dialogs.questions.count == 1)
    #expect(dialogs.stoppingCounts == [1])
    #expect(remembered.value == [.end])
    // Kept because the user chose so in Settings › Sessions: the launch
    // notice does not name them.
    #expect(dialogs.keptInBackground.map(Set.init) == [Set(keptSessions)])
}

@Test @MainActor func aWindowWithOnlyEndedOrNativeTabsNeverAsksAboutSessions() async throws {
    let harness = try PersistentHarness()
    let dialogs = CloseDialogs()
    let remembered = Recorder<[LocalSessionsOnQuit]>([])
    let workspace = rememberingWorkspace(harness, remembered: remembered)
    defer {
        dialogs.restore()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // A persistent tab whose program ended, and a busy native tab.
    let ended = workspace.addSession(title: "Ended")
    #expect(await harness.waitUntilAttached(ended))
    harness.exit(try #require(ended.persistentSession?.sessionID), code: 3)
    #expect(await harness.fake.wait { ended.state == .exited(3) })
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "cat", command: "/bin/cat"),
        projectRoot: harness.project.path
    )
    harness.settings.value.persistLocalSessions = true
    #expect(!native.isPersistentLocalSession)
    #expect(native.hasRunningProcess())
    let window = ClosingWindow()
    let delegate = closeDelegate(for: window, workspace: workspace)

    // Only "Close window?" for the native program; cancelled, nothing closes.
    #expect(!delegate.windowShouldClose(window))
    #expect(dialogs.questions.isEmpty)
    #expect(dialogs.stoppingCounts == [1])
    dialogs.respond(.alertSecondButtonReturn)
    #expect(workspace.sessions.count == 2)
    #expect(window.closeCount == 0)

    // A running session makes it the sessions question; Cancel there keeps
    // every tab and the window, and stores nothing.
    let running = workspace.addSession(title: "Running")
    #expect(await harness.waitUntilAttached(running))
    #expect(!delegate.windowShouldClose(window))
    #expect(dialogs.questions.map { $0.summary.runningSessions.map(\.id) } == [[running.id]])
    #expect(dialogs.stoppingCounts == [1])
    dialogs.answer(.cancel)
    #expect(workspace.sessions.count == 3)
    #expect(native.isRunning)
    #expect(window.closeCount == 0)
    #expect(remembered.value.isEmpty)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.requests("remove").isEmpty)
    #expect(window.closeCount == 0)
}

@Test @MainActor func aWindowCloseQuestionListsBusyAndIdleSessionsAndMentionsNativeProcessesInOneDialog() async throws {
    let harness = try PersistentHarness()
    let dialogs = CloseDialogs()
    let workspace = harness.workspace()
    defer {
        dialogs.restore()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let idle = workspace.addSession(title: "Idle")
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(idle))
    #expect(await harness.waitUntilAttached(agent))
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "cat", command: "/bin/cat"),
        projectRoot: harness.project.path
    )
    harness.settings.value.persistLocalSessions = true
    #expect(native.hasRunningProcess())
    let window = ClosingWindow()
    let delegate = closeDelegate(for: window, workspace: workspace)

    #expect(!delegate.windowShouldClose(window))
    #expect(dialogs.questions.count == 1)
    #expect(dialogs.stoppingCounts.isEmpty)
    let question = try #require(dialogs.questions.first)
    #expect(question.summary.runningSessions.map(\.id) == [agent.id, idle.id])
    #expect(question.summary.stoppedWhenKeeping == 1)
    #expect(question.messageText == "Keep 2 sessions running in the background?")
    #expect(question.informativeText.hasSuffix("This window has 1 other running process. It will be stopped."))
    let titles = [agent, idle].map {
        SidebarSessionLabel.label(for: $0, pathDisplayMode: TerminalSettings.shared.sidebarTerminalPathDisplayMode).title
    }
    #expect(question.sessionList == "• \(titles[0]) (running)\n• \(titles[1])")

    // Keep Running: the native program stops, the sessions run on.
    dialogs.answer(.keep)
    #expect(!native.isRunning)
    #expect(await harness.fake.wait { window.closeCount == 1 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func aWindowClosingWithItsLastTabAfterACleanExitAsksNothing() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let dialogs = CloseDialogs()
    let workspace = harness.workspace()
    defer {
        dialogs.restore()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let window = ClosingWindow()
    let delegate = closeDelegate(for: window, workspace: workspace)
    workspace.closeTabAfterCleanExit = { workspace, session in
        SessionCloseCoordinator.closeTabAfterCleanExit(session, in: workspace, repository: nil, window: window)
    }
    let tab = workspace.addSession(title: "Only")
    #expect(await harness.waitUntilAttached(tab))

    // The shell exits: its tab closes, and the window's close finds nothing
    // to ask about.
    harness.exit(try #require(tab.persistentSession?.sessionID), code: 0)
    #expect(await harness.fake.wait { workspace.sessions.isEmpty })
    #expect(delegate.windowShouldClose(window))
    #expect(dialogs.questions.isEmpty)
    #expect(dialogs.stoppingCounts.isEmpty)
}

@Test @MainActor func aProjectWindowsLastTabClosesTheWindowThroughItsCloseDelegateWhenItsShellExits() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let dialogs = CloseDialogs()
    let root = try canonicalDirectory("cherry-clean-exit-window")
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let chromeState = ProjectWindowChromeState()
    let window = ClosingWindow()
    let delegate = ProjectWindowCloseDelegate(window: window)
    delegate.workspace = repository.activeWorkspace
    delegate.repository = repository
    window.delegate = delegate
    defer {
        dialogs.restore()
        registry.unregister(window: window, projectRoot: root.path)
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
    }
    // As the app's window binder does: the window claims the project, and
    // the repository learns its chrome state.
    #expect(registry.register(
        window: window, projectRoot: root.path, workspace: repository.activeWorkspace, repository: repository,
        noteStore: nil, todoStore: nil, chromeState: chromeState
    ))
    repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
    let workspace = repository.activeWorkspace
    let shell = try #require(workspace.sessions.first)
    #expect(await harness.waitUntilAttached(shell))
    let sessionID = try #require(shell.persistentSession?.sessionID)

    // Its shell exits: the tab closes and removes its ended session, then
    // the window closes through its close delegate, which finds nothing to
    // ask about.
    harness.exit(sessionID, code: 0)
    #expect(await harness.fake.wait { window.closeCount == 1 })
    #expect(workspace.sessions.isEmpty)
    #expect(dialogs.questions.isEmpty)
    #expect(dialogs.stoppingCounts.isEmpty)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(sessionID) })
    #expect(!harness.requestIDs("kill").contains(sessionID))
    closeWithoutConfirmation(window, delegate: delegate)
    #expect(workspace.closeAllIntent == .windowClosed)
}

@Test @MainActor func aWindowClosedWithoutItsConfirmationFollowsThePreferenceAndKeepsWhenItWouldAsk() async throws {
    let harness = try PersistentHarness()
    let dialogs = CloseDialogs()
    var workspaces: [TerminalWorkspace] = []
    defer {
        dialogs.restore()
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    for (preference, intent) in [
        (LocalSessionsOnQuit.ask, SessionCloseIntent.windowClosed),
        (.keep, .windowClosed),
        (.end, .windowClosedEndingSessions)
    ] {
        harness.settings.value.localSessionsOnQuit = preference
        let workspace = harness.workspace()
        workspaces.append(workspace)
        let tab = workspace.addSession(title: "\(preference)")
        #expect(await harness.waitUntilAttached(tab))
        let sessionID = try #require(tab.persistentSession?.sessionID)
        let window = ClosingWindow()
        let told = dialogs.keptInBackground.count
        closeWithoutConfirmation(window, delegate: closeDelegate(for: window, workspace: workspace))
        let label = Comment(rawValue: "\(preference)")
        #expect(workspace.closeAllIntent == intent, label)
        await harness.hosting.waitForPendingEnds(timeout: .seconds(3))
        #expect(harness.requestIDs("kill").contains(sessionID) == (intent == .windowClosedEndingSessions), label)
        // Only the preference that keeps sessions is a choice to keep them;
        // kept because nothing asked, the launch notice may name it.
        #expect(Array(dialogs.keptInBackground.dropFirst(told)) == (preference == .keep ? [[sessionID]] : []), label)
    }
}

@Test @MainActor func aUserQuitWaitsForTheAnswerToAWindowsCloseQuestion() async throws {
    let harness = try PersistentHarness()
    let dialogs = CloseDialogs()
    let workspace = harness.workspace()
    defer {
        dialogs.restore()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let shell = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(shell))
    let other = ClosingWindow()
    let window = ClosingWindow()
    let delegate = closeDelegate(for: window, workspace: workspace)
    window.delegate = delegate
    func waiting(_ reason: CherryAppDelegate.QuitReason) -> NSWindow? {
        CherryAppDelegate.windowToAnswerBeforeQuitting(reason: reason, among: [other, window])
    }
    #expect(waiting(.user) == nil)

    // The window asks about its sessions: a quit of the user's waits for
    // that answer (it would keep or end them, and a quit question queued
    // behind it would still list them); a log out, restart, shut down or
    // update never waits.
    #expect(!delegate.windowShouldClose(window))
    #expect(dialogs.questions.count == 1)
    #expect(waiting(.user) === window)
    #expect(waiting(.powerOff) == nil)
    #expect(waiting(.update) == nil)
    dialogs.answer(.cancel)
    #expect(waiting(.user) == nil)

    // So does "Close window?".
    harness.settings.value.localSessionsOnQuit = .end
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    #expect(!delegate.windowShouldClose(window))
    #expect(dialogs.stoppingCounts == [1])
    #expect(waiting(.user) === window)
    dialogs.respond(.alertSecondButtonReturn)
    #expect(waiting(.user) == nil)
    #expect(window.closeCount == 0)

    // And so does a tab close's question, "Close “server”?": answered
    // Detach Instead, the session a quit question queued behind it would
    // list goes to the background, where no End Sessions reaches it.
    let chromeState = ProjectWindowChromeState()
    delegate.chromeState = chromeState
    SessionCloseCoordinator.close(command, in: workspace, chromeState: chromeState)
    let request = try #require(chromeState.pendingTabClose)
    #expect(waiting(.user) === window)
    #expect(waiting(.powerOff) == nil)
    SessionCloseCoordinator.answerTabClose(.cancel, to: request, chromeState: chromeState)
    #expect(waiting(.user) == nil)
    // "Close Agent Group?" too.
    chromeState.requestAgentGroupClose(sessionID: command.id)
    #expect(waiting(.user) === window)
    chromeState.pendingAgentGroupCloseSessionID = nil
    #expect(waiting(.user) == nil)
}

// MARK: - Quitting

@Test @MainActor func theQuitSummaryCountsEveryWindowsRunningSessionsAndEndingThemTerminatesThem() async throws {
    let harness = try PersistentHarness()
    let rootA = try canonicalDirectory("cherry-quit-a")
    let rootB = try canonicalDirectory("cherry-quit-b")
    let repository = RepositoryWorkspace(
        projectRoot: rootA.path,
        backendPolicy: harness.policy,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    let plain = TerminalWorkspace(projectRoot: rootB.path, createInitialSession: false, backendPolicy: harness.policy)
    let registry = ProjectWindowRegistry()
    let windowA = ClosingWindow()
    let windowB = ClosingWindow()
    defer {
        registry.cancelTermination()
        registry.unregister(window: windowA, projectRoot: rootA.path)
        registry.unregister(window: windowB, projectRoot: rootB.path)
        repository.closeAllSessions(intent: .windowClosed)
        plain.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
    }
    let shell = try #require(repository.activeWorkspace.sessions.first)
    let command = repository.activeWorkspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve"), projectRoot: rootA.path
    )
    let other = plain.addSession(title: "Other")
    for tab in [shell, command, other] {
        #expect(await harness.waitUntilAttached(tab))
    }
    #expect(registry.register(
        window: windowA, projectRoot: rootA.path, workspace: repository.activeWorkspace, repository: repository,
        noteStore: nil, todoStore: nil, chromeState: nil
    ))
    #expect(registry.register(
        window: windowB, projectRoot: rootB.path, workspace: plain,
        noteStore: nil, todoStore: nil, chromeState: nil
    ))

    let summary = registry.teardownSummary(pathDisplayMode: .repoFocused)
    #expect(summary.runningSessions.first?.id == command.id)
    #expect(Set(summary.runningSessions.map(\.id)) == [shell.id, command.id, other.id])
    #expect(Set(summary.runningSessions.map(\.place)) == [
        repository.repositoryName, MenuBarAgentPresentation.projectName(projectRoot: rootB.path)
    ])
    #expect(summary.persistentTabCount == 3)
    #expect(summary.stoppedWhenKeeping == 0)
    #expect(summary.stoppedWhenEnding == 1)
    #expect(SessionTeardownConfirmation.decide(summary, preference: .ask, mayAsk: true) == .askAboutSessions)

    // End Sessions.
    let sessions = try sessionIDs([shell, command, other])
    registry.tearDownForQuit(intent: .appQuitEndingSessions)
    #expect(repository.activeWorkspace.closeAllIntent == .appQuitEndingSessions)
    #expect(plain.closeAllIntent == .appQuitEndingSessions)
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(3)))
    #expect(Set(harness.requestIDs("kill")) == Set(sessions))
    #expect(Set(harness.requestIDs("remove")) == Set(sessions))
}

/// A confirmed quit's teardown steps, recorded
/// (`CherryAppDelegate.tearDownForQuit`).
@MainActor
private final class RecordedQuitSteps {
    private(set) var events: [String] = []
    private(set) var slept: [Duration] = []
    /// The tabs the workspace held when the windows left the screen.
    private(set) var tabsWhenOffScreen: Int?

    func steps(watching workspace: TerminalWorkspace, hosting: PersistentLocalSessions) -> QuitTeardownSteps {
        QuitTeardownSteps(
            takeWindowsOffScreen: { [unowned self] in
                events.append("off screen")
                tabsWhenOffScreen = workspace.sessions.count
            },
            waitForLaunches: { [unowned self] _ in events.append("launches") },
            waitForEnds: { [unowned self] timeout in
                events.append("ends")
                await hosting.waitForPendingEnds(timeout: timeout)
            },
            sleep: { [unowned self] duration in
                events.append("sleep")
                slept.append(duration)
            }
        )
    }

    func replied() {
        events.append("reply")
    }
}

@MainActor
private func register(_ workspace: TerminalWorkspace, in registry: ProjectWindowRegistry, window: NSWindow) -> Bool {
    registry.register(
        window: window, projectRoot: workspace.projectRoot, workspace: workspace,
        noteStore: nil, todoStore: nil, chromeState: nil
    )
}

@Test @MainActor func aQuitEndingSessionsTakesTheWindowsOffScreenBeforeItsTeardownAndWaitsOnlyForTheEndings() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let registry = ProjectWindowRegistry()
    let window = ClosingWindow()
    defer {
        registry.cancelTermination()
        registry.unregister(window: window, projectRoot: harness.project.path)
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let shell = workspace.addSession(title: "Shell")
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve"), projectRoot: harness.project.path
    )
    for tab in [shell, command] {
        #expect(await harness.waitUntilAttached(tab))
    }
    // A session the CLI created, attached without owning it.
    let cli = HostedSessionInfo(id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 77, clients: 1)
    harness.fake.sessions.append(cli)
    _ = try await harness.control.list()
    let attached = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: cli)), info: cli)
    #expect(await harness.fake.wait { attached.usesNativePTYBackend })
    #expect(register(workspace, in: registry, window: window))
    #expect(CherryAppDelegate.confirmedQuitPlan(
        .appQuitEndingSessions, registry: registry, localSessions: harness.hosting
    ) == .finish(.appQuitEndingSessions))

    let sessions = try sessionIDs([shell, command])
    let recorded = RecordedQuitSteps()
    var replied = false
    CherryAppDelegate.tearDownForQuit(
        intent: .appQuitEndingSessions,
        registry: registry,
        steps: recorded.steps(watching: workspace, hosting: harness.hosting)
    ) {
        recorded.replied()
        replied = true
    }
    // The window left the screen before any tab was torn down; the
    // teardown then ran at once, and the waits follow.
    #expect(recorded.tabsWhenOffScreen == 3)
    #expect(recorded.events == ["off screen"])
    #expect(workspace.sessions.isEmpty)
    #expect(workspace.closeAllIntent == .appQuitEndingSessions)
    #expect(!shell.isRunning)
    #expect(!command.isRunning)
    // The tab attached to a session it does not own only disconnects, as
    // the app's exit does: it is left to it.
    #expect(attached.isRunning)
    #expect(await harness.fake.wait { replied })
    // No native program was stopped: no escalation to wait for.
    #expect(recorded.events == ["off screen", "launches", "ends", "reply"])
    #expect(recorded.slept.isEmpty)
    #expect(Set(harness.requestIDs("kill")) == Set(sessions))
    #expect(Set(harness.requestIDs("remove")) == Set(sessions))
}

@Test @MainActor func keepRunningQuitsAtOnceUnlessNativeProgramsStopAndThenLeavesPersistentTabsToTheExit() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let registry = ProjectWindowRegistry()
    let window = ClosingWindow()
    defer {
        registry.cancelTermination()
        registry.unregister(window: window, projectRoot: harness.project.path)
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let shell = workspace.addSession(title: "Shell")
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    for tab in [shell, agent] {
        #expect(await harness.waitUntilAttached(tab))
    }
    #expect(register(workspace, in: registry, window: window))

    // Keep Running with only persistent tabs: nothing to stop, so the quit
    // goes at once, tearing nothing down (their adapters end with the app).
    #expect(registry.runningProcessCount(endingWith: .appQuit) == 0)
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .terminateNow)

    // Unless a session is still being ended: a tab closed just before.
    let closed = workspace.addSession(title: "Closed")
    #expect(await harness.waitUntilAttached(closed))
    let closedID = try #require(closed.persistentSession?.sessionID)
    workspace.close(closed, intent: .userClosedTab)
    #expect(harness.hosting.hasPendingEnds)
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .finish(.appQuit))
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(3)))
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .terminateNow)

    // A native program to stop: the quit tears down first.
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "cat", command: "/bin/cat"),
        projectRoot: harness.project.path
    )
    harness.settings.value.persistLocalSessions = true
    #expect(native.hasRunningProcess())
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .finish(.appQuit))

    let recorded = RecordedQuitSteps()
    var replied = false
    CherryAppDelegate.tearDownForQuit(
        intent: .appQuit,
        registry: registry,
        steps: recorded.steps(watching: workspace, hosting: harness.hosting)
    ) {
        recorded.replied()
        replied = true
    }
    #expect(recorded.tabsWhenOffScreen == 3)
    #expect(workspace.sessions.isEmpty)
    #expect(workspace.closeAllIntent == .appQuit)
    // The native program stops; the persistent tabs are left as they are:
    // their adapters still run, and their sessions keep running.
    #expect(!native.isRunning)
    for tab in [shell, agent] {
        #expect(tab.isRunning)
        #expect(tab.usesNativePTYBackend)
        #expect(tab.persistentSession != nil)
    }
    #expect(await harness.fake.wait { replied })
    // The native program's HUP → TERM → KILL escalation is waited out.
    #expect(recorded.events == ["off screen", "launches", "ends", "sleep", "reply"])
    let slept = try #require(recorded.slept.first)
    #expect(slept > .zero && slept <= ShellProcessController.terminationEscalationDuration)
    // Only the session of the tab closed before the quit was ended.
    #expect(harness.requestIDs("kill") == [closedID])

    // A later teardown closes the tabs left to the exit, with its intent.
    workspace.closeAllSessions(intent: .windowClosed)
    #expect(!shell.isRunning)
    #expect(!agent.isRunning)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.requestIDs("kill") == [closedID])
}

@Test @MainActor func aKeepingQuitThatTearsDownToEndASessionDoesNotWaitForAnIdleNativeShellsEscalation() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let registry = ProjectWindowRegistry()
    let window = ClosingWindow()
    defer {
        registry.cancelTermination()
        registry.unregister(window: window, projectRoot: harness.project.path)
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let shell = workspace.addSession(title: "Shell")
    let closed = workspace.addSession(title: "Closed")
    for tab in [shell, closed] {
        #expect(await harness.waitUntilAttached(tab))
    }
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addSession(title: "Native")
    harness.settings.value.persistLocalSessions = true
    #expect(native.isRunning)
    // Its shell reaches its prompt: idle.
    #expect(await harness.fake.wait(timeout: 10) { !native.hasRunningProcess() })
    #expect(register(workspace, in: registry, window: window))

    // A session still being ended takes the quit through its teardown.
    let closedID = try #require(closed.persistentSession?.sessionID)
    workspace.close(closed, intent: .userClosedTab)
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .finish(.appQuit))
    let recorded = RecordedQuitSteps()
    var replied = false
    CherryAppDelegate.tearDownForQuit(
        intent: .appQuit,
        registry: registry,
        steps: recorded.steps(watching: workspace, hosting: harness.hosting)
    ) {
        recorded.replied()
        replied = true
    }
    #expect(!native.isRunning)
    #expect(await harness.fake.wait { replied })
    // The idle shell was hung up, as the exit would: no escalation to wait
    // out, only the ending.
    #expect(recorded.events == ["off screen", "launches", "ends", "reply"])
    #expect(recorded.slept.isEmpty)
    #expect(harness.requestIDs("kill") == [closedID])
}

@Test @MainActor func keepRunningWaitsForTheCreateOfATabClosedWhileItWasUnderWay() async throws {
    let harness = try PersistentHarness()
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = harness.workspace()
    let registry = ProjectWindowRegistry()
    let window = ClosingWindow()
    defer {
        registry.cancelTermination()
        registry.unregister(window: window, projectRoot: harness.project.path)
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    #expect(register(workspace, in: registry, window: window))
    let tab = workspace.addSession(title: "Cold")
    #expect(await harness.fake.wait { held.isHeld })
    // An open tab's Create under way keeps what it makes: nothing to wait for.
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .terminateNow)

    // ⌘W before it answered: nothing can undo that close, and the session
    // is ended once the Create answers. Quitting at once would leave it
    // running with no tab and no record, so the quit waits for it.
    SessionCloseCoordinator.closeTab(
        tab, in: workspace, chromeState: ProjectWindowChromeState(), allowEmptyWorkspace: true, registry: registry
    )
    #expect(workspace.sessions.isEmpty)
    #expect(!harness.hosting.hasPendingEnds)
    #expect(!harness.hosting.hasDeferredEnds)
    #expect(CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .finish(.appQuit))

    // The Create answers: its session is ended, and then the quit goes at once.
    let request = try #require(harness.creates().first)
    let info = HostedSessionInfo(
        id: "session-late", name: "Cold", cwd: harness.project.path, pid: 85, owner: "CherryTests",
        tags: request.json["tags"] as? [String: String] ?? [:]
    )
    harness.fake.sessions.append(info)
    held.answer(.created(info))
    #expect(await harness.fake.wait { harness.requestIDs("kill").contains("session-late") })
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(3)))
    #expect(await harness.fake.wait {
        CherryAppDelegate.confirmedQuitPlan(.appQuit, registry: registry, localSessions: harness.hosting) == .terminateNow
    })
}

@Test @MainActor func aWindowClosedKeepingItsSessionsLeavesTheScreenBeforeItsTabsAreTornDown() async throws {
    let harness = try PersistentHarness()
    let dialogs = CloseDialogs()
    let takeOffScreen = ProjectWindowCloseDelegate.takeOffScreen
    var workspaces: [TerminalWorkspace] = []
    defer {
        ProjectWindowCloseDelegate.takeOffScreen = takeOffScreen
        dialogs.restore()
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    // Keep Running in its question, and the preference keeping sessions
    // without asking.
    for answering in [true, false] {
        let label = Comment(rawValue: answering ? "Keep Running" : "preference")
        harness.settings.value.localSessionsOnQuit = answering ? .ask : .keep
        let workspace = harness.workspace()
        workspaces.append(workspace)
        let tab = workspace.addSession(title: "Shell")
        #expect(await harness.waitUntilAttached(tab), label)
        let window = ClosingWindow()
        let delegate = closeDelegate(for: window, workspace: workspace)
        var tabsWhenOffScreen: [Int] = []
        ProjectWindowCloseDelegate.takeOffScreen = { closing in
            #expect(closing === window, label)
            tabsWhenOffScreen.append(workspace.sessions.count)
        }
        if answering {
            #expect(!delegate.windowShouldClose(window), label)
            #expect(tabsWhenOffScreen.isEmpty, label)
            dialogs.answer(.keep)
        } else {
            #expect(delegate.windowShouldClose(window), label)
            closeWithoutConfirmation(window, delegate: delegate)
        }
        // Off screen once, with its tab still there; then torn down.
        #expect(tabsWhenOffScreen == [1], label)
        #expect(workspace.sessions.isEmpty, label)
        #expect(workspace.closeAllIntent == .windowClosed, label)
    }
}

@Test @MainActor func endingAWindowsSessionsAlsoEndsThoseOfItsSavedTabsNoOpenTabShows() async throws {
    let root = try canonicalDirectory("cherry-end-saved")
    let storeDirectory = try canonicalDirectory("cherry-end-saved-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    // A worktree the window has not restored (not discovered yet) saved a
    // tab whose session still runs.
    let feature = root.appendingPathComponent("feature", isDirectory: true).path
    let saved = WorkspaceSessionRecord(
        id: UUID(), kind: .command, title: "server", commandName: "server", workingDirectory: feature,
        projectRoot: feature,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "s-feature", owned: true)
    )
    let store = WorkspaceStateStore(directory: storeDirectory)

    for (answer, ends) in [(SessionCloseIntent.windowClosed, false), (.windowClosedEndingSessions, true)] {
        let label = Comment(rawValue: "\(answer)")
        let harness = try PersistentHarness()
        defer { harness.cleanUp() }
        harness.fake.sessions = [HostedSessionInfo(
            id: "s-feature", name: "server", cwd: feature, pid: 31, owner: "CherryTests",
            tags: [PersistentSessionTag.tab: saved.id.uuidString, PersistentSessionTag.kind: "command"]
        )]
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path,
            activeWorktreeRoot: root.path,
            worktrees: [
                WorktreeStateRecord(root: root.path, sessions: []),
                WorktreeStateRecord(root: feature, sessions: [saved])
            ]
        ))
        let repository = RepositoryWorkspace(
            projectRoot: root.path,
            backendPolicy: harness.policy,
            stateStore: store,
            sessionRestorer: harness.restorer,
            autoStartCommands: { _ in [] },
            restoredTabLaunchQueue: RestoredTabLaunchQueue()
        )
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await repository.waitForPendingRestores()
        // A quit that ends sessions counts it, so it ends it even when no
        // open tab has a session to end (`SessionQuitPlan`).
        #expect(repository.teardownSummary(.quit, pathDisplayMode: .repoFocused).savedSessionsNotOpen == 1, label)
        repository.flushPersistentState()
        repository.closeAllSessions(intent: answer)

        if ends {
            #expect(await harness.fake.wait { harness.requestIDs("remove").contains("s-feature") }, label)
            #expect(harness.requestIDs("kill").contains("s-feature"), label)
            // Recorded to end until it is gone, then no more.
            #expect(await harness.fake.wait {
                store.flush()
                return store.loadSessionsToEnd().isEmpty
            }, label)
        } else {
            try await Task.sleep(for: .milliseconds(300))
            #expect(!harness.requestIDs("kill").contains("s-feature"), label)
            store.flush()
            #expect(store.loadSessionsToEnd().isEmpty, label)
        }
        // The saved tab stays either way; the next restore drops it once its
        // session is gone.
        store.flush()
        let state = store.load(repositoryRoot: repository.repositoryRoot)
        #expect(state?.worktree(root: feature)?.sessions.map(\.id) == [saved.id], label)
    }
}

private func canonicalDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = try #require(url.path.withCString { realpath($0, nil) })
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

// MARK: - Quits the system ends sessions after

@Test @MainActor func onlyAPowerOffQuitEventIsRecordedAndOnQuitEndRecordsItsSessionsAsEnded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-system-quit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)
    // Only a quit event that names a log out, restart or shut down; not one
    // without a reason, which counts as a power off only because the system
    // announced one (a log out another app may have cancelled).
    for code in [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown] {
        #expect(CherryAppDelegate.isPowerOffQuit(quitEvent(reason: OSType(code))))
    }
    #expect(!CherryAppDelegate.isPowerOffQuit(quitEvent(reason: nil)))
    #expect(!CherryAppDelegate.isPowerOffQuit(nil))

    let asked = Recorder(0)
    let ending: () -> [(hostID: String, sessionID: String)] = {
        asked.value += 1
        return [(hostID: "host-a", sessionID: "s1")]
    }
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Shell", workingDirectory: "/",
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "s1", owned: true)
    )
    CherryAppDelegate.recordSystemQuit(isPowerOffEvent: false, onQuit: .end, store: store, sessionsEndedByAQuit: ending)
    #expect(store.loadSystemQuits().isEmpty)
    #expect(asked.value == 0)
    // Keep Running (or Ask): the quit is recorded, its sessions are not ended.
    CherryAppDelegate.recordSystemQuit(isPowerOffEvent: true, onQuit: .keep, store: store, sessionsEndedByAQuit: ending)
    #expect(store.loadSystemQuits().count == 1)
    #expect(asked.value == 0)
    #expect(!store.wasEndedOnPurpose(record))
    // End Sessions: as after ⌘Q, their tabs do not come back.
    CherryAppDelegate.recordSystemQuit(isPowerOffEvent: true, onQuit: .end, store: store, sessionsEndedByAQuit: ending)
    #expect(store.loadSystemQuits().count == 2)
    #expect(asked.value == 1)
    #expect(store.wasEndedOnPurpose(record))

    // The launch hands the store to the local sessions, which record what
    // they end.
    let localSessions = PersistentLocalSessions(owner: "CherryTests", installationUnavailableReason: { "tests" })
    #expect(localSessions.endedSessionsStore == nil)
    CherryAppDelegate.configureSessionRecords(localSessions: localSessions, store: store)
    #expect(localSessions.endedSessionsStore === store)
}
