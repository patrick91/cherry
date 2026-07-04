import Foundation

/// Backoff policy for auto-restarting managed commands. A command that keeps
/// exiting almost immediately is crash-looping: restarting it every 350ms
/// forever burns CPU and wipes the failure output before anyone can read it.
/// Escalate the delay between attempts and give up after a few consecutive
/// rapid exits; a manual restart (or a run that survives) resets the policy.
enum CommandAutoRestartPolicy {
    /// A run shorter than this counts as a rapid exit (crash-loop candidate).
    static let rapidExitInterval: TimeInterval = 5

    /// Delay before the next restart, indexed by consecutive rapid exits so
    /// far: a healthy command restarts quickly, each consecutive rapid exit
    /// escalates the delay, and exhausting the table pauses auto-restart.
    static let restartDelays: [TimeInterval] = [0.35, 1, 2, 5]

    static func nextConsecutiveRapidExitCount(previous: Int, runDuration: TimeInterval?) -> Int {
        guard let runDuration, runDuration < rapidExitInterval else { return 0 }
        return previous + 1
    }

    /// The delay before the next automatic restart, or nil to give up until a
    /// manual restart resets the policy.
    static func restartDelay(consecutiveRapidExits: Int) -> TimeInterval? {
        guard consecutiveRapidExits < restartDelays.count else { return nil }
        return restartDelays[consecutiveRapidExits]
    }
}
