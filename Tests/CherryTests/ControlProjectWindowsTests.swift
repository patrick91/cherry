import CherryControl
import Foundation
import Testing
@testable import Cherry

// Cherry MCP with several windows of one project (#22): a scoped request
// goes to the caller's own window, else the active one, else the project's
// most recently active; what a request finds by id it acts on in the window
// that has it, and a project command's name finds its one tab in any of the
// project's windows. The server is given its windows through its
// providers, as the app's registry gives them; its tabs run /bin/cat.

/// Which window is active, which the project's most recently active, and
/// which tab is the caller: the server's providers read them.
@MainActor
private final class Routing {
    var active: TerminalWorkspace?
    var mostRecent: TerminalWorkspace?
    var caller: TerminalSession?
}

/// A control server for two windows of one project, its primary and
/// another, that share the project's to-dos and commands.
@MainActor
private final class TwoProjectWindows {
    let defaultsName = "CherryTests.ControlProjectWindows.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AgentSettings
    let project: URL
    let todosRoot: URL
    let socketURL: URL
    let primary: TerminalWorkspace
    let second: TerminalWorkspace
    let primaryChrome = quietChromeState()
    let secondChrome = quietChromeState()
    let todos: ProjectTodoStore
    let routing = Routing()
    let server: CherryControlServer
    let echo = AgentToolDefinition(name: "Echo", command: "/bin/cat")

    init() throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        settings = AgentSettings(defaults: defaults)
        project = try canonicalTemporaryDirectory("cherry-control-windows")
        todosRoot = try canonicalTemporaryDirectory("cherry-control-windows-todos")
        socketURL = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("control.sock")
        _ = settings.addProject(path: project.path)
        try settings.upsertAgent(echo)
        try settings.setProjectFeatures(ProjectFeatureSettings(todosEnabled: true), for: project.path, storage: .local)
        primary = TerminalWorkspace(projectRoot: project.path, createInitialSession: false, launchBackend: .hostManaged)
        second = TerminalWorkspace(
            projectRoot: project.path, createInitialSession: false, launchBackend: .hostManaged, windowID: UUID()
        )
        // As each window's repository sets it once the window claimed the
        // project.
        primary.otherProjectWindows = { [weak second] in second.map { [$0] } ?? [] }
        second.otherProjectWindows = { [weak primary] in primary.map { [$0] } ?? [] }
        let todos = ProjectTodoStore.shared(projectRoot: project.path, storageDirectory: todosRoot)
        self.todos = todos
        let root = project.path
        let routing = routing
        let windows = [primary, second]
        let chromes = [primaryChrome, secondChrome]
        let chrome: @MainActor (TerminalWorkspace?) -> ProjectWindowChromeState? = { workspace in
            windows.firstIndex { $0 === workspace }.map { chromes[$0] }
        }
        // As the registry resolves a root: /private/var and /var name one folder.
        let isProject: (String) -> Bool = {
            CherryControl.standardizedProjectRoot($0) == CherryControl.standardizedProjectRoot(root)
        }
        server = CherryControlServer(
            workspaceProvider: { routing.active },
            todoStoreProvider: { todos },
            chromeStateProvider: { chrome(routing.active) },
            workspaceForProjectRootProvider: { isProject($0) ? routing.mostRecent : nil },
            todoStoreForProjectRootProvider: { isProject($0) ? todos : nil },
            chromeStateForProjectRootProvider: { isProject($0) ? chrome(routing.mostRecent) : nil },
            openProjectRootsProvider: { [root] },
            openWorkspacesProvider: { windows },
            chromeStateForWorkspaceProvider: { chrome($0) },
            socketURL: socketURL,
            agentSettings: settings
        )
        server.callerSessionResolverForTesting = { _ in routing.caller }
        routing.active = primary
        routing.mostRecent = primary
    }

    func agent(in workspace: TerminalWorkspace, title: String) -> TerminalSession {
        workspace.addAgentSession(agent: echo, projectRoot: project.path, title: title, select: false)
    }

    /// A project command (running /bin/cat), configured for the project.
    func command(_ name: String) throws -> ProjectCommandDefinition {
        let command = ProjectCommandDefinition(name: name, command: "/bin/cat")
        try settings.upsertCommand(command, for: project.path)
        return command
    }

    func send(_ request: CherryControlRequest) async throws -> CherryControlResponse {
        let url = socketURL
        return try await Task.detached {
            try CherryControlClient(socketURL: url).send(request)
        }.value
    }

    func scoped(_ request: CherryControlRequest) -> CherryControlRequest {
        .scoped(.init(projectRoot: project.path, request: request))
    }

    func processIDs(_ response: CherryControlResponse) -> Set<String>? {
        guard case .listProcesses(let result)? = response.result else { return nil }
        return Set(result.processes.map(\.id))
    }

    func stop() {
        server.stop()
        for workspace in [primary, second] {
            workspace.sessions.forEach { $0.stop() }
            workspace.closeAllSessions(intent: .windowClosed)
        }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.removeItem(at: todosRoot)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
}

/// An agent in a project's second window spawns a sub-agent with a scoped
/// request: it opens in that window, under its parent, though the user
/// looks at the project's primary window.
@Test @MainActor func aScopedSpawnFromAProjectsSecondWindowOpensInItWithItsParent() async throws {
    let windows = try TwoProjectWindows()
    defer { windows.stop() }
    _ = windows.agent(in: windows.primary, title: "Lead")
    let caller = windows.agent(in: windows.second, title: "Orchestrator")
    windows.routing.caller = caller
    windows.server.start()

    let response = try await windows.send(windows.scoped(.spawnProcess(.init(
        kind: "agent", name: "Echo", title: "Worker", parentAgentID: caller.id.uuidString
    ))))
    guard case .spawnProcess(let spawned)? = response.result else {
        Issue.record("Expected spawnProcess result, got \(String(describing: response))")
        return
    }
    let worker = try #require(windows.second.session(id: spawned.process.id))
    #expect(worker.parentAgentID == caller.id)
    #expect(spawned.process.parentAgentID == caller.id.uuidString)
    #expect(windows.primary.sessions.map(\.title) == ["Lead"])
    // Its listings are that window's.
    let listed = try await windows.send(windows.scoped(.listProcesses(.init())))
    #expect(windows.processIDs(listed) == Set(windows.second.sessions.map(\.id.uuidString)))
}

/// With no caller Cherry knows (a CherryMCP no tab's program started), or
/// one in neither window, a scoped request goes to the active window when
/// it is the project's, else to the project's most recently active window.
@Test @MainActor func aScopedRequestWithNoKnownCallerGoesToTheActiveThenTheMostRecentWindow() async throws {
    let windows = try TwoProjectWindows()
    defer { windows.stop() }
    let otherProject = try canonicalTemporaryDirectory("cherry-control-windows-other")
    let elsewhere = TerminalWorkspace(projectRoot: otherProject.path, createInitialSession: false, launchBackend: .hostManaged)
    defer {
        elsewhere.closeAllSessions(intent: .windowClosed)
        try? FileManager.default.removeItem(at: otherProject)
    }
    _ = windows.agent(in: windows.primary, title: "Primary agent")
    _ = windows.agent(in: windows.second, title: "Second agent")
    let primaryIDs = Set(windows.primary.sessions.map(\.id.uuidString))
    let secondIDs = Set(windows.second.sessions.map(\.id.uuidString))
    windows.server.start()
    func listed() async throws -> Set<String>? {
        windows.processIDs(try await windows.send(windows.scoped(.listProcesses(.init()))))
    }

    // The active window is the project's second one.
    windows.routing.active = windows.second
    #expect(try await listed() == secondIDs)
    // A caller in neither window changes nothing.
    windows.routing.caller = elsewhere.addAgentSession(agent: windows.echo, projectRoot: otherProject.path, select: false)
    #expect(try await listed() == secondIDs)
    windows.routing.caller = nil
    // Another project's window is active: the project's most recently
    // active window.
    windows.routing.active = elsewhere
    windows.routing.mostRecent = windows.primary
    #expect(try await listed() == primaryIDs)
    windows.routing.mostRecent = windows.second
    #expect(try await listed() == secondIDs)
}

/// select_process selects a tab in the window that has it, never in the
/// window the request went to, and shows that window's terminal; the
/// window is not brought forward.
@Test @MainActor func selectProcessSelectsTheTabInTheWindowThatHasIt() async throws {
    let windows = try TwoProjectWindows()
    defer { windows.stop() }
    let primaryTab = windows.agent(in: windows.primary, title: "Primary agent")
    windows.primary.select(primaryTab)
    let secondFirst = windows.agent(in: windows.second, title: "Second agent")
    let secondOther = windows.agent(in: windows.second, title: "Second other")
    windows.second.select(secondFirst)
    // Both windows show their to-dos.
    let todo = try windows.todos.create(title: "Review", markdown: "")
    windows.primaryChrome.selectTodo(id: todo.id)
    windows.secondChrome.selectTodo(id: todo.id)
    windows.server.start()

    // From the active primary window, by id.
    let response = try await windows.send(.selectProcess(.init(processID: secondOther.id.uuidString)))
    guard case .selectProcess(let selected)? = response.result else {
        Issue.record("Expected selectProcess result, got \(String(describing: response))")
        return
    }
    #expect(selected.process.id == secondOther.id.uuidString)
    #expect(selected.process.selected)
    #expect(windows.second.selectedSessionID == secondOther.id)
    #expect(windows.secondChrome.isShowingTerminalContent)
    // The primary window keeps its selection and its to-do.
    #expect(windows.primary.selectedSessionID == primaryTab.id)
    #expect(windows.primaryChrome.selectedTodoID == todo.id)
    #expect(!windows.primaryChrome.isShowingTerminalContent)
}

/// To-dos are the project's, one store for its windows; which one a window
/// shows is its own: select_todo from an agent in the second window
/// selects it there, list_todos says what the caller's window selects, and
/// delete_todo clears the caller's window's selection.
@Test @MainActor func todoSelectionGoesToTheCallersWindow() async throws {
    let windows = try TwoProjectWindows()
    defer { windows.stop() }
    let primaryAgent = windows.agent(in: windows.primary, title: "Primary agent")
    let secondAgent = windows.agent(in: windows.second, title: "Second agent")
    let todo = try windows.todos.create(title: "Review", markdown: "")
    windows.server.start()
    func selectedTodo() async throws -> String? {
        guard case .listTodos(let listed)? = try await windows.send(windows.scoped(.listTodos)).result else {
            Issue.record("Expected listTodos result")
            return nil
        }
        return listed.selectedTodoID
    }

    windows.routing.caller = secondAgent
    let response = try await windows.send(windows.scoped(.selectTodo(.init(todoID: todo.id.uuidString))))
    #expect(response.error == nil)
    #expect(windows.secondChrome.selectedTodoID == todo.id)
    #expect(windows.primaryChrome.selectedTodoID == nil)
    #expect(try await selectedTodo() == todo.id.uuidString)
    // The primary window's agent sees its own window's.
    windows.routing.caller = primaryAgent
    #expect(try await selectedTodo() == nil)

    // Deleted by the second window's agent: that window shows it no more
    // (the primary, which shows it too, finds it gone and shows the board).
    windows.primaryChrome.selectTodo(id: todo.id)
    windows.routing.caller = secondAgent
    let deleted = try await windows.send(windows.scoped(.deleteTodo(.init(todoID: todo.id.uuidString))))
    #expect(deleted.error == nil)
    #expect(windows.secondChrome.selectedTodoID == nil)
    #expect(windows.primaryChrome.selectedTodoID == todo.id)
    #expect(windows.todos.todos.isEmpty)
}

// MARK: - Commands

/// start_process and spawn_process of a command that another window of the
/// project runs return that tab, described as its window shows it: nothing
/// starts in the caller's window.
@Test @MainActor func mcpStartProcessReturnsTheCommandTabAnotherWindowRuns() async throws {
    let windows = try TwoProjectWindows()
    defer { windows.stop() }
    let server = try windows.command("server")
    let tab = windows.primary.addCommandSession(command: server, projectRoot: windows.project.path, select: false)
    windows.primary.select(tab)
    windows.routing.caller = windows.agent(in: windows.second, title: "Orchestrator")
    windows.server.start()
    #expect(await eventually { tab.isRunning })

    let started = try await windows.send(windows.scoped(.startProcess(.init(processName: "server", kind: "command"))))
    guard case .startProcess(let result)? = started.result else {
        Issue.record("Expected startProcess result, got \(String(describing: started))")
        return
    }
    #expect(result.process.id == tab.id.uuidString)
    // Selected in the window that has it.
    #expect(result.process.selected)
    #expect(windows.second.commandSessions.isEmpty)

    let spawned = try await windows.send(windows.scoped(.spawnProcess(.init(kind: "command", name: "Server"))))
    guard case .spawnProcess(let spawnResult)? = spawned.result else {
        Issue.record("Expected spawnProcess result, got \(String(describing: spawned))")
        return
    }
    #expect(spawnResult.process.id == tab.id.uuidString)
    #expect(spawnResult.process.selected)
    #expect(windows.second.commandSessions.isEmpty)
    #expect(windows.primary.commandSessions.map(\.id) == [tab.id])
}

/// A command's name finds its tab in any window of the project (rename,
/// input, stop); another window's other tabs are not found by name.
@Test @MainActor func aCommandNameResolvesToItsTabInAnyWindowOfTheProject() async throws {
    let windows = try TwoProjectWindows()
    defer { windows.stop() }
    let server = try windows.command("server")
    let tab = windows.primary.addCommandSession(command: server, projectRoot: windows.project.path, select: false)
    _ = windows.agent(in: windows.primary, title: "Lead")
    windows.routing.caller = windows.agent(in: windows.second, title: "Orchestrator")
    windows.server.start()
    #expect(await eventually { tab.isRunning })

    let renamed = try await windows.send(windows.scoped(.renameProcess(.init(processName: "server", title: "API"))))
    #expect(renamed.error == nil)
    #expect(tab.title == "API")
    let input = try await windows.send(windows.scoped(.sendProcessInput(.init(processName: "server", text: "ping", submit: true))))
    guard case .sendProcessInput(let sent)? = input.result else {
        Issue.record("Expected sendProcessInput result, got \(String(describing: input))")
        return
    }
    #expect(sent.processID == tab.id.uuidString)
    #expect(sent.sentBytes > 0)
    let stopped = try await windows.send(windows.scoped(.stopProcess(.init(processName: "server"))))
    guard case .stopProcess(let stopResult)? = stopped.result else {
        Issue.record("Expected stopProcess result, got \(String(describing: stopped))")
        return
    }
    #expect(stopResult.process.id == tab.id.uuidString)
    #expect(await eventually { !tab.isRunning })

    // The primary's agent is that window's alone.
    let lead = try await windows.send(windows.scoped(.stopProcess(.init(processName: "Lead"))))
    #expect(lead.error?.code == "process_not_found")
}

/// stop_all_commands stops the project's commands in every one of its
/// windows; its listing is the caller's window's.
@Test @MainActor func stopAllCommandsStopsTheProjectsCommandsInEveryWindow() async throws {
    let windows = try TwoProjectWindows()
    defer { windows.stop() }
    let web = windows.primary.addCommandSession(command: try windows.command("web"), projectRoot: windows.project.path, select: false)
    let worker = windows.second.addCommandSession(
        command: try windows.command("worker"), projectRoot: windows.project.path, select: false
    )
    windows.routing.caller = windows.agent(in: windows.second, title: "Orchestrator")
    windows.server.start()
    #expect(await eventually { web.isRunning && worker.isRunning })

    let response = try await windows.send(windows.scoped(.stopAllCommands(.init())))
    guard case .stopAllCommands(let listed)? = response.result else {
        Issue.record("Expected stopAllCommands result, got \(String(describing: response))")
        return
    }
    #expect(await eventually { !web.isRunning && !worker.isRunning })
    let listedIDs = Set(listed.processes.map(\.id))
    #expect(listedIDs.contains(worker.id.uuidString))
    #expect(!listedIDs.contains(web.id.uuidString))
}
