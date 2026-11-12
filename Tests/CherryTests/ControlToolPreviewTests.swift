@testable import Cherry
import CherryControl
import Foundation
import Testing

// preview_files (`cherry preview PATH…`, docs/cli.md › Showing Files)
// against a private server: the caller's files found as a Cmd-click finds
// them, what is shown and what the agent is told. The presenter records:
// no toast, panel or window comes up.

@MainActor
private final class ControlToolPreviewHarness {
    let root: URL
    let workspace: TerminalWorkspace
    let tab: TerminalSession
    let socketURL: URL
    let server: CherryControlServer
    var shared: [QuickViewShare] = []
    var opensPanel = false

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlToolPreview-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("web/notes"), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("web/shot.png"))
        try "one\ntwo\n".write(to: root.appendingPathComponent("web/notes/todo.md"), atomically: true, encoding: .utf8)
        socketURL = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("control.sock")
        let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false, launchBackend: .hostManaged)
        self.workspace = workspace
        tab = workspace.addSession(title: "Codex")
        server = CherryControlServer(
            workspaceProvider: { workspace },
            todoStoreProvider: { nil },
            chromeStateProvider: { nil },
            workspaceForProjectRootProvider: { $0 == workspace.projectRoot ? workspace : nil },
            todoStoreForProjectRootProvider: { _ in nil },
            chromeStateForProjectRootProvider: { _ in nil },
            openProjectRootsProvider: { [workspace.projectRoot].compactMap { $0 } },
            openWorkspacesProvider: { [workspace] },
            chromeStateForWorkspaceProvider: { _ in nil },
            socketURL: socketURL
        )
        let tab = tab
        server.callerSessionResolverForTesting = { _ in tab }
        server.previewPresenter = { [unowned self] share in
            self.shared.append(share)
            return share.open || self.opensPanel
        }
        server.start()
    }

    /// `cherry preview` from the caller's shell in `directory`.
    func preview(_ arguments: [String: JSONValue], directory: String? = nil) async throws -> CallToolResult {
        let request = CherryControlRequest.callTool(.init(
            name: "preview_files", arguments: arguments,
            context: ToolCallContext(projectRoot: root.path, workingDirectory: directory, interface: "cli")
        ))
        let socketURL = socketURL
        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try CherryControlClient(socketURL: socketURL, timeout: 30, credentials: nil, controlMachine: nil).send(request)
                })
            }
        }
        guard case .callTool(let result)? = response.result else {
            throw response.error ?? CherryControlError(code: "call_failed", message: "Expected a callTool result, got \(response)")
        }
        return result
    }

    func stop() {
        server.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
}

private func previewError(_ result: CallToolResult) -> String? {
    result.isError ? result.structured?.objectValue?["error"]?.objectValue?["code"]?.stringValue : nil
}

private func previewPayload(_ result: CallToolResult) throws -> PreviewFilesResult {
    guard !result.isError, let structured = result.structured else {
        throw CherryControlError(code: "unexpected_result", message: result.text)
    }
    return try JSONDecoder().decode(PreviewFilesResult.self, from: JSONEncoder().encode(structured))
}

@Suite(.serialized) @MainActor
struct ControlToolPreviewTests {
    @Test func ControlToolPreviewFindsTheCallersFilesAndOffersThemInAToast() async throws {
        let harness = try ControlToolPreviewHarness()
        defer { harness.stop() }
        let web = harness.root.appendingPathComponent("web").path
        let result = try await harness.preview(
            ["paths": .array([.string("shot.png"), .string("notes/todo.md:2"), .string("nope.txt")]), "message": .string("The render\nand more")],
            directory: web
        )
        let payload = try previewPayload(result)
        #expect(payload.machine == "This Mac" && !payload.opened)
        #expect(payload.files == [
            .init(path: web + "/shot.png", foundPath: web + "/shot.png", kind: "file"),
            .init(path: web + "/notes/todo.md:2", foundPath: web + "/notes/todo.md", kind: "file"),
            .init(path: web + "/nope.txt", foundPath: nil, kind: nil),
        ])
        // The text the agent reads says the same.
        #expect(result.text.contains("\"found_path\""))

        let share = try #require(harness.shared.first)
        #expect(harness.shared.count == 1)
        #expect(share.requests.map(\.candidates) == [
            [QuickViewCandidate(path: web + "/shot.png")],
            [QuickViewCandidate(path: web + "/notes/todo.md", line: 2)],
        ])
        #expect(share.requests.allSatisfy { $0.machine == .thisMac } && share.source.machine == .thisMac)
        #expect(share.sharer == "Codex" && share.message == "The render" && !share.open && share.window == nil)
        let toast = share.toast {}
        #expect(toast.title == "Codex shared 2 files" && toast.message == "The render" && toast.actions.map(\.title) == ["View"])
        #expect(toast.pausesWhileUnattended)
    }

    @Test func ControlToolPreviewOpensAtOnceWhenAskedAndShowsFolders() async throws {
        let harness = try ControlToolPreviewHarness()
        defer { harness.stop() }
        // Relative to the tab when the caller's directory is not known.
        let result = try await harness.preview(["paths": .array([.string("web/notes")]), "open": .bool(true)])
        let payload = try previewPayload(result)
        #expect(payload.opened)
        #expect(payload.files == [.init(path: "web/notes", foundPath: harness.root.path + "/web/notes", kind: "folder")])
        let share = try #require(harness.shared.first)
        #expect(share.open && share.what == "notes")
        #expect(share.requests == [.path(harness.root.path + "/web/notes", on: .thisMac)])
    }

    @Test func ControlToolPreviewRefusesWhatItCannotShow() async throws {
        let harness = try ControlToolPreviewHarness()
        defer { harness.stop() }
        #expect(previewError(try await harness.preview(["paths": .array([.string("gone.png"), .string("/nowhere/x")])])) == "file_not_found")
        #expect(previewError(try await harness.preview(["paths": .array([])])) == "invalid_argument")
        #expect(previewError(try await harness.preview([:])) == "invalid_argument")
        let many = (1...11).map { JSONValue.string("f\($0).txt") }
        #expect(previewError(try await harness.preview(["paths": .array(many)])) == "invalid_argument")
        #expect(previewError(try await harness.preview(["paths": .string("shot.png")])) == "invalid_argument")
        #expect(harness.shared.isEmpty)

        // A caller Cherry cannot place: This Mac's files, by absolute path.
        harness.server.callerSessionResolverForTesting = { _ in nil }
        let shot = harness.root.appendingPathComponent("web/shot.png").path
        let payload = try previewPayload(try await harness.preview(["paths": .array([.string(shot)])]))
        #expect(payload.files.first?.foundPath == shot)
        #expect(harness.shared.last?.sharer == "An agent")
    }
}
