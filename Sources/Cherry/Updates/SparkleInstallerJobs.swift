import Foundation
import os

/// Sparkle 2.10.0 submits its installer and progress agent as launchd jobs named after the host
/// bundle (InstallerLauncher/SUInstallerLauncher.m). Removing them discards a staged update:
/// the app's installer connection invalidates and Sparkle aborts the session (SUInstallationError).
/// Sparkle-internal: re-check on every Sparkle upgrade (docs/releasing.md).
enum SparkleInstallerJobs {
    private static let logger = Logger(subsystem: SessionLog.subsystem, category: "Updates")
    /// How long one `launchctl remove` may take.
    static let launchctlTimeout: TimeInterval = 2

    static func labels(bundleIdentifier: String) -> [String] {
        ["\(bundleIdentifier)-sparkle-updater", "\(bundleIdentifier)-sparkle-progress"]
    }

    /// `/bin/launchctl remove <label>` for each, waiting at most 2 s each; failures are logged, not thrown.
    static func remove(bundleIdentifier: String, run: (_ arguments: [String]) -> Void = Self.launchctl) {
        guard !bundleIdentifier.isEmpty else { return }
        for label in labels(bundleIdentifier: bundleIdentifier) {
            run(["remove", label])
        }
    }

    /// Runs `/bin/launchctl` with `arguments`, at most `launchctlTimeout`.
    static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let command = (["launchctl"] + arguments).joined(separator: " ")
        do {
            try process.run()
        } catch {
            logger.error("\(command, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard finished.wait(timeout: .now() + launchctlTimeout) == .success else {
            process.terminate()
            logger.error("\(command, privacy: .public) took longer than \(launchctlTimeout, privacy: .public) s")
            return
        }
        // A job that is not loaded (nothing staged) exits non-zero too.
        if process.terminationStatus != 0 {
            logger.info("\(command, privacy: .public) exited \(process.terminationStatus, privacy: .public)")
        }
    }
}
