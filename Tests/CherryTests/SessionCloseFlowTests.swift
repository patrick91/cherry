import AppKit
import Foundation
import Testing
@testable import Cherry

// ⌘W and ⌘D on a window's last tab, the close question, and tabs that
// close because their shell exited, for local tabs that run as persistent
// sessions (docs/specs/multiplexer-default.md, "Close intents"). Against the
// fake `cherry control` (FakeControlHelper).

/// Records `performClose` instead of closing.
@MainActor
private final class RecordingWindow: NSWindow {
    var closeRequests = 0
    /// Stands for a sheet on the window.
    var presentedSheet: NSWindow?

    override var attachedSheet: NSWindow? { presentedSheet }

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

@Test @MainActor func commandWOnAWindowsLastPersistentTabEndsItsSessionAsATabCloseThenClosesTheWindow() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Server")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let window = RecordingWindow()

    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: nil, window: window)
    // The tab closed as the user closing it (its session ends, and its
    // idle shell asks nothing), and then the window: nothing is left for
    // the window's teardown to detach, save and bring back.
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
    #expect(await harness.fake.wait { harness.fake.requests("kill").contains { $0.string("id") == sessionID } })
    #expect(workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: []).sessions.isEmpty)
}

@Test @MainActor func commandDOnTheLastTabDetachesItsSessionThenClosesTheWindow() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Server")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let window = RecordingWindow()

    SessionCloseCoordinator.detachSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: nil, window: window)
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.sessions.contains { $0.id == sessionID && $0.isRunning })
    // Not saved to come back with the window: it is in the background.
    #expect(workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: []).sessions.isEmpty)
}

@Test @MainActor func commandWOnTheLastTabAsksBeforeItStopsABusyProgramThenClosesTheWindow() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "npm", arguments: "run dev"),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    #expect(command.hasRunningProcess())
    let chromeState = ProjectWindowChromeState()
    let window = RecordingWindow()
    func closeLastTab() throws -> TabCloseRequest {
        SessionCloseCoordinator.closeSelectedTabOrWindow(
            workspace: workspace, repository: nil, chromeState: chromeState, window: window
        )
        // "Close “server”?" is up; nothing closed yet.
        let request = try #require(chromeState.pendingTabClose)
        #expect(request.sessionID == command.id)
        #expect(request.closingWindow === window)
        #expect(request.allowEmptyWorkspace)
        #expect(workspace.sessions.count == 1)
        #expect(window.closeRequests == 0)
        return request
    }

    // Cancelled: the tab and the window stay.
    SessionCloseCoordinator.answerTabClose(.cancel, to: try closeLastTab(), chromeState: chromeState)
    #expect(chromeState.pendingTabClose == nil)
    #expect(workspace.sessions.count == 1)
    #expect(window.closeRequests == 0)
    #expect(harness.fake.requests("kill").isEmpty)

    // Close: the command stops with its tab, then the window closes.
    SessionCloseCoordinator.answerTabClose(.close, to: try closeLastTab(), chromeState: chromeState)
    #expect(chromeState.pendingTabClose == nil)
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
    #expect(await harness.fake.wait { !harness.fake.requests("kill").isEmpty })
}

@Test @MainActor func commandWOnARunningAgentsLastTabDetachedInsteadKeepsItRunningAndClosesTheWindow() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    let sessionID = try #require(agent.persistentSession?.sessionID)
    let chromeState = ProjectWindowChromeState()
    let window = RecordingWindow()

    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: chromeState, window: window)
    // The one question, "Close “Claude”?", with Detach Instead.
    let request = try #require(chromeState.pendingTabClose)
    let question = try #require(SessionCloseCoordinator.question(for: request))
    #expect(question.informativeText == "This agent is running. Closing the tab stops it.")
    #expect(question.buttonTitles == ["Close", "Detach Instead", "Cancel"])
    // A second ⌘W while it is up asks nothing more.
    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: chromeState, window: window)
    #expect(chromeState.pendingTabClose?.id == request.id)

    SessionCloseCoordinator.answerTabClose(.detach, to: request, chromeState: chromeState)
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.sessions.contains { $0.id == sessionID && $0.isRunning })
}

@Test @MainActor func aLastTabsCloseAnsweredWhileItsQuestionsSheetIsStillOnTheWindowClosesItOnceTheSheetWent() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "npm", arguments: "run dev"),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    let chromeState = ProjectWindowChromeState()
    let window = RecordingWindow()
    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: chromeState, window: window)
    let request = try #require(chromeState.pendingTabClose)

    // `NSAlert` answers while its sheet is still on the window, which
    // ignores a close until then: the window closes once it went.
    window.presentedSheet = NSWindow()
    SessionCloseCoordinator.answerTabClose(.close, to: request, chromeState: chromeState)
    #expect(workspace.sessions.isEmpty)
    try await Task.sleep(for: .milliseconds(100))
    #expect(window.closeRequests == 0)
    window.presentedSheet = nil
    #expect(await harness.fake.wait { window.closeRequests == 1 })

    // Not when a tab came meanwhile.
    let next = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "worker", command: "npm", arguments: "run worker"),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(next))
    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: chromeState, window: window)
    window.presentedSheet = NSWindow()
    SessionCloseCoordinator.answerTabClose(.close, to: try #require(chromeState.pendingTabClose), chromeState: chromeState)
    let reopened = workspace.addSession(title: "Shell")
    window.presentedSheet = nil
    try await Task.sleep(for: .milliseconds(100))
    #expect(window.closeRequests == 1)
    #expect(workspace.sessions.map(\.id) == [reopened.id])
}

/// The first button titled `title` in `view`'s hierarchy.
@MainActor
private func button(titled title: String, in view: NSView?) -> NSButton? {
    guard let view else { return nil }
    if let button = view as? NSButton, button.title == title { return button }
    return view.subviews.lazy.compactMap { button(titled: title, in: $0) }.first
}

@Test @MainActor func answeringALastTabsCloseQuestionInItsRealSheetClosesTheWindow() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    for answer in [TabCloseQuestion.closeButtonTitle, TabCloseQuestion.detachButtonTitle] {
        let command = workspace.addCommandSession(
            command: ProjectCommandDefinition(name: "server", command: "npm", arguments: "run dev"),
            projectRoot: harness.project.path
        )
        #expect(await harness.waitUntilAttached(command))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let chromeState = ProjectWindowChromeState()
        let presenter = TabCloseAlertPresenterView()
        presenter.chromeState = chromeState
        window.contentView?.addSubview(presenter)
        window.orderFrontRegardless()
        defer {
            window.attachedSheet?.close()
            window.close()
        }

        // ⌘W on the window's last tab: its question comes as a sheet.
        SessionCloseCoordinator.closeSelectedTabOrWindow(
            workspace: workspace, repository: nil, chromeState: chromeState, window: window
        )
        presenter.presentIfNeeded()
        #expect(await harness.fake.wait { window.attachedSheet != nil }, "\(answer)")
        let choice = try #require(button(titled: answer, in: window.attachedSheet?.contentView), "\(answer)")
        choice.performClick(nil)

        // The tab closes (or detaches), and so does the window.
        #expect(await harness.fake.wait(timeout: 2) { !window.isVisible }, "\(answer)")
        #expect(workspace.sessions.isEmpty, "\(answer)")
    }
}

@Test @MainActor func commandWWithOtherTabsClosesOnlyTheSelectedTab() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let first = workspace.addSession(title: "One")
    let second = workspace.addSession(title: "Two")
    #expect(await harness.waitUntilAttached(first))
    #expect(await harness.waitUntilAttached(second))
    workspace.select(second)
    let window = RecordingWindow()

    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: nil, window: window)
    #expect(workspace.sessions.map(\.id) == [first.id])
    #expect(window.closeRequests == 0)
}

// MARK: - The close question

@Test @MainActor func theCloseQuestionNamesTheTabAndWhatRunsAndOffersDetachOnlyWhenTheTabCan() throws {
    let persistent = TabCloseQuestion(tabName: "server", program: "npm run dev", canDetach: true)
    #expect(persistent.messageText == "Close “server”?")
    #expect(persistent.informativeText == "npm run dev is running. Closing the tab stops it.")
    #expect(persistent.buttonTitles == ["Close", "Detach Instead", "Cancel"])
    let alert = persistent.makeAlert()
    #expect(alert.messageText == persistent.messageText)
    #expect(alert.informativeText == persistent.informativeText)
    #expect(alert.alertStyle == .warning)
    #expect(alert.buttons.map(\.title) == persistent.buttonTitles)
    #expect(alert.buttons[0].hasDestructiveAction)
    #expect(persistent.answer(for: .alertFirstButtonReturn) == .close)
    #expect(persistent.answer(for: .alertSecondButtonReturn) == .detach)
    #expect(persistent.answer(for: .alertThirdButtonReturn) == .cancel)
    #expect(persistent.answer(for: .cancel) == .cancel)

    // A native tab's program cannot outlive its tab: Close or Cancel.
    let native = TabCloseQuestion(tabName: "vim", program: "A program", canDetach: false)
    #expect(native.buttonTitles == ["Close", "Cancel"])
    #expect(native.makeAlert().buttons.map(\.title) == ["Close", "Cancel"])
    #expect(native.answer(for: .alertSecondButtonReturn) == .cancel)

    // What runs: an agent is "This agent", a command its command line.
    let policy = SessionBackendPolicy(settings: { .defaults })
    let agent = TerminalSession(title: "Claude", subtitle: "", tint: .systemOrange, launchShell: false, kind: .agent)
    #expect(TabCloseQuestion.program(of: agent, policy: policy) == "This agent")
    let shell = TerminalSession(title: "zsh", subtitle: "", tint: .systemOrange, launchShell: false)
    #expect(TabCloseQuestion.program(of: shell, policy: policy) == "A program")
    #expect(!SessionCloseCoordinator.canDetach(agent))
    #expect(!SessionCloseCoordinator.canDetach(shell))
}

@Test func aNativeShellIsBusyOnlyWhileAJobHasItsPTYsForeground() {
    func process(
        _ pid: pid_t, parent: pid_t, group: pid_t, foreground: pid_t, _ name: String
    ) -> ShellProcessController.ProcessSnapshotEntry {
        ShellProcessController.ProcessSnapshotEntry(
            pid: pid, parentPID: parent, processGroupID: group, controllingTTY: 7,
            foregroundProcessGroupID: foreground, name: name
        )
    }
    func busy(leader: pid_t, _ snapshot: [ShellProcessController.ProcessSnapshotEntry]) -> Bool {
        ShellProcessController.shellHasForegroundJob(sessionLeaderPID: leader, in: snapshot)
    }

    // Ghostty's tab: login(1) leads the PTY's session, and the shell is its
    // child, in a group of its own. At its prompt (whether or not Ghostty
    // sees one: bash 3.2 has no shell integration), the shell has the
    // foreground: idle, and closing its tab asks nothing.
    #expect(!busy(leader: 100, [
        process(100, parent: 1, group: 100, foreground: 200, "login"),
        process(200, parent: 100, group: 200, foreground: 200, "bash"),
    ]))
    // Before the shell took a group and the foreground of its own.
    #expect(!busy(leader: 100, [
        process(100, parent: 1, group: 100, foreground: 100, "login"),
        process(200, parent: 100, group: 100, foreground: 100, "zsh"),
    ]))
    // A job in the foreground: busy.
    #expect(busy(leader: 100, [
        process(100, parent: 1, group: 100, foreground: 300, "login"),
        process(200, parent: 100, group: 200, foreground: 300, "zsh"),
        process(300, parent: 200, group: 300, foreground: 300, "vim"),
    ]))
    // A shell that leads its session itself.
    #expect(!busy(leader: 200, [process(200, parent: 1, group: 200, foreground: 200, "nu")]))
    #expect(busy(leader: 200, [
        process(200, parent: 1, group: 200, foreground: 300, "nu"),
        process(300, parent: 200, group: 300, foreground: 300, "top"),
    ]))
    // Gone: nothing runs.
    #expect(!busy(leader: 100, []))
}

@Test @MainActor func closingAnAgentTabAttachedToASessionItDoesNotOwnLeavesTheAgentRunning() throws {
    let policy = SessionBackendPolicy(settings: { .defaults })
    // A local session another app or the CLI runs, attached from File ›
    // Persistent Sessions: its close action is `.terminate` (a local
    // hosted tab), but closing only disconnects, and asks nothing.
    let attachment = HostedSessionAttachment(
        host: .local, hostID: "host-a", sessionID: "session-cli", name: "Claude",
        remoteWorkingDirectory: "/", executablePath: "/usr/bin/true"
    )
    let attached = TerminalSession(
        title: "Claude", subtitle: "", tint: .systemOrange, launchShell: false, kind: .agent,
        agentName: "Claude",
        hostedAttachment: attachment
    )
    #expect(policy.closeAction(for: attached, intent: .userClosedTab) == .terminate)
    #expect(!SessionCloseCoordinator.closeEndsProgram(of: attached, policy: policy))
    #expect(!SessionCloseCoordinator.closeAsks(attached, policy: policy))
    // Detaching it disconnects it too.
    #expect(SessionCloseCoordinator.canDetach(attached))
    #expect(policy.closeAction(for: attached, intent: .userDetachedTab) == .detach)
    // Found again where it was attached from.
    #expect(ClosedTabNotice.reopenTarget(for: attached, in: "/work/app") == .attach(attachment, worktreeRoot: "/work/app"))
    let notice = ClosedTabNotice(tabName: "Claude", reopen: .attach(attachment, worktreeRoot: "/work/app"))
    #expect(notice.title == "Claude is running in the background")
    #expect(notice.message == "Attach to it again from File › Persistent Sessions.")
    // An SSH host's session: the same.
    let remote = TerminalSession(
        title: "Codex", subtitle: "", tint: .systemOrange, launchShell: false, kind: .agent,
        hostedAttachment: HostedSessionAttachment(
            host: try HostedSessionHost.ssh("devbox"), hostID: "host-b", sessionID: "session-remote", name: "Codex",
            remoteWorkingDirectory: "~", executablePath: "/c"
        )
    )
    #expect(!SessionCloseCoordinator.closeEndsProgram(of: remote, policy: policy))

    // A native agent's tab stops it, and cannot detach.
    let native = TerminalSession(title: "Claude", subtitle: "", tint: .systemOrange, launchShell: false, kind: .agent)
    #expect(SessionCloseCoordinator.closeEndsProgram(of: native, policy: policy))
    #expect(SessionCloseCoordinator.closeEndsProgram(of: native, intent: .userDetachedTab, policy: policy))
    #expect(ClosedTabNotice.make(for: native, policy: policy) == nil)
    #expect(ClosedTabNotice.make(for: native, intent: .userDetachedTab, policy: policy) == nil)
}

@Test @MainActor func closingAPersistentAgentEndsItsSessionAndDetachingItKeepsItRunning() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    // ⌘W ends it (asking first), with no toast.
    #expect(SessionCloseCoordinator.closeEndsProgram(of: agent, policy: workspace.backendPolicy))
    #expect(SessionCloseCoordinator.closeAsks(agent, policy: workspace.backendPolicy))
    #expect(ClosedTabNotice.make(for: agent, policy: workspace.backendPolicy) == nil)
    // ⌘D keeps it running, and says where it went.
    #expect(SessionCloseCoordinator.canDetach(agent))
    #expect(!SessionCloseCoordinator.closeEndsProgram(of: agent, intent: .userDetachedTab, policy: workspace.backendPolicy))
    let sessionID = try #require(agent.persistentSession?.sessionID)
    let notice = try #require(ClosedTabNotice.make(
        for: agent, intent: .userDetachedTab, policy: workspace.backendPolicy, pathDisplayMode: .repoFocused
    ))
    #expect(notice.message == "Open or end it from Background Sessions in the Cherry menu bar icon.")
    #expect(notice.reopen == [.backgroundSession(id: sessionID)])
}

// MARK: - Closing a tab whose shell exited

// A terminal tab whose own shell exits by itself with status 0 closes
// (`programExited`); every other ending keeps the tab showing it.

@MainActor
private func openTabs(_ count: Int, in workspace: TerminalWorkspace, harness: PersistentHarness) async throws -> [TerminalSession] {
    var tabs: [TerminalSession] = []
    for index in 1...count {
        let tab = workspace.addSession(title: "Tab \(index)")
        #expect(await harness.waitUntilAttached(tab))
        tabs.append(tab)
    }
    return tabs
}

@MainActor
private func sessionID(of tab: TerminalSession) throws -> String {
    try #require(tab.persistentSession?.sessionID)
}

@Test @MainActor func aTerminalWhoseShellExitsCleanlyClosesItsTabAndRemovesItsEndedSession() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tabs = try await openTabs(2, in: workspace, harness: harness)
    let (other, exiting) = (tabs[0], tabs[1])
    workspace.select(exiting)
    let exitingSession = try sessionID(of: exiting)
    // Whether the tab was still open right after the workspace heard of
    // the exit: it closes on the next main-loop turn, never inside the
    // report (which may come from inside Ghostty's tick).
    let reported = try #require(exiting.programDidExit)
    let openWhenReported = Recorder<Bool?>(nil)
    exiting.programDidExit = { session in
        reported(session)
        openWhenReported.value = workspace.sessions.contains { $0 === session }
    }

    harness.exit(exitingSession, code: 0)
    #expect(await harness.fake.wait { !workspace.sessions.contains { $0 === exiting } })
    #expect(openWhenReported.value == true)
    #expect(exiting.state == .exited(0))
    #expect(workspace.sessions.map(\.id) == [other.id])
    #expect(workspace.selectedSessionID == other.id)
    #expect(workspace.terminalDisplayItems == [.single(other.id)])
    // Its ended session is removed; nothing was running, so nothing is killed.
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(exitingSession) })
    #expect(!harness.requestIDs("kill").contains(exitingSession))
    #expect(harness.hosting.owningTab(of: exitingSession) == nil)
    #expect(workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: []).sessions.map(\.id) == [other.id])
    #expect(other.isRunning)
}

@Test @MainActor func aTerminalWhoseShellFailsOrIsKilledKeepsItsTabShowingTheExit() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tabs = try await openTabs(3, in: workspace, harness: harness)
    let (failing, killed) = (tabs[1], tabs[2])

    harness.exit(try sessionID(of: failing), code: 3)
    harness.exit(try sessionID(of: killed), code: 137, signal: 9)
    #expect(await harness.fake.wait { failing.state == .exited(3) && killed.state == .exited(137) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.map(\.id) == tabs.map(\.id))
    #expect(failing.persistentSessionEndedMessage == "Session ended (exit 3)")
    #expect(killed.persistentSessionEndedMessage == "Session ended (exit 137)")
    #expect(harness.fake.requests("remove").isEmpty)

    // An adapter that reports the program exited without saying how is no
    // clean exit either.
    let unknown = workspace.addSession(title: "Unknown")
    #expect(await harness.waitUntilAttached(unknown))
    let unknownSession = try sessionID(of: unknown)
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach \(unknownSession) ") } })
    let call = try #require(harness.attachCalls.last { $0.contains("attach \(unknownSession) ") })
    try HostedSessionFakeCLI.writeStatus(
        #"{"outcome":"exited","exit_code":null,"signal":null,"message":null}"#, to: try harness.statusFile(of: call)
    )
    unknown.ingestNativeChildExit(exitCode: 0)
    #expect(unknown.state == .exited(1))
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.contains { $0 === unknown })
}

@Test @MainActor func commandAndAgentTabsStayOpenWhenTheirProgramExitsCleanly() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "build", command: "make"),
        projectRoot: harness.project.path
    )
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    for tab in [anchor, command, agent] {
        #expect(await harness.waitUntilAttached(tab))
    }

    harness.exit(try sessionID(of: command), code: 0)
    harness.exit(try sessionID(of: agent), code: 0)
    #expect(await harness.fake.wait { command.state == .exited(0) && agent.state == .exited(0) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.map(\.id) == [anchor.id, command.id, agent.id])
    #expect(agent.agentActivityState == .idle)
    #expect(agent.persistentSessionEndedMessage == "Session ended (exit 0)")
    #expect(harness.fake.requests("remove").isEmpty)
}

@Test @MainActor func aShellThatEndsWithinTheMinimumRunTimeKeepsItsTab() async throws {
    #expect(SessionBackendPolicy(settings: { .defaults }).cleanExitMinimumRunTime == 1)
    let harness = try PersistentHarness()
    // Longer than any test takes to get here: the shell ended "at once".
    harness.cleanExitMinimumRunTime = 60
    let keeping = harness.workspace()
    harness.cleanExitMinimumRunTime = 0
    let closing = harness.workspace()
    defer {
        keeping.closeAllSessions(intent: .windowClosed)
        closing.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let kept = try await openTabs(2, in: keeping, harness: harness)[1]
    let closed = try await openTabs(2, in: closing, harness: harness)[1]

    harness.exit(try sessionID(of: kept), code: 0)
    harness.exit(try sessionID(of: closed), code: 0)
    #expect(await harness.fake.wait { !closing.sessions.contains { $0 === closed } })
    #expect(kept.state == .exited(0))
    #expect(keeping.sessions.contains { $0 === kept })
    #expect(kept.persistentSessionEndedMessage == "Session ended (exit 0)")
}

@Test @MainActor func closingTabsOnCleanExitFollowsTheSessionsSetting() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    harness.settings.value.closeTabsOnCleanExit = false
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = try await openTabs(2, in: workspace, harness: harness)[1]

    harness.exit(try sessionID(of: tab), code: 0)
    #expect(await harness.fake.wait { tab.state == .exited(0) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.contains { $0 === tab })
    #expect(!workspace.closesTabAfterExit(tab))
    #expect(tab.persistentSessionEndedMessage == "Session ended (exit 0)")
    #expect(harness.fake.requests("remove").isEmpty)
    // Read at each exit: turned on, the same tab would close.
    harness.settings.value.closeTabsOnCleanExit = true
    #expect(workspace.closesTabAfterExit(tab))

    // Workspaces made without a policy (tests) keep exited tabs.
    #expect(!SessionPersistenceSettings.native.closeTabsOnCleanExit)
    #expect(!TerminalWorkspace(createInitialSession: false).backendPolicy.settings().closeTabsOnCleanExit)
}

@Test @MainActor func aStopRestartOrCloseIsNeverTakenForACleanExit() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tabs = try await openTabs(4, in: workspace, harness: harness)
    let (anchor, stopped, restarted, closed) = (tabs[0], tabs[1], tabs[2], tabs[3])

    // Stopped on request (MCP `stop_process`): a clean exit 0, and the tab
    // stays so it can be started again.
    stopped.stopProgram()
    #expect(stopped.state == .exited(0))
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.contains { $0 === stopped })

    // Restarted in the same turn as the exit: the tab stays and runs again.
    let restartedSession = try sessionID(of: restarted)
    restarted.persistentProgramDidExit(sessionID: restartedSession, status: 0)
    #expect(restarted.state == .exited(0))
    #expect(workspace.restart(restarted))
    #expect(await harness.fake.wait {
        restarted.persistentSession.map { $0.sessionID != restartedSession } ?? false && restarted.state == .live
    })
    #expect(workspace.sessions.contains { $0 === restarted })

    // Closed, then its exit arrives: nothing else closes, and its session
    // is ended once.
    let closedSession = try sessionID(of: closed)
    workspace.close(closed)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(closedSession) })
    harness.exit(closedSession, code: 0)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.requestIDs("remove").filter { $0 == closedSession }.count == 1)
    #expect(workspace.sessions.map(\.id) == [anchor.id, stopped.id, restarted.id])
}

@Test @MainActor func aTabAttachedToASessionItDoesNotOwnStaysWhenThatSessionEnds() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))
    let fromCLI = HostedSessionInfo(id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72)
    let otherApp = HostedSessionInfo(
        id: "session-other-app", name: "Theirs", cwd: harness.project.path, pid: 73,
        owner: "Cherry Sessions", tags: [PersistentSessionTag.tab: UUID().uuidString]
    )
    harness.fake.sessions.append(contentsOf: [fromCLI, otherApp])
    _ = try await harness.control.list()
    // An SSH host's session takes the same path: any attached tab learns
    // its session's exit from its adapter's status file.
    var attachedTabs: [TerminalSession] = []
    for attachment in [
        try #require(harness.hosting.attachment(for: fromCLI)),
        try #require(harness.hosting.attachment(for: otherApp))
    ] {
        let label = Comment(rawValue: attachment.sessionID)
        let tab = workspace.attachHostedSession(attachment)
        #expect(!tab.isPersistentLocalSession, label)
        #expect(await harness.fake.wait {
            harness.attachCalls.contains { $0.contains("attach \(attachment.sessionID) ") }
        }, label)
        let call = try #require(harness.attachCalls.last { $0.contains("attach \(attachment.sessionID) ") })
        try HostedSessionFakeCLI.writeStatus(
            #"{"outcome":"exited","exit_code":0,"signal":null,"message":null}"#, to: try harness.statusFile(of: call)
        )
        tab.ingestNativeChildExit(exitCode: 0)
        #expect(tab.state == .exited(0), label)
        #expect(tab.hostedAttachmentStatus == .exited(code: 0, signal: nil), label)
        #expect(!workspace.closesTabAfterExit(tab), label)
        attachedTabs.append(tab)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.map(\.id) == [anchor.id] + attachedTabs.map(\.id))
    #expect(harness.fake.requests("remove").isEmpty)
}

@Test @MainActor func anEndedSessionAttachedFromTheSheetStaysOpen() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tabs = try await openTabs(2, in: workspace, harness: harness)
    // Detached, keeping its session running, which then exited cleanly.
    let keptSession = try sessionID(of: tabs[1])
    workspace.close(tabs[1], intent: .userDetachedTab)
    harness.exit(keptSession, code: 0)
    #expect(await harness.fake.wait { harness.fake.sessions.contains { $0.id == keptSession && !$0.isRunning } })
    _ = try await harness.control.list()
    let info = try #require(harness.hosting.sessionInfo(keptSession))
    #expect(harness.hosting.canAdopt(info))

    // Attached from File › Persistent Sessions to read what it printed:
    // the tab owns it and shows its exit, and stays.
    let adopted = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: info)), info: info)
    #expect(adopted.isPersistentLocalSession)
    #expect(await harness.fake.wait { adopted.state == .exited(0) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.contains { $0 === adopted })
    #expect(adopted.persistentSessionEndedMessage == "Session ended (exit 0)")
    #expect(!harness.requestIDs("remove").contains(keptSession))
}

@Test @MainActor func aSplitPaneWhoseShellExitsCleanlyClosesAndItsSplitCollapses() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let left = workspace.addSession(title: "Left")
    #expect(await harness.waitUntilAttached(left))
    let right = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(await harness.waitUntilAttached(right))
    let group = try #require(workspace.splitGroup(containing: right.id))
    #expect(workspace.terminalDisplayItems == [.split(group.id)])
    #expect(workspace.selectedSessionID == right.id)

    harness.exit(try sessionID(of: right), code: 0)
    #expect(await harness.fake.wait { !workspace.sessions.contains { $0 === right } })
    #expect(workspace.terminalDisplayItems == [.single(left.id)])
    #expect(workspace.terminalSplitGroups.isEmpty)
    #expect(workspace.selectedSessionID == left.id)
}

@Test @MainActor func theWindowsLastTabClosesTheWindowWhenItsShellExitsCleanly() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Only")
    #expect(await harness.waitUntilAttached(tab))
    let tabSession = try sessionID(of: tab)

    // A workspace on its own has no window: its last tab stays.
    harness.exit(tabSession, code: 0)
    #expect(await harness.fake.wait { tab.state == .exited(0) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.map(\.id) == [tab.id])
    #expect(workspace.closesTabAfterExit(tab))

    // Nor does it close without a window, or while a sheet is on it.
    SessionCloseCoordinator.closeTabAfterCleanExit(tab, in: workspace, repository: nil, window: nil)
    let window = RecordingWindow()
    window.presentedSheet = NSWindow()
    SessionCloseCoordinator.closeTabAfterCleanExit(tab, in: workspace, repository: nil, window: window)
    #expect(workspace.sessions.map(\.id) == [tab.id])
    #expect(window.closeRequests == 0)
    #expect(harness.fake.requests("remove").isEmpty)

    // Nor while the window shows a note: ⌘W would close the note, not the
    // window, so the window does not vanish under it.
    window.presentedSheet = nil
    let chromeState = ProjectWindowChromeState()
    chromeState.selectedNoteID = UUID()
    SessionCloseCoordinator.closeTabAfterCleanExit(
        tab, in: workspace, repository: nil, chromeState: chromeState, window: window
    )
    #expect(workspace.sessions.map(\.id) == [tab.id])
    #expect(window.closeRequests == 0)

    // Otherwise the tab closes, and then its window, as ⌘W closes them.
    chromeState.selectedNoteID = nil
    SessionCloseCoordinator.closeTabAfterCleanExit(
        tab, in: workspace, repository: nil, chromeState: chromeState, window: window
    )
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(tabSession) })
    #expect(!harness.requestIDs("kill").contains(tabSession))

    // The same when a window's workspace hears the exit.
    let windowed = harness.workspace()
    defer { windowed.closeAllSessions(intent: .windowClosed) }
    let otherWindow = RecordingWindow()
    windowed.closeTabAfterCleanExit = { workspace, session in
        SessionCloseCoordinator.closeTabAfterCleanExit(session, in: workspace, repository: nil, window: otherWindow)
    }
    let last = windowed.addSession(title: "Last")
    #expect(await harness.waitUntilAttached(last))
    harness.exit(try sessionID(of: last), code: 0)
    #expect(await harness.fake.wait { otherWindow.closeRequests == 1 })
    #expect(windowed.sessions.isEmpty)
}

@Test @MainActor func aProjectWindowsWorktreeClosesATabWhoseShellExitsCleanly() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let repository = RepositoryWorkspace(
        projectRoot: harness.project.path,
        backendPolicy: harness.policy,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let workspace = repository.activeWorkspace
    let shell = try #require(workspace.sessions.first)
    #expect(await harness.waitUntilAttached(shell))
    let tab = workspace.addSession(title: "Second")
    #expect(await harness.waitUntilAttached(tab))

    harness.exit(try sessionID(of: tab), code: 0)
    #expect(await harness.fake.wait { !workspace.sessions.contains { $0 === tab } })
    // Its last tab has no window to close with it (no window claimed the
    // project): it stays.
    harness.exit(try sessionID(of: shell), code: 0)
    #expect(await harness.fake.wait { shell.state == .exited(0) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.map(\.id) == [shell.id])
}

@Test @MainActor func aNativeTerminalWhoseShellExitsClosesOnTheNextTurnAfterGhosttyClosesItsSurface() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addSession(title: "Native")
    harness.settings.value.persistLocalSessions = true
    #expect(!native.isPersistentLocalSession)
    #expect(native.isRunning)

    // As Ghostty reports it, inside its tick: the child exited (login(1)
    // says 0), then the surface asks to close. The tab stays until the
    // next main-loop turn, so the surface is not freed under Ghostty.
    native.ingestNativeChildExit(exitCode: 0)
    native.nativeSurfaceDidClose()
    #expect(native.state == .exited(0))
    #expect(workspace.sessions.contains { $0 === native })
    #expect(await harness.fake.wait { !workspace.sessions.contains { $0 === native } })
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    #expect(anchor.isRunning)
}

@Test @MainActor func theMinimumRunTimeCountsFromWhenTheShellStartedNotWhenItsTabAskedForIt() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.creationTimeout = 2
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    defer {
        harness.fake.respond = nil
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let minimum = workspace.backendPolicy.cleanExitMinimumRunTime
    #expect(minimum == 1)
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))

    // The host takes longer than the minimum to start the session (a
    // daemon starting cold): the shell runs from its Create's answer.
    let fake = harness.fake
    fake.respond = { request, connection in
        guard request.op == "create" else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + minimum + 0.2) {
            if case .answer(let message) = fake.defaultReply(to: request, on: connection) {
                connection.push(message, req: request.req)
            }
        }
        return .silence
    }
    let late = workspace.addSession(title: "Late")
    #expect(await harness.waitUntilAttached(late))
    #expect(try #require(late.programStartedAt) > (try #require(late.startedAt)).addingTimeInterval(minimum))
    // It ends at once: its tab stays and shows how it ended.
    harness.exit(try sessionID(of: late), code: 0)
    #expect(await harness.fake.wait { late.state == .exited(0) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.contains { $0 === late })
    #expect(!workspace.closesTabAfterExit(late))

    // The host never starts it: the tab runs natively from then on, and a
    // shell that ends at once there keeps its tab too.
    fake.respond = { request, _ in request.op == "create" ? .silence : nil }
    let fallback = workspace.addSession(title: "Fallback")
    #expect(await harness.fake.wait(timeout: 4) { !fallback.isPersistentLocalSession })
    #expect(try #require(fallback.programStartedAt) > (try #require(fallback.startedAt)).addingTimeInterval(minimum))
    fallback.ingestNativeChildExit(exitCode: 0)
    #expect(fallback.state == .exited(0))
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.contains { $0 === fallback })
    #expect(!workspace.closesTabAfterExit(fallback))
}
