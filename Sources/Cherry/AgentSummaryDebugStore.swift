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
    let title: String?
    let summary: String?
    let error: String?

    var status: String {
        let details = "(\(filteredLineCount)/\(inputLineCount) lines, \(charactersSent) chars)"
        if let summary {
            let result = [title, summary].compactMap { $0 }.joined(separator: " — ")
            return "Returned: \(result) \(details)"
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
        generated_title: \(title ?? "")
        status: \(status)

        --- transcript ---
        \(transcript)

        --- prompt ---
        \(prompt)

        """
    }

    var logText: String {
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
        generated_title: \(title ?? "")
        status: \(status)

        """
    }
}

@MainActor
final class AgentSummaryDebugStore: ObservableObject {
    static let shared = AgentSummaryDebugStore()
    private static let maximumLogBytes: UInt64 = 2_000_000

    @Published private(set) var lastRecord: AgentSummaryDebugRecord?
    private let configuredLogURL: URL?
    private let environment: [String: String]

    init(
        logURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTestProcess: Bool = AgentSummaryDebugStore.isTestProcess(
            arguments: ProcessInfo.processInfo.arguments
        )
    ) {
        configuredLogURL = logURL
        self.environment = environment
        if Self.shouldPurgeLegacyLog(environment: environment, isTestProcess: isTestProcess)
            || (!isTestProcess && Self.logContainsLegacyTranscript(at: self.logURL)) {
            try? FileManager.default.removeItem(at: self.logURL)
        }
    }

    var logURL: URL {
        if let configuredLogURL {
            return configuredLogURL
        }
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cherry", isDirectory: true)
        return directory.appendingPathComponent("AgentSummaryDebug.log", isDirectory: false)
    }

    nonisolated static func diskLoggingEnabled(environment: [String: String]) -> Bool {
        let value = environment["CHERRY_AGENT_SUMMARY_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    nonisolated static func shouldPurgeLegacyLog(
        environment: [String: String],
        isTestProcess: Bool
    ) -> Bool {
        !isTestProcess && !diskLoggingEnabled(environment: environment)
    }

    nonisolated static func isTestProcess(arguments: [String]) -> Bool {
        arguments.contains { argument in
            argument.contains("CherryTests.xctest")
                || URL(fileURLWithPath: argument).lastPathComponent == "CherryTests"
        }
    }

    private nonisolated static func logContainsLegacyTranscript(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer {
            try? handle.close()
        }
        guard let data = try? handle.read(upToCount: 4_096) else {
            return false
        }
        return String(decoding: data, as: UTF8.self).contains("--- transcript ---")
    }

    func record(_ record: AgentSummaryDebugRecord) {
        lastRecord = record
        guard Self.diskLoggingEnabled(environment: environment) else { return }
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
        guard let data = (record.logText + "\n").data(using: .utf8) else { return }

        let existingSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
        if existingSize + UInt64(data.count) > Self.maximumLogBytes {
            try? data.write(to: url, options: .atomic)
            return
        }

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
