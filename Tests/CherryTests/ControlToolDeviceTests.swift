@testable import Cherry
import CherryControl
import Foundation
import Testing

// The machines a caller reaches (list_devices, add_project, and `device` on
// open_project and spawn_agent; docs/cli.md › Devices), against a private
// server whose devices are a stand-in `ControlDeviceDirectory`.

private let controlToolDeviceID = UUID(uuidString: "5B0E7C1A-2F4D-4C8E-9A61-0D3E2F1B7C55")!

@MainActor
private final class ControlToolDeviceHarness {
    let defaultsName = "CherryTests.ControlToolDevice.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AgentSettings
    let home: URL
    let projectRoot: URL
    let workspace: TerminalWorkspace
    let socketURL: URL
    let server: CherryControlServer
    var opened: [String] = []
    var deviceProjects: [String] = ["/Users/pat/old"]
    var added: [(path: String, create: Bool)] = []

    init() throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ControlToolDevice-\(UUID().uuidString)", isDirectory: true)
        projectRoot = home.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        socketURL = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("control.sock")
        settings = AgentSettings(defaults: defaults)
        _ = settings.addProject(path: projectRoot.path)
        let workspace = TerminalWorkspace(projectRoot: projectRoot.path, launchBackend: .hostManaged)
        self.workspace = workspace
        var openProject: (String) -> Void = { _ in }
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
            openProjectProvider: { openProject($0) },
            socketURL: socketURL,
            agentSettings: settings
        )
        openProject = { [weak self] in self?.opened.append($0) }
        server.deviceDirectory = ControlDeviceDirectory(
            devices: { [weak self] in
                [.init(id: controlToolDeviceID, name: "patmini", homeDirectory: "/Users/pat", projects: self?.deviceProjects ?? [])]
            },
            addProject: { [weak self] path, deviceID, create in
                #expect(deviceID == controlToolDeviceID)
                guard let self else { throw CherryControlError(code: "gone", message: "Gone.") }
                self.added.append((path, create))
                let alreadyAdded = self.deviceProjects.contains(path)
                if !alreadyAdded { self.deviceProjects.append(path) }
                return .init(path: path, created: create, alreadyAdded: alreadyAdded)
            }
        )
        server.start()
    }

    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> CallToolResult {
        let request = CherryControlRequest.callTool(.init(
            name: name, arguments: arguments, context: ToolCallContext(projectRoot: projectRoot.path, interface: "cli")
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
            throw CherryControlError(code: "call_failed", message: "Expected a callTool result, got \(String(describing: response))")
        }
        return result
    }

    func stop() {
        server.stop()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
}

private func controlToolDeviceError(_ result: CallToolResult) -> String? {
    result.isError ? result.structured?.objectValue?["error"]?.objectValue?["code"]?.stringValue : nil
}

@MainActor
@Test func ControlToolDeviceListsThisMacThenTheDevicesWithTheirProjectsKeys() async throws {
    let harness = try ControlToolDeviceHarness()
    defer { harness.stop() }

    let result = try await harness.call("list_devices", [:])
    #expect(!result.isError, "\(result.text)")
    let devices = try #require(result.structured?.objectValue?["devices"]?.arrayValue)
    #expect(devices.count == 2)
    let thisMac = try #require(devices.first?.objectValue)
    #expect(thisMac["id"] == .string("this-mac"))
    #expect(thisMac["caller"] == .bool(true))
    #expect(thisMac["projects"]?.arrayValue?.first?.objectValue?["root"] == .string(harness.projectRoot.path))
    #expect(thisMac["projects"]?.arrayValue?.first?.objectValue?["open"] == .bool(true))
    let device = try #require(devices.last?.objectValue)
    #expect(device["id"] == .string(controlToolDeviceID.uuidString.lowercased()))
    #expect(device["name"] == .string("patmini"))
    #expect(device["os"] == .string("macOS"))
    #expect(device["caller"] == .bool(false))
    // Whether it is connected is not said: a tool that needs the device
    // reaches it, or says why it could not.
    #expect(device["connected"] == nil)
    let project = try #require(device["projects"]?.arrayValue?.first?.objectValue)
    #expect(project["root"] == .string("device:\(controlToolDeviceID.uuidString.lowercased()):/Users/pat/old"))
    #expect(project["path"] == .string("/Users/pat/old"))
    #expect(project["open"] == .bool(false))
}

@MainActor
@Test func ControlToolDeviceAddsAFolderOnADeviceAndOpensItByItsPathThere() async throws {
    let harness = try ControlToolDeviceHarness()
    defer { harness.stop() }
    let key = "device:\(controlToolDeviceID.uuidString.lowercased()):/Users/pat/code/app"

    let added = try await harness.call("add_project", ["path": .string("~/code/app"), "device": .string("PATMINI"), "create": .bool(true)])
    #expect(!added.isError, "\(added.text)")
    let payload = try #require(added.structured?.objectValue)
    #expect(payload["projectRoot"] == .string(key))
    #expect(payload["device"] == .string("patmini"))
    #expect(payload["created"] == .bool(true))
    #expect(payload["alreadyAdded"] == .bool(false))
    #expect(payload["opened"] == .bool(true))
    #expect(harness.added.map(\.path) == ["/Users/pat/code/app"])
    #expect(harness.added.map(\.create) == [true])
    #expect(harness.opened == [key])

    // Opened again by its path there, or by its key; never as This Mac's path.
    let byPath = try await harness.call("open_project", ["project_root": .string("~/code/app"), "device": .string("patmini")])
    #expect(!byPath.isError, "\(byPath.text)")
    let byKey = try await harness.call("open_project", ["project_root": .string(key)])
    #expect(!byKey.isError, "\(byKey.text)")
    #expect(harness.opened == [key, key, key])
    let unknown = try await harness.call("open_project", ["project_root": .string("/Users/pat/never"), "device": .string("patmini")])
    #expect(controlToolDeviceError(unknown) == "project_not_found")

    // Left closed when asked; dot components refused before the device is asked.
    let closed = try await harness.call("add_project", ["path": .string("/Users/pat/old"), "device": .string("patmini"), "open": .bool(false)])
    #expect(closed.structured?.objectValue?["alreadyAdded"] == .bool(true))
    #expect(closed.structured?.objectValue?["opened"] == .bool(false))
    #expect(harness.opened.count == 3)
    let dots = try await harness.call("add_project", ["path": .string("/Users/pat/../etc"), "device": .string("patmini")])
    #expect(controlToolDeviceError(dots) == "invalid_project_root")
    let nowhere = try await harness.call("add_project", ["path": .string("/x"), "device": .string("nowhere")])
    #expect(controlToolDeviceError(nowhere) == "device_not_found")
    #expect(harness.added.count == 2)
}

@MainActor
@Test func ControlToolDeviceAddsAndMakesAFolderOnThisMac() async throws {
    let harness = try ControlToolDeviceHarness()
    defer { harness.stop() }
    let folder = harness.home.appendingPathComponent("new-app", isDirectory: true).path

    let missing = try await harness.call("add_project", ["path": .string(folder)])
    #expect(controlToolDeviceError(missing) == "folder_not_found")
    #expect(!FileManager.default.fileExists(atPath: folder))

    let made = try await harness.call("add_project", ["path": .string(folder), "create": .bool(true)])
    #expect(!made.isError, "\(made.text)")
    #expect(made.structured?.objectValue?["projectRoot"] == .string(folder))
    #expect(made.structured?.objectValue?["device"] == .string("This Mac"))
    #expect(made.structured?.objectValue?["created"] == .bool(true))
    #expect(FileManager.default.fileExists(atPath: folder))
    #expect(harness.settings.projects.contains { $0.root == folder })
    #expect(harness.opened == [folder])

    let again = try await harness.call("add_project", ["path": .string(folder), "device": .string("this-mac"), "create": .bool(true)])
    #expect(again.structured?.objectValue?["created"] == .bool(false))
    #expect(again.structured?.objectValue?["alreadyAdded"] == .bool(true))

    // Only the folder itself is made, never its parents.
    let deep = try await harness.call("add_project", ["path": .string(harness.home.path + "/a/b"), "create": .bool(true)])
    #expect(controlToolDeviceError(deep) == "folder_not_created")
    #expect(harness.added.isEmpty)
}
