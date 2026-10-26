import CherryControl
import Foundation
import Testing
@testable import Cherry

// A task for a worker in another project (docs/cli.md › Tasks And Results):
// an orchestrator in one project's window spawns a worker with
// `project_root` naming another open project. The tool layer names the
// caller as its parent; the worker opens top-level in that project's window
// (a sidebar nests only its own window's tabs) and the caller owns its task.

/// A control server for two open projects, "cloud" (the active window,
/// where the orchestrator runs) and "auth".
@MainActor
private final class TwoProjects {
    let defaultsName = "CherryTests.CrossProject.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AgentSettings
    let cloud: URL
    let auth: URL
    let cloudWindow: TerminalWorkspace
    let authWindow: TerminalWorkspace
    let socketURL: URL
    let server: CherryControlServer
    let board = AgentTaskBoard()
    let echo = AgentToolDefinition(name: "Echo", command: "/bin/cat")
    var caller: TerminalSession?

    init() throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        settings = AgentSettings(defaults: defaults)
        cloud = try canonicalTemporaryDirectory("cherry-cross-cloud")
        auth = try canonicalTemporaryDirectory("cherry-cross-auth")
        _ = settings.addProject(path: cloud.path)
        _ = settings.addProject(path: auth.path)
        try settings.upsertAgent(echo)
        cloudWindow = TerminalWorkspace(projectRoot: cloud.path, createInitialSession: false, launchBackend: .hostManaged)
        authWindow = TerminalWorkspace(projectRoot: auth.path, createInitialSession: false, launchBackend: .hostManaged)
        socketURL = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("control.sock")
        let windows = [cloudWindow, authWindow]
        let roots = [cloud.path, auth.path]
        let cloudWindow = cloudWindow
        server = CherryControlServer(
            workspaceProvider: { cloudWindow },
            todoStoreProvider: { nil },
            chromeStateProvider: { nil },
            workspaceForProjectRootProvider: { root in
                windows.first {
                    CherryControl.standardizedProjectRoot($0.projectRoot ?? "") == CherryControl.standardizedProjectRoot(root)
                }
            },
            todoStoreForProjectRootProvider: { _ in nil },
            chromeStateForProjectRootProvider: { _ in nil },
            openProjectRootsProvider: { roots },
            openWorkspacesProvider: { windows },
            chromeStateForWorkspaceProvider: { _ in nil },
            socketURL: socketURL,
            agentSettings: settings,
            taskBoard: board
        )
        server.callerSessionResolverForTesting = { [weak self] _ in self?.caller }
    }

    func call(_ name: String, _ arguments: [String: JSONValue]) async -> CallToolResult {
        await ToolCalls.call(name: name, arguments: arguments, socketURL: socketURL)
    }

    func stop() {
        server.stop()
        for workspace in [cloudWindow, authWindow] {
            workspace.sessions.forEach { $0.stop() }
            workspace.closeAllSessions(intent: .windowClosed)
        }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: cloud)
        try? FileManager.default.removeItem(at: auth)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
}

@Test @MainActor func ControlAgentTaskCrossProjectWorkerOpensInItsProjectAndReportsToTheCaller() async throws {
    let projects = try TwoProjects()
    defer { projects.stop() }
    let lead = projects.cloudWindow.addAgentSession(
        agent: projects.echo, projectRoot: projects.cloud.path, title: "Lead", select: false
    )
    projects.caller = lead
    projects.server.start()

    // As `cherry spawn agent Echo --project-root <auth> --task -` sends it:
    // the layer names the caller as the parent.
    let spawned = await projects.call("spawn_agent", [
        "name": .string("Echo"), "task": .string("Add a logout route"), "label": .string("logout route"),
        "project_root": .string(projects.auth.path),
    ])
    #expect(!spawned.isError, "\(spawned.text)")
    let process = try #require(spawned.structured?.objectValue?["process"]?.objectValue)
    let taskID = try #require(process["taskID"]?.stringValue)
    let runID = try #require(process["runID"]?.stringValue)
    let workerID = try #require(process["id"]?.stringValue)
    #expect(process["parentAgentID"] == nil || process["parentAgentID"] == .null)

    // The worker is a top-level tab of auth's window, in auth's folder.
    let worker = try #require(projects.authWindow.session(id: workerID))
    #expect(worker.kind == .agent && worker.parentAgentID == nil)
    #expect(worker.workingDirectory == projects.auth.path)
    #expect(projects.cloudWindow.sessions.map(\.id) == [lead.id])

    // The caller owns its run: the sidebar counts the worker on its row.
    let run = try #require(projects.server.tasks.run(runID, device: nil))
    #expect(run.ownerID == lead.id)
    #expect(projects.board.workerSummaries[lead.id]?.open == 1)
    #expect(projects.board.badges[worker.id]?.label == "logout route")

    // The worker reads its task and reports from its own tab.
    projects.caller = worker
    let mine = await projects.call("get_my_task", [:])
    #expect(!mine.isError, "\(mine.text)")
    #expect(mine.text.contains(taskID) && mine.text.contains("Add a logout route"), "\(mine.text)")
    let reported = await projects.call("report_result", [
        "value": .object(["branch": .string("logout-route")]), "summary": .string("Added POST /logout"),
    ])
    #expect(!reported.isError, "\(reported.text)")

    // The caller, scoped to its own project, sees the run settle and reads
    // the result.
    projects.caller = lead
    let waited = await projects.call("wait_for_tasks", ["run_id": .string(runID), "timeout_ms": .int(2_000)])
    #expect(!waited.isError, "\(waited.text)")
    let task = await projects.call("get_task", ["task_id": .string(taskID)])
    #expect(task.text.contains(#""state":"reported""#), "\(task.text)")
    #expect(task.text.contains("Added POST"))
    #expect(projects.board.workerSummaries[lead.id]?.reported == 1)

    // An explicit parent of another project's window is taken the same way;
    // one that is not an agent is refused.
    let explicit = await projects.call("spawn_agent", [
        "name": .string("Echo"), "task": .string("Review it"), "project_root": .string(projects.auth.path),
        "parent_agent_id": .string(lead.id.uuidString),
    ])
    #expect(!explicit.isError, "\(explicit.text)")
    let shell = projects.cloudWindow.addSession(title: "Shell", select: false)
    let notAgent = await projects.call("spawn_agent", [
        "name": .string("Echo"), "project_root": .string(projects.auth.path),
        "parent_agent_id": .string(shell.id.uuidString),
    ])
    #expect(notAgent.structured?.objectValue?["error"]?.objectValue?["code"]?.stringValue == "parent_agent_not_agent", "\(notAgent.text)")

    // A project that is not open says how to open it.
    let closed = await projects.call("spawn_agent", [
        "name": .string("Echo"), "task": .string("Elsewhere"), "project_root": .string("/nonexistent/closed-project"),
    ])
    #expect(closed.structured?.objectValue?["error"]?.objectValue?["code"]?.stringValue == "project_unavailable", "\(closed.text)")
    let message = closed.structured?.objectValue?["error"]?.objectValue?["message"]?.stringValue ?? ""
    #expect(message.hasSuffix("Open it first: cherry project open /nonexistent/closed-project"), "\(message)")
}
