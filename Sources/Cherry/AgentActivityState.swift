import Foundation

enum AgentActivityState: String, Equatable, Codable {
    case unknown
    case idle
    case permission
    case working
    case error

    var showsWorkingIndicator: Bool {
        self == .working
    }
}
