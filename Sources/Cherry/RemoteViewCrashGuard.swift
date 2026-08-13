import CherryCrashGuard
import Foundation

/// Protects window presentation from a macOS 27 ViewBridge regression.
///
/// The affected OS can leave Safari's text-completion remote view associated
/// with the wrong window, then raise an Objective-C exception the next time a
/// window (including a MenuBarExtra window) is ordered onscreen. Swift cannot
/// catch Objective-C exceptions, so the narrow catcher lives in a small
/// Objective-C target.
enum RemoteViewCrashGuard {
    static func isRequired(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion == 27
    }

    static func installIfNeeded() {
        guard isRequired(on: ProcessInfo.processInfo.operatingSystemVersion) else { return }
        CherryInstallRemoteViewCrashGuard()
    }
}
