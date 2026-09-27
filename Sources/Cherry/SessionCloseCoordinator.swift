import AppKit
import Foundation

/// Why a tab is being closed. Every path that ends a tab's program names one,
/// because a persistent (hosted) session can outlive its tab and the right
/// outcome depends on who closed it.
enum SessionCloseIntent: String, CaseIterable, Sendable {
    /// Tab close button, ⌘W, the sidebar's and pane menu's Close: ends the
    /// tab's program (a tab attached to a session it does not own only
    /// disconnects). In a window that stays open, a persistent tab's
    /// session ends only once ⌘Z can no longer bring the tab back
    /// (`ClosedTabHistory`).
    case userClosedTab
    /// ⌘D (Detach Tab), the sidebar's and pane menu's Detach, and a close
    /// question's Detach Instead: the tab closes and its session keeps
    /// running in the background. Only for a tab that can detach
    /// (`SessionCloseCoordinator.canDetach`).
    case userDetachedTab
    /// MCP `close_process` / `close_terminal`; a user tab close by proxy,
    /// never asked about.
    case mcpClose
    /// The project window closed keeping its local sessions running: the
    /// user answered Keep Running, Settings › Sessions keeps them, or
    /// nothing asked (the window had no running session, or it closed
    /// without its close confirmation).
    case windowClosed
    /// The project window closed ending its local sessions: the user
    /// answered End Sessions, or Settings › Sessions ends them.
    case windowClosedEndingSessions
    /// Cherry is quitting keeping local sessions running: the user answered
    /// Keep Running, Settings › Sessions keeps them, or nothing asked (no
    /// session was running, or a log out, restart, shut down or update).
    case appQuit
    /// Cherry is quitting ending local sessions: the user answered End
    /// Sessions, or Settings › Sessions ends them.
    case appQuitEndingSessions
    /// A second window for an already open project is discarded.
    case duplicateWindowTeardown
    /// The tab's worktree was removed.
    case worktreeRemoved
    /// Restart (menu, MCP `restart_process`): end the program and start it
    /// again in the same tab.
    case restart
    /// A terminal tab's shell exited with status 0: the tab closes by
    /// itself (`TerminalWorkspace.tabProgramDidExit`).
    case programExited

    /// The whole workspace goes away with its window or the app. Workspace
    /// persistence keeps the state saved before the teardown.
    var tearsDownWorkspace: Bool {
        switch self {
        case .windowClosed, .windowClosedEndingSessions, .appQuit, .appQuitEndingSessions, .duplicateWindowTeardown:
            true
        case .userClosedTab, .userDetachedTab, .mcpClose, .worktreeRemoved, .restart, .programExited:
            false
        }
    }

    /// Cherry is quitting, keeping local sessions or ending them.
    var isAppQuit: Bool {
        self == .appQuit || self == .appQuitEndingSessions
    }

    /// A window close or quit that ends local sessions (End Sessions, or
    /// Settings › Sessions): the sessions of saved tabs no open tab shows
    /// end too (`RepositoryWorkspace.endSavedSessionsNotOpen`).
    var endsLocalSessions: Bool {
        self == .windowClosedEndingSessions || self == .appQuitEndingSessions
    }
}

/// A teardown the user may be asked about: closing a project window, or
/// quitting. Whether it keeps or ends local sessions is part of its intent.
enum SessionTeardown: Sendable {
    case windowClose
    case quit

    func intent(endingSessions: Bool) -> SessionCloseIntent {
        switch self {
        case .windowClose: endingSessions ? .windowClosedEndingSessions : .windowClosed
        case .quit: endingSessions ? .appQuitEndingSessions : .appQuit
        }
    }

    /// The intent the sessions question's answer closes with; nil for
    /// Cancel, which closes nothing.
    func intent(for answer: SessionTeardownAnswer) -> SessionCloseIntent? {
        switch answer {
        case .keep: intent(endingSessions: false)
        case .end: intent(endingSessions: true)
        case .cancel: nil
        }
    }
}

enum SessionCloseAction: Equatable, Sendable {
    /// Signal the tab's local process tree (a native tab).
    case stop
    /// End only the local attach client; the hosted session keeps running.
    case detach
    /// End the hosted session on its host.
    case terminate
}

/// Where a tab's program runs, as far as closing it is concerned.
enum SessionCloseBackend: Equatable, Sendable {
    case native
    /// A tab of a session on This Mac: a local tab that runs its program as
    /// a persistent session (`TerminalSession.isPersistentLocalSession`), or
    /// one attached from File › Persistent Sessions that its workspace could
    /// not make its own (another tab runs that session). Only a persistent
    /// tab has a session a close ends (`SessionBackendPolicy`'s terminator);
    /// an attached one only disconnects.
    case hostedLocal
    /// A tab attached to a session on an SSH host: closing it only ends its
    /// attach client.
    case hostedRemote

    @MainActor
    init(_ session: TerminalSession) {
        if session.isPersistentLocalSession {
            self = .hostedLocal
        } else if let attachment = session.hostedAttachment {
            self = attachment.host == .local ? .hostedLocal : .hostedRemote
        } else {
            self = .native
        }
    }
}

/// The single decision of what closing a tab does, per
/// docs/specs/multiplexer-default.md ("Close intents").
enum SessionClosePolicy {
    /// Local tabs run as persistent sessions by default, and closing one
    /// follows its intent (`hostedLocalAction(for:)`): a window close or
    /// quit carries Settings › Sessions' choice (or its question's answer)
    /// in its intent. False makes a local persistent tab detach for every
    /// intent.
    static let hostedLocalTabsFollowSettings = true

    @MainActor
    static func closeAction(
        for session: TerminalSession,
        intent: SessionCloseIntent,
        hostedLocalTabsFollowSettings: Bool = hostedLocalTabsFollowSettings
    ) -> SessionCloseAction {
        closeAction(
            for: SessionCloseBackend(session),
            intent: intent,
            hostedLocalTabsFollowSettings: hostedLocalTabsFollowSettings
        )
    }

    static func closeAction(
        for backend: SessionCloseBackend,
        intent: SessionCloseIntent,
        hostedLocalTabsFollowSettings: Bool = hostedLocalTabsFollowSettings
    ) -> SessionCloseAction {
        switch backend {
        case .native:
            // Restart relaunches after the stop. A native tab cannot detach
            // (`SessionCloseCoordinator.canDetach`).
            return .stop
        case .hostedRemote:
            // Restart reconnects after the detach.
            return .detach
        case .hostedLocal:
            guard hostedLocalTabsFollowSettings else { return .detach }
            return hostedLocalAction(for: intent)
        }
    }

    /// The spec's "Local hosted tab" column. A tab close (⌘W, MCP) ends its
    /// session; a detach keeps it running in the background. Restart
    /// terminates, then the tab creates a new session with the same tab id.
    /// A tab closing because its shell exited leaves nothing to keep:
    /// ending its session only removes it (the host lists it as exited, so
    /// there is nothing to kill). A window close or quit carries its answer
    /// (or Settings › Sessions') in its intent.
    static func hostedLocalAction(for intent: SessionCloseIntent) -> SessionCloseAction {
        switch intent {
        case .userDetachedTab, .windowClosed, .appQuit, .duplicateWindowTeardown:
            .detach
        case .userClosedTab, .mcpClose, .windowClosedEndingSessions, .appQuitEndingSessions, .worktreeRemoved,
             .restart, .programExited:
            .terminate
        }
    }
}

@MainActor
enum SessionCloseCoordinator {
    /// Whether closing `session`'s tab with `intent` ends its program, as
    /// its confirmations say: a native tab's close stops it, and a
    /// persistent tab's ends its session unless its close action detaches
    /// (a detach, or a window close or quit keeping sessions). A tab
    /// attached to a session it does not own (File › Persistent Sessions;
    /// another app's or the CLI's, or an SSH host's) only disconnects,
    /// whatever its close action: nothing ends that session.
    static func closeEndsProgram(
        of session: TerminalSession,
        intent: SessionCloseIntent = .userClosedTab,
        policy: SessionBackendPolicy
    ) -> Bool {
        guard session.hostedAttachment == nil else { return false }
        return policy.closeAction(for: session, intent: intent) != .detach
    }

    /// Whether a user's close of `session`'s tab asks first ("Close
    /// “<name>”?", `TabCloseQuestion`): the close stops its program while
    /// it is at work (`ClosedTabNotice.programIsAtWork`: an agent, a
    /// running command, or a terminal whose host or PTY reports a job in
    /// its foreground). An idle shell never asks, nor does a tab whose close
    /// leaves its program running.
    static func closeAsks(_ session: TerminalSession, policy: SessionBackendPolicy) -> Bool {
        closeEndsProgram(of: session, policy: policy) && ClosedTabNotice.programIsAtWork(session, policy: policy)
    }

    /// Whether `session`'s tab can be detached (⌘D, Detach, Detach
    /// Instead): the tab closes and its session keeps running in the
    /// background. This app's own persistent tab while its program runs
    /// (its session's Create may still be under way), or a tab attached to
    /// a session it does not own that has not ended, which detaching only
    /// disconnects. A native tab's program cannot outlive its tab.
    static func canDetach(_ session: TerminalSession) -> Bool {
        if session.isPersistentLocalSession {
            return session.isProgramRunning
        }
        return session.hostedAttachment != nil && !session.hostedSessionEnded
    }

    /// Whether a group close's question offers to detach `sessions`
    /// instead (Close Split Group…, "Close Agent Group?"): every one of
    /// them can detach, and closing them would stop at least one.
    static func canDetachInstead(_ sessions: [TerminalSession], policy: SessionBackendPolicy) -> Bool {
        !sessions.isEmpty && sessions.allSatisfy(canDetach)
            && sessions.contains { closeEndsProgram(of: $0, policy: policy) }
    }

    static func hasOpenSessionsInOtherWorktrees(
        than workspace: TerminalWorkspace,
        repository: RepositoryWorkspace?
    ) -> Bool {
        repository?.allLoadedWorkspaces().contains { candidate in
            candidate !== workspace && !candidate.sessions.isEmpty
        } ?? false
    }

    static func shouldCloseWindow(
        for workspace: TerminalWorkspace,
        repository: RepositoryWorkspace?
    ) -> Bool {
        guard workspace.sessions.count <= 1 else { return false }
        return !hasOpenSessionsInOtherWorktrees(than: workspace, repository: repository)
    }

    /// ⌘W and Close Tab: closes the selected tab as the user closing it
    /// (`close`: its program ends, a persistent tab's session too, asking
    /// first when that stops a program at work; a tab attached to a session
    /// it does not own only disconnects), which ⌘Z can undo for a while
    /// (`closeTabs`). When it is the window's last tab
    /// (no other worktree of the window has tabs), the window closes after
    /// the tab, with nothing left to ask about: closing the window with the
    /// tab in it would ask whether to keep the tab's session running
    /// (`SessionTeardownQuestion`) to bring it back next time. A program the
    /// close leaves running asks nothing: the window's toast says where it
    /// went, or, when the window closes with its last tab, another project
    /// window's (`ClosedTabNotice`). A shown note closes instead.
    /// `registry`: the windows' registry (the repository's, else the app's).
    static func closeSelectedTabOrWindow(
        workspace: TerminalWorkspace,
        repository: RepositoryWorkspace?,
        chromeState: ProjectWindowChromeState?,
        window: NSWindow?,
        registry: ProjectWindowRegistry? = nil
    ) {
        if chromeState?.closeSelectedNoteIfNeeded() == true {
            return
        }
        let registry = registry ?? repository?.windowRegistry ?? .shared
        let closesWindow = shouldCloseWindow(for: workspace, repository: repository)
        guard let session = workspace.selectedSession ?? (closesWindow ? workspace.sessions.first : nil) else {
            if closesWindow { window?.performClose(nil) }
            return
        }
        close(
            session,
            in: workspace,
            chromeState: chromeState,
            allowEmptyWorkspace: hasOpenSessionsInOtherWorktrees(than: workspace, repository: repository),
            closingWindow: closesWindow ? window : nil,
            registry: registry
        )
    }

    /// ⌘D and Detach Tab: detaches the selected tab (`detach`), the focused
    /// pane in a split. On the window's last tab the window closes after
    /// it, as with ⌘W. Nothing for a tab that cannot detach (`canDetach`),
    /// or while the window shows a note, the todo board or an idle command
    /// instead of the tab.
    static func detachSelectedTabOrWindow(
        workspace: TerminalWorkspace,
        repository: RepositoryWorkspace?,
        chromeState: ProjectWindowChromeState?,
        window: NSWindow?,
        registry: ProjectWindowRegistry? = nil
    ) {
        guard chromeState?.isShowingTerminalContent != false,
              let session = workspace.selectedSession, canDetach(session)
        else { return }
        let registry = registry ?? repository?.windowRegistry ?? .shared
        detach(
            session,
            in: workspace,
            chromeState: chromeState,
            allowEmptyWorkspace: hasOpenSessionsInOtherWorktrees(than: workspace, repository: repository),
            closingWindow: shouldCloseWindow(for: workspace, repository: repository) ? window : nil,
            registry: registry
        )
    }

    /// A terminal tab whose shell exited with status 0 closes
    /// (`programExited`), as ⌘W closes it but without asking, since nothing
    /// runs: on the window's last tab (no other worktree of the window has
    /// tabs) the window closes after it. Without a window, while a sheet is
    /// on it, or while it shows a note (⌘W would close the note, not the
    /// window), that last tab stays and shows its exit.
    static func closeTabAfterCleanExit(
        _ session: TerminalSession,
        in workspace: TerminalWorkspace,
        repository: RepositoryWorkspace?,
        chromeState: ProjectWindowChromeState? = nil,
        window: NSWindow?
    ) {
        guard workspace.sessions.contains(where: { $0 === session }) else { return }
        guard shouldCloseWindow(for: workspace, repository: repository) else {
            workspace.close(
                session,
                allowEmptyWorkspace: hasOpenSessionsInOtherWorktrees(than: workspace, repository: repository),
                intent: .programExited
            )
            return
        }
        guard let window, window.attachedSheet == nil, chromeState?.selectedNoteID == nil else { return }
        workspace.close(session, allowEmptyWorkspace: true, intent: .programExited)
        guard workspace.sessions.isEmpty else { return }
        window.performClose(nil)
    }

    /// A user's close (⌘W, the sidebar's and pane menu's Close). An agent
    /// with sub-agents asks which to close ("Close Agent Group?"), and a
    /// close that stops a program at work (`closeAsks`) asks "Close
    /// “<name>”?" (`TabCloseQuestion`), whose answer closes, detaches
    /// instead or keeps the tab (`answerTabClose`): both through
    /// `chromeState`, the one question the close shows; without it (no
    /// window) the tab closes at once. Any other tab closes at once
    /// (`closeTab`). `closingWindow`: the window that closes after the tab,
    /// its last (⌘W).
    static func close(
        _ session: TerminalSession,
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?,
        allowEmptyWorkspace: Bool = false,
        closingWindow window: NSWindow? = nil,
        registry: ProjectWindowRegistry = .shared
    ) {
        if session.kind == .agent, !workspace.descendantAgentSessions(of: session).isEmpty {
            if let chromeState {
                chromeState.requestAgentGroupClose(
                    sessionID: session.id,
                    allowEmptyWorkspace: allowEmptyWorkspace
                )
            } else {
                workspace.close(session, allowEmptyWorkspace: allowEmptyWorkspace)
            }
            return
        }

        if let chromeState, closeAsks(session, policy: workspace.backendPolicy) {
            // One question at a time: a second close while it is up (its
            // sheet takes the keys) waits for its answer.
            guard chromeState.pendingTabClose == nil else { return }
            chromeState.requestTabClose(TabCloseRequest(
                sessionID: session.id,
                workspace: workspace,
                allowEmptyWorkspace: allowEmptyWorkspace || window != nil,
                closingWindow: window,
                registry: registry
            ))
            return
        }
        closeTab(
            session, in: workspace, chromeState: chromeState,
            allowEmptyWorkspace: allowEmptyWorkspace, closingWindow: window, registry: registry
        )
    }

    /// Detaches the tab at once, when it can (`canDetach`): it closes with
    /// `userDetachedTab` and its session keeps running in the background
    /// (a session it does not own is only disconnected). An agent's
    /// sub-agents stay, as top-level agents. The window's toast says where
    /// it went, an idle shell's too, as the user did it on purpose
    /// (`closeTab`). `closingWindow`: as for `close`.
    static func detach(
        _ session: TerminalSession,
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?,
        allowEmptyWorkspace: Bool = false,
        closingWindow window: NSWindow? = nil,
        registry: ProjectWindowRegistry = .shared
    ) {
        guard canDetach(session) else { return }
        closeTab(
            session, in: workspace, chromeState: chromeState, allowEmptyWorkspace: allowEmptyWorkspace,
            intent: .userDetachedTab, closingWindow: window, registry: registry
        )
    }

    /// Closes the tab at once with `intent`, then, when that emptied the
    /// workspace of `closingWindow` (it closed its last tab), the window.
    /// The window's toast says what happened (`closeTabs`): on this window,
    /// or, when it closed, on the project window active last.
    static func closeTab(
        _ session: TerminalSession,
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?,
        allowEmptyWorkspace: Bool = false,
        intent: SessionCloseIntent = .userClosedTab,
        closingWindow window: NSWindow? = nil,
        registry: ProjectWindowRegistry = .shared
    ) {
        closeTabs([session], in: workspace, chromeState: chromeState, intent: intent, closingWindow: window, registry: registry) {
            workspace.close(session, allowEmptyWorkspace: allowEmptyWorkspace || window != nil, intent: intent)
        }
    }

    /// Closes `sessions`' tabs together with `close` (a split group; an
    /// agent with or without its sub-agents). A user's close or detach in a
    /// window that stays open (not one that closes after it) can be undone:
    /// the tabs go into the window's closed tabs (`ClosedTabHistory`), which
    /// ⌘Z brings back where they were while their toast would last, and a
    /// close of this app's own persistent tab stops only its adapter until
    /// then (`TerminalWorkspace.deferringSessionEnds`,
    /// `PersistentLocalSessions.deferEnd`). Native tabs never come back.
    /// One toast says what happened: "Closed <name>" with Undo (⌘Z) for a
    /// close that ends sessions later, or that nothing else is said about;
    /// else, when the close detached the tabs or left programs at work
    /// (`ClosedTabNotice`), that notice, with Reopen (the undo, while it
    /// lasts). `closingWindow`: as for `closeTab`.
    static func closeTabs(
        _ sessions: [TerminalSession],
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?,
        intent: SessionCloseIntent = .userClosedTab,
        closingWindow window: NSWindow? = nil,
        registry: ProjectWindowRegistry = .shared,
        close: () -> Void
    ) {
        let notices = chromeState == nil && window == nil ? [] : sessions.compactMap { session in
            ClosedTabNotice.make(
                for: session, in: workspace.projectRoot, intent: intent, policy: workspace.backendPolicy
            ).map { (session, $0) }
        }
        let undoable = window == nil && chromeState != nil
            && (intent == .userClosedTab || intent == .userDetachedTab)
        let pathDisplayMode = TerminalSettings.shared.sidebarTerminalPathDisplayMode
        let comingBack = !undoable ? [] : sessions.compactMap { session in
            workspace.closedTab(
                for: session, name: SidebarSessionLabel.label(for: session, pathDisplayMode: pathDisplayMode).title
            ).map { (session, $0) }
        }
        var endsLeft: [TerminalSession] = []
        if comingBack.isEmpty {
            close()
        } else {
            endsLeft = workspace.deferringSessionEnds(close)
        }
        let isClosed: (TerminalSession) -> Bool = { session in !workspace.sessions.contains { $0 === session } }
        let closed = notices.filter { isClosed($0.0) }.map(\.1)
        let notice = ClosedTabNotice.combining(closed)
        var closedTabs = comingBack.filter { isClosed($0.0) }
        // The sessions the close left running end once it can no longer be
        // undone, and at the next launch if Cherry exits first.
        let policy = workspace.backendPolicy
        for session in endsLeft {
            guard let hosting = session.persistentHosting, let binding = session.persistentSession,
                  let index = closedTabs.firstIndex(where: { $0.0 === session })
            else {
                policy.terminateHostedSession(session, intent)
                continue
            }
            hosting.deferEnd(
                ofSession: binding.sessionID, record: closedTabs[index].1.record, recordedIn: registry.workspaceStateStore
            ) {
                policy.terminateHostedSession(session, intent)
            }
            closedTabs[index].1.pendingEnd = hosting
        }
        if let window, workspace.sessions.isEmpty {
            performClose(window, emptied: workspace)
            // This window goes: the toast goes on the one active last, if
            // any (else Background Sessions lists it; the launch notice
            // does not name a session detached on purpose).
            guard let notice,
                  let other = registry.mostRecentlyActiveProjectWindow(excluding: window, chromeState: chromeState)
            else { return }
            showToast(
                notice, on: other.chromeState, workspace: other.workspace, repository: other.repository,
                policy: workspace.backendPolicy, registry: registry
            )
            return
        }
        guard let chromeState else { return }
        let tabs = closedTabs.map(\.1)
        let entry = chromeState.closedTabs.record(
            tabs,
            action: intent == .userDetachedTab ? .detach : .close,
            workspace: workspace,
            repository: registry.repository(for: chromeState)
        )
        if let entry, notice == nil || tabs.contains(where: { $0.pendingEnd != nil }) {
            showClosedToast(names: tabs.map(\.name), entry: entry, on: chromeState)
        } else if let notice {
            showToast(notice, on: chromeState, workspace: workspace, policy: policy, registry: registry, undoEntry: entry)
        }
    }

    /// Closes `window`, whose last tab a close or detach just took out of
    /// `workspace`, as its close button does. While a sheet is on it (the
    /// "Close “<name>”?" that asked for this close: `NSAlert` calls its
    /// completion while the sheet is still being ordered out), AppKit
    /// ignores the close, so it waits for the sheet to go, as
    /// `ProjectWindowCloseDelegate` does, then closes the window unless a
    /// tab came to it or it closed meanwhile.
    static func performClose(_ window: NSWindow, emptied workspace: TerminalWorkspace) {
        guard window.attachedSheet != nil else {
            window.performClose(nil)
            return
        }
        Task { @MainActor [weak window, weak workspace] in
            // Not once a tab came, or the window closed some other way (its
            // workspace was torn down).
            var closes: Bool { workspace.map { $0.sessions.isEmpty && !$0.isTornDown } ?? false }
            while let window, window.attachedSheet != nil, closes {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let window, closes else { return }
            window.performClose(nil)
        }
    }

    /// "Closed <name>" ("Closed N tabs"), with Undo (⌘Z), which brings the
    /// tabs back while `entry` of the window's closed tabs lasts. Like the
    /// entry, it waits while the pointer rests on it and while its window
    /// is not key in the active app.
    static func showClosedToast(names: [String], entry: UUID, on chromeState: ProjectWindowChromeState) {
        let subject = names.count == 1 ? names[0] : "\(names.count) tabs"
        let toast = ProjectWindowToast(
            name: "Closed " + subject,
            predicate: "",
            action: ProjectWindowToast.Action(title: "Undo", shortcut: "⌘Z") { [weak chromeState] in
                chromeState?.closedTabs.undo(entry)
            },
            pausesWhileUnattended: true,
            symbolName: ProjectWindowToast.closedSymbolName
        )
        chromeState.closedTabs.setToast(toast.id, for: entry)
        chromeState.toasts.show(toast)
    }

    // MARK: "Close “<name>”?"

    /// The question `request` asks now; nil when there is nothing left to
    /// ask (its tab closed, or its program stopped, meanwhile).
    static func question(for request: TabCloseRequest) -> TabCloseQuestion? {
        guard let workspace = request.workspace,
              let session = workspace.session(withID: request.sessionID),
              closeAsks(session, policy: workspace.backendPolicy)
        else { return nil }
        return TabCloseQuestion(for: session, policy: workspace.backendPolicy)
    }

    /// "Close “<name>”?" was answered (`TabCloseAlertPresenterView`), or had
    /// nothing left to ask (answered Close): Close closes the tab, stopping
    /// its program; Detach Instead detaches it (a tab that can no longer
    /// detach, its program having ended, closes); Cancel keeps it. A close
    /// or detach of the window's last tab closes the window after it.
    static func answerTabClose(
        _ answer: TabCloseAnswer,
        to request: TabCloseRequest,
        chromeState: ProjectWindowChromeState?
    ) {
        if let chromeState, chromeState.pendingTabClose?.id == request.id {
            chromeState.pendingTabClose = nil
        }
        guard answer != .cancel,
              let workspace = request.workspace,
              let session = workspace.session(withID: request.sessionID)
        else { return }
        closeTab(
            session, in: workspace, chromeState: chromeState, allowEmptyWorkspace: request.allowEmptyWorkspace,
            intent: answer == .detach && canDetach(session) ? .userDetachedTab : .userClosedTab,
            closingWindow: request.closingWindow, registry: request.registry
        )
    }

    // MARK: Toasts

    /// Shows `notice` in the toast of the window `chromeState` belongs to.
    /// Reopen brings the sessions back: while `undoEntry` of the window's
    /// closed tabs lasts (the toast waits as it does), as ⌘Z does, where
    /// their tabs were; else in their project's window (`reopen`), where
    /// `workspace` takes those it cannot place.
    static func showToast(
        _ notice: ClosedTabNotice,
        on chromeState: ProjectWindowChromeState,
        workspace: TerminalWorkspace,
        repository: RepositoryWorkspace? = nil,
        policy: SessionBackendPolicy,
        registry: ProjectWindowRegistry,
        undoEntry: UUID? = nil
    ) {
        let repository = repository ?? registry.repository(for: chromeState)
        let hosting = policy.localSessions
        let targets = notice.reopen
        let action = targets.isEmpty && undoEntry == nil ? nil : ProjectWindowToast.Action(
            title: "Reopen", shortcut: undoEntry == nil ? nil : "⌘Z"
        ) { [weak workspace, weak repository, weak chromeState] in
            if let undoEntry, chromeState?.closedTabs.undo(undoEntry) == true { return }
            Task { @MainActor in
                for target in targets {
                    await reopen(
                        target, hosting: hosting, into: repository?.activeWorkspace ?? workspace,
                        chromeState: chromeState, registry: registry
                    )
                }
            }
        }
        let toast = ProjectWindowToast(
            name: notice.subject, predicate: notice.predicate, message: notice.message, action: action,
            pausesWhileUnattended: undoEntry != nil
        )
        if let undoEntry {
            chromeState.closedTabs.setToast(toast.id, for: undoEntry)
        }
        chromeState.toasts.show(toast)
    }

    /// A toast's Reopen: shows a closed tab's session in a tab again where
    /// that tab was, and returns the tab. This app's own session goes the
    /// way Background Sessions → Open takes it
    /// (`ProjectWindowRegistry.showBackgroundSession`: its project's
    /// window, opened again when it closed with its last tab, adopted with
    /// its tab id, kind, agent and command); a session the tab did not own
    /// is attached again in the worktree it was closed from, its window
    /// opened again likewise
    /// (`ProjectWindowRegistry.workspaceOpeningWindow`). `workspace` (the
    /// toast's window's) takes a session whose worktree no window shows.
    /// Nothing when a session of This Mac is gone; an SSH host's is not
    /// asked.
    @discardableResult
    static func reopen(
        _ target: ClosedTabNotice.Reopen,
        hosting: PersistentLocalSessions?,
        into workspace: TerminalWorkspace?,
        chromeState: ProjectWindowChromeState?,
        registry: ProjectWindowRegistry
    ) async -> TerminalSession? {
        switch target {
        case .attach(let attachment, let worktreeRoot):
            if attachment.host == .local, let hosting, hosting.control.hostID == attachment.hostID {
                _ = try? await hosting.control.list()
                guard hosting.sessionInfo(attachment.sessionID) != nil else { return nil }
            }
            var destination = workspace
            if let worktreeRoot, let own = await registry.workspaceOpeningWindow(worktreeRoot: worktreeRoot) {
                destination = own
            }
            guard let destination, !destination.isTornDown else { return nil }
            let tab = destination.attachHostedSession(attachment)
            if let root = registry.projectRoot(containing: tab.id) {
                registry.revealSession(id: tab.id, projectRoot: root)
            } else {
                chromeState?.selectTerminal()
            }
            return tab
        case .backgroundSession(let id):
            guard let hosting else { return nil }
            // A fresh list: the closed tab's adapter has let go of it by now.
            _ = try? await hosting.control.list()
            guard let info = hosting.sessionInfo(id) else { return nil }
            await registry.showBackgroundSession(info, localSessions: hosting)
            return hosting.owningTab(of: id)
                ?? hosting.control.hostID.flatMap { OpenHostedTabs.shared.tab(showingSession: id, hostID: $0) }
        }
    }

    /// Close Split Group…: asks (`splitGroupCloseAlert`), then closes the
    /// group's panes together (`closeTabs`), or, answered Detach Instead,
    /// detaches them together.
    static func confirmAndCloseSplitGroup(
        _ group: TerminalSplitGroup,
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?
    ) {
        let panes = group.paneSessionIDs.compactMap { workspace.session(withID: $0) }
        let alert = splitGroupCloseAlert(for: panes, policy: workspace.backendPolicy)
        let answer = splitGroupCloseAnswer(
            for: alert.runModal(), detachOffered: canDetachInstead(panes, policy: workspace.backendPolicy)
        )
        guard answer != .cancel else { return }
        let intent: SessionCloseIntent = answer == .detach ? .userDetachedTab : .userClosedTab
        closeTabs(panes, in: workspace, chromeState: chromeState, intent: intent) {
            workspace.closeSplitGroup(id: group.id, intent: intent)
        }
    }

    /// "Close Split Group?", which says which panes' programs the close
    /// stops (`closeEndsProgram`) and which keep running, with Detach
    /// Instead when they can all keep running (`canDetachInstead`).
    static func splitGroupCloseAlert(for panes: [TerminalSession], policy: SessionBackendPolicy) -> NSAlert {
        let stopped = panes.filter { closeEndsProgram(of: $0, policy: policy) }.count
        let alert = NSAlert()
        alert.messageText = "Close Split Group?"
        alert.informativeText = switch stopped {
        case panes.count:
            "This will stop and close \(panes.count) terminal panes."
        case 0:
            "This will close \(panes.count) terminal panes. Their programs keep running in the background."
        case panes.count - 1:
            "This will close \(panes.count) terminal panes and stop \(stopped) of them. "
                + "The other one keeps running in the background."
        default:
            "This will close \(panes.count) terminal panes and stop \(stopped) of them. "
                + "The others keep running in the background."
        }
        alert.alertStyle = stopped > 0 ? .warning : .informational
        alert.addButton(withTitle: "Close Split Group")
        if canDetachInstead(panes, policy: policy) {
            alert.addButton(withTitle: TabCloseQuestion.detachButtonTitle)
        }
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// What a button of `splitGroupCloseAlert` answered.
    nonisolated static func splitGroupCloseAnswer(
        for response: NSApplication.ModalResponse,
        detachOffered: Bool
    ) -> TabCloseAnswer {
        switch response {
        case .alertFirstButtonReturn: .close
        case .alertSecondButtonReturn where detachOffered: .detach
        default: .cancel
        }
    }
}

// MARK: - "Close “<name>”?"

/// What a close question answers (`TabCloseQuestion`, and Close Split
/// Group…'s): close, stopping the program; detach instead, keeping it
/// running in the background; or keep the tab.
enum TabCloseAnswer: Equatable, Sendable {
    case close
    case detach
    case cancel
}

/// A user's close of a tab whose program is at work, waiting for its
/// question (`ProjectWindowChromeState.pendingTabClose`), which the window's
/// `TabCloseAlertPresenterView` asks as a sheet.
struct TabCloseRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    weak var workspace: TerminalWorkspace?
    /// The close may leave the workspace without tabs (its window closes
    /// with it, or other worktrees of the window have tabs).
    let allowEmptyWorkspace: Bool
    /// The window that closes after the tab, its last (⌘W).
    weak var closingWindow: NSWindow?
    let registry: ProjectWindowRegistry
}

/// "Close “<name>”?", asked before a user's close stops a program at work
/// (`SessionCloseCoordinator.closeAsks`): an agent, a running command, or a
/// terminal whose host or PTY reports a job in its foreground; an idle
/// shell never asks. The one dialog a tab close shows: **Close**
/// (destructive) stops it, **Detach Instead** (for a tab that can detach)
/// keeps it running in the background, **Cancel** keeps the tab.
struct TabCloseQuestion: Equatable {
    static let closeButtonTitle = "Close"
    static let detachButtonTitle = "Detach Instead"

    /// The tab's sidebar name.
    let tabName: String
    /// What runs, as the sentence's subject: "This agent", a command's
    /// command line, or a terminal's foreground job as its host reports it
    /// ("A program" when it does not say).
    let program: String
    /// Detach Instead is offered (`SessionCloseCoordinator.canDetach`).
    let canDetach: Bool

    init(tabName: String, program: String, canDetach: Bool) {
        self.tabName = tabName
        self.program = program
        self.canDetach = canDetach
    }

    @MainActor
    init(
        for session: TerminalSession,
        policy: SessionBackendPolicy,
        pathDisplayMode: SidebarTerminalPathDisplayMode = TerminalSettings.shared.sidebarTerminalPathDisplayMode
    ) {
        self.init(
            tabName: SidebarSessionLabel.label(for: session, pathDisplayMode: pathDisplayMode).title,
            program: Self.program(of: session, policy: policy),
            canDetach: SessionCloseCoordinator.canDetach(session)
        )
    }

    var messageText: String { "Close “\(tabName)”?" }

    var informativeText: String { "\(program) is running. Closing the tab stops it." }

    var buttonTitles: [String] {
        [Self.closeButtonTitle] + (canDetach ? [Self.detachButtonTitle] : []) + ["Cancel"]
    }

    @MainActor
    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: Self.closeButtonTitle).hasDestructiveAction = true
        if canDetach {
            alert.addButton(withTitle: Self.detachButtonTitle)
        }
        // A button titled Cancel gets Escape.
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// What a button of `makeAlert()` answered.
    func answer(for response: NSApplication.ModalResponse) -> TabCloseAnswer {
        switch response {
        case .alertFirstButtonReturn: .close
        case .alertSecondButtonReturn where canDetach: .detach
        default: .cancel
        }
    }

    /// The subject of "… is running".
    @MainActor
    static func program(of session: TerminalSession, policy: SessionBackendPolicy) -> String {
        switch session.kind {
        case .agent:
            return "This agent"
        case .command:
            return session.launchCommand?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? session.title
        case .terminal:
            let hosting = session.persistentHosting ?? policy.localSessions
            let foreground = session.hostedSessionBinding
                .flatMap { hosting?.sessionInfo($0.sessionID)?.foreground?.name.nilIfEmpty }
            return foreground ?? "A program"
        }
    }
}

// MARK: - Closing a tab that leaves its program running

/// What a window's toast says when closing tabs left their sessions
/// running in the background, instead of a confirmation: the user detached
/// them (⌘D, Detach, Detach Instead), or they were attached to sessions
/// they do not own, which a close only disconnects. A detach always says
/// where its session went; a close only when its program was at work (an
/// idle shell, or a program that ended, is not worth a word).
struct ClosedTabNotice: Equatable {
    /// How Reopen brings a session back (`SessionCloseCoordinator.reopen`).
    enum Reopen: Equatable {
        /// This app's own session, now in Background Sessions.
        case backgroundSession(id: String)
        /// A session the tab was attached to without owning it, and the
        /// worktree the tab was closed from.
        case attach(HostedSessionAttachment, worktreeRoot: String?)
    }

    static let backgroundSessionsMessage = "Open or end it from Background Sessions in the Cherry menu bar icon."
    static let backgroundSessionsMessagePlural = "Open or end them from Background Sessions in the Cherry menu bar icon."
    static let persistentSessionsMessage = "Attach to it again from File › Persistent Sessions."

    /// The closed tabs' sidebar names.
    let tabNames: [String]
    /// How many of them were attached to sessions they did not own.
    let attachedCount: Int
    /// The sessions Reopen brings back: none for a persistent tab closed
    /// while its session's Create was under way, as that session has no id
    /// yet (it goes to Background Sessions).
    let reopen: [Reopen]

    /// `tabName`: the tab's sidebar name.
    init(tabName: String, reopen: Reopen?, attached: Bool? = nil) {
        tabNames = [tabName]
        if let attached {
            attachedCount = attached ? 1 : 0
        } else if case .attach = reopen {
            attachedCount = 1
        } else {
            attachedCount = 0
        }
        self.reopen = reopen.map { [$0] } ?? []
    }

    private init(tabNames: [String], attachedCount: Int, reopen: [Reopen]) {
        self.tabNames = tabNames
        self.attachedCount = attachedCount
        self.reopen = reopen
    }

    /// One notice for tabs closed together; nil for none.
    static func combining(_ notices: [ClosedTabNotice]) -> ClosedTabNotice? {
        guard notices.count > 1 else { return notices.first }
        return ClosedTabNotice(
            tabNames: notices.flatMap(\.tabNames),
            attachedCount: notices.reduce(0) { $0 + $1.attachedCount },
            reopen: notices.flatMap(\.reopen)
        )
    }

    /// What runs on: the tab's name, or how many tabs.
    var subject: String {
        tabNames.count == 1 ? tabNames[0] : "\(tabNames.count) tabs"
    }

    var predicate: String {
        tabNames.count == 1 ? " is running in the background" : " are running in the background"
    }

    var title: String { subject + predicate }

    /// Where to find them again.
    var message: String {
        let single = tabNames.count == 1
        switch attachedCount {
        case 0:
            return single ? Self.backgroundSessionsMessage : Self.backgroundSessionsMessagePlural
        case tabNames.count:
            return single ? Self.persistentSessionsMessage : "Attach to them again from File › Persistent Sessions."
        default:
            return "Find them in Background Sessions in the Cherry menu bar icon, or in File › Persistent Sessions."
        }
    }

    /// The notice for closing `session`'s tab in `worktreeRoot`'s workspace
    /// with `intent`, read before it closes: nil when the close ends its
    /// program (asked about or not), or, for a close that is not a detach,
    /// when its program is not at work (`programIsAtWork`).
    @MainActor
    static func make(
        for session: TerminalSession,
        in worktreeRoot: String? = nil,
        intent: SessionCloseIntent = .userClosedTab,
        policy: SessionBackendPolicy,
        pathDisplayMode: SidebarTerminalPathDisplayMode = TerminalSettings.shared.sidebarTerminalPathDisplayMode
    ) -> ClosedTabNotice? {
        guard !SessionCloseCoordinator.closeEndsProgram(of: session, intent: intent, policy: policy),
              intent == .userDetachedTab || programIsAtWork(session, policy: policy)
        else { return nil }
        return ClosedTabNotice(
            tabName: SidebarSessionLabel.label(for: session, pathDisplayMode: pathDisplayMode).title,
            reopen: reopenTarget(for: session, in: worktreeRoot),
            attached: session.hostedAttachment != nil
        )
    }

    /// The session a tab of `worktreeRoot`'s workspace shows, as Reopen
    /// finds it again once the tab closed.
    @MainActor
    static func reopenTarget(for session: TerminalSession, in worktreeRoot: String? = nil) -> Reopen? {
        if let attachment = session.hostedAttachment {
            return .attach(attachment, worktreeRoot: worktreeRoot)
        }
        return session.persistentSession.map { .backgroundSession(id: $0.sessionID) }
    }

    /// A command or agent whose program runs, or a terminal whose shell runs
    /// a job in its foreground: as its host reports it for a session of
    /// This Mac (`TerminalSession.hasRunningProcess`); a terminal attached
    /// to an SSH host's session counts as idle.
    @MainActor
    static func programIsAtWork(_ session: TerminalSession, policy: SessionBackendPolicy) -> Bool {
        guard session.isProgramRunning, !session.hostedSessionEnded else { return false }
        switch session.kind {
        case .command, .agent:
            return true
        case .terminal:
            guard let attachment = session.hostedAttachment else { return session.hasRunningProcess() }
            guard attachment.host == .local else { return false }
            return policy.localSessions?.sessionInfo(attachment.sessionID)?.isBusy ?? false
        }
    }
}

// MARK: - Closing a window or quitting

/// What closing a project window or quitting would do to the tabs it
/// closes, for its one confirmation (`SessionTeardownConfirmation`).
struct SessionTeardownSummary: Equatable {
    /// A local persistent tab whose program runs.
    struct Session: Equatable {
        /// The tab's id.
        let id: UUID
        /// Its session on the local host; nil while its Create is under way.
        let hostSessionID: String?
        /// The tab's name, as the sidebar shows it.
        let title: String
        /// Its project (a quit), or its worktree (a window with tabs in
        /// several); nil otherwise.
        let place: String?
        /// Its program is busy (`TerminalSession.hasRunningProcess`): a
        /// command, an agent, or a shell running a job.
        let isBusy: Bool
    }

    /// Local persistent tabs whose program runs (their Create may still be
    /// under way): the answer keeps them running or ends them. Busy ones
    /// first. Native tabs, tabs attached to a session they do not own and
    /// tabs whose program ended are not asked about.
    var runningSessions: [Session] = []
    /// Persistent tabs a teardown that ends sessions ends, ended ones too:
    /// a quit that ends them waits for their host.
    var persistentTabCount = 0
    /// Busy tabs the teardown stops even when it keeps sessions (native tabs).
    var stoppedWhenKeeping = 0
    /// Busy tabs a teardown that ends sessions stops (native and persistent).
    var stoppedWhenEnding = 0
    /// Saved tabs no open tab shows whose sessions a teardown that ends
    /// sessions ends too (`RepositoryWorkspace.endSavedSessionsNotOpen`);
    /// not asked about.
    var savedSessionsNotOpen = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        let sessions = lhs.runningSessions + rhs.runningSessions
        return Self(
            runningSessions: sessions.filter(\.isBusy) + sessions.filter { !$0.isBusy },
            persistentTabCount: lhs.persistentTabCount + rhs.persistentTabCount,
            stoppedWhenKeeping: lhs.stoppedWhenKeeping + rhs.stoppedWhenKeeping,
            stoppedWhenEnding: lhs.stoppedWhenEnding + rhs.stoppedWhenEnding,
            savedSessionsNotOpen: lhs.savedSessionsNotOpen + rhs.savedSessionsNotOpen
        )
    }
}

/// The one dialog, at most, that closing a project window or quitting
/// shows: the question about its running local sessions, which also names
/// the busy programs the close stops anyway, or else today's confirmation
/// for those programs.
enum SessionTeardownConfirmation: Equatable {
    /// Close or quit now, ending local sessions or keeping them.
    case none(endsSessions: Bool)
    /// "Close window?" / "Quit Cherry?": `count` busy programs stop.
    case confirmStopping(count: Int, endsSessions: Bool)
    /// "Keep N sessions running in the background?" (`SessionTeardownQuestion`).
    case askAboutSessions

    /// `preference`: Settings › Sessions (`LocalSessionsOnQuit`).
    /// `mayAsk`: false for a log out, restart, shut down or update, which
    /// keep sessions whatever the preference and never ask about them. With
    /// no running session nothing is asked: ended persistent tabs follow the
    /// preference (asking keeps them, showing their exit next time).
    /// `systemEndsSessions`: a log out, restart or shut down, after which
    /// the system ends the sessions it keeps: their busy programs stop as
    /// surely as native ones, so they are confirmed too, and Cancel keeps
    /// the user logged in.
    static func decide(
        _ summary: SessionTeardownSummary,
        preference: LocalSessionsOnQuit,
        mayAsk: Bool,
        systemEndsSessions: Bool = false
    ) -> Self {
        if mayAsk, preference == .ask, !summary.runningSessions.isEmpty {
            return .askAboutSessions
        }
        let endsSessions = mayAsk && preference == .end
        let stopped = endsSessions || systemEndsSessions ? summary.stoppedWhenEnding : summary.stoppedWhenKeeping
        return stopped > 0 ? .confirmStopping(count: stopped, endsSessions: endsSessions) : .none(endsSessions: endsSessions)
    }
}

/// What quitting does once its one dialog, if any, is decided
/// (`CherryAppDelegate.applicationShouldTerminate`).
enum SessionQuitPlan: Equatable {
    /// Quit at once: nothing to stop or end. Kept sessions outlive the app.
    case terminateNow
    /// Take every window off screen, tear down the tabs whose close does
    /// what the app's exit does not, with this intent, then quit
    /// (`finishQuit`): ending sessions is waited for.
    case finish(SessionCloseIntent)
    /// "Quit Cherry?" for `count` busy programs; confirmed, tear down with
    /// `intent`.
    case confirmStopping(count: Int, intent: SessionCloseIntent)
    /// "Keep N sessions running in the background?"; its answer's intent
    /// (`SessionTeardown.intent(for:)`) tears down.
    case askAboutSessions

    init(_ decision: SessionTeardownConfirmation, summary: SessionTeardownSummary) {
        switch decision {
        case .none(let endsSessions):
            // Idle persistent tabs, or the sessions of saved tabs no open
            // tab shows, that quitting ends: end them, then quit.
            let ends = endsSessions && (summary.persistentTabCount > 0 || summary.savedSessionsNotOpen > 0)
            self = ends ? .finish(.appQuitEndingSessions) : .terminateNow
        case .confirmStopping(let count, let endsSessions):
            self = .confirmStopping(count: count, intent: SessionTeardown.quit.intent(endingSessions: endsSessions))
        case .askAboutSessions:
            self = .askAboutSessions
        }
    }

    /// What a quit answered or confirmed with `intent` does (Keep Running,
    /// End Sessions, "Quit Cherry?"). Keeping local sessions with no native
    /// program to stop (`nativeProgramsStopped`: busy native tabs, counted
    /// when answered) and no session being ended (`endingSessions`: a tab
    /// closed just before, whose Kill or Remove is still under way, which
    /// ⌘Z could still bring back, whose session the quit ends, or whose
    /// Create was still under way, whose session is ended when it answers), it
    /// quits at once, as a quit with nothing running does: idle native
    /// shells end with the app (their terminals hang up; a background job
    /// that ignores SIGHUP outlives it, as it does a quit that asked
    /// nothing), as do the attach adapters of persistent tabs, whose
    /// sessions run on. Otherwise the quit tears down, then waits for what
    /// it stops or ends.
    static func confirmed(_ intent: SessionCloseIntent, nativeProgramsStopped: Int, endingSessions: Bool = false) -> Self {
        intent.endsLocalSessions || nativeProgramsStopped > 0 || endingSessions ? .finish(intent) : .terminateNow
    }
}

enum SessionTeardownAnswer: Equatable, Sendable {
    case keep
    case end
    case cancel
}

/// "Keep N sessions running in the background?", asked when a project
/// window closes or Cherry quits with local sessions running: Keep Running
/// (the default), End Sessions or Cancel, and "Don't ask again", which
/// stores a Keep or End answer as the preference.
@MainActor
struct SessionTeardownQuestion {
    let teardown: SessionTeardown
    let summary: SessionTeardownSummary
    /// The window's project, for a window close.
    let projectName: String?

    /// How many sessions the question lists by name; the rest are counted.
    static let listedSessionLimit = 5

    var messageText: String {
        let count = summary.runningSessions.count
        return count == 1
            ? "Keep 1 session running in the background?"
            : "Keep \(count) sessions running in the background?"
    }

    var informativeText: String {
        let single = summary.runningSessions.count == 1
        let project = projectName ?? "this project"
        let keeping = switch (teardown, single) {
        case (.quit, true):
            "It keeps running after Cherry quits, and its tab comes back when you open Cherry again. "
                + "End Sessions stops its program."
        case (.quit, false):
            "They keep running after Cherry quits, and their tabs come back when you open Cherry again. "
                + "End Sessions stops their programs."
        case (.windowClose, true):
            "It keeps running after this window closes, and its tab comes back when you open \(project) again. "
                + "Until then, open or end it from Background Sessions in the Cherry menu bar icon. "
                + "End Sessions stops its program."
        case (.windowClose, false):
            "They keep running after this window closes, and their tabs come back when you open \(project) again. "
                + "Until then, open or end them from Background Sessions in the Cherry menu bar icon. "
                + "End Sessions stops their programs."
        }
        let stopped = summary.stoppedWhenKeeping
        guard stopped > 0 else { return keeping }
        let stopping = switch (teardown, stopped == 1) {
        case (.quit, true): "1 other running process will be stopped."
        case (.quit, false): "\(stopped) other running processes will be stopped."
        case (.windowClose, true): "This window has 1 other running process. It will be stopped."
        case (.windowClose, false): "This window has \(stopped) other running processes. They will be stopped."
        }
        return keeping + "\n\n" + stopping
    }

    /// One line per session, busy ones first and marked, then how many
    /// more there are.
    var sessionList: String {
        let sessions = summary.runningSessions
        var lines = sessions.prefix(Self.listedSessionLimit).map { session in
            "• " + session.title
                + (session.place.map { " — " + $0 } ?? "")
                + (session.isBusy ? " (running)" : "")
        }
        if sessions.count > Self.listedSessionLimit {
            lines.append("and \(sessions.count - Self.listedSessionLimit) more")
        }
        return lines.joined(separator: "\n")
    }

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = summary.stoppedWhenKeeping > 0 ? .warning : .informational
        // Return keeps them; a button titled Cancel gets Escape.
        alert.addButton(withTitle: LocalSessionsOnQuit.keep.label)
        alert.addButton(withTitle: LocalSessionsOnQuit.end.label).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let list = NSTextField(wrappingLabelWithString: sessionList)
        list.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        list.textColor = .secondaryLabelColor
        list.preferredMaxLayoutWidth = 260
        list.setFrameSize(list.fittingSize)
        alert.accessoryView = list
        return alert
    }

    /// The answer a button gave, and the preference "Don't ask again"
    /// stores with it: Keep or End only, never a Cancel.
    nonisolated static func answer(
        for response: NSApplication.ModalResponse,
        suppressed: Bool
    ) -> (answer: SessionTeardownAnswer, remember: LocalSessionsOnQuit?) {
        switch response {
        case .alertFirstButtonReturn: (.keep, suppressed ? .keep : nil)
        case .alertSecondButtonReturn: (.end, suppressed ? .end : nil)
        default: (.cancel, nil)
        }
    }

    /// `answer(for:suppressed:)` for `alert`'s suppression checkbox.
    static func answer(
        of alert: NSAlert,
        response: NSApplication.ModalResponse
    ) -> (answer: SessionTeardownAnswer, remember: LocalSessionsOnQuit?) {
        answer(for: response, suppressed: alert.suppressionButton?.state == .on)
    }
}
