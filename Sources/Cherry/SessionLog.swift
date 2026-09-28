import Foundation
import os

/// The app's diagnostics about tabs and their sessions, in the unified log:
/// subsystem the app's bundle identifier, category "Sessions". Read them
/// with Console, or `log stream --predicate 'category == "Sessions"'`
/// (`--level debug` for the input and terminal traces that
/// `CHERRY_DEBUG_*` switches on). Messages are public: they name tabs,
/// sessions and paths. What was typed or printed (the input and buffer
/// traces a developer switches on) is private: the unified log redacts it
/// unless private data is enabled for the subsystem.
enum SessionLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "Cherry"
    private static let logger = Logger(subsystem: subsystem, category: "Sessions")

    /// A message as observers see it.
    struct Entry: Sendable, Equatable {
        var type: OSLogType
        var message: String
        /// Logged as private (`debugContent`).
        var isPrivate: Bool
    }

    private static let observers = OSAllocatedUnfairLock<[UUID: @Sendable (Entry) -> Void]>(
        initialState: [:]
    )

    /// Something about a session worth knowing afterwards: a tab that runs
    /// natively, a session that could not be ended or renamed.
    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        forward(Entry(type: .default, message: message, isPrivate: false))
    }

    /// Something went wrong that the user may notice.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        forward(Entry(type: .error, message: message, isPrivate: false))
    }

    /// A developer's trace (`CHERRY_DEBUG_*`) that holds nothing typed or
    /// printed.
    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        forward(Entry(type: .debug, message: message, isPrivate: false))
    }

    /// A developer's trace of what was typed or printed
    /// (`CHERRY_DEBUG_INPUT`): private in the unified log.
    static func debugContent(_ message: String) {
        logger.debug("\(message, privacy: .private)")
        forward(Entry(type: .debug, message: message, isPrivate: true))
    }

    /// Sees every message from now on (tests), until `remove` is called
    /// with the token.
    static func observe(_ handler: @escaping @Sendable (Entry) -> Void) -> UUID {
        let token = UUID()
        observers.withLock { $0[token] = handler }
        return token
    }

    static func remove(_ token: UUID) {
        _ = observers.withLock { $0.removeValue(forKey: token) }
    }

    private static func forward(_ entry: Entry) {
        let handlers = observers.withLock { Array($0.values) }
        for handler in handlers { handler(entry) }
    }
}
