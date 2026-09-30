import CherryControl
import Foundation
import Testing
@testable import Cherry

// The Omni bar's folders on another Mac, against a fake remote Mac
// (Scripts/fake-remote-mac): the listing and scanning scripts run with
// `sh -s` through the ssh shim, as `RemoteProjectAccess` runs git, with the
// fake Mac's private HOME. Gated like the other real-host suites
// (CHERRY_TEST_HOST_INTEGRATION=1, Scripts/build-host debug). No daemon runs
// there, and none is started.

private let foldersRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@Test(.enabled(if: foldersRealHostEnabled))
@MainActor func RemoteDeviceRealHostOmniFoldersListAndScanTheDevicesFoldersOverSSH() async throws {
    let mac = try FakeRemoteMac(name: "folders", host: "none", startsDaemon: false)
    do {
        let home = mac.home
        for path in ["github/pat/cherry/.git", "github/pat/notes", "github/pat/it's $(touch pwned)/.git", "code/app/.git"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let shell = mac.shell
        let listing = await OmniRemoteFolders.list("~/github/pat/", on: mac.name, shell: shell)
        guard case .listed(let contents) = listing else {
            Issue.record("not listed: \(listing)")
            await mac.tearDown()
            return
        }
        #expect(contents.path == home.appendingPathComponent("github/pat").path)
        #expect(Set(contents.entries) == [
            .init(name: "cherry", isRepository: true),
            .init(name: "notes", isRepository: false),
            .init(name: "it's $(touch pwned)", isRepository: true),
        ])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("github/pat/pwned").path))
        #expect(await OmniRemoteFolders.list("~/nowhere/", on: mac.name, shell: shell) == .missing)

        let found = try #require(await OmniRemoteFolders.scan(on: mac.name, shell: shell))
        #expect(Set(found) == Set([
            "github/pat/cherry", "github/pat/it's $(touch pwned)", "code/app",
        ].map { home.appendingPathComponent($0).path }))

        // The Mac does not answer: a failure, never an empty folder.
        mac.set("offline", true)
        if case .failed = await OmniRemoteFolders.list("~/github/pat/", on: mac.name, shell: shell) {} else {
            Issue.record("an offline Mac's folder listed")
        }
        #expect(await OmniRemoteFolders.scan(on: mac.name, shell: shell) == nil)
        mac.set("offline", false)
    } catch {
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}
