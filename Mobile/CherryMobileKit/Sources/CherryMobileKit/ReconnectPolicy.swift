import Foundation

/// When the app connects to a Mac again by itself (docs/specs/ios-app.md,
/// Reconnects): after a dropped connection or a failed connect, with waits
/// that double up to a limit, but never after a refusal only the user can
/// change.
public struct ReconnectPolicy: Equatable, Sendable {
    public var firstDelay: Duration
    public var maximumDelay: Duration

    public static let standard = ReconnectPolicy(firstDelay: .seconds(1), maximumDelay: .seconds(30))

    public init(firstDelay: Duration, maximumDelay: Duration) {
        self.firstDelay = firstDelay
        self.maximumDelay = maximumDelay
    }

    /// The wait before try number `attempt` (1 for the first): `firstDelay`,
    /// doubled for each try after it, at most `maximumDelay`.
    public func delay(beforeAttempt attempt: Int) -> Duration {
        let doublings = min(max(attempt - 1, 0), 30)
        return min(firstDelay * (1 << doublings), maximumDelay)
    }

    /// Whether trying again can help after `error`: a Mac out of reach, its
    /// session host not running yet, a connection that broke. A refused key,
    /// a changed host key, a missing `cherry` or another protocol version
    /// stay as they are until the user changes something.
    public static func retries(after error: any Error) -> Bool {
        guard let error = error as? MacConnectionError else { return true }
        switch error {
        case .unreachable, .noSessionHost, .failed:
            return true
        case .authenticationFailed, .hostKeyMismatch, .cherryNotFound, .protocolMismatch, .sessionGone,
             .transcriptUnsupported, .noConversation:
            return false
        }
    }
}
