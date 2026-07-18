import Foundation

public enum CherryControl {
    public static let socketEnvironmentKey = "CHERRY_CONTROL_SOCKET"
    public static let socketNamespaceEnvironmentKey = "CHERRY_CONTROL_NAMESPACE"
    public static let projectRootEnvironmentKey = "CHERRY_PROJECT_ROOT"
    public static let processIDEnvironmentKey = "CHERRY_PROCESS_ID"
    public static let agentIDEnvironmentKey = "CHERRY_AGENT_ID"
    public static let selectedAgentParentID = "selected"
    public static let topLevelAgentParentID = "top_level"

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

        let uid = getuid()
        return URL(fileURLWithPath: "/tmp/cherry-\(uid)", isDirectory: true)
            .appendingPathComponent(socketNamespace(environment: environment, executableURL: executableURL), isDirectory: true)
            .appendingPathComponent("control.sock", isDirectory: false)
    }

    public static var socketDirectoryURL: URL {
        socketURL.deletingLastPathComponent()
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
    case startAllCommands(ProcessBulkCommandRequest)
    case stopAllCommands(ProcessBulkCommandRequest)
    case restartAllCommands(ProcessBulkCommandRequest)
    case listTerminals
    case listAgents
    case listNotes
    case listTodos
    case createTerminal(CreateTerminalRequest)
    case runAgent(RunAgentRequest)
    case createNote(CreateNoteRequest)
    case getNote(NoteIDRequest)
    case updateNote(UpdateNoteRequest)
    case appendNote(AppendNoteRequest)
    case renameNote(RenameNoteRequest)
    case searchNotes(SearchNotesRequest)
    case deleteNote(NoteIDRequest)
    case selectNote(NoteIDRequest)
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
    case renameTerminal(RenameTerminalRequest)
    case selectTerminal(TerminalIDRequest)
    case sendInput(SendInputRequest)
    case getTerminalOutput(GetTerminalOutputRequest)
    case getTerminalRawOutput(GetTerminalRawOutputRequest)
    case searchOutput(SearchOutputRequest)
    case clearOutput(TerminalIDRequest)
    case restartTerminal(TerminalIDRequest)
    case closeTerminal(CloseTerminalRequest)
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
    public let title: String?
    public let workingDirectory: String?
    public let text: String?
    public let rawBase64: String?
    public let submit: Bool?
    public let parentAgentID: String?
    public let waitMilliseconds: Int?
    public let lineLimit: Int?

    public init(
        kind: String,
        name: String? = nil,
        model: String? = nil,
        title: String? = nil,
        workingDirectory: String? = nil,
        text: String? = nil,
        rawBase64: String? = nil,
        submit: Bool? = nil,
        parentAgentID: String? = nil,
        waitMilliseconds: Int? = nil,
        lineLimit: Int? = nil
    ) {
        self.kind = kind
        self.name = name
        self.model = model
        self.title = title
        self.workingDirectory = workingDirectory
        self.text = text
        self.rawBase64 = rawBase64
        self.submit = submit
        self.parentAgentID = parentAgentID
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
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

public struct ProcessBulkCommandRequest: Codable, Equatable, Sendable {
    public let waitMilliseconds: Int?
    public let lineLimit: Int?

    public init(waitMilliseconds: Int? = nil, lineLimit: Int? = nil) {
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
    }
}

public struct TerminalIDRequest: Codable, Equatable, Sendable {
    public let terminalID: String

    public init(terminalID: String) {
        self.terminalID = terminalID
    }
}

public struct NoteIDRequest: Codable, Equatable, Sendable {
    public let noteID: String

    public init(noteID: String) {
        self.noteID = noteID
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

public struct CreateNoteRequest: Codable, Equatable, Sendable {
    public let title: String
    public let markdown: String
    public let open: Bool?

    public init(title: String, markdown: String, open: Bool? = nil) {
        self.title = title
        self.markdown = markdown
        self.open = open
    }
}

public struct UpdateNoteRequest: Codable, Equatable, Sendable {
    public let noteID: String
    public let title: String?
    public let markdown: String?
    public let open: Bool?

    public init(noteID: String, title: String? = nil, markdown: String? = nil, open: Bool? = nil) {
        self.noteID = noteID
        self.title = title
        self.markdown = markdown
        self.open = open
    }
}

public struct AppendNoteRequest: Codable, Equatable, Sendable {
    public let noteID: String
    public let markdown: String

    public init(noteID: String, markdown: String) {
        self.noteID = noteID
        self.markdown = markdown
    }
}

public struct RenameNoteRequest: Codable, Equatable, Sendable {
    public let noteID: String
    public let title: String

    public init(noteID: String, title: String) {
        self.noteID = noteID
        self.title = title
    }
}

public struct SearchNotesRequest: Codable, Equatable, Sendable {
    public let query: String
    public let caseSensitive: Bool?
    public let maxMatches: Int?

    public init(query: String, caseSensitive: Bool? = nil, maxMatches: Int? = nil) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.maxMatches = maxMatches
    }
}

public struct CreateTodoRequest: Codable, Equatable, Sendable {
    public let title: String
    public let markdown: String
    public let status: TodoStatus?
    public let tags: [String]?
    public let open: Bool?

    public init(title: String, markdown: String = "", status: TodoStatus? = nil, tags: [String]? = nil, open: Bool? = nil) {
        self.title = title
        self.markdown = markdown
        self.status = status
        self.tags = tags
        self.open = open
    }
}

public struct UpdateTodoRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let title: String?
    public let markdown: String?
    public let status: TodoStatus?
    public let tags: [String]?
    public let open: Bool?

    public init(
        todoID: String,
        title: String? = nil,
        markdown: String? = nil,
        status: TodoStatus? = nil,
        tags: [String]? = nil,
        open: Bool? = nil
    ) {
        self.todoID = todoID
        self.title = title
        self.markdown = markdown
        self.status = status
        self.tags = tags
        self.open = open
    }
}

public struct MoveTodoRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let status: TodoStatus?
    public let afterTodoID: String?
    public let open: Bool?

    public init(todoID: String, status: TodoStatus? = nil, afterTodoID: String? = nil, open: Bool? = nil) {
        self.todoID = todoID
        self.status = status
        self.afterTodoID = afterTodoID
        self.open = open
    }
}

public struct AddTodoCommentRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let markdown: String
    public let author: String?
    public let terminalID: String?
    public let open: Bool?

    public init(
        todoID: String,
        markdown: String,
        author: String? = nil,
        terminalID: String? = nil,
        open: Bool? = nil
    ) {
        self.todoID = todoID
        self.markdown = markdown
        self.author = author
        self.terminalID = terminalID
        self.open = open
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

public struct CreateTerminalRequest: Codable, Equatable, Sendable {
    public let title: String?
    public let workingDirectory: String?
    public let command: String?

    public init(title: String?, workingDirectory: String?, command: String?) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.command = command
    }
}

public struct RunAgentRequest: Codable, Equatable, Sendable {
    public let agentName: String
    public let model: String?
    public let title: String?
    public let text: String?
    public let rawBase64: String?
    public let waitMilliseconds: Int?
    public let lineLimit: Int?
    public let submit: Bool?
    public let parentAgentID: String?
    public let select: Bool?

    public init(
        agentName: String,
        model: String? = nil,
        title: String? = nil,
        text: String? = nil,
        rawBase64: String? = nil,
        waitMilliseconds: Int? = nil,
        lineLimit: Int? = nil,
        submit: Bool? = nil,
        parentAgentID: String? = nil,
        select: Bool? = nil
    ) {
        self.agentName = agentName
        self.model = model
        self.title = title
        self.text = text
        self.rawBase64 = rawBase64
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
        self.submit = submit
        self.parentAgentID = parentAgentID
        self.select = select
    }
}

public struct CloseTerminalRequest: Codable, Equatable, Sendable {
    public let terminalID: String
    public let agentClosePolicy: AgentClosePolicy?

    public init(terminalID: String, agentClosePolicy: AgentClosePolicy? = nil) {
        self.terminalID = terminalID
        self.agentClosePolicy = agentClosePolicy
    }
}

public struct RenameTerminalRequest: Codable, Equatable, Sendable {
    public let terminalID: String
    public let title: String?

    public init(terminalID: String, title: String?) {
        self.terminalID = terminalID
        self.title = title
    }
}

public struct SendInputRequest: Codable, Equatable, Sendable {
    public let terminalID: String
    public let text: String?
    public let rawBase64: String?
    public let waitMilliseconds: Int?
    public let lineLimit: Int?

    public init(
        terminalID: String,
        text: String?,
        rawBase64: String?,
        waitMilliseconds: Int?,
        lineLimit: Int?
    ) {
        self.terminalID = terminalID
        self.text = text
        self.rawBase64 = rawBase64
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
    }
}

public struct GetTerminalOutputRequest: Codable, Equatable, Sendable {
    public let terminalID: String
    public let startLine: Int?
    public let lineLimit: Int?

    public init(terminalID: String, startLine: Int?, lineLimit: Int?) {
        self.terminalID = terminalID
        self.startLine = startLine
        self.lineLimit = lineLimit
    }
}

public struct GetTerminalRawOutputRequest: Codable, Equatable, Sendable {
    public let terminalID: String
    public let maxBytes: Int?

    public init(terminalID: String, maxBytes: Int?) {
        self.terminalID = terminalID
        self.maxBytes = maxBytes
    }
}

public struct SearchOutputRequest: Codable, Equatable, Sendable {
    public let terminalID: String
    public let query: String
    public let caseSensitive: Bool?
    public let maxMatches: Int?

    public init(terminalID: String, query: String, caseSensitive: Bool?, maxMatches: Int?) {
        self.terminalID = terminalID
        self.query = query
        self.caseSensitive = caseSensitive
        self.maxMatches = maxMatches
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
    case startAllCommands(ListProcessesResult)
    case stopAllCommands(ListProcessesResult)
    case restartAllCommands(ListProcessesResult)
    case listTerminals(ListTerminalsResult)
    case listAgents(ListAgentsResult)
    case listNotes(ListNotesResult)
    case listTodos(ListTodosResult)
    case createTerminal(TerminalSummaryResult)
    case runAgent(RunAgentResult)
    case createNote(NoteDetailResult)
    case getNote(NoteDetailResult)
    case updateNote(NoteDetailResult)
    case appendNote(NoteDetailResult)
    case renameNote(NoteDetailResult)
    case searchNotes(SearchNotesResult)
    case deleteNote(DeleteNoteResult)
    case selectNote(SelectNoteResult)
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
    case renameTerminal(TerminalSummaryResult)
    case selectTerminal(SelectTerminalResult)
    case sendInput(SendInputResult)
    case getTerminalOutput(TerminalOutputResult)
    case getTerminalRawOutput(TerminalRawOutputResult)
    case searchOutput(SearchOutputResult)
    case clearOutput(ClearOutputResult)
    case restartTerminal(TerminalSummaryResult)
    case closeTerminal(CloseTerminalResult)
}

public struct CherryControlError: Codable, Equatable, Error, Sendable {
    public let code: String
    public let message: String
    public let serviceCandidates: [ServiceRecord]?

    public init(code: String, message: String, serviceCandidates: [ServiceRecord]? = nil) {
        self.code = code
        self.message = message
        self.serviceCandidates = serviceCandidates
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
    public let summary: String?
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
        summary: String? = nil,
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
        self.summary = summary
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
        features: ProjectFeatureAvailability = .init(notesEnabled: false, todosEnabled: false)
    ) {
        self.root = root
        self.name = name
        self.active = active
        self.open = open
        self.features = features
    }
}

public struct ProjectFeatureAvailability: Codable, Equatable, Sendable {
    public let notesEnabled: Bool
    public let todosEnabled: Bool

    public init(notesEnabled: Bool, todosEnabled: Bool) {
        self.notesEnabled = notesEnabled
        self.todosEnabled = todosEnabled
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
    public let noteCount: Int?
    public let todoCount: Int?
    public let features: ProjectFeatureAvailability
    public let selectedProcessID: String?
    public let selectedProcessName: String?
    public let health: String

    public init(
        projectRoot: String?,
        processCounts: ProcessCounts,
        noteCount: Int?,
        todoCount: Int?,
        features: ProjectFeatureAvailability = .init(notesEnabled: false, todosEnabled: false),
        selectedProcessID: String?,
        selectedProcessName: String?,
        health: String
    ) {
        self.projectRoot = projectRoot
        self.processCounts = processCounts
        self.noteCount = noteCount
        self.todoCount = todoCount
        self.features = features
        self.selectedProcessID = selectedProcessID
        self.selectedProcessName = selectedProcessName
        self.health = health
    }
}

public struct TerminalPerformanceCounters: Codable, Equatable, Sendable {
    public let ptyChunks: Int
    public let ptyBytes: Int
    public let ghosttyFeedChunks: Int
    public let ghosttyFeedBytes: Int
    public let processorBacklogDropCount: Int
    public let processorBacklogDroppedBytes: Int
    public let backgroundOutputThrottleCount: Int
    public let processorChanges: Int
    public let representableUpdates: Int
    public let containerConfigures: Int
    public let bridgeAttaches: Int
    public let reusedBridgeAttaches: Int
    public let fitToSizeCalls: Int
    public let settingsApplies: Int
    public let settingsReconfigures: Int
    public let renderTicks: Int

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
    public let summary: String?
    public let selected: Bool
    public let agentName: String?
    public let commandName: String?
    public let parentAgentID: String?
    public let childAgentCount: Int?
    public let agentActivityState: String?
    public let usesAlternateScreen: Bool?
    public let lastContentChangeAt: Date?
    public let contentVersion: Int?

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
        summary: String?,
        selected: Bool,
        agentName: String?,
        commandName: String?,
        parentAgentID: String? = nil,
        childAgentCount: Int? = nil,
        agentActivityState: String? = nil,
        usesAlternateScreen: Bool? = nil,
        lastContentChangeAt: Date? = nil,
        contentVersion: Int? = nil
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
        self.summary = summary
        self.selected = selected
        self.agentName = agentName
        self.commandName = commandName
        self.parentAgentID = parentAgentID
        self.childAgentCount = childAgentCount
        self.agentActivityState = agentActivityState
        self.usesAlternateScreen = usesAlternateScreen
        self.lastContentChangeAt = lastContentChangeAt
        self.contentVersion = contentVersion
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
        agentName: String?
    ) {
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

    public init(process: ProcessSummary) {
        self.process = process
    }
}

public enum ProcessIdleWaitReason: String, Codable, Equatable, Sendable {
    case idle
    case exited
    case timedOut = "timed_out"
    case permission
    case agentError = "agent_error"
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

    public init(
        process: ProcessSummary,
        reason: ProcessIdleWaitReason,
        observedNewOutput: Bool,
        sinceOutputVersion: Int,
        outputVersion: Int,
        lastOutputAt: Date?,
        agentActivityState: String? = nil,
        output: TerminalOutputResult
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
    }
}

public struct SpawnProcessResult: Codable, Equatable, Sendable {
    public let process: ProcessSummary
    public let sentBytes: Int
    public let output: TerminalOutputResult?

    public init(process: ProcessSummary, sentBytes: Int, output: TerminalOutputResult?) {
        self.process = process
        self.sentBytes = sentBytes
        self.output = output
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

public struct ProjectNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectRoot: String
    public var title: String
    public var markdown: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        projectRoot: String,
        title: String,
        markdown: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.projectRoot = projectRoot
        self.title = title
        self.markdown = markdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NoteInfo: Codable, Equatable, Sendable {
    public let id: String
    public let link: String?
    public let projectRoot: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, link: String? = nil, projectRoot: String, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.link = link
        self.projectRoot = projectRoot
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ListNotesResult: Codable, Equatable, Sendable {
    public let activeProjectRoot: String
    public let notes: [NoteInfo]
    public let selectedNoteID: String?

    public init(activeProjectRoot: String, notes: [NoteInfo], selectedNoteID: String?) {
        self.activeProjectRoot = activeProjectRoot
        self.notes = notes
        self.selectedNoteID = selectedNoteID
    }
}

public struct NoteDetailResult: Codable, Equatable, Sendable {
    public let note: ProjectNote
    public let link: String?
    public let selected: Bool

    public init(note: ProjectNote, link: String? = nil, selected: Bool) {
        self.note = note
        self.link = link
        self.selected = selected
    }
}

public struct NoteSearchMatch: Codable, Equatable, Sendable {
    public let noteID: String
    public let title: String
    public let lineNumber: Int?
    public let text: String

    public init(noteID: String, title: String, lineNumber: Int?, text: String) {
        self.noteID = noteID
        self.title = title
        self.lineNumber = lineNumber
        self.text = text
    }
}

public struct SearchNotesResult: Codable, Equatable, Sendable {
    public let activeProjectRoot: String
    public let matches: [NoteSearchMatch]

    public init(activeProjectRoot: String, matches: [NoteSearchMatch]) {
        self.activeProjectRoot = activeProjectRoot
        self.matches = matches
    }
}

public struct SelectNoteResult: Codable, Equatable, Sendable {
    public let noteID: String
    public let selected: Bool

    public init(noteID: String, selected: Bool) {
        self.noteID = noteID
        self.selected = selected
    }
}

public struct DeleteNoteResult: Codable, Equatable, Sendable {
    public let noteID: String
    public let deleted: Bool

    public init(noteID: String, deleted: Bool) {
        self.noteID = noteID
        self.deleted = deleted
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

public struct TerminalSummaryResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let link: String?
    public let title: String
    public let state: String
    public let kind: String?
    public let agentName: String?
    public let summary: String?
    public let parentAgentID: String?
    public let childAgentCount: Int?

    public init(
        terminalID: String,
        link: String? = nil,
        title: String,
        state: String,
        kind: String? = nil,
        agentName: String? = nil,
        summary: String? = nil,
        parentAgentID: String? = nil,
        childAgentCount: Int? = nil
    ) {
        self.terminalID = terminalID
        self.link = link
        self.title = title
        self.state = state
        self.kind = kind
        self.agentName = agentName
        self.summary = summary
        self.parentAgentID = parentAgentID
        self.childAgentCount = childAgentCount
    }
}

public struct RunAgentResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let link: String?
    public let title: String
    public let state: String
    public let kind: String?
    public let agentName: String?
    public let summary: String?
    public let parentAgentID: String?
    public let childAgentCount: Int?
    public let projectRoot: String
    public let sentBytes: Int
    public let output: TerminalOutputResult?

    public init(
        terminalID: String,
        link: String? = nil,
        title: String,
        state: String,
        kind: String?,
        agentName: String?,
        summary: String?,
        parentAgentID: String? = nil,
        childAgentCount: Int? = nil,
        projectRoot: String,
        sentBytes: Int,
        output: TerminalOutputResult?
    ) {
        self.terminalID = terminalID
        self.link = link
        self.title = title
        self.state = state
        self.kind = kind
        self.agentName = agentName
        self.summary = summary
        self.parentAgentID = parentAgentID
        self.childAgentCount = childAgentCount
        self.projectRoot = projectRoot
        self.sentBytes = sentBytes
        self.output = output
    }
}

public struct SelectTerminalResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let selected: Bool

    public init(terminalID: String, selected: Bool) {
        self.terminalID = terminalID
        self.selected = selected
    }
}

public struct SendInputResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let sentBytes: Int
    public let output: TerminalOutputResult?

    public init(terminalID: String, sentBytes: Int, output: TerminalOutputResult?) {
        self.terminalID = terminalID
        self.sentBytes = sentBytes
        self.output = output
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
    public let note: ProjectNote?
    public let noteLink: String?
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
        note: ProjectNote? = nil,
        noteLink: String? = nil,
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
        self.note = note
        self.noteLink = noteLink
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
    public let cleared: Bool

    public init(terminalID: String, cleared: Bool) {
        self.terminalID = terminalID
        self.cleared = cleared
    }
}

public struct CloseTerminalResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let closed: Bool

    public init(terminalID: String, closed: Bool) {
        self.terminalID = terminalID
        self.closed = closed
    }
}
