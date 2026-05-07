import Foundation

public enum CherryControl {
    public static let socketEnvironmentKey = "CHERRY_CONTROL_SOCKET"
    public static let socketNamespaceEnvironmentKey = "CHERRY_CONTROL_NAMESPACE"

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
    case listTerminals
    case listAgents
    case listNotes
    case listTodos
    case createTerminal(CreateTerminalRequest)
    case runAgent(RunAgentRequest)
    case createNote(CreateNoteRequest)
    case getNote(NoteIDRequest)
    case updateNote(UpdateNoteRequest)
    case deleteNote(NoteIDRequest)
    case selectNote(NoteIDRequest)
    case createTodo(CreateTodoRequest)
    case getTodo(TodoIDRequest)
    case updateTodo(UpdateTodoRequest)
    case moveTodo(MoveTodoRequest)
    case deleteTodo(TodoIDRequest)
    case selectTodo(TodoIDRequest)
    case addTodoComment(AddTodoCommentRequest)
    case renameTerminal(RenameTerminalRequest)
    case selectTerminal(TerminalIDRequest)
    case sendInput(SendInputRequest)
    case getTerminalOutput(GetTerminalOutputRequest)
    case getTerminalRawOutput(GetTerminalRawOutputRequest)
    case searchOutput(SearchOutputRequest)
    case clearOutput(TerminalIDRequest)
    case restartTerminal(TerminalIDRequest)
    case closeTerminal(TerminalIDRequest)
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

public struct CreateTodoRequest: Codable, Equatable, Sendable {
    public let title: String
    public let markdown: String
    public let status: TodoStatus?
    public let open: Bool?

    public init(title: String, markdown: String = "", status: TodoStatus? = nil, open: Bool? = nil) {
        self.title = title
        self.markdown = markdown
        self.status = status
        self.open = open
    }
}

public struct UpdateTodoRequest: Codable, Equatable, Sendable {
    public let todoID: String
    public let title: String?
    public let markdown: String?
    public let status: TodoStatus?
    public let open: Bool?

    public init(
        todoID: String,
        title: String? = nil,
        markdown: String? = nil,
        status: TodoStatus? = nil,
        open: Bool? = nil
    ) {
        self.todoID = todoID
        self.title = title
        self.markdown = markdown
        self.status = status
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
    public let title: String?
    public let text: String?
    public let rawBase64: String?
    public let waitMilliseconds: Int?
    public let lineLimit: Int?
    public let select: Bool?

    public init(
        agentName: String,
        title: String? = nil,
        text: String? = nil,
        rawBase64: String? = nil,
        waitMilliseconds: Int? = nil,
        lineLimit: Int? = nil,
        select: Bool? = nil
    ) {
        self.agentName = agentName
        self.title = title
        self.text = text
        self.rawBase64 = rawBase64
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
        self.select = select
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
    case listTerminals(ListTerminalsResult)
    case listAgents(ListAgentsResult)
    case listNotes(ListNotesResult)
    case listTodos(ListTodosResult)
    case createTerminal(TerminalSummaryResult)
    case runAgent(RunAgentResult)
    case createNote(NoteDetailResult)
    case getNote(NoteDetailResult)
    case updateNote(NoteDetailResult)
    case deleteNote(DeleteNoteResult)
    case selectNote(SelectNoteResult)
    case createTodo(TodoDetailResult)
    case getTodo(TodoDetailResult)
    case updateTodo(TodoDetailResult)
    case moveTodo(TodoDetailResult)
    case deleteTodo(DeleteTodoResult)
    case selectTodo(SelectTodoResult)
    case addTodoComment(TodoDetailResult)
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

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct TerminalInfo: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let selected: Bool
    public let workingDirectory: String
    public let lineCount: Int
    public let kind: String?
    public let agentName: String?
    public let summary: String?

    public init(
        id: String,
        title: String,
        state: String,
        selected: Bool,
        workingDirectory: String,
        lineCount: Int,
        kind: String? = nil,
        agentName: String? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.selected = selected
        self.workingDirectory = workingDirectory
        self.lineCount = lineCount
        self.kind = kind
        self.agentName = agentName
        self.summary = summary
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
    public let projectRoot: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, projectRoot: String, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
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
    public let selected: Bool

    public init(note: ProjectNote, selected: Bool) {
        self.note = note
        self.selected = selected
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
        self.comments = comments
    }
}

public struct TodoInfo: Codable, Equatable, Sendable {
    public let id: String
    public let projectRoot: String
    public let title: String
    public let status: TodoStatus
    public let position: Int
    public let commentCount: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        projectRoot: String,
        title: String,
        status: TodoStatus,
        position: Int,
        commentCount: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.projectRoot = projectRoot
        self.title = title
        self.status = status
        self.position = position
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
    public let selected: Bool

    public init(todo: ProjectTodo, selected: Bool) {
        self.todo = todo
        self.selected = selected
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
    public let title: String
    public let state: String
    public let kind: String?
    public let agentName: String?
    public let summary: String?

    public init(terminalID: String, title: String, state: String, kind: String? = nil, agentName: String? = nil, summary: String? = nil) {
        self.terminalID = terminalID
        self.title = title
        self.state = state
        self.kind = kind
        self.agentName = agentName
        self.summary = summary
    }
}

public struct RunAgentResult: Codable, Equatable, Sendable {
    public let terminalID: String
    public let title: String
    public let state: String
    public let kind: String?
    public let agentName: String?
    public let summary: String?
    public let projectRoot: String
    public let sentBytes: Int
    public let output: TerminalOutputResult?

    public init(
        terminalID: String,
        title: String,
        state: String,
        kind: String?,
        agentName: String?,
        summary: String?,
        projectRoot: String,
        sentBytes: Int,
        output: TerminalOutputResult?
    ) {
        self.terminalID = terminalID
        self.title = title
        self.state = state
        self.kind = kind
        self.agentName = agentName
        self.summary = summary
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
    public let lines: [String]

    public init(
        terminalID: String,
        startLine: Int,
        endLineExclusive: Int,
        totalLines: Int,
        lines: [String]
    ) {
        self.terminalID = terminalID
        self.startLine = startLine
        self.endLineExclusive = endLineExclusive
        self.totalLines = totalLines
        self.lines = lines
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
