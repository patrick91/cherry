import Foundation

/// What a tab's program says it is doing, from its program status reports
/// (OSC 7501, `ProgramStatus`): its root record's state. `unknown` while it
/// reports nothing (a program or version that does not speak the protocol).
/// The raw values are the ones MCP reports.
enum AgentActivityState: String, Equatable, Codable {
    case unknown
    /// At rest at its prompt, or done with a turn.
    case idle
    /// Blocked on the user's approval (`kind=permission`).
    case permission
    /// Blocked on the user's answer or credentials (`kind=question`,
    /// `auth`, or no kind).
    case needsInput = "needs_input"
    case working
    case error

    init(_ status: ProgramStatus?) {
        guard let status else {
            self = .unknown
            return
        }
        switch status.state {
        case .idle, .done: self = .idle
        case .working: self = .working
        case .blocked: self = status.kind == .permission ? .permission : .needsInput
        case .error: self = .error
        case .unknown: self = .unknown
        }
    }

    var showsWorkingIndicator: Bool {
        self == .working
    }

    /// The turn waits on the user's answer to a permission prompt or a
    /// question: the sidebar, the menu bar and project switcher ask for
    /// the user's attention.
    var awaitsUserAnswer: Bool {
        self == .permission || self == .needsInput
    }
}

/// Where a tab's latest turn stands, from its program status reports. The
/// raw values are the ones MCP reports (`agent_turn_state`).
enum AgentTurnState: String, Codable, Equatable, Sendable {
    /// The program has not reported a turn since it started.
    case notStarted = "not_started"
    /// It reported `working` (or `blocked` within the turn).
    case active
    /// It reported `done` or `error` after working.
    case completed
    /// It went back to `idle` from a turn without finishing it (the user
    /// cancelled it).
    case userInterrupted = "user_interrupted"
}
