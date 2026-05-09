import CherryControl
import CryptoKit
import Foundation

@MainActor
final class ProjectTodoStore: ObservableObject {
    @Published private(set) var todos: [ProjectTodo] = []
    @Published private(set) var tagCatalog: [TodoTag] = []

    let projectRoot: String
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let storageVersion = 1
    private static let tagColorPalette = [
        "#D73A49",
        "#E36209",
        "#B08800",
        "#22863A",
        "#0086B3",
        "#0366D6",
        "#5A32A3",
        "#B31D8C",
        "#6F42C1",
        "#1B7F79",
        "#CB2431",
        "#735C0F"
    ]

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

    func create(title: String, markdown: String, status: TodoStatus = .backlog, tags: [String] = []) throws -> ProjectTodo {
        let now = Date()
        let todo = ProjectTodo(
            id: UUID(),
            projectRoot: projectRoot,
            title: normalizedTitle(title),
            markdown: markdown,
            status: status,
            position: nextPosition(in: status),
            createdAt: now,
            updatedAt: now,
            tags: resolvedTags(for: tags)
        )
        todos.append(todo)
        sortTodos()
        try save()
        return todo
    }

    func update(id: UUID, title: String?, markdown: String?, status: TodoStatus?, tags: [String]? = nil) throws -> ProjectTodo {
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
        if let tags {
            todo.tags = resolvedTags(for: tags)
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

    func move(id: UUID, to targetIndex: Int, within status: TodoStatus) throws -> ProjectTodo {
        let statusTodos = todos
            .filter { $0.status == status }
            .sorted(by: Self.todoSort)
        guard let currentIndex = statusTodos.firstIndex(where: { $0.id == id }) else {
            throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(id.uuidString) in \(status.rawValue).")
        }

        let clampedIndex = min(max(targetIndex, 0), statusTodos.count - 1)
        guard currentIndex != clampedIndex else {
            return try todo(id: id)
        }

        let afterTodoID: UUID?
        if clampedIndex == 0 {
            afterTodoID = nil
        } else if currentIndex < clampedIndex {
            afterTodoID = statusTodos[clampedIndex].id
        } else {
            afterTodoID = statusTodos[clampedIndex - 1].id
        }

        return try move(id: id, status: status, afterTodoID: afterTodoID)
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

    func updateComment(todoID: UUID, commentID: UUID, markdown: String) throws -> ProjectTodo {
        guard let todoIndex = todos.firstIndex(where: { $0.id == todoID }) else {
            throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(todoID.uuidString).")
        }
        guard let commentIndex = todos[todoIndex].comments.firstIndex(where: { $0.id == commentID }) else {
            throw CherryControlError(code: "todo_comment_not_found", message: "No Cherry todo comment exists with id \(commentID.uuidString).")
        }

        todos[todoIndex].comments[commentIndex].markdown = markdown
        todos[todoIndex].updatedAt = Date()
        sortTodos()
        try save()
        return try todo(id: todoID)
    }

    func deleteComment(todoID: UUID, commentID: UUID) throws -> ProjectTodo {
        guard let todoIndex = todos.firstIndex(where: { $0.id == todoID }) else {
            throw CherryControlError(code: "todo_not_found", message: "No Cherry todo exists with id \(todoID.uuidString).")
        }
        let originalCount = todos[todoIndex].comments.count
        todos[todoIndex].comments.removeAll { $0.id == commentID }
        guard todos[todoIndex].comments.count != originalCount else {
            throw CherryControlError(code: "todo_comment_not_found", message: "No Cherry todo comment exists with id \(commentID.uuidString).")
        }

        todos[todoIndex].updatedAt = Date()
        sortTodos()
        try save()
        return try todo(id: todoID)
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
        guard let data = try? Data(contentsOf: fileURL) else {
            todos = []
            tagCatalog = []
            return
        }

        if let decoded = try? decoder.decode(ProjectTodoFile.self, from: data) {
            tagCatalog = decoded.tagCatalog
            todos = decoded.todos.filter { $0.projectRoot == projectRoot }
        } else if let decoded = try? decoder.decode([ProjectTodo].self, from: data) {
            tagCatalog = []
            todos = decoded.filter { $0.projectRoot == projectRoot }
        } else {
            tagCatalog = []
            todos = []
            return
        }

        reconcileTagsAfterLoad()
        for status in TodoStatus.allCases {
            normalizePositions(in: status)
        }
        sortTodos()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(ProjectTodoFile(
            version: Self.storageVersion,
            projectRoot: projectRoot,
            tagCatalog: tagCatalog,
            todos: todos
        ))
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

    private func resolvedTags(for names: [String]) -> [TodoTag] {
        var resolved: [TodoTag] = []
        var seen = Set<String>()

        for rawName in names {
            guard let name = normalizedTagName(rawName) else { continue }
            let id = tagID(forNormalizedName: name)
            guard seen.insert(id).inserted else { continue }

            if let existing = tagCatalog.first(where: { $0.id == id }) {
                resolved.append(existing)
            } else {
                let tag = TodoTag(id: id, name: name, colorHex: Self.randomTagColor())
                tagCatalog.append(tag)
                sortTagCatalog()
                resolved.append(tag)
            }
        }

        return resolved
    }

    private func reconcileTagsAfterLoad() {
        var catalogByID: [String: TodoTag] = [:]
        for tag in tagCatalog {
            guard let name = normalizedTagName(tag.name) else { continue }
            let id = tagID(forNormalizedName: name)
            if catalogByID[id] == nil {
                catalogByID[id] = TodoTag(
                    id: id,
                    name: name,
                    colorHex: Self.normalizedColorHex(tag.colorHex) ?? Self.randomTagColor()
                )
            }
        }

        for todoIndex in todos.indices {
            var resolved: [TodoTag] = []
            var seen = Set<String>()
            for tag in todos[todoIndex].tags {
                guard let name = normalizedTagName(tag.name) else { continue }
                let id = tagID(forNormalizedName: name)
                guard seen.insert(id).inserted else { continue }

                if let catalogTag = catalogByID[id] {
                    resolved.append(catalogTag)
                } else {
                    let catalogTag = TodoTag(
                        id: id,
                        name: name,
                        colorHex: Self.normalizedColorHex(tag.colorHex) ?? Self.randomTagColor()
                    )
                    catalogByID[id] = catalogTag
                    resolved.append(catalogTag)
                }
            }
            todos[todoIndex].tags = resolved
        }

        tagCatalog = catalogByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func sortTagCatalog() {
        tagCatalog.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func normalizedTagName(_ name: String) -> String? {
        let parts = name.split(whereSeparator: \.isWhitespace)
        let normalized = parts.joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private func tagID(forNormalizedName name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func randomTagColor() -> String {
        tagColorPalette.randomElement() ?? "#0366D6"
    }

    private static func normalizedColorHex(_ colorHex: String) -> String? {
        let trimmed = colorHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#\(hex)"
    }
}

private struct ProjectTodoFile: Codable {
    var version: Int
    var projectRoot: String
    var tagCatalog: [TodoTag]
    var todos: [ProjectTodo]
}
