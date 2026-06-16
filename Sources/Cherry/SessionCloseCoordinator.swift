import Foundation

@MainActor
enum SessionCloseCoordinator {
    static func close(
        _ session: TerminalSession,
        in workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState?
    ) {
        guard session.kind == .agent else {
            workspace.close(session)
            return
        }

        if !workspace.descendantAgentSessions(of: session).isEmpty {
            if let chromeState {
                chromeState.requestAgentGroupClose(sessionID: session.id)
            } else {
                workspace.close(session)
            }
            return
        }

        if session.isRunning, let chromeState {
            chromeState.requestAgentClose(sessionID: session.id)
        } else {
            workspace.close(session)
        }
    }
}
