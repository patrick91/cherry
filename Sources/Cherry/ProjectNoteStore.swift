import CherryControl
import CryptoKit
import Foundation

private final class ProjectNotePersistence: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "Cherry.ProjectNotePersistence", qos: .utility)

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func saveSynchronously(_ notes: [ProjectNote]) throws {
        try queue.sync {
            try Self.write(notes, to: fileURL)
        }
    }

    func saveInBackground(_ notes: [ProjectNote]) {
        let fileURL = fileURL
        queue.async {
            try? Self.write(notes, to: fileURL)
        }
    }

    func flush() {
        queue.sync {}
    }

    func loadSynchronously(projectRoot: String) -> [ProjectNote] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode([ProjectNote].self, from: data) else { return [] }
            return decoded
                .filter { $0.projectRoot == projectRoot }
                .sorted(by: projectNoteDisplayOrder)
        }
    }

    private static func write(_ notes: [ProjectNote], to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notes)
        try data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class ProjectNoteStore: ObservableObject {
    @Published private(set) var notes: [ProjectNote] = []
    @Published private(set) var isLoading = false

    let projectRoot: String
    private let persistence: ProjectNotePersistence
    private var backgroundLoadTask: Task<Void, Never>?

    init(
        projectRoot: String,
        storageDirectory: URL = ProjectNoteStore.defaultStorageDirectory(),
        loadsInBackground: Bool = false
    ) {
        self.projectRoot = projectRoot
        let fileURL = storageDirectory
            .appendingPathComponent(Self.projectStorageName(projectRoot: projectRoot), isDirectory: false)
        persistence = ProjectNotePersistence(fileURL: fileURL)
        if loadsInBackground {
            loadInBackground()
        } else {
            load()
        }
    }

    static func defaultStorageDirectory() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cherry", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    static func projectStorageName(projectRoot: String) -> String {
        let digest = SHA256.hash(data: Data(projectRoot.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    func create(title: String, markdown: String) throws -> ProjectNote {
        try requireLoaded()
        let now = Date()
        let note = ProjectNote(
            id: UUID(),
            projectRoot: projectRoot,
            title: normalizedTitle(title),
            markdown: markdown,
            createdAt: now,
            updatedAt: now
        )
        notes.append(note)
        sortNotes()
        try save()
        return note
    }

    func update(id: UUID, title: String?, markdown: String?) throws -> ProjectNote {
        try requireLoaded()
        let note = try mutate(id: id, title: title, markdown: markdown)
        try save()
        return note
    }

    /// Editor autosaves update observable state immediately but keep JSON
    /// encoding and atomic disk I/O off the main actor.
    func updateFromEditor(id: UUID, title: String?, markdown: String?) throws -> ProjectNote {
        try requireLoaded()
        let note = try mutate(id: id, title: title, markdown: markdown)
        persistence.saveInBackground(notes)
        return note
    }

    private func mutate(id: UUID, title: String?, markdown: String?) throws -> ProjectNote {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw CherryControlError(code: "note_not_found", message: "No Cherry note exists with id \(id.uuidString).")
        }
        var note = notes[index]
        if let title {
            note.title = normalizedTitle(title)
        }
        if let markdown {
            note.markdown = markdown
        }
        note.updatedAt = Date()
        notes[index] = note
        sortNotes()
        return note
    }

    func delete(id: UUID) throws {
        try requireLoaded()
        let originalCount = notes.count
        notes.removeAll { $0.id == id }
        guard notes.count != originalCount else {
            throw CherryControlError(code: "note_not_found", message: "No Cherry note exists with id \(id.uuidString).")
        }
        try save()
    }

    func note(id: UUID) throws -> ProjectNote {
        try requireLoaded()
        guard let note = notes.first(where: { $0.id == id }) else {
            throw CherryControlError(code: "note_not_found", message: "No Cherry note exists with id \(id.uuidString).")
        }
        return note
    }

    private func load() {
        notes = persistence.loadSynchronously(projectRoot: projectRoot)
    }

    private func loadInBackground() {
        isLoading = true
        let persistence = persistence
        let projectRoot = projectRoot
        backgroundLoadTask = Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                persistence.loadSynchronously(projectRoot: projectRoot)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.notes = loaded
            self.isLoading = false
            self.backgroundLoadTask = nil
        }
    }

    private func save() throws {
        try persistence.saveSynchronously(notes)
    }

    func flushPendingWrites() {
        persistence.flush()
    }

    private func sortNotes() {
        notes.sort(by: projectNoteDisplayOrder)
    }

    private func requireLoaded() throws {
        guard !isLoading else {
            throw CherryControlError(
                code: "notes_loading",
                message: "Cherry is still loading this project's notes."
            )
        }
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func projectNoteDisplayOrder(_ lhs: ProjectNote, _ rhs: ProjectNote) -> Bool {
    if lhs.updatedAt == rhs.updatedAt {
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
    return lhs.updatedAt > rhs.updatedAt
}
