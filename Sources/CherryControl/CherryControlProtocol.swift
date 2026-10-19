import Foundation

public enum CherryControl {
    public static let socketEnvironmentKey = "CHERRY_CONTROL_SOCKET"
    public static let socketNamespaceEnvironmentKey = "CHERRY_CONTROL_NAMESPACE"
    public static let projectRootEnvironmentKey = "CHERRY_PROJECT_ROOT"
    public static let processIDEnvironmentKey = "CHERRY_PROCESS_ID"
    public static let agentIDEnvironmentKey = "CHERRY_AGENT_ID"
    public static let selectedAgentParentID = "selected"
    public static let topLevelAgentParentID = "top_level"
    /// A wait's default timeout (`wait_for_process_idle`,
    /// `wait_for_events`): under the 60 s an MCP client such as Codex or Pi
    /// gives a tool call by default, so the answer is never lost to the
    /// client's own timeout.
    public static let defaultWaitMilliseconds = 50_000
    /// `send_agent_message`'s default wait: its message may first take a
    /// few seconds to reach the agent, within the same 60 s.
    public static let defaultAgentMessageWaitMilliseconds = 40_000
    /// The longest `wait_for_events` call: under every client's default
    /// tool timeout. Call it again to keep waiting.
    public static let maximumEventWaitMilliseconds = 50_000

    public static var socketURL: URL {
        socketURL(
            environment: ProcessInfo.processInfo.environment,
            executableURL: Bundle.main.executableURL
        )
    }

    public static func socketURL(
        environment: [String: String],
        executableURL: URL?
    ) -> URL {
        if let socketPath = environment[socketEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            return URL(fileURLWithPath: socketPath)
        }

        return sharedSocketRoot
            .appendingPathComponent(socketNamespace(environment: environment, executableURL: executableURL), isDirectory: true)
            .appendingPathComponent("control.sock", isDirectory: false)
    }

    /// The directory every derived socket path's namespace is in,
    /// `/tmp/cherry-<uid>`: one per user, shared by the copies of Cherry.
    public static var sharedSocketRoot: URL {
        URL(fileURLWithPath: "/tmp/cherry-\(getuid())", isDirectory: true)
    }

    public static func socketNamespace(
        environment: [String: String],
        executableURL: URL?
    ) -> String {
        if let namespace = environment[socketNamespaceEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !namespace.isEmpty {
            return sanitizedSocketComponent(namespace)
        }

        let identityURL = controlInstanceIdentityURL(executableURL: executableURL)
        let label = controlInstanceLabel(identityURL: identityURL)
        let hash = stableHexHash(identityURL.standardizedFileURL.path)
        return "\(sanitizedSocketComponent(label))-\(hash.prefix(12))"
    }

    private static func controlInstanceIdentityURL(executableURL: URL?) -> URL {
        guard let executableURL else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .standardizedFileURL
        }

        let standardizedExecutableURL = executableURL.standardizedFileURL
        let pathComponents = standardizedExecutableURL.pathComponents
        if let appIndex = pathComponents.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
            let appPath = NSString.path(withComponents: Array(pathComponents.prefix(through: appIndex)))
            return URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL
        }

        return standardizedExecutableURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func controlInstanceLabel(identityURL: URL) -> String {
        if identityURL.pathExtension.lowercased() == "app" {
            return identityURL.deletingPathExtension().lastPathComponent
        }

        return "cherry-dev"
    }

    private static func sanitizedSocketComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var output = ""

        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else if !output.hasSuffix("-") {
                output.append("-")
            }
        }

        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return String(trimmed.prefix(48)).isEmpty ? "default" : String(trimmed.prefix(48))
    }

    private static func stableHexHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    /// A This Mac project root (or a path in one) as the app and CherryMCP
    /// compare them: standardized, `.` and `..` resolved.
    public static func standardizedProjectRoot(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// Whether `path` is `projectRoot` or inside it (both standardized).
    public static func path(_ path: String, isInsideProjectRoot projectRoot: String) -> Bool {
        path == projectRoot || path.hasPrefix(projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/")
    }
}

public enum CherryControlRequest: Codable, Equatable, Sendable {
    indirect case scoped(ScopedControlRequest)
    case listProjects
    case openProject(OpenProjectRequest)
    case getProjectStatus
    case getPerformanceStatus
    case resolveLink(ResolveDeepLinkRequest)
    case listProcesses(ListProcessesRequest)
    case getProcessStatus(ProcessSelectorRequest)
    case getProcessOutput(GetProcessOutputRequest)
    case getProcessRawOutput(GetProcessRawOutputRequest)
    case searchProcessOutput(SearchProcessOutputRequest)
    case waitForProcessIdle(WaitForProcessIdleRequest)
    case subscribe(SubscribeRequest)
    case unsubscribe(UnsubscribeRequest)
    case waitForEvents(WaitForEventsRequest)
    case listSubscriptions
    /// Tasks (`AgentTasksProtocol.swift`): the worker's side, identified
    /// by its own tab, never a selector.
    case getMyTask
    case reportResult(ReportResultRequest)
    case reportProgress(ReportProgressRequest)
    /// Tasks: the orchestrator's side.
    case waitForTasks(WaitForTasksRequest)
    case getTask(GetTaskRequest)
    case listTasks(ListTasksRequest)
    case cancelTasks(CancelTasksRequest)
    case getProcessPorts(GetProcessPortsRequest)
    case servicesList(ServicesListRequest)
    case waitForBoundPort(WaitForBoundPortRequest)
    case spawnProcess(SpawnProcessRequest)
    case startProcess(ProcessLifecycleRequest)
    case stopProcess(ProcessLifecycleRequest)
    case restartProcess(ProcessLifecycleRequest)
    case closeProcess(CloseProcessRequest)
    case renameProcess(RenameProcessRequest)
    case selectProcess(ProcessSelectorRequest)
    case sendProcessInput(SendProcessInputRequest)
    /// Picks an option of the permission or question menu an agent shows
    /// (`AgentPromptInfo`), read off its screen again first.
    case answerPrompt(AnswerPromptRequest)
    case startAllCommands(ProcessBulkCommandRequest)
    case stopAllCommands(ProcessBulkCommandRequest)
    case restartAllCommands(ProcessBulkCommandRequest)
    case listTerminals
    case listAgents
    case listTodos
    case createTodo(CreateTodoRequest)
    case getTodo(TodoIDRequest)
    case updateTodo(UpdateTodoRequest)
    case moveTodo(MoveTodoRequest)
    case deleteTodo(TodoIDRequest)
    case selectTodo(TodoIDRequest)
    case addTodoComment(AddTodoCommentRequest)
    case listTodoComments(TodoIDRequest)
    case updateTodoComment(UpdateTodoCommentRequest)
    case deleteTodoComment(DeleteTodoCommentRequest)
    case clearOutput(TerminalIDRequest)
    /// Control protocol 2 (`CherryToolProtocol.swift`): the app that
    /// answers, its tools for a client, and one MCP tool run in the app as
    /// its caller. Never inside `scoped`: a tool call names its project in
    /// its arguments.
    case appInfo
    case listTools(ListToolsRequest)
    case callTool(CallToolRequest)
}

public struct ScopedControlRequest: Codable, Equatable, Sendable {
    public let projectRoot: String
    public let request: CherryControlRequest

    public init(projectRoot: String, request: CherryControlRequest) {
        self.projectRoot = projectRoot
        self.request = request
    }
}

public struct ListProcessesRequest: Codable, Equatable, Sendable {
    public let kind: String?

    public init(kind: String? = nil) {
        self.kind = kind
    }
}

public struct ProcessSelectorRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?

    public init(processID: String? = nil, processName: String? = nil) {
        self.processID = processID
        self.processName = processName
    }
}

public struct GetProcessOutputRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let startLine: Int?
    public let lineLimit: Int?

    public init(processID: String? = nil, processName: String? = nil, startLine: Int? = nil, lineLimit: Int? = nil) {
        self.processID = processID
        self.processName = processName
        self.startLine = startLine
        self.lineLimit = lineLimit
    }
}

public struct GetProcessRawOutputRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let maxBytes: Int?

    public init(processID: String? = nil, processName: String? = nil, maxBytes: Int? = nil) {
        self.processID = processID
        self.processName = processName
        self.maxBytes = maxBytes
    }
}

public struct SearchProcessOutputRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let query: String
    public let caseSensitive: Bool?
    public let maxMatches: Int?

    public init(
        processID: String? = nil,
        processName: String? = nil,
        query: String,
        caseSensitive: Bool? = nil,
        maxMatches: Int? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.query = query
        self.caseSensitive = caseSensitive
        self.maxMatches = maxMatches
    }
}

public struct WaitForProcessIdleRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let sinceOutputVersion: Int?
    public let requireNewOutput: Bool?
    public let quietMilliseconds: Int?
    public let timeoutMilliseconds: Int?
    public let lineLimit: Int?

    public init(
        processID: String? = nil,
        processName: String? = nil,
        sinceOutputVersion: Int? = nil,
        requireNewOutput: Bool? = nil,
        quietMilliseconds: Int? = nil,
        timeoutMilliseconds: Int? = nil,
        lineLimit: Int? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.sinceOutputVersion = sinceOutputVersion
        self.requireNewOutput = requireNewOutput
        self.quietMilliseconds = quietMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
        self.lineLimit = lineLimit
    }
}

public struct GetProcessPortsRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let includeUnattributed: Bool?

    public init(processID: String? = nil, processName: String? = nil, includeUnattributed: Bool? = nil) {
        self.processID = processID
        self.processName = processName
        self.includeUnattributed = includeUnattributed
    }
}

public struct ServicesListRequest: Codable, Equatable, Sendable {
    public let kind: String?
    public let includeUnattributed: Bool?

    public init(kind: String? = nil, includeUnattributed: Bool? = nil) {
        self.kind = kind
        self.includeUnattributed = includeUnattributed
    }
}

public struct WaitForBoundPortRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let port: Int?
    public let timeoutMilliseconds: Int?
    public let includeUnattributed: Bool?
    public let probeHTTP: Bool?
    public let path: String?

    public init(
        processID: String? = nil,
        processName: String? = nil,
        port: Int? = nil,
        timeoutMilliseconds: Int? = nil,
        includeUnattributed: Bool? = nil,
        probeHTTP: Bool? = nil,
        path: String? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.port = port
        self.timeoutMilliseconds = timeoutMilliseconds
        self.includeUnattributed = includeUnattributed
        self.probeHTTP = probeHTTP
        self.path = path
    }
}

public struct SpawnProcessRequest: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String?
    public let model: String?
    /// Agents only: a reasoning effort or thinking level for this launch
    /// ("low", "high", …), passed as the agent CLI takes it.
    public let effort: String?
    public let title: String?
    public let workingDirectory: String?
    public let text: String?
    public let rawBase64: String?
    public let submit: Bool?
    public let parentAgentID: String?
    public let waitMilliseconds: Int?
    public let lineLimit: Int?
    /// Agents only: the worker's brief, as a task (exclusive with `text`
    /// and `rawBase64`). Cherry types a kickoff line into the agent, which
    /// reads the brief with `get_my_task` and answers with `report_result`.
    public let task: String?
    /// The task's short name (the sidebar shows it).
    public let label: String?
    public let phase: String?
    /// The run to add the task to; nil for the caller's current run.
    public let runID: String?
    /// The JSON Schema (`TaskResultSchema`'s subset) the result must match.
    public let resultSchema: JSONValue?
    /// With `task`: the worker may use its own CLI's subagents in its tab
    /// (it still cannot hand out Cherry tasks).
    public let allowSubagents: Bool?

    public init(
        kind: String,
        name: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        title: String? = nil,
        workingDirectory: String? = nil,
        text: String? = nil,
        rawBase64: String? = nil,
        submit: Bool? = nil,
        parentAgentID: String? = nil,
        waitMilliseconds: Int? = nil,
        lineLimit: Int? = nil,
        task: String? = nil,
        label: String? = nil,
        phase: String? = nil,
        runID: String? = nil,
        resultSchema: JSONValue? = nil,
        allowSubagents: Bool? = nil
    ) {
        self.kind = kind
        self.name = name
        self.model = model
        self.effort = effort
        self.title = title
        self.workingDirectory = workingDirectory
        self.text = text
        self.rawBase64 = rawBase64
        self.submit = submit
        self.parentAgentID = parentAgentID
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
        self.task = task
        self.label = label
        self.phase = phase
        self.runID = runID
        self.resultSchema = resultSchema
        self.allowSubagents = allowSubagents
    }
}

public enum AgentClosePolicy: String, Codable, Equatable, Sendable {
    case reject
    case closeSubAgents = "close_sub_agents"
    case promoteSubAgents = "promote_sub_agents"
}

public struct CloseProcessRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let agentClosePolicy: AgentClosePolicy?

    public init(
        processID: String? = nil,
        processName: String? = nil,
        agentClosePolicy: AgentClosePolicy? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.agentClosePolicy = agentClosePolicy
    }
}

public struct ProcessLifecycleRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let kind: String?
    public let waitMilliseconds: Int?
    public let lineLimit: Int?

    public init(
        processID: String? = nil,
        processName: String? = nil,
        kind: String? = nil,
        waitMilliseconds: Int? = nil,
        lineLimit: Int? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.kind = kind
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
    }
}

public struct RenameProcessRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let title: String?

    public init(processID: String? = nil, processName: String? = nil, title: String? = nil) {
        self.processID = processID
        self.processName = processName
        self.title = title
    }
}

public struct SendProcessInputRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let text: String?
    public let rawBase64: String?
    public let submit: Bool?
    public let waitMilliseconds: Int?
    public let lineLimit: Int?

    public init(
        processID: String? = nil,
        processName: String? = nil,
        text: String? = nil,
        rawBase64: String? = nil,
        submit: Bool? = nil,
        waitMilliseconds: Int? = nil,
        lineLimit: Int? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.text = text
        self.rawBase64 = rawBase64
        self.submit = submit
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
    }
}

public struct AnswerPromptRequest: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    /// An option's number ("2") or its label, matched without regard to
    /// case: the whole label first, then a unique start, then a unique part.
    public let choice: String
    public let waitMilliseconds: Int?
    public let lineLimit: Int?

    public init(
        processID: String? = nil,
        processName: String? = nil,
        choice: String,
        waitMilliseconds: Int? = nil,
        lineLimit: Int? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.choice = choice
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
    }
}

public struct ProcessBulkCommandRequest: Codable, Equatable, Sendable {
    public let waitMilliseconds: Int?

    public init(waitMilliseconds: Int? = nil) {
        self.waitMilliseconds = waitMilliseconds
    }
}

public struct TerminalIDRequest: Codable, Equatable, Sendable {
    public let terminalID: String

    public init(terminalID: String) {
        self.terminalID = terminalID
    }
}

public struct TodoIDRequest: Codable, Equatable, Sendable {
    public let todoID: String

    public init(todoID: String) {
        self.todoID = todoID
    }
}

public struct ResolveDeepLinkRequest: Codable, Equatable, Sendable {
    public let link: String
    public let includeOutput: Bool?
    public let startLine: Int?
    public let lineLimit: Int?

    public init(link: String, includeOutput: Bool? = nil, startLine: Int? = nil, lineLimit: Int? = nil) {
        self.link = link
        self.includeOutput = includeOutput
        self.startLine = startLine
        self.lineLimit = lineLimit
    }
}

public struct CreateTodoRequest: Codable, Equatable, Sendable {
    public let title: String
    public let markdown: String
    public let status: TodoStatus?
    public let tags: [String]?

    public init(title: String, markdown: String = "", status: TodoStatus? = nil, tags: [String]? = nil) {
        self.title = title
        self.markdown = markdown
        self.status = status
        self.tags = tags
    }
}

public struct UpdateTodoRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let title: String?
    public let markdown: String?
    public let status: TodoStatus?
    public let tags: [String]?

    public init(
        todoID: String,
        title: String? = nil,
        markdown: String? = nil,
        status: TodoStatus? = nil,
        tags: [String]? = nil
    ) {
        self.todoID = todoID
        self.title = title
        self.markdown = markdown
        self.status = status
        self.tags = tags
    }
}

public struct MoveTodoRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let status: TodoStatus?
    public let afterTodoID: String?

    public init(todoID: String, status: TodoStatus? = nil, afterTodoID: String? = nil) {
        self.todoID = todoID
        self.status = status
        self.afterTodoID = afterTodoID
    }
}

public struct AddTodoCommentRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let markdown: String
    public let author: String?
    public let terminalID: String?

    public init(
        todoID: String,
        markdown: String,
        author: String? = nil,
        terminalID: String? = nil
    ) {
        self.todoID = todoID
        self.markdown = markdown
        self.author = author
        self.terminalID = terminalID
    }
}

public struct UpdateTodoCommentRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let commentID: String
    public let markdown: String

    public init(todoID: String, commentID: String, markdown: String) {
        self.todoID = todoID
        self.commentID = commentID
        self.markdown = markdown
    }
}

public struct DeleteTodoCommentRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let commentID: String

    public init(todoID: String, commentID: String) {
        self.todoID = todoID
        self.commentID = commentID
    }
}

public struct CherryControlResponse: Codable, Equatable, Sendable {
    public let result: CherryControlResult?
    public let error: CherryControlError?

    public init(result: CherryControlResult) {
        self.result = result
        self.error = nil
    }

    public init(error: CherryControlError) {
        self.result = nil
        self.error = error
    }
}

public enum CherryControlResult: Codable, Equatable, Sendable {
    case listProjects(ListProjectsResult)
    case openProject(OpenProjectResult)
    case getProjectStatus(ProjectStatusResult)
    case getPerformanceStatus(PerformanceStatusResult)
    case resolveLink(ResolveDeepLinkResult)
    case listProcesses(ListProcessesResult)
    case getProcessStatus(ProcessStatusResult)
    case getProcessOutput(TerminalOutputResult)
    case getProcessRawOutput(TerminalRawOutputResult)
    case searchProcessOutput(SearchOutputResult)
    case waitForProcessIdle(WaitForProcessIdleResult)
    case subscribe(SubscribeResult)
    case unsubscribe(UnsubscribeResult)
    case waitForEvents(WaitForEventsResult)
    case listSubscriptions(ListSubscriptionsResult)
    case getMyTask(GetMyTaskResult)
    case reportResult(ReportResultResult)
    case reportProgress(ReportProgressResult)
    case waitForTasks(WaitForTasksResult)
    case getTask(AgentTaskDetail)
    case listTasks(ListTasksResult)
    case cancelTasks(CancelTasksResult)
    case getProcessPorts(ServicesResult)
    case servicesList(ServicesResult)
    case waitForBoundPort(WaitForBoundPortResult)
    case spawnProcess(SpawnProcessResult)
    case startProcess(ProcessLifecycleResult)
    case stopProcess(ProcessLifecycleResult)
    case restartProcess(ProcessLifecycleResult)
    case closeProcess(CloseProcessResult)
    case renameProcess(ProcessStatusResult)
    case selectProcess(ProcessStatusResult)
    case sendProcessInput(SendProcessInputResult)
    case answerPrompt(AnswerPromptResult)
    case startAllCommands(ListProcessesResult)
    case stopAllCommands(ListProcessesResult)
    case restartAllCommands(ListProcessesResult)
    case listTerminals(ListTerminalsResult)
    case listAgents(ListAgentsResult)
    case listTodos(ListTodosResult)
    case createTodo(TodoDetailResult)
    case getTodo(TodoDetailResult)
    case updateTodo(TodoDetailResult)
    case moveTodo(TodoDetailResult)
    case deleteTodo(DeleteTodoResult)
    case selectTodo(SelectTodoResult)
    case addTodoComment(TodoDetailResult)
    case listTodoComments(ListTodoCommentsResult)
    case updateTodoComment(TodoDetailResult)
    case deleteTodoComment(TodoDetailResult)
    case clearOutput(ClearOutputResult)
    /// Control protocol 2 (`CherryToolProtocol.swift`).
    case appInfo(AppInfoResult)
    case listTools(ListToolsResult)
    case callTool(CallToolResult)
}

public struct CherryControlError: Codable, Equatable, Error, Sendable {
    public let code: String
    public let message: String
    public let serviceCandidates: [ServiceRecord]?
    /// Each problem, when there are several (`schema_mismatch`: where the
    /// value does not match the task's result schema).
    public let details: [String]?
    /// `agent_awaiting_permission`, `agent_awaiting_input` and answer_prompt's
    /// errors: the menu the agent shows, when its screen shows one.
    public let prompt: AgentPromptInfo?

    public init(
        code: String,
        message: String,
        serviceCandidates: [ServiceRecord]? = nil,
        details: [String]? = nil,
        prompt: AgentPromptInfo? = nil
    ) {
        self.code = code
        self.message = message
        self.serviceCandidates = serviceCandidates
        self.details = details
        self.prompt = prompt
    }
}

public struct TerminalInfo: Codable, Equatable, Sendable {
    public let id: String
    public let link: String?
    public let title: String
    public let state: String
    public let selected: Bool
    public let workingDirectory: String
    public let lineCount: Int
    public let kind: String?
    public let agentName: String?
    public let parentAgentID: String?
    public let childAgentCount: Int?

    public init(
        id: String,
        title: String,
        state: String,
        selected: Bool,
        workingDirectory: String,
        lineCount: Int,
        link: String? = nil,
        kind: String? = nil,
        agentName: String? = nil,
        parentAgentID: String? = nil,
        childAgentCount: Int? = nil
    ) {
        self.id = id
        self.link = link
        self.title = title
        self.state = state
        self.selected = selected
        self.workingDirectory = workingDirectory
        self.lineCount = lineCount
        self.kind = kind
        self.agentName = agentName
        self.parentAgentID = parentAgentID
        self.childAgentCount = childAgentCount
    }
}

public struct ListTerminalsResult: Codable, Equatable, Sendable {
    public let terminals: [TerminalInfo]
    public let selectedTerminalID: String?

    public init(terminals: [TerminalInfo], selectedTerminalID: String?) {
        self.terminals = terminals
        self.selectedTerminalID = selectedTerminalID
    }
}

public struct OpenProjectRequest: Codable, Equatable, Sendable {
    public let projectRoot: String

    public init(projectRoot: String) {
        self.projectRoot = projectRoot
    }
}

public struct ProjectInfo: Codable, Equatable, Sendable {
    public let root: String
    public let name: String
    public let active: Bool
    public let open: Bool
    public let features: ProjectFeatureAvailability

    public init(
        root: String,
        name: String,
        active: Bool,
        open: Bool,
        features: ProjectFeatureAvailability = .init(todosEnabled: false)
    ) {
        self.root = root
        self.name = name
        self.active = active
        self.open = open
        self.features = features
    }
}

extension CodingUserInfoKey {
    /// True on an encoder that writes what agents read (CherryMCP's tool
    /// results), not the control wire: fields the wire keeps only for older
    /// helpers stay out of it.
    public static let cherryAgentFacingOutput = CodingUserInfoKey(rawValue: "cherry.agentFacingOutput")!
}

/// A project's optional features. The wire still carries `notesEnabled`,
/// always false: CherryMCP helpers from before notes were removed (an agent's
/// helper in a persistent session an update kept, a build installed on another
/// Mac) decode it as required, and without it their `list_projects` and
/// `get_project_status` answers would not decode. Agents never see it
/// (`cherryAgentFacingOutput`).
public struct ProjectFeatureAvailability: Codable, Equatable, Sendable {
    public let todosEnabled: Bool

    public init(todosEnabled: Bool) {
        self.todosEnabled = todosEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case notesEnabled
        case todosEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        todosEnabled = try container.decode(Bool.self, forKey: .todosEnabled)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if encoder.userInfo[.cherryAgentFacingOutput] as? Bool != true {
            try container.encode(false, forKey: .notesEnabled)
        }
        try container.encode(todosEnabled, forKey: .todosEnabled)
    }
}

public struct ListProjectsResult: Codable, Equatable, Sendable {
    public let activeProjectRoot: String?
    public let projects: [ProjectInfo]

    public init(activeProjectRoot: String?, projects: [ProjectInfo]) {
        self.activeProjectRoot = activeProjectRoot
        self.projects = projects
    }
}

public struct OpenProjectResult: Codable, Equatable, Sendable {
    public let projectRoot: String
    public let alreadyOpen: Bool

    public init(projectRoot: String, alreadyOpen: Bool) {
        self.projectRoot = projectRoot
        self.alreadyOpen = alreadyOpen
    }
}

public struct ProcessCounts: Codable, Equatable, Sendable {
    public let total: Int
    public let terminals: Int
    public let agents: Int
    public let commands: Int

    public init(total: Int, terminals: Int, agents: Int, commands: Int) {
        self.total = total
        self.terminals = terminals
        self.agents = agents
        self.commands = commands
    }
}

public struct ProjectStatusResult: Codable, Equatable, Sendable {
    public let projectRoot: String?
    public let processCounts: ProcessCounts
    public let todoCount: Int?
    public let features: ProjectFeatureAvailability
    public let selectedProcessID: String?
    public let selectedProcessName: String?
    public let health: String

    public init(
        projectRoot: String?,
        processCounts: ProcessCounts,
        todoCount: Int?,
        features: ProjectFeatureAvailability = .init(todosEnabled: false),
        selectedProcessID: String?,
        selectedProcessName: String?,
        health: String
    ) {
        self.projectRoot = projectRoot
        self.processCounts = processCounts
        self.todoCount = todoCount
        self.features = features
        self.selectedProcessID = selectedProcessID
        self.selectedProcessName = selectedProcessName
        self.health = health
    }
}

public struct TerminalPerformanceCounters: Codable, Equatable, Sendable {
    public var ptyChunks: Int
    public var ptyBytes: Int
    public var ghosttyFeedChunks: Int
    public var ghosttyFeedBytes: Int
    public var processorBacklogDropCount: Int
    public var processorBacklogDroppedBytes: Int
    public var backgroundOutputThrottleCount: Int
    public var processorChanges: Int
    public var representableUpdates: Int
    public var containerConfigures: Int
    public var bridgeAttaches: Int
    public var reusedBridgeAttaches: Int
    public var fitToSizeCalls: Int
    public var settingsApplies: Int
    public var settingsReconfigures: Int
    public var renderTicks: Int

    public init(
        ptyChunks: Int = 0,
        ptyBytes: Int = 0,
        ghosttyFeedChunks: Int = 0,
        ghosttyFeedBytes: Int = 0,
        processorBacklogDropCount: Int = 0,
        processorBacklogDroppedBytes: Int = 0,
        backgroundOutputThrottleCount: Int = 0,
        processorChanges: Int = 0,
        representableUpdates: Int = 0,
        containerConfigures: Int = 0,
        bridgeAttaches: Int = 0,
        reusedBridgeAttaches: Int = 0,
        fitToSizeCalls: Int = 0,
        settingsApplies: Int = 0,
        settingsReconfigures: Int = 0,
        renderTicks: Int = 0
    ) {
        self.ptyChunks = ptyChunks
        self.ptyBytes = ptyBytes
        self.ghosttyFeedChunks = ghosttyFeedChunks
        self.ghosttyFeedBytes = ghosttyFeedBytes
        self.processorBacklogDropCount = processorBacklogDropCount
        self.processorBacklogDroppedBytes = processorBacklogDroppedBytes
        self.backgroundOutputThrottleCount = backgroundOutputThrottleCount
        self.processorChanges = processorChanges
        self.representableUpdates = representableUpdates
        self.containerConfigures = containerConfigures
        self.bridgeAttaches = bridgeAttaches
        self.reusedBridgeAttaches = reusedBridgeAttaches
        self.fitToSizeCalls = fitToSizeCalls
        self.settingsApplies = settingsApplies
        self.settingsReconfigures = settingsReconfigures
        self.renderTicks = renderTicks
    }
}

public struct PerformanceStatusResult: Codable, Equatable, Sendable {
    public let activeProjectRoot: String?
    public let processCounts: ProcessCounts
    public let selectedProcessID: String?
    public let ghosttyLiveBridgeCount: Int
    public let ghosttyInstalledOutputObserverCount: Int
    public let rawOutputObserverCount: Int
    public let rawOutputRetainedBytes: Int
    public let rawOutputRetainedChunkCount: Int
    public let terminalPerfEnabled: Bool
    public let terminalPerfCounters: TerminalPerformanceCounters

    public init(
        activeProjectRoot: String?,
        processCounts: ProcessCounts,
        selectedProcessID: String?,
        ghosttyLiveBridgeCount: Int,
        ghosttyInstalledOutputObserverCount: Int,
        rawOutputObserverCount: Int,
        rawOutputRetainedBytes: Int,
        rawOutputRetainedChunkCount: Int,
        terminalPerfEnabled: Bool,
        terminalPerfCounters: TerminalPerformanceCounters
    ) {
        self.activeProjectRoot = activeProjectRoot
        self.processCounts = processCounts
        self.selectedProcessID = selectedProcessID
        self.ghosttyLiveBridgeCount = ghosttyLiveBridgeCount
        self.ghosttyInstalledOutputObserverCount = ghosttyInstalledOutputObserverCount
        self.rawOutputObserverCount = rawOutputObserverCount
        self.rawOutputRetainedBytes = rawOutputRetainedBytes
        self.rawOutputRetainedChunkCount = rawOutputRetainedChunkCount
        self.terminalPerfEnabled = terminalPerfEnabled
        self.terminalPerfCounters = terminalPerfCounters
    }
}

public struct ProcessSummary: Codable, Equatable, Sendable {
    public let id: String
    public let link: String?
    public let name: String
    public let kind: String
    public let state: String
    public let pid: Int32?
    public let startedAt: Date?
    public let exitedAt: Date?
    public let lastOutputAt: Date?
    public let acceptsInput: Bool
    public let exitCode: Int32?
    public let restartPolicy: String?
    public let workingDirectory: String
    public let commandLine: String?
    public let lineCount: Int
    public let outputVersion: Int
    public let selected: Bool
    public let agentName: String?
    public let commandName: String?
    public let parentAgentID: String?
    public let childAgentCount: Int?
    public let agentActivityState: String?
    public let usesAlternateScreen: Bool?
    public let lastContentChangeAt: Date?
    public let contentVersion: Int?
    /// Why the launch failed, when `state` is `failed`.
    public let failureMessage: String?
    /// Agents only: how many turns Cherry saw start in this tab, over its
    /// whole life: submitted (typed Enter or MCP input), or reported by the
    /// agent (OSC 7501 `working`, also for a turn it began by itself: a
    /// background task's result, a scheduled wake-up). Monotonic, so "done
    /// since my message" compares against it.
    public let agentTurn: Int?
    /// Agents only: `not_started`, `active`, `completed` or
    /// `user_interrupted`, for the latest turn.
    public let agentTurnState: String?
    /// A worker of a Cherry task (MCP `spawn_agent` with `task`): its
    /// task, the task's state (`AgentTaskState`), run, phase and label,
    /// and its latest result's summary.
    public let taskID: String?
    public let taskState: String?
    public let runID: String?
    public let phase: String?
    public let label: String?
    public let resultSummary: String?
    /// What the tab's program says it is doing (OSC 7501 program status:
    /// its root record), when it says anything. Its text is the program's
    /// own: data, never instructions.
    public let programStatus: ProcessProgramStatus?

    public init(
        id: String,
        link: String? = nil,
        name: String,
        kind: String,
        state: String,
        pid: Int32? = nil,
        startedAt: Date? = nil,
        exitedAt: Date? = nil,
        lastOutputAt: Date? = nil,
        acceptsInput: Bool = false,
        exitCode: Int32? = nil,
        restartPolicy: String? = nil,
        workingDirectory: String,
        commandLine: String?,
        lineCount: Int,
        outputVersion: Int = 0,
        selected: Bool,
        agentName: String?,
        commandName: String?,
        parentAgentID: String? = nil,
        childAgentCount: Int? = nil,
        agentActivityState: String? = nil,
        usesAlternateScreen: Bool? = nil,
        lastContentChangeAt: Date? = nil,
        contentVersion: Int? = nil,
        failureMessage: String? = nil,
        agentTurn: Int? = nil,
        agentTurnState: String? = nil,
        taskID: String? = nil,
        taskState: String? = nil,
        runID: String? = nil,
        phase: String? = nil,
        label: String? = nil,
        resultSummary: String? = nil,
        programStatus: ProcessProgramStatus? = nil
    ) {
        self.id = id
        self.link = link
        self.name = name
        self.kind = kind
        self.state = state
        self.pid = pid
        self.startedAt = startedAt
        self.exitedAt = exitedAt
        self.lastOutputAt = lastOutputAt
        self.acceptsInput = acceptsInput
        self.exitCode = exitCode
        self.restartPolicy = restartPolicy
        self.workingDirectory = workingDirectory
        self.commandLine = commandLine
        self.lineCount = lineCount
        self.outputVersion = outputVersion
        self.selected = selected
        self.agentName = agentName
        self.commandName = commandName
        self.parentAgentID = parentAgentID
        self.childAgentCount = childAgentCount
        self.agentActivityState = agentActivityState
        self.usesAlternateScreen = usesAlternateScreen
        self.lastContentChangeAt = lastContentChangeAt
        self.contentVersion = contentVersion
        self.failureMessage = failureMessage
        self.agentTurn = agentTurn
        self.agentTurnState = agentTurnState
        self.taskID = taskID
        self.taskState = taskState
        self.runID = runID
        self.phase = phase
        self.label = label
        self.resultSummary = resultSummary
        self.programStatus = programStatus
    }
}

/// A program status record (OSC 7501) as MCP reports it.
public struct ProcessProgramStatus: Codable, Equatable, Sendable {
    /// `idle`, `working`, `done`, `blocked` or `error`.
    public let state: String
    /// For `blocked`: `permission`, `question` or `auth`, when it said.
    public let kind: String?
    /// 0–100, when it said.
    public let progress: Int?
    /// A stable name for the program (`claude-code`, `pi`, `cargo`).
    public let app: String?
    public let title: String?
    /// One line saying what it is doing, waiting for or finished.
    public let message: String?

    public init(
        state: String,
        kind: String? = nil,
        progress: Int? = nil,
        app: String? = nil,
        title: String? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
    }
}

public enum ServiceAttribution: String, Codable, Equatable, Sendable {
    case processTree = "process_tree"
    case unattributed
}

public enum ServiceReadiness: String, Codable, Equatable, Sendable {
    case bound
    case httpOK = "http_ok"
    case httpFailed = "http_failed"
}

public struct ServiceRecord: Codable, Equatable, Sendable {
    public let processID: String?
    public let processName: String?
    public let kind: String?
    public let pid: Int32?
    public let port: Int
    public let host: String
    public let url: String
    public let attribution: ServiceAttribution
    public let protocolGuess: String?
    public var readiness: ServiceReadiness
    public let lastSeenAt: Date
    public let commandName: String?
    public let agentName: String?
    /// The Mac the service runs on when it is not This Mac (a tab of
    /// another Mac, docs/specs/remote-devices.md phase 4a); nil for This Mac.
    public let machine: String?
    /// The service's URL on that Mac (`url` is then the forwarded one here).
    public let remoteURL: String?
    /// The Mac the service was forwarded from ("Studio"): `url` is a port
    /// of This Mac's loopback forwarded over SSH to it.
    public let forwardedFrom: String?
    /// Why a service of another Mac could not be forwarded (`url` is then
    /// its URL there).
    public let forwardError: String?

    public init(
        processID: String?,
        processName: String?,
        kind: String?,
        pid: Int32?,
        port: Int,
        host: String,
        url: String,
        attribution: ServiceAttribution,
        protocolGuess: String?,
        readiness: ServiceReadiness,
        lastSeenAt: Date,
        commandName: String?,
        agentName: String?,
        machine: String? = nil,
        remoteURL: String? = nil,
        forwardedFrom: String? = nil,
        forwardError: String? = nil
    ) {
        self.machine = machine
        self.remoteURL = remoteURL
        self.forwardedFrom = forwardedFrom
        self.forwardError = forwardError
        self.processID = processID
        self.processName = processName
        self.kind = kind
        self.pid = pid
        self.port = port
        self.host = host
        self.url = url
        self.attribution = attribution
        self.protocolGuess = protocolGuess
        self.readiness = readiness
        self.lastSeenAt = lastSeenAt
        self.commandName = commandName
        self.agentName = agentName
    }
}

public struct ServicesResult: Codable, Equatable, Sendable {
    public let activeProjectRoot: String?
    public let services: [ServiceRecord]
    public let unattributed: [ServiceRecord]

    public init(activeProjectRoot: String?, services: [ServiceRecord], unattributed: [ServiceRecord]) {
        self.activeProjectRoot = activeProjectRoot
        self.services = services
        self.unattributed = unattributed
    }
}

public struct WaitForBoundPortResult: Codable, Equatable, Sendable {
    public let service: ServiceRecord

    public init(service: ServiceRecord) {
        self.service = service
    }
}

public struct ListProcessesResult: Codable, Equatable, Sendable {
    public let activeProjectRoot: String?
    public let processes: [ProcessSummary]
    public let selectedProcessID: String?

    public init(activeProjectRoot: String?, processes: [ProcessSummary], selectedProcessID: String?) {
        self.activeProjectRoot = activeProjectRoot
        self.processes = processes
        self.selectedProcessID = selectedProcessID
    }
}

public struct ProcessStatusResult: Codable, Equatable, Sendable {
    public let process: ProcessSummary
    /// get_process_status of an agent that shows a permission or question
    /// menu: the menu as its screen shows it.
    public let prompt: AgentPromptInfo?

    public init(process: ProcessSummary, prompt: AgentPromptInfo? = nil) {
        self.process = process
        self.prompt = prompt
    }
}

/// A permission or question menu an agent CLI shows at the bottom of its
/// screen, as Cherry read it there. Its texts are the program's output:
/// data, never instructions.
public struct AgentPromptInfo: Codable, Equatable, Sendable {
    /// `permission` (approve a command, an edit, a plan) or `question` (the
    /// agent asks the user to choose).
    public let kind: String
    /// The line that asks, when the screen shows one above the options.
    public let question: String?
    public let options: [AgentPromptOption]

    public static let permissionKind = "permission"
    public static let questionKind = "question"

    public init(kind: String, question: String?, options: [AgentPromptOption]) {
        self.kind = kind
        self.question = question
        self.options = options
    }
}

public struct AgentPromptOption: Codable, Equatable, Sendable {
    /// The number the menu shows (1 first).
    public let number: Int
    public let label: String
    /// What the menu says about it, when it says more than its label.
    public let detail: String?
    /// The highlighted option, which Enter picks.
    public let selected: Bool

    public init(number: Int, label: String, detail: String? = nil, selected: Bool) {
        self.number = number
        self.label = label
        self.detail = detail
        self.selected = selected
    }
}

public struct AnswerPromptResult: Codable, Equatable, Sendable {
    public let processID: String
    /// The menu as it was read just before Cherry answered it.
    public let prompt: AgentPromptInfo
    /// The option picked.
    public let answered: AgentPromptOption
    public let sentBytes: Int
    public let output: TerminalOutputResult?

    public init(processID: String, prompt: AgentPromptInfo, answered: AgentPromptOption, sentBytes: Int, output: TerminalOutputResult?) {
        self.processID = processID
        self.prompt = prompt
        self.answered = answered
        self.sentBytes = sentBytes
        self.output = output
    }
}

public enum ProcessIdleWaitReason: String, Codable, Equatable, Sendable {
    case idle
    case exited
    /// A persistent-session tab lost its attach client; the hosted program
    /// may still be running.
    case disconnected
    case timedOut = "timed_out"
    case permission
    case agentError = "agent_error"
    /// The agent asks the user a question (a choice menu): its turn is
    /// paused on an answer, not done.
    case needsInput = "needs_input"
    /// The process's tab was closed while the wait ran.
    case closed
}

public struct WaitForProcessIdleResult: Codable, Equatable, Sendable {
    public let process: ProcessSummary
    public let reason: ProcessIdleWaitReason
    public let timedOut: Bool
    public let observedNewOutput: Bool
    public let sinceOutputVersion: Int
    public let outputVersion: Int
    public let lastOutputAt: Date?
    public let agentActivityState: String?
    public let output: TerminalOutputResult
    /// Agents: the tab's turn counter when the wait ended (`agent_turn`).
    public let agentTurn: Int?
    /// Agents: whether the latest submitted turn showed that it started
    /// (working evidence after the submit). False on an `idle` result means
    /// the agent never looked busy after the message: it answered at once,
    /// or a CLI Cherry cannot read settled after the start grace.
    public let turnStarted: Bool?

    public init(
        process: ProcessSummary,
        reason: ProcessIdleWaitReason,
        observedNewOutput: Bool,
        sinceOutputVersion: Int,
        outputVersion: Int,
        lastOutputAt: Date?,
        agentActivityState: String? = nil,
        output: TerminalOutputResult,
        agentTurn: Int? = nil,
        turnStarted: Bool? = nil
    ) {
        self.process = process
        self.reason = reason
        self.timedOut = reason == .timedOut
        self.observedNewOutput = observedNewOutput
        self.sinceOutputVersion = sinceOutputVersion
        self.outputVersion = outputVersion
        self.lastOutputAt = lastOutputAt
        self.agentActivityState = agentActivityState
        self.output = output
        self.agentTurn = agentTurn
        self.turnStarted = turnStarted
    }
}

public struct SpawnProcessResult: Codable, Equatable, Sendable {
    public let process: ProcessSummary
    public let sentBytes: Int
    public let output: TerminalOutputResult?
    /// The task, when the agent was spawned with one.
    public let task: AgentTaskInfo?
    /// Why the first input (a task's kickoff) did not arrive, when it was
    /// refused or failed (`agent_awaiting_permission`,
    /// `input_not_delivered`, …): the process runs either way. Absent when
    /// it arrived or there was none, and from apps that predate it.
    public let inputError: CherryControlError?

    public init(
        process: ProcessSummary,
        sentBytes: Int,
        output: TerminalOutputResult?,
        task: AgentTaskInfo? = nil,
        inputError: CherryControlError? = nil
    ) {
        self.process = process
        self.sentBytes = sentBytes
        self.output = output
        self.task = task
        self.inputError = inputError
    }
}

public struct ProcessLifecycleResult: Codable, Equatable, Sendable {
    public let process: ProcessSummary
    public let output: TerminalOutputResult?

    public init(process: ProcessSummary, output: TerminalOutputResult?) {
        self.process = process
        self.output = output
    }
}

public struct SendProcessInputResult: Codable, Equatable, Sendable {
    public let processID: String
    public let sentBytes: Int
    public let output: TerminalOutputResult?

    public init(processID: String, sentBytes: Int, output: TerminalOutputResult?) {
        self.processID = processID
        self.sentBytes = sentBytes
        self.output = output
    }
}

public struct CloseProcessResult: Codable, Equatable, Sendable {
    public let processID: String
    public let closed: Bool

    public init(processID: String, closed: Bool) {
        self.processID = processID
        self.closed = closed
    }
}

public struct AgentInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let command: String
    public let arguments: String
    public let commandLine: String
    public let enabled: Bool
    public let launchable: Bool
    public let activeSessionCount: Int

    public init(
        id: String,
        name: String,
        command: String,
        arguments: String,
        commandLine: String,
        enabled: Bool,
        launchable: Bool,
        activeSessionCount: Int
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.commandLine = commandLine
        self.enabled = enabled
        self.launchable = launchable
        self.activeSessionCount = activeSessionCount
    }
}

public struct ListAgentsResult: Codable, Equatable, Sendable {
    public let activeProjectRoot: String?
    public let agents: [AgentInfo]

    public init(activeProjectRoot: String?, agents: [AgentInfo]) {
        self.activeProjectRoot = activeProjectRoot
        self.agents = agents
    }
}

public enum TodoStatus: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case backlog
    case ready
    case doing
    case blocked
    case done

    public var id: String { rawValue }
}

public struct TodoTag: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var colorHex: String

    public init(id: String, name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

public struct TodoComment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var markdown: String
    public var authorLabel: String
    public var authorTerminalID: String?
    public var authorAgentName: String?
    public let createdAt: Date

    public init(
        id: UUID,
        markdown: String,
        authorLabel: String,
        authorTerminalID: String? = nil,
        authorAgentName: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.markdown = markdown
        self.authorLabel = authorLabel
        self.authorTerminalID = authorTerminalID
        self.authorAgentName = authorAgentName
        self.createdAt = createdAt
    }
}

public struct ProjectTodo: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectRoot: String
    public var title: String
    public var markdown: String
    public var status: TodoStatus
    public var position: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var tags: [TodoTag]
    public var comments: [TodoComment]

    public init(
        id: UUID,
        projectRoot: String,
        title: String,
        markdown: String,
        status: TodoStatus,
        position: Int,
        createdAt: Date,
        updatedAt: Date,
        tags: [TodoTag] = [],
        comments: [TodoComment] = []
    ) {
        self.id = id
        self.projectRoot = projectRoot
        self.title = title
        self.markdown = markdown
        self.status = status
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
        self.comments = comments
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectRoot
        case title
        case markdown
        case status
        case position
        case createdAt
        case updatedAt
        case tags
        case comments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectRoot = try container.decode(String.self, forKey: .projectRoot)
        title = try container.decode(String.self, forKey: .title)
        markdown = try container.decode(String.self, forKey: .markdown)
        status = try container.decode(TodoStatus.self, forKey: .status)
        position = try container.decode(Int.self, forKey: .position)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        tags = try container.decodeIfPresent([TodoTag].self, forKey: .tags) ?? []
        comments = try container.decodeIfPresent([TodoComment].self, forKey: .comments) ?? []
    }
}

public struct TodoInfo: Codable, Equatable, Sendable {
    public let id: String
    public let link: String?
    public let projectRoot: String
    public let title: String
    public let status: TodoStatus
    public let position: Int
    public let tags: [TodoTag]
    public let commentCount: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        link: String? = nil,
        projectRoot: String,
        title: String,
        status: TodoStatus,
        position: Int,
        tags: [TodoTag] = [],
        commentCount: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.link = link
        self.projectRoot = projectRoot
        self.title = title
        self.status = status
        self.position = position
        self.tags = tags
        self.commentCount = commentCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ListTodosResult: Codable, Equatable, Sendable {
    public let activeProjectRoot: String
    public let todos: [TodoInfo]
    public let selectedTodoID: String?

    public init(activeProjectRoot: String, todos: [TodoInfo], selectedTodoID: String?) {
        self.activeProjectRoot = activeProjectRoot
        self.todos = todos
        self.selectedTodoID = selectedTodoID
    }
}

public struct TodoDetailResult: Codable, Equatable, Sendable {
    public let todo: ProjectTodo
    public let link: String?
    public let selected: Bool

    public init(todo: ProjectTodo, link: String? = nil, selected: Bool) {
        self.todo = todo
        self.link = link
        self.selected = selected
    }
}

public struct ListTodoCommentsResult: Codable, Equatable, Sendable {
    public let todoID: String
    public let comments: [TodoComment]

    public init(todoID: String, comments: [TodoComment]) {
        self.todoID = todoID
        self.comments = comments
    }
}

public struct SelectTodoResult: Codable, Equatable, Sendable {
    public let todoID: String
    public let selected: Bool

    public init(todoID: String, selected: Bool) {
        self.todoID = todoID
        self.selected = selected
    }
}

public struct DeleteTodoResult: Codable, Equatable, Sendable {
    public let todoID: String
    public let deleted: Bool

    public init(todoID: String, deleted: Bool) {
        self.todoID = todoID
        self.deleted = deleted
    }
}

public struct TerminalOutputResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let startLine: Int
    public let endLineExclusive: Int
    public let totalLines: Int
    public let outputVersion: Int
    public let screen: String?
    public let contentVersion: Int?
    public let lines: [String]

    public init(
        terminalID: String,
        startLine: Int,
        endLineExclusive: Int,
        totalLines: Int,
        outputVersion: Int = 0,
        screen: String? = nil,
        contentVersion: Int? = nil,
        lines: [String]
    ) {
        self.terminalID = terminalID
        self.startLine = startLine
        self.endLineExclusive = endLineExclusive
        self.totalLines = totalLines
        self.outputVersion = outputVersion
        self.screen = screen
        self.contentVersion = contentVersion
        self.lines = lines
    }
}

public struct ResolveDeepLinkResult: Codable, Equatable, Sendable {
    public let link: String
    public let projectKey: String
    public let kind: CherryDeepLink.TargetKind
    public let targetID: String
    public let found: Bool
    public let projectRoot: String?
    public let todo: ProjectTodo?
    public let todoLink: String?
    public let process: ProcessSummary?
    public let output: TerminalOutputResult?

    public init(
        link: String,
        projectKey: String,
        kind: CherryDeepLink.TargetKind,
        targetID: String,
        found: Bool,
        projectRoot: String?,
        todo: ProjectTodo? = nil,
        todoLink: String? = nil,
        process: ProcessSummary? = nil,
        output: TerminalOutputResult? = nil
    ) {
        self.link = link
        self.projectKey = projectKey
        self.kind = kind
        self.targetID = targetID
        self.found = found
        self.projectRoot = projectRoot
        self.todo = todo
        self.todoLink = todoLink
        self.process = process
        self.output = output
    }
}

public struct TerminalRawOutputResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let text: String
    public let byteCount: Int
    public let truncated: Bool

    public init(terminalID: String, text: String, byteCount: Int, truncated: Bool) {
        self.terminalID = terminalID
        self.text = text
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

public struct SearchOutputResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let matches: [SearchOutputMatch]

    public init(terminalID: String, matches: [SearchOutputMatch]) {
        self.terminalID = terminalID
        self.matches = matches
    }
}

public struct SearchOutputMatch: Codable, Equatable, Sendable {
    public let lineNumber: Int
    public let text: String

    public init(lineNumber: Int, text: String) {
        self.lineNumber = lineNumber
        self.text = text
    }
}

public struct ClearOutputResult: Codable, Equatable, Sendable {
    public let terminalID: String
    /// False when the tab was cleared but its host kept the session's
    /// history (`hostKeptHistory` says why): MCP output read through the
    /// host, and the next attach adapter, may still show it.
    public let cleared: Bool
    /// Why a persistent tab's host kept its history; absent when it cleared
    /// it, or the tab has no host.
    public let hostKeptHistory: String?

    public init(terminalID: String, cleared: Bool, hostKeptHistory: String? = nil) {
        self.terminalID = terminalID
        self.cleared = cleared
        self.hostKeptHistory = hostKeptHistory
    }
}


// MARK: - Monitors

/// The kinds of monitor events (`MonitorEvent.type`).
public enum MonitorEventType: String, Codable, CaseIterable, Equatable, Sendable {
    /// An agent finished a turn: it reports idle after working or, when it
    /// reports no status, its output went quiet after a submitted turn
    /// (`basis`). A Cherry task's worker also gets one when its task
    /// settles (`task_id`), apart from its turns' dones.
    case done
    /// An agent asks the user a question with a choice menu.
    case needsInput = "needs_input"
    /// An agent waits for a permission answer.
    case permission
    /// An agent reported an error.
    case error
    /// The process ended (`exit N`) or its launch failed.
    case exited
    /// The process's tab was closed: it is no longer watched.
    case closed
    /// A line of the process's output contains `output_pattern`.
    case outputMatch = "output_match"

    /// What a subscription watches when it names no events.
    public static let defaults: [MonitorEventType] = [.done, .needsInput, .permission, .error, .exited, .closed]
}

public struct SubscribeRequest: Codable, Equatable, Sendable {
    /// Processes to watch (process ids).
    public let processIDs: [String]?
    /// Also watch the subscriber's sub-agents, including ones spawned later.
    public let subAgents: Bool?
    /// Event types (`MonitorEventType` raw values); nil for the defaults.
    public let events: [String]?
    /// Case-insensitive text an `output_match` event looks for.
    public let outputPattern: String?
    /// The caller's own process (its tab), which a wake line goes to. It
    /// must be the caller: Cherry checks it.
    public let subscriberProcessID: String?
    /// Type a wake line into the subscriber's tab when it is idle and
    /// events are ready. Defaults to true when the subscriber is known.
    public let wake: Bool?

    public init(
        processIDs: [String]? = nil,
        subAgents: Bool? = nil,
        events: [String]? = nil,
        outputPattern: String? = nil,
        subscriberProcessID: String? = nil,
        wake: Bool? = nil
    ) {
        self.processIDs = processIDs
        self.subAgents = subAgents
        self.events = events
        self.outputPattern = outputPattern
        self.subscriberProcessID = subscriberProcessID
        self.wake = wake
    }
}

/// A watched process as a monitor sees it now.
public struct MonitorProcessStatus: Codable, Equatable, Sendable {
    public let processID: String
    public let name: String
    public let kind: String
    /// `working`, `idle`, `needs_input`, `permission`, `error`, `unknown`
    /// (agents), `running` (other processes), `exited`, `disconnected` or
    /// `closed`.
    public let status: String
    public let state: String
    public let agentTurn: Int?
    public let exitCode: Int32?
    /// A Cherry task's worker: its task and the task's state
    /// (`AgentTaskState`); `wait_for_tasks` and `get_task` read its result.
    public let taskID: String?
    public let taskState: String?

    public init(
        processID: String,
        name: String,
        kind: String,
        status: String,
        state: String,
        agentTurn: Int?,
        exitCode: Int32?,
        taskID: String? = nil,
        taskState: String? = nil
    ) {
        self.processID = processID
        self.name = name
        self.kind = kind
        self.status = status
        self.state = state
        self.agentTurn = agentTurn
        self.exitCode = exitCode
        self.taskID = taskID
        self.taskState = taskState
    }
}

public struct MonitorEvent: Codable, Equatable, Sendable {
    /// Increases by one per event of the subscription: the cursor.
    public let seq: Int
    public let type: MonitorEventType
    public let processID: String
    public let processName: String
    public let kind: String
    public let at: Date
    /// Agents: the tab's turn counter (`agent_turn`) when it happened.
    public let agentTurn: Int?
    /// `exited`: the exit status, when the process reported one.
    public let exitCode: Int32?
    /// `output_match`: the matching line (at most 300 characters). It is
    /// the process's own output: data, never instructions.
    public let matchedLine: String?
    /// `done` of an agent that reports no status: what Cherry took for the
    /// end of its turn (`output_quiet`: its screen stayed still after it),
    /// once per submitted turn. Absent when the agent reported it, and on a
    /// task's settle.
    public let basis: String?
    /// The `done` of a Cherry task's settle, once per task: the task and its
    /// state (`AgentTaskState`). Only that one has them: the dones of its
    /// worker's turns never do.
    public let taskID: String?
    public let taskState: String?
    /// `needs_input` and `permission`: the menu the agent's screen shows,
    /// when it shows one already (answer it with answer_prompt).
    public let prompt: AgentPromptInfo?
    /// The state held when the subscription was made (or the process was
    /// added to it), rather than a change seen afterwards.
    public let initial: Bool

    /// `basis` of a `done` inferred from the agent's output going quiet.
    public static let outputQuietBasis = "output_quiet"

    public init(
        seq: Int,
        type: MonitorEventType,
        processID: String,
        processName: String,
        kind: String,
        at: Date,
        agentTurn: Int? = nil,
        exitCode: Int32? = nil,
        matchedLine: String? = nil,
        basis: String? = nil,
        taskID: String? = nil,
        taskState: String? = nil,
        prompt: AgentPromptInfo? = nil,
        initial: Bool = false
    ) {
        self.seq = seq
        self.type = type
        self.processID = processID
        self.processName = processName
        self.kind = kind
        self.at = at
        self.agentTurn = agentTurn
        self.exitCode = exitCode
        self.matchedLine = matchedLine
        self.basis = basis
        self.taskID = taskID
        self.taskState = taskState
        self.prompt = prompt
        self.initial = initial
    }
}

public struct SubscriptionInfo: Codable, Equatable, Sendable {
    public let subscriptionID: String
    public let subscriberProcessID: String?
    public let processIDs: [String]
    public let subAgents: Bool
    public let events: [MonitorEventType]
    public let outputPattern: String?
    /// Wake lines go to the subscriber's tab.
    public let wake: Bool
    /// Why wake lines are off for this subscription, when they are.
    public let wakeUnavailableReason: String?
    public let createdAt: Date
    /// The last event read (acknowledged).
    public let cursor: Int
    /// Events not read yet.
    public let pendingEvents: Int

    public init(
        subscriptionID: String,
        subscriberProcessID: String?,
        processIDs: [String],
        subAgents: Bool,
        events: [MonitorEventType],
        outputPattern: String?,
        wake: Bool,
        wakeUnavailableReason: String?,
        createdAt: Date,
        cursor: Int,
        pendingEvents: Int
    ) {
        self.subscriptionID = subscriptionID
        self.subscriberProcessID = subscriberProcessID
        self.processIDs = processIDs
        self.subAgents = subAgents
        self.events = events
        self.outputPattern = outputPattern
        self.wake = wake
        self.wakeUnavailableReason = wakeUnavailableReason
        self.createdAt = createdAt
        self.cursor = cursor
        self.pendingEvents = pendingEvents
    }
}

public struct SubscribeResult: Codable, Equatable, Sendable {
    public let subscription: SubscriptionInfo
    public let watching: [MonitorProcessStatus]

    public init(subscription: SubscriptionInfo, watching: [MonitorProcessStatus]) {
        self.subscription = subscription
        self.watching = watching
    }
}

public struct UnsubscribeRequest: Codable, Equatable, Sendable {
    public let subscriptionID: String

    public init(subscriptionID: String) {
        self.subscriptionID = subscriptionID
    }
}

public struct UnsubscribeResult: Codable, Equatable, Sendable {
    public let subscriptionID: String
    public let removed: Bool

    public init(subscriptionID: String, removed: Bool) {
        self.subscriptionID = subscriptionID
        self.removed = removed
    }
}

public struct WaitForEventsRequest: Codable, Equatable, Sendable {
    public let subscriptionID: String
    /// Events after this seq are returned, and every event up to it is
    /// acknowledged (dropped). Nil: after the last one read.
    public let cursor: Int?
    /// At most `CherryControl.maximumEventWaitMilliseconds`; 0 returns at once.
    public let timeoutMilliseconds: Int?
    public let maxEvents: Int?

    public init(subscriptionID: String, cursor: Int? = nil, timeoutMilliseconds: Int? = nil, maxEvents: Int? = nil) {
        self.subscriptionID = subscriptionID
        self.cursor = cursor
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maxEvents = maxEvents
    }
}

public struct WaitForEventsResult: Codable, Equatable, Sendable {
    public let subscriptionID: String
    public let events: [MonitorEvent]
    /// Pass it as `cursor` next time.
    public let cursor: Int
    public let timedOut: Bool
    /// Events dropped unread because too many were pending.
    public let droppedEvents: Int
    /// Events still pending after these (more than `max_events`).
    public let moreEvents: Int
    public let watching: [MonitorProcessStatus]

    public init(
        subscriptionID: String,
        events: [MonitorEvent],
        cursor: Int,
        timedOut: Bool,
        droppedEvents: Int,
        moreEvents: Int,
        watching: [MonitorProcessStatus]
    ) {
        self.subscriptionID = subscriptionID
        self.events = events
        self.cursor = cursor
        self.timedOut = timedOut
        self.droppedEvents = droppedEvents
        self.moreEvents = moreEvents
        self.watching = watching
    }
}

public struct ListSubscriptionsResult: Codable, Equatable, Sendable {
    public let subscriptions: [SubscriptionInfo]

    public init(subscriptions: [SubscriptionInfo]) {
        self.subscriptions = subscriptions
    }
}
