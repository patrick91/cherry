import Foundation

@MainActor
enum SessionCloseCoordinator {
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

    static func close(
        _ session: TerminalSession,
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?,
        allowEmptyWorkspace: Bool = false
    ) {
        guard session.kind == .agent else {
            workspace.close(session, allowEmptyWorkspace: allowEmptyWorkspace)
            return
        }

        if !workspace.descendantAgentSessions(of: session).isEmpty {
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

        if session.isRunning, let chromeState {
            chromeState.requestAgentClose(
                sessionID: session.id,
                allowEmptyWorkspace: allowEmptyWorkspace
            )
        } else {
            workspace.close(session, allowEmptyWorkspace: allowEmptyWorkspace)
        }
    }
}
