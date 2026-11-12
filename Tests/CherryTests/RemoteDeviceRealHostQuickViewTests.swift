import CherryControl
import Foundation
import Testing
@testable import Cherry

// Quick View of another Mac's files against a fake remote Mac
// (Scripts/fake-remote-mac): the look and copy scripts run with `sh -s`
// through the ssh shim, with the fake Mac's private HOME. Gated like the
// other real-host suites (CHERRY_TEST_HOST_INTEGRATION=1, Scripts/build-host
// debug). No daemon runs there, and none is started.

private let quickViewRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@Test(.enabled(if: quickViewRealHostEnabled))
@MainActor func RemoteDeviceRealHostQuickViewLooksAtAndCopiesTheDevicesFilesOverSSH() async throws {
    let mac = try FakeRemoteMac(name: "quickview", host: "none", startsDaemon: false)
    let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("quickview-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    do {
        let home = mac.home
        let reference = home.appendingPathComponent("work/app/.reference/accordion $(touch pwned)")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        let story = reference.appendingPathComponent("Accordion.story")
        try Data("{\"slides\": 1}\n".utf8).write(to: story)
        let shell = mac.shell
        let files = QuickViewRemoteFiles(
            machine: .remote(name: "Studio", destination: mac.name), destination: mac.name,
            shell: { _ in shell }, cache: QuickViewCache(directory: cacheDirectory)
        )

        // A path relative to the project, as an agent prints it, with its
        // line; `~/…` expanded there.
        let context = QuickViewContext(
            machine: .remote(name: "Studio", destination: mac.name),
            workingDirectory: home.appendingPathComponent("work/app/web").path,
            projectRoot: home.appendingPathComponent("work/app").path,
            homeDirectory: nil
        )
        let request = try #require(QuickViewLink.request(
            text: ".reference/accordion $(touch pwned)/Accordion.story:4", kind: .unknown, context: context
        ))
        guard case let .file(file, line) = await files.look(at: request.candidates) else {
            Issue.record("the story was not found there")
            await mac.tearDown()
            return
        }
        #expect(file.path == story.path && file.size == 14 && line == 4)
        guard case let .local(copy) = await files.copy(file, refresh: false) else {
            Issue.record("the story was not copied")
            await mac.tearDown()
            return
        }
        #expect(try Data(contentsOf: copy) == Data("{\"slides\": 1}\n".utf8))
        #expect(copy.path.hasPrefix(cacheDirectory.path))

        // Its folder lists; nothing named runs.
        let folder = await files.look(at: [QuickViewCandidate(path: "~/work/app/.reference")])
        #expect(folder == .folder(QuickViewFolder(
            path: home.appendingPathComponent("work/app/.reference").path,
            entries: [.init(name: "accordion $(touch pwned)", isFolder: true)]
        )))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("work/app/.reference/pwned").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("pwned").path))
        #expect(await files.look(at: [QuickViewCandidate(path: "~/work/none.txt")]) == .missing)

        // The Mac does not answer: a failure, never "nothing there".
        mac.set("offline", true)
        if case .failed = await files.look(at: request.candidates) {} else {
            Issue.record("an offline Mac's file was looked at")
        }
        if case .failed = await files.copy(file, refresh: true) {} else {
            Issue.record("an offline Mac's file was copied")
        }
        mac.set("offline", false)
    } catch {
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}
