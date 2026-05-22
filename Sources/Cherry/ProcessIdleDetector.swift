import Foundation

enum ProcessIdleDetector {
    static func observedNewOutput(currentOutputVersion: Int, sinceOutputVersion: Int) -> Bool {
        currentOutputVersion > sinceOutputVersion
    }

    static func isQuiet(
        now: Date,
        lastOutputAt: Date?,
        startedAt: Date,
        quietMilliseconds: Int,
        requireNewOutput: Bool,
        observedNewOutput: Bool
    ) -> Bool {
        guard !requireNewOutput || observedNewOutput else { return false }
        guard quietMilliseconds > 0 else { return true }

        let quietInterval = TimeInterval(quietMilliseconds) / 1_000
        if let lastOutputAt {
            return now.timeIntervalSince(lastOutputAt) >= quietInterval
        }

        return !requireNewOutput && now.timeIntervalSince(startedAt) >= quietInterval
    }
}
