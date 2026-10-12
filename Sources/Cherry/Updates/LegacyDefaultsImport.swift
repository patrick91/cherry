import CoreFoundation
import Foundation
import os

/// Copies the persisted defaults of the local builds Cherry had before releases
/// (dev.patrick.cherry.local) into this app's domain, once.
enum LegacyDefaultsImport {
    static let markerKey = "migration.importedDefaultsFrom"
    private static let logger = Logger(subsystem: SessionLog.subsystem, category: "Updates")

    /// A preferences domain's persisted values only (current user, any host): never the
    /// argument domain (launch arguments) or the registration domain.
    struct Domain {
        var read: () -> [String: Any]
        var write: ([String: Any]) -> Void

        static func cfPreferences(_ name: String) -> Domain {
            let domain = name as CFString
            return Domain(
                read: {
                    CFPreferencesCopyMultiple(nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                        as? [String: Any] ?? [:]
                },
                write: { values in
                    CFPreferencesSetMultiple(values as CFDictionary, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                }
            )
        }
    }

    /// Pure: the values to write, or nil when the import already ran. Every
    /// key of `source` but Sparkle's (`SU…`) that `target` lacks, and the
    /// marker, even when there is nothing else.
    static func plan(source: [String: Any], target: [String: Any]) -> [String: Any]? {
        guard target[markerKey] == nil else { return nil }
        var values: [String: Any] = [:]
        for (key, value) in source where !key.hasPrefix("SU") && key != markerKey && target[key] == nil {
            values[key] = value
        }
        values[markerKey] = CherryRelease.legacyBundleIdentifier
        return values
    }

    /// Imports once, only into the release identity (never `swift run`,
    /// tests, CherryDev, Cherry Sessions, smoke copies, or a variant that
    /// keeps the id but moves its data). The old domain is never changed.
    @discardableResult
    static func runIfNeeded(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        source: Domain = .cfPreferences(CherryRelease.legacyBundleIdentifier),
        target: Domain = .cfPreferences(CherryRelease.bundleIdentifier)
    ) -> Int {
        guard CherryRelease.isReleaseIdentity(bundleIdentifier: bundleIdentifier, info: info),
              let values = plan(source: source.read(), target: target.read())
        else { return -1 }
        target.write(values)
        let imported = values.count - 1
        logger.info("imported \(imported, privacy: .public) settings from \(CherryRelease.legacyBundleIdentifier, privacy: .public)")
        return imported
    }
}
