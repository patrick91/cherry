import Foundation

enum AgentActivityState: String, Equatable, Codable {
    case unknown
    case idle
    case permission
    /// The agent asks the user a question with a choice menu
    /// (`AgentQuestionPrompt`) and its turn waits on the answer. The raw
    /// value is the one MCP reports.
    case needsInput = "needs_input"
    case working
    case error

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
