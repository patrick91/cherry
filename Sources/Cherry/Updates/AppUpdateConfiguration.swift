import CherryControl
import Foundation

/// The identity release builds have (Packaging/release.conf, docs/releasing.md).
enum CherryRelease {
    /// Packaging/release.conf RELEASE_BUNDLE_ID (AppUpdateTests keeps them equal).
    static let bundleIdentifier = "dev.patrick.cherry"
    /// Local builds before releases; their persisted defaults are imported once.
    static let legacyBundleIdentifier = "dev.patrick.cherry.local"

    /// Whether this Info.plist is the release identity: the bundle id AND Cherry's own
    /// data and scheme (raw values; a variant that keeps the id but moves its data is not).
    static func isReleaseIdentity(bundleIdentifier: String?, info: [String: Any]) -> Bool {
        bundleIdentifier == Self.bundleIdentifier
            && info["CherryApplicationSupportName"] as? String == CherryAppIdentity.defaultApplicationSupportName
            && info["CherryURLScheme"] as? String == CherryAppIdentity.defaultURLScheme
    }
}

/// Whether this copy of Cherry updates itself (`AppUpdater`), or why not.
enum AppUpdateEnablement: Equatable, Sendable {
    case enabled
    case disabled(Reason)

    enum Reason: Equatable, Sendable {
        /// `swift run`, tests.
        case notAnApp
        /// CherryDev, Cherry Sessions, smoke copies, variants (`CherryRelease.isReleaseIdentity` false).
        case otherIdentity(String?)
        case debugBuild
        /// No https SUFeedURL, SUPublicEDKey not base64 of 32 bytes, or empty CFBundleVersion.
        case notConfigured
        /// `HostedSessionInstallation.runsFromDiskImage`.
        case diskImage
        /// The instance lock is not resolved yet.
        case pending
        /// The instance lock is held by another copy.
        case secondCopy

        /// Shown in Settings › Updates.
        var explanation: String {
            switch self {
            case .notAnApp:
                "This copy runs outside an app bundle."
            case .otherIdentity(let identifier):
                identifier.map {
                    "This build (\($0)) doesn't update itself; only Cherry (\(CherryRelease.bundleIdentifier)) does."
                } ?? "This build doesn't update itself; only Cherry (\(CherryRelease.bundleIdentifier)) does."
            case .debugBuild:
                "Debug builds don't update themselves."
            case .notConfigured:
                "This build has no update feed or signing key."
            case .diskImage:
                "Move Cherry to Applications to get updates."
            case .pending:
                "Updates start once Cherry has finished opening its windows."
            case .secondCopy:
                "Another copy of Cherry is running; it handles updates."
            }
        }
    }

    var reason: Reason? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }

    /// Whether this binary was built in debug configuration.
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Pure. The first failing rule, in the order of the cases above, wins.
    /// `holdsInstanceLock`: nil while the lock is unresolved.
    static func decide(
        bundleIdentifier: String?,
        bundleURL: URL,
        info: [String: Any],
        isDebugBuild: Bool,
        runsFromDiskImage: Bool,
        holdsInstanceLock: Bool?
    ) -> AppUpdateEnablement {
        guard bundleURL.pathExtension.lowercased() == "app" else { return .disabled(.notAnApp) }
        guard CherryRelease.isReleaseIdentity(bundleIdentifier: bundleIdentifier, info: info) else {
            return .disabled(.otherIdentity(bundleIdentifier))
        }
        guard !isDebugBuild else { return .disabled(.debugBuild) }
        guard isConfigured(info) else { return .disabled(.notConfigured) }
        guard !runsFromDiskImage else { return .disabled(.diskImage) }
        guard let holdsInstanceLock else { return .disabled(.pending) }
        guard holdsInstanceLock else { return .disabled(.secondCopy) }
        return .enabled
    }

    /// An https SUFeedURL with a host, an SUPublicEDKey that is the base64
    /// of 32 bytes (an Ed25519 public key) and a CFBundleVersion: what
    /// Sparkle needs to start and to order builds.
    static func isConfigured(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        guard let key = info["SUPublicEDKey"] as? String,
              let data = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32
        else { return false }
        guard let build = info["CFBundleVersion"] as? String,
              !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }
}
