import Foundation

// A spawn's first message (`spawn_agent` with `message`, `spawn_process`
// with an agent's text) goes in as a task's kickoff does: once the agent
// shows its composer on a still screen (`waitForAgentComposerReadiness`).
// Typed is not sent: Claude Code can show its composer before it takes
// input (while it loads) and drop the Enter, leaving the message in its
// composer while the spawn said it was sent. So the message is watched
// after it was typed, as a kickoff is (`checkKickoff`): its turn starting
// ends the watch, and a message left in the composer gets its Enter.
// Unlike a kickoff, it is never typed again: it has no mark Cherry could
// find it by among the sent messages, so a message gone from the composer
// counts as sent.

extension CherryControlServer {
    /// How long a first message is watched after it was typed.
    static let firstMessageWatchLimit: TimeInterval = 60
    /// How often it is looked at.
    static let firstMessageCheckInterval: Duration = .milliseconds(100)

    /// What a look at a first message decided.
    enum FirstMessageStep: Equatable {
        /// Look again later.
        case wait
        /// It sits unsent in the composer: press its Enter.
        case pressEnter
        /// Nothing more to do, and why.
        case done(String)
    }

    /// Watches `message`, typed into the agent `session` just started at
    /// `typedAt` with its Enter, until its turn starts, it leaves the
    /// composer, the tab ends, or `firstMessageWatchLimit` passed; Enter
    /// again (at most `maximumKickoffEnterPresses` times) while it sits
    /// unsent in the composer (`firstMessageStep`).
    @MainActor
    func watchFirstMessage(_ message: String, into session: TerminalSession, workspace: TerminalWorkspace, typedAt: Date) {
        let deadline = typedAt.addingTimeInterval(Self.firstMessageWatchLimit)
        Task { @MainActor [weak self, weak session, weak workspace] in
            var enterPresses = 0
            var lastActionAt = typedAt
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.firstMessageCheckInterval)
                guard let self, let session else { return }
                let tab = session.id.uuidString
                guard Date() < deadline else {
                    SessionLog.debug("[agent] first message of \(tab): no longer watched (\(Int(Self.firstMessageWatchLimit)) s)")
                    return
                }
                await self.refreshForMonitorIfDue(session, now: Date())
                let step = self.firstMessageStep(
                    message, session: session, workspace: workspace,
                    typedAt: typedAt, lastActionAt: lastActionAt, enterPresses: enterPresses, now: Date()
                )
                switch step {
                case .wait:
                    continue
                case .done(let why):
                    SessionLog.debug("[agent] first message of \(tab): \(why)")
                    return
                case .pressEnter:
                    enterPresses += 1
                    SessionLog.notice("[agent] first message of \(tab) sat unsent in its composer: pressed its Enter (\(enterPresses))")
                    do {
                        _ = try await self.typeCherryLine("", into: session)
                    } catch {
                        SessionLog.debug("[agent] first message of \(tab): its Enter was not sent: \(error)")
                        return
                    }
                    lastActionAt = Date()
                }
            }
        }
    }

    /// One look at a first message typed at `typedAt`: done once its turn
    /// started (`kickoffTurnStarted`), its tab ended, or the composer does
    /// not hold it (sent, or cleared); else, once `kickoffCheckDelay`
    /// passed since it was typed or Enter was last pressed, the screen has
    /// been still for `kickoffQuietInterval`, nobody types into the tab and
    /// Cherry types no line into it, and the agent is at its composer
    /// (reports idle, or shows its composer when it reports nothing): its
    /// Enter, when the composer holds it (`composerHolds`) and fewer than
    /// `maximumKickoffEnterPresses` were pressed. Never at a permission
    /// prompt or a question.
    @MainActor
    func firstMessageStep(
        _ message: String,
        session: TerminalSession,
        workspace: TerminalWorkspace?,
        typedAt: Date,
        lastActionAt: Date,
        enterPresses: Int,
        now: Date
    ) -> FirstMessageStep {
        let status = monitorStatus(session: session, workspace: workspace, now: now)
        switch status {
        case "closed", "exited", "disconnected":
            return .done("its tab is \(status)")
        default:
            break
        }
        if kickoffTurnStarted(session, since: typedAt) { return .done("its turn started") }
        guard now.timeIntervalSince(lastActionAt) >= tasks.kickoffCheckDelay,
              screenIsStill(session, for: tasks.kickoffQuietInterval, now: now),
              session.acceptsControlInput,
              !session.humanIsComposing(within: tasks.kickoffQuietInterval),
              !isTypingWakeLine(into: session)
        else { return .wait }
        let lines = terminalOutput(for: session, startLine: nil, lineLimit: 80).lines
        let agent = session.agentToolKey
        if session.reportsProgramStatus {
            guard session.agentActivityState == .idle else { return .wait }
        } else {
            guard AgentScreenActivity.verdict(for: lines, agent: agent) == .prompt else { return .wait }
        }
        guard AgentScreenActivity.composerHolds(message, in: lines, agent: agent) else {
            return .done("its composer does not hold it")
        }
        guard enterPresses < AgentTaskRegistry.maximumKickoffEnterPresses else {
            return .done("it stayed unsent in its composer after \(enterPresses) Enters")
        }
        return .pressEnter
    }
}
