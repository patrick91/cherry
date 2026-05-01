import AppKit
import Foundation

struct AgentSummaryDebugRecord: Equatable {
    let date: Date
    let sessionID: UUID
    let sessionTitle: String
    let command: String
    let workingDirectory: String
    let inputLineCount: Int
    let filteredLineCount: Int
    let charactersSent: Int
    let transcript: String
    let prompt: String
    let summary: String?
    let error: String?

    var status: String {
        let details = "(\(filteredLineCount)/\(inputLineCount) lines, \(charactersSent) chars)"
        if let summary {
            return "Returned: \(summary) \(details)"
        } else if let error {
            return "Failed: \(error) \(details)"
        } else {
            return "Started \(details)"
        }
    }

    var text: String {
        let formatter = ISO8601DateFormatter()
        return """
        === Agent Summary Debug ===
        date: \(formatter.string(from: date))
        session_id: \(sessionID.uuidString)
        session_title: \(sessionTitle)
        command: \(command)
        working_directory: \(workingDirectory)
        input_line_count: \(inputLineCount)
        filtered_line_count: \(filteredLineCount)
        characters_sent: \(charactersSent)
        status: \(status)

        --- transcript ---
        \(transcript)

        --- prompt ---
        \(prompt)

        """
    }
}

@MainActor
final class AgentSummaryDebugStore: ObservableObject {
    static let shared = AgentSummaryDebugStore()

    @Published private(set) var lastRecord: AgentSummaryDebugRecord?

    var logURL: URL {
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cherry", isDirectory: true)
        return directory.appendingPathComponent("AgentSummaryDebug.log", isDirectory: false)
    }

    func record(_ record: AgentSummaryDebugRecord) {
        lastRecord = record
        append(record)
    }

    func copyLastRecord() {
        guard let lastRecord else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastRecord.text, forType: .string)
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    private func append(_ record: AgentSummaryDebugRecord) {
        let url = logURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = (record.text + "\n").data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer {
                try? handle.close()
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
