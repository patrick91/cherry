import CoreFoundation
import Foundation
import Testing
@testable import Cherry

// A release build's first launch copies the settings of the local builds
// before it (dev.patrick.cherry.local) once (`LegacyDefaultsImport`, the
// first statement of `CherryApp.init`). Only the release identity imports;
// these tests never touch either real preferences domain.

/// A preferences domain in memory.
private final class MemoryDomain {
    var values: [String: Any]
    var reads = 0
    var writes = 0

    init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    var domain: LegacyDefaultsImport.Domain {
        LegacyDefaultsImport.Domain(
            read: {
                self.reads += 1
                return self.values
            },
            write: { values in
                self.writes += 1
                self.values.merge(values) { _, new in new }
            }
        )
    }
}

/// The release identity's data folder and scheme.
private var releaseInfo: [String: Any] {
    ["CherryApplicationSupportName": "Cherry", "CherryURLScheme": "cherry"]
}

@Test func importRunsOnlyForTheReleaseIdentity() {
    let others: [(String?, [String: Any])] = [
        // The local builds themselves.
        ("dev.patrick.cherry.local", releaseInfo),
        // CherryDev (script/build_and_run.sh).
        ("app.cherry.CherryDev", ["CherryApplicationSupportName": "CherryDev", "CherryURLScheme": "cherry-dev"]),
        // `swift run`, tests.
        (nil, releaseInfo),
        // The release id with its data or links elsewhere.
        ("dev.patrick.cherry", ["CherryApplicationSupportName": "Cherry Local", "CherryURLScheme": "cherry"]),
        ("dev.patrick.cherry", ["CherryApplicationSupportName": "Cherry", "CherryURLScheme": "cherry-local"]),
        ("dev.patrick.cherry", [:]),
    ]
    for (identifier, info) in others {
        let label = Comment(rawValue: "\(identifier ?? "nil") \(info)")
        let source = MemoryDomain(["terminal.appearance": "dark"])
        let target = MemoryDomain()
        #expect(LegacyDefaultsImport.runIfNeeded(
            bundleIdentifier: identifier, info: info, source: source.domain, target: target.domain
        ) == -1, label)
        #expect(source.reads == 0 && target.reads == 0, label)
        #expect(target.writes == 0, label)
        #expect(target.values.isEmpty, label)
    }
    #expect(CherryRelease.isReleaseIdentity(bundleIdentifier: "dev.patrick.cherry", info: releaseInfo))
}

@Test func importCopiesPersistedKeysSkipsSparkleAndNeverOverwrites() {
    let source = MemoryDomain([
        "terminal.appearance": "dark",
        "sessions.onQuit": "end",
        "projects": ["/Users/me/cherry"],
        "SULastCheckTime": Date(timeIntervalSince1970: 1_800_000_000),
        "SUEnableAutomaticChecks": false,
        LegacyDefaultsImport.markerKey: "something else",
    ])
    let target = MemoryDomain(["sessions.onQuit": "keep"])

    let imported = LegacyDefaultsImport.runIfNeeded(
        bundleIdentifier: CherryRelease.bundleIdentifier, info: releaseInfo,
        source: source.domain, target: target.domain
    )
    #expect(imported == 2)
    #expect(target.values["terminal.appearance"] as? String == "dark")
    #expect(target.values["projects"] as? [String] == ["/Users/me/cherry"])
    // The target's own value stays.
    #expect(target.values["sessions.onQuit"] as? String == "keep")
    // Sparkle's keys are the new app's own.
    #expect(target.values["SULastCheckTime"] == nil)
    #expect(target.values["SUEnableAutomaticChecks"] == nil)
    #expect(target.values[LegacyDefaultsImport.markerKey] as? String == "dev.patrick.cherry.local")
    // The old domain is never changed.
    #expect(source.writes == 0)
    #expect(source.values["sessions.onQuit"] as? String == "end")

    // The plan alone.
    let plan = LegacyDefaultsImport.plan(source: ["a": 1, "SUFeedURL": "x", "b": 2], target: ["b": 3])
    #expect(Set(plan?.keys.map { $0 } ?? []) == ["a", LegacyDefaultsImport.markerKey])
}

@Test func importSetsTheMarkerEvenWhenTheOldDomainIsEmptyAndRunsOnce() {
    let source = MemoryDomain()
    let target = MemoryDomain()
    #expect(LegacyDefaultsImport.runIfNeeded(
        bundleIdentifier: CherryRelease.bundleIdentifier, info: releaseInfo,
        source: source.domain, target: target.domain
    ) == 0)
    #expect(target.values.count == 1)
    #expect(target.values[LegacyDefaultsImport.markerKey] as? String == CherryRelease.legacyBundleIdentifier)

    // Settings the old build saves later are not taken.
    source.values["terminal.appearance"] = "dark"
    #expect(LegacyDefaultsImport.runIfNeeded(
        bundleIdentifier: CherryRelease.bundleIdentifier, info: releaseInfo,
        source: source.domain, target: target.domain
    ) == -1)
    #expect(target.writes == 1)
    #expect(target.values["terminal.appearance"] == nil)
    #expect(LegacyDefaultsImport.plan(source: ["a": 1], target: [LegacyDefaultsImport.markerKey: "x"]) == nil)
}

@Test func cfPreferencesDomainsRoundTrip() throws {
    let base = "CherryTests.LegacyImport.\(UUID().uuidString)"
    let sourceName = "\(base).source"
    let targetName = "\(base).target"
    defer {
        UserDefaults.standard.removePersistentDomain(forName: sourceName)
        UserDefaults.standard.removePersistentDomain(forName: targetName)
    }
    let sourceDefaults = try #require(UserDefaults(suiteName: sourceName))
    sourceDefaults.set("dark", forKey: "terminal.appearance")
    sourceDefaults.set(true, forKey: "sessions.persistLocal")
    sourceDefaults.set(Date(timeIntervalSince1970: 1_800_000_000), forKey: "SULastCheckTime")
    // Registered defaults are not persisted: not the old build's settings.
    sourceDefaults.register(defaults: ["registered.only": 1])
    let targetDefaults = try #require(UserDefaults(suiteName: targetName))
    targetDefaults.set("keep", forKey: "sessions.onQuit")
    // Nor do they count as the new app's own values.
    targetDefaults.register(defaults: ["terminal.appearance": "light"])

    let source = LegacyDefaultsImport.Domain.cfPreferences(sourceName)
    let target = LegacyDefaultsImport.Domain.cfPreferences(targetName)
    let read = source.read()
    #expect(read["terminal.appearance"] as? String == "dark")
    #expect(read["registered.only"] == nil)
    #expect(target.read()["terminal.appearance"] == nil)

    let imported = LegacyDefaultsImport.runIfNeeded(
        bundleIdentifier: CherryRelease.bundleIdentifier, info: releaseInfo, source: source, target: target
    )
    #expect(imported == 2)
    let written = target.read()
    #expect(written["terminal.appearance"] as? String == "dark")
    #expect(written["sessions.persistLocal"] as? Bool == true)
    #expect(written["sessions.onQuit"] as? String == "keep")
    #expect(written["SULastCheckTime"] == nil)
    #expect(written[LegacyDefaultsImport.markerKey] as? String == CherryRelease.legacyBundleIdentifier)
    // The app reads them through UserDefaults.
    #expect(UserDefaults(suiteName: targetName)?.string(forKey: "terminal.appearance") == "dark")
    #expect(UserDefaults(suiteName: targetName)?.bool(forKey: "sessions.persistLocal") == true)
    // The old domain is unchanged.
    #expect(source.read()[LegacyDefaultsImport.markerKey] == nil)
    #expect(source.read().count == 3)

    // Once.
    #expect(LegacyDefaultsImport.runIfNeeded(
        bundleIdentifier: CherryRelease.bundleIdentifier, info: releaseInfo, source: source, target: target
    ) == -1)
}
