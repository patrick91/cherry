import CherryControl
import Foundation
import Testing
@testable import Cherry

@Test func appIdentityKeepsStandardBuildDefaults() {
    let identity = CherryAppIdentity()
    #expect(identity.applicationSupportName == "Cherry")
    #expect(identity.urlScheme == "cherry")
}

@Test func appIdentityReadsVariantAndRejectsUnsafeComponents() {
    var warnings: [String] = []
    let identity = CherryAppIdentity(infoDictionary: [
        "CherryApplicationSupportName": "Cherry Sessions",
        "CherryURLScheme": "cherry-sessions",
    ], warn: { warnings.append($0) })
    #expect(identity.applicationSupportName == "Cherry Sessions")
    #expect(identity.urlScheme == "cherry-sessions")
    #expect(warnings.isEmpty)
    #expect(MCPInstallCommandBuilder.commands(identity: identity).allSatisfy {
        $0.command.contains(" cherry-sessions -- ")
    })

    // Absent keys are the standard build and are not worth a warning.
    #expect(CherryAppIdentity(infoDictionary: [:], warn: { warnings.append($0) }) == CherryAppIdentity())
    #expect(warnings.isEmpty)

    let invalid = CherryAppIdentity(infoDictionary: [
        "CherryApplicationSupportName": "../Cherry",
        "CherryURLScheme": "cherry; exit",
    ], warn: { warnings.append($0) })
    #expect(invalid == CherryAppIdentity())
    #expect(warnings.count == 2)
    #expect(warnings.contains { $0.contains("CherryApplicationSupportName \"../Cherry\"") && $0.contains("\"Cherry\"") })
    #expect(warnings.contains { $0.contains("CherryURLScheme \"cherry; exit\"") && $0.contains("\"cherry\"") })
}

@Test func appIdentityWarnsForEveryOverrideThatFallsBackToCherry() {
    let invalidSupportNames: [Any] = ["", "  ", ".", "..", "Cherry/Sessions", "a\u{0}b", 42]
    for value in invalidSupportNames {
        var warnings: [String] = []
        let identity = CherryAppIdentity(
            infoDictionary: ["CherryApplicationSupportName": value, "CherryURLScheme": "cherry-dev"],
            warn: { warnings.append($0) }
        )
        #expect(identity.applicationSupportName == "Cherry")
        #expect(identity.urlScheme == "cherry-dev")
        #expect(warnings.count == 1 && warnings[0].hasPrefix("Ignoring invalid CherryApplicationSupportName"),
                "\(value): \(warnings)")
    }

    let invalidSchemes: [Any] = ["", "cherry_sessions", "1cherry", "cherry sessions", "chérry", "cherry\ndev", false]
    for value in invalidSchemes {
        var warnings: [String] = []
        let identity = CherryAppIdentity(
            infoDictionary: ["CherryApplicationSupportName": "Cherry Dev", "CherryURLScheme": value],
            warn: { warnings.append($0) }
        )
        #expect(identity.applicationSupportName == "Cherry Dev")
        #expect(identity.urlScheme == "cherry")
        #expect(warnings.count == 1 && warnings[0].hasPrefix("Ignoring invalid CherryURLScheme"),
                "\(value): \(warnings)")
    }
    // Control characters are escaped instead of breaking the log line.
    var escaped: [String] = []
    _ = CherryAppIdentity(infoDictionary: ["CherryURLScheme": "cherry\ndev"], warn: { escaped.append($0) })
    #expect(escaped.first?.contains(#""cherry\ndev""#) == true)

    // Accepted, but on a case-insensitive volume it is the main app's folder.
    var caseWarnings: [String] = []
    let caseVariant = CherryAppIdentity(
        infoDictionary: ["CherryApplicationSupportName": "cherry", "CherryURLScheme": "Cherry-Dev"],
        warn: { caseWarnings.append($0) }
    )
    #expect(caseVariant.applicationSupportName == "cherry")
    #expect(caseVariant.urlScheme == "cherry-dev")
    #expect(caseWarnings.count == 1 && caseWarnings[0].contains("only by case"))
}

@Test func appIdentityUsesContainingBundleForMCPHelper() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Cherry Sessions.app")
    let contents = app.appendingPathComponent("Contents")
    let executables = contents.appendingPathComponent("MacOS")
    try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "dev.patrick.cherry.sessions.test",
        "CFBundleName": "Cherry Sessions",
        "CFBundleExecutable": "Cherry",
        "CFBundlePackageType": "APPL",
        "CherryApplicationSupportName": "Cherry Sessions",
        "CherryURLScheme": "cherry-sessions",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))

    let config = CherryAppIdentity.configurationInfo(
        bundle: .main,
        executableURL: executables.appendingPathComponent("CherryMCP")
    )
    #expect(CherryAppIdentity(infoDictionary: config).urlScheme == "cherry-sessions")
    #expect(CherryAppIdentity(infoDictionary: config).applicationSupportName == "Cherry Sessions")

    let appSocket = CherryControl.socketURL(environment: [:], executableURL: executables.appendingPathComponent("Cherry"))
    let helperSocket = CherryControl.socketURL(environment: [:], executableURL: executables.appendingPathComponent("CherryMCP"))
    let stableSocket = CherryControl.socketURL(
        environment: [:],
        executableURL: root.appendingPathComponent("Cherry.app/Contents/MacOS/Cherry")
    )
    #expect(appSocket == helperSocket)
    #expect(appSocket != stableSocket)
}
