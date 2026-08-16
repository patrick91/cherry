import Darwin
import Foundation

/// Resolves stable process identity from a PTY name exposed by libghostty.
struct TerminalTTYSessionIdentity: Equatable, Sendable {
    let sessionLeaderPID: pid_t

    init?(ttyName: String) {
        let trimmedName = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != "not a tty" else { return nil }

        let path = trimmedName.hasPrefix("/dev/")
            ? trimmedName
            : "/dev/\(URL(fileURLWithPath: trimmedName).lastPathComponent)"
        let fileDescriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fileDescriptor >= 0 else { return nil }
        defer { close(fileDescriptor) }

        let sessionLeaderPID = tcgetsid(fileDescriptor)
        guard sessionLeaderPID > 1 else { return nil }
        self.sessionLeaderPID = sessionLeaderPID
    }
}
