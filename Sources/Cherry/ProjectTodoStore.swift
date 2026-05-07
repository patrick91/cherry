import CherryControl
import CryptoKit
import Foundation

@MainActor
final class ProjectTodoStore: ObservableObject {
    @Published private(set) var todos: [ProjectTodo] = []

    let projectRoot: String
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        projectRoot: String,
        storageDirectory: URL = ProjectTodoStore.defaultStorageDirectory()
    ) {
        self.projectRoot = projectRoot
        fileURL = storageDirectory
            .appendingPathComponent(Self.projectStorageName(projectRoot: projectRoot), isDirectory: false)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    static func defaultStorageDirectory() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cherry", isDirectory: true)
            .appendingPathComponent("Todos", isDirectory: true)
    }

    static func projectStorageName(projectRoot: String) -> String {
        let digest = SHA256.hash(data: Data(projectRoot.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    func create(title: String, markdown: String, status: TodoStatus = .backlog) throws -> ProjectTodo {
        let now = Date()
        let todo = ProjectTodo(
            id: UUID(),
            projectRoot: projectRoot,
            title: normalizedTitle(title),
            markdown: markdown,
            status: status,
            position: nextPosition(in: status),
            createdAt: now,
            updatedAt: now
        )
        todos.append(todo)
        sortTodos()
        try save()
        return todo
    }

    func update(id: UUID, title: String?, markdown: String?, status: TodoStatus?) throws -> ProjectTodo {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(id.uuidString).")
        }

        var todo = todos[index]
        let oldStatus = todo.status
        if let title {
            todo.title = normalizedTitle(title)
        }
        if let markdown {
            todo.markdown = markdown
        }
        if let status, status != todo.status {
            todo.status = status
            todo.position = nextPosition(in: status)
        }
        todo.updatedAt = Date()
        todos[index] = todo
        if oldStatus != todo.status {
            normalizePositions(in: oldStatus)
            normalizePositions(in: todo.status)
        }
        sortTodos()
        try save()
        return todo
    }

    func move(id: UUID, status requestedStatus: TodoStatus?, afterTodoID: UUID?) throws -> ProjectTodo {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(id.uuidString).")
        }

        let originalStatus = todos[index].status
        let targetStatus = requestedStatus ?? originalStatus
        if let afterTodoID, afterTodoID == id {
            throw CherryControlError(code: "invalid_todo_move", message: "A todo cannot be moved after itself.")
        }
        if let afterTodoID {
            guard let after = todos.first(where: { $0.id == afterTodoID }) else {
                throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(afterTodoID.uuidString).")
            }
            guard after.status == targetStatus else {
                throw CherryControlError(code: "invalid_todo_move", message: "afterTodoID must refer to a todo in the target status.")
            }
        }

        var todo = todos.remove(at: index)
        todo.status = targetStatus
        todo.updatedAt = Date()

        var targetTodos = todos
            .filter { $0.status == targetStatus }
            .sorted(by: Self.todoSort)
        let insertIndex: Int
        if let afterTodoID, let afterIndex = targetTodos.firstIndex(where: { $0.id == afterTodoID }) {
            insertIndex = afterIndex + 1
        } else if let requestedStatus, requestedStatus != originalStatus {
            insertIndex = targetTodos.count
        } else {
            insertIndex = 0
        }
        targetTodos.insert(todo, at: min(max(insertIndex, 0), targetTodos.count))

        let orderedIDs = Dictionary(uniqueKeysWithValues: targetTodos.enumerated().map { offset, todo in
            (todo.id, offset)
        })
        for todoIndex in todos.indices where todos[todoIndex].status == targetStatus {
            if let offset = orderedIDs[todos[todoIndex].id] {
                todos[todoIndex].position = offset
            }
        }
        todo.position = orderedIDs[id] ?? insertIndex
        todos.append(todo)
        normalizePositions(in: originalStatus)
        normalizePositions(in: targetStatus)
        sortTodos()
        try save()
        return try self.todo(id: id)
    }

    func addComment(
        id: UUID,
        markdown: String,
        authorLabel: String,
        authorTerminalID: String?,
        authorAgentName: String?
    ) throws -> ProjectTodo {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(id.uuidString).")
        }
        let now = Date()
        var todo = todos[index]
        todo.comments.append(.init(
            id: UUID(),
            markdown: markdown,
            authorLabel: normalizedAuthor(authorLabel),
            authorTerminalID: authorTerminalID,
            authorAgentName: authorAgentName,
            createdAt: now
        ))
        todo.updatedAt = now
        todos[index] = todo
        sortTodos()
        try save()
        return todo
    }

    func delete(id: UUID) throws {
        let originalCount = todos.count
        todos.removeAll { $0.id == id }
        guard todos.count != originalCount else {
            throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(id.uuidString).")
        }
        for status in TodoStatus.allCases {
            normalizePositions(in: status)
        }
        sortTodos()
        try save()
    }

    func todo(id: UUID) throws -> ProjectTodo {
        guard let todo = todos.first(where: { $0.id == id }) else {
            throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(id.uuidString).")
        }
        return todo
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([ProjectTodo].self, from: data)
        else {
            todos = []
            return
        }
        todos = decoded.filter { $0.projectRoot == projectRoot }
        for status in TodoStatus.allCases {
            normalizePositions(in: status)
        }
        sortTodos()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(todos)
        try data.write(to: fileURL, options: .atomic)
    }

    private func nextPosition(in status: TodoStatus) -> Int {
        (todos.filter { $0.status == status }.map(\.position).max() ?? -1) + 1
    }

    private func normalizePositions(in status: TodoStatus) {
        let ordered = todos
            .filter { $0.status == status }
            .sorted(by: Self.todoSort)
        for (position, todo) in ordered.enumerated() {
            guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { continue }
            todos[index].position = position
        }
    }

    private func sortTodos() {
        todos.sort(by: Self.todoSort)
    }

    private static func todoSort(lhs: ProjectTodo, rhs: ProjectTodo) -> Bool {
        let lhsStatus = TodoStatus.allCases.firstIndex(of: lhs.status) ?? 0
        let rhsStatus = TodoStatus.allCases.firstIndex(of: rhs.status) ?? 0
        if lhsStatus != rhsStatus {
            return lhsStatus < rhsStatus
        }
        if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedAuthor(_ author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "MCP" : trimmed
    }
}
