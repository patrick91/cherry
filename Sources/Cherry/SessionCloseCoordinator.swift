import AppKit
import Foundation

/// Why a tab is being closed. Every path that ends a tab's program names one,
/// because a persistent (hosted) session can outlive its tab and the right
/// outcome depends on who closed it.
enum SessionCloseIntent: String, CaseIterable, Sendable {
    /// Tab close button, ⌘W, the sidebar's Close.
    case userClosedTab
    /// MCP `close_process` / `close_terminal`; a user tab close by proxy.
    case mcpClose
    /// The project window closed.
    case windowClosed
    /// Cherry is quitting.
    case appQuit
    /// A second window for an already open project is discarded.
    case duplicateWindowTeardown
    /// The tab's worktree was removed.
    case worktreeRemoved
    /// Restart (menu, MCP `restart_process`): end the program and start it
    /// again in the same tab.
    case restart

    /// The whole workspace goes away with its window or the app. Workspace
    /// persistence keeps the state saved before the teardown.
    var tearsDownWorkspace: Bool {
        switch self {
        case .windowClosed, .appQuit, .duplicateWindowTeardown:
            true
        case .userClosedTab, .mcpClose, .worktreeRemoved, .restart:
            false
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
    /// follows Settings › Sessions (`hostedLocalAction(for:settings:)`).
    /// False makes a local persistent tab detach for every intent.
    static let hostedLocalTabsFollowSettings = true

    @MainActor
    static func closeAction(
        for session: TerminalSession,
        intent: SessionCloseIntent,
        settings: SessionPersistenceSettings,
        hostedLocalTabsFollowSettings: Bool = hostedLocalTabsFollowSettings
    ) -> SessionCloseAction {
        closeAction(
            for: SessionCloseBackend(session),
            intent: intent,
            settings: settings,
            hostedLocalTabsFollowSettings: hostedLocalTabsFollowSettings
        )
    }

    static func closeAction(
        for backend: SessionCloseBackend,
        intent: SessionCloseIntent,
        settings: SessionPersistenceSettings,
        hostedLocalTabsFollowSettings: Bool = hostedLocalTabsFollowSettings
    ) -> SessionCloseAction {
        switch backend {
        case .native:
            // Restart relaunches after the stop.
            return .stop
        case .hostedRemote:
            // Restart reconnects after the detach.
            return .detach
        case .hostedLocal:
            guard hostedLocalTabsFollowSettings else { return .detach }
            return hostedLocalAction(for: intent, settings: settings)
        }
    }

    /// The spec's "Local hosted tab" column. Restart terminates, then the tab
    /// creates a new session with the same tab id.
    static func hostedLocalAction(
        for intent: SessionCloseIntent,
        settings: SessionPersistenceSettings
    ) -> SessionCloseAction {
        switch intent {
        case .userClosedTab, .mcpClose:
            settings.keepLocalSessionsAfterTabClose ? .detach : .terminate
        case .windowClosed, .appQuit:
            settings.endLocalSessionsOnQuit ? .terminate : .detach
        case .duplicateWindowTeardown:
            .detach
        case .worktreeRemoved, .restart:
            .terminate
        }
    }
}

@MainActor
enum SessionCloseCoordinator {
    /// Whether closing `session`'s tab with `intent` ends its program, as
    /// its confirmations say: a native tab's close stops it, and a
    /// persistent tab's ends its session unless its close action detaches.
    /// A tab attached to a session it does not own (File › Persistent
    /// Sessions; another app's or the CLI's, or an SSH host's) only
    /// disconnects, whatever its close action: nothing ends that session.
    static func closeEndsProgram(
        of session: TerminalSession,
        intent: SessionCloseIntent = .userClosedTab,
        policy: SessionBackendPolicy
    ) -> Bool {
        guard session.hostedAttachment == nil else { return false }
        return policy.closeAction(for: session, intent: intent) != .detach
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

    /// ⌘W and File › Close Tab: closes the selected tab. When it is the
    /// window's last tab (no other worktree of the window has tabs), that
    /// tab closes as any tab the user closes (`userClosedTab`: a persistent
    /// tab's session ends unless Settings › Sessions keeps sessions after a
    /// tab close, and the tab is not saved to come back), then the window
    /// closes. Closing the window with the tab in it would detach the tab's
    /// session and restore the tab at the next launch. A running agent
    /// asks first, as closing any agent tab does; a busy program the close
    /// stops asks first, as closing the window did.
    static func closeSelectedTabOrWindow(
        workspace: TerminalWorkspace,
        repository: RepositoryWorkspace?,
        chromeState: ProjectWindowChromeState?,
        window: NSWindow?
    ) {
        if chromeState?.closeSelectedNoteIfNeeded() == true {
            return
        }
        guard shouldCloseWindow(for: workspace, repository: repository) else {
            guard let session = workspace.selectedSession else { return }
            close(
                session,
                in: workspace,
                chromeState: chromeState,
                allowEmptyWorkspace: hasOpenSessionsInOtherWorktrees(than: workspace, repository: repository)
            )
            return
        }
        guard let session = workspace.selectedSession ?? workspace.sessions.first else {
            window?.performClose(nil)
            return
        }
        closeLastTab(session, in: workspace, chromeState: chromeState, window: window)
    }

    private static func closeLastTab(
        _ session: TerminalSession,
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?,
        window: NSWindow?
    ) {
        if session.kind == .agent, session.isRunning, let chromeState {
            // Its confirmation closes the tab (`AgentCloseAlertPresenterView`),
            // then the window.
            windowsClosingAfterAgentTab[session.id] = WeakWindow(window)
            close(session, in: workspace, chromeState: chromeState, allowEmptyWorkspace: true)
            return
        }
        let closeTabThenWindow = { [weak workspace, weak session, weak window] in
            guard let workspace, let session, workspace.sessions.contains(where: { $0 === session }) else { return }
            workspace.close(session, allowEmptyWorkspace: true, intent: .userClosedTab)
            guard workspace.sessions.isEmpty else { return }
            window?.performClose(nil)
        }
        let endsProgram = closeEndsProgram(of: session, policy: workspace.backendPolicy)
        guard endsProgram, session.hasRunningProcess() else {
            closeTabThenWindow()
            return
        }
        confirmStoppingLastTab(window) { confirmed in
            if confirmed { closeTabThenWindow() }
        }
    }

    private struct WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow?) { self.window = window }
    }

    /// Windows whose last tab, a running agent, closes once its
    /// confirmation is answered (`agentTabCloseDidFinish`).
    private static var windowsClosingAfterAgentTab: [UUID: WeakWindow] = [:]

    /// The agent close confirmation for `sessionID` was answered: when that
    /// closed a window's last tab (⌘W), the window closes too.
    static func agentTabCloseDidFinish(sessionID: UUID, closed: Bool, workspace: TerminalWorkspace?) {
        guard let entry = windowsClosingAfterAgentTab.removeValue(forKey: sessionID) else { return }
        guard closed, let workspace, workspace.sessions.isEmpty else { return }
        entry.window?.performClose(nil)
    }

    /// Asks before ⌘W on a window's last tab stops its busy program, as
    /// closing the window asks (the window closes after the tab). Tests
    /// replace it.
    static var confirmStoppingLastTab: @MainActor (NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void = { window, answer in
        let alert = NSAlert()
        alert.messageText = "Close window?"
        alert.informativeText = "This window has a running process. It will be stopped."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and close")
        alert.addButton(withTitle: "Cancel")
        if let window, window.isVisible {
            RemoteViewCrashGuard.installIfNeeded()
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(response == .alertFirstButtonReturn) }
            }
        } else {
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// Agents that are running or have sub-agents ask for confirmation
    /// through `chromeState`; that confirmation closes with a user intent.
    static func close(
        _ session: TerminalSession,
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?,
        allowEmptyWorkspace: Bool = false,
        intent: SessionCloseIntent = .userClosedTab
    ) {
        guard session.kind == .agent else {
            workspace.close(session, allowEmptyWorkspace: allowEmptyWorkspace, intent: intent)
            return
        }

        if !workspace.descendantAgentSessions(of: session).isEmpty {
            if let chromeState {
                chromeState.requestAgentGroupClose(
                    sessionID: session.id,
                    allowEmptyWorkspace: allowEmptyWorkspace
                )
            } else {
                workspace.close(session, allowEmptyWorkspace: allowEmptyWorkspace, intent: intent)
            }
            return
        }

        if session.isRunning, let chromeState {
            chromeState.requestAgentClose(
                sessionID: session.id,
                allowEmptyWorkspace: allowEmptyWorkspace
            )
        } else {
            workspace.close(session, allowEmptyWorkspace: allowEmptyWorkspace, intent: intent)
        }
    }
}
