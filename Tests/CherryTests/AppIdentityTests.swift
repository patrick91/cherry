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
    let identity = CherryAppIdentity(infoDictionary: [
        "CherryApplicationSupportName": "Cherry Sessions",
        "CherryURLScheme": "cherry-sessions",
    ])
    #expect(identity.applicationSupportName == "Cherry Sessions")
    #expect(identity.urlScheme == "cherry-sessions")
    #expect(MCPInstallCommandBuilder.commands(identity: identity).allSatisfy {
        $0.command.contains(" cherry-sessions -- ")
    })

    let invalid = CherryAppIdentity(infoDictionary: [
        "CherryApplicationSupportName": "../Cherry",
        "CherryURLScheme": "cherry; exit",
    ])
    #expect(invalid == CherryAppIdentity())
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
