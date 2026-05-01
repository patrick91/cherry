import CherryControl
import CryptoKit
import Foundation

@MainActor
final class ProjectNoteStore: ObservableObject {
    @Published private(set) var notes: [ProjectNote] = []

    let projectRoot: String
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        projectRoot: String,
        storageDirectory: URL = ProjectNoteStore.defaultStorageDirectory()
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
            .appendingPathComponent("Notes", isDirectory: true)
    }

    static func projectStorageName(projectRoot: String) -> String {
        let digest = SHA256.hash(data: Data(projectRoot.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    func create(title: String, markdown: String) throws -> ProjectNote {
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
        try save()
        return note
    }

    func delete(id: UUID) throws {
        let originalCount = notes.count
        notes.removeAll { $0.id == id }
        guard notes.count != originalCount else {
            throw CherryControlError(code: "note_not_found", message: "No Cherry note exists with id \(id.uuidString).")
        }
        try save()
    }

    func note(id: UUID) throws -> ProjectNote {
        guard let note = notes.first(where: { $0.id == id }) else {
            throw CherryControlError(code: "note_not_found", message: "No Cherry note exists with id \(id.uuidString).")
        }
        return note
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([ProjectNote].self, from: data)
        else {
            notes = []
            return
        }
        notes = decoded.filter { $0.projectRoot == projectRoot }
        sortNotes()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(notes)
        try data.write(to: fileURL, options: .atomic)
    }

    private func sortNotes() {
        notes.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
