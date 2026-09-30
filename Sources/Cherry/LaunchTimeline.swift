import Darwin
import Foundation
import os

/// How long each phase of a launch took, from the moment the process started
/// until the restored windows show their tabs: one "launch: <phase> +<ms>"
/// line per phase in the unified log (`SessionLog`, category "Sessions"),
/// and a signpost event per phase (category "Launch", for Instruments'
/// os_signpost track). Read a launch with
/// `log show --last 2m --predicate 'eventMessage BEGINSWITH "launch:"'`.
/// Only the app's own launch is logged (`isEnabled`, which `CherryApp` sets;
/// tests leave it off), and only its first `window` seconds: later windows
/// are not part of the launch.
enum LaunchTimeline {
    /// Set once by the app, before its first phase.
    nonisolated(unsafe) static var isEnabled = false

    /// When this process started (the kernel's record, so it includes the
    /// time dyld and the runtime took before any of Cherry's code ran).
    static let processStart: Date = processStartDate() ?? Date()
    /// How long after the process started phases are still logged.
    static let window: TimeInterval = 60

    private static let signposter = OSSignposter(subsystem: SessionLog.subsystem, category: "Launch")

    /// Milliseconds since the process started.
    static func elapsedMilliseconds(now: Date = Date()) -> Int {
        Int((now.timeIntervalSince(processStart) * 1_000).rounded())
    }

    /// Logs `phase` with the time since the process started, while the
    /// launch lasts.
    static func mark(_ phase: @autoclosure () -> String) {
        guard isEnabled else { return }
        let elapsed = elapsedMilliseconds()
        guard Double(elapsed) < window * 1_000 else { return }
        let phase = phase()
        signposter.emitEvent("launch", "\(phase, privacy: .public)")
        // The wall clock too, to line the phases up with what is measured
        // outside the process (the log's own timestamps can be tens of
        // milliseconds off).
        let wall = String(format: "%.4f", Date().timeIntervalSince1970)
        SessionLog.notice("launch: \(phase) +\(elapsed)ms @\(wall)")
    }

    /// Whether phases are still logged now: the launch's first `seconds`
    /// (at most `window`). Cheap enough to ask per frame.
    static func isLogging(within seconds: TimeInterval = window) -> Bool {
        guard isEnabled else { return false }
        return Date().timeIntervalSince(processStart) < min(seconds, window)
    }

    private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
