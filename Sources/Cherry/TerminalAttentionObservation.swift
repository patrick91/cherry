import Foundation

enum TerminalAttentionLabel: String, Codable, CaseIterable, Equatable, Sendable {
    case approvalRequired = "approval_required"
    case waitingForInput = "waiting_for_input"
    case readyForReview = "ready_for_review"
    case noAttentionNeeded = "no_attention_needed"
    case unknown
}

enum TerminalAttentionObservationEvent: String, Codable, Equatable, Sendable {
    case contentChanged = "content_changed"
    case inputSubmitted = "input_submitted"
    case activityStateChanged = "activity_state_changed"
    case notification
    case processExited = "process_exited"
    case labeledCheckpoint = "labeled_checkpoint"
}

struct TerminalAttentionObservation: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct SessionContext: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let harness: String?
        let harnessVersion: String?
        let runID: String?
    }

    struct TerminalContext: Codable, Equatable, Sendable {
        struct Cursor: Codable, Equatable, Sendable {
            let row: Int
            let column: Int
            let shape: String
            let isVisible: Bool
        }

        struct Color: Codable, Equatable, Sendable {
            enum Space: String, Codable, Equatable, Sendable {
                case ansi16
                case palette256
                case rgb
            }

            let space: Space
            let components: [Int]
        }

        struct StyledRun: Codable, Equatable, Sendable {
            enum Attribute: String, Codable, Equatable, Sendable {
                case bold
                case dim
                case inverse
                case italic
                case underline
                case strikethrough
            }

            let text: String
            let foreground: Color?
            let background: Color?
            let attributes: [Attribute]
        }

        let columns: Int
        let rows: Int
        let usesAlternateScreen: Bool
        let cursor: Cursor
        let grid: [String]
        /// Optional styled runs corresponding one-for-one with `grid`.
        ///
        /// Older observations and native Ghostty surfaces that only expose
        /// flattened text omit this field. Keeping `grid` authoritative makes
        /// the addition backward compatible with schema version 1.
        let styledGrid: [[StyledRun]]?
        let scrollbackLinesOmitted: Int
    }

    struct TimingContext: Codable, Equatable, Sendable {
        let millisecondsSinceStarted: Int?
        let millisecondsSinceLastOutput: Int?
        let millisecondsSinceLastContentChange: Int?
        let millisecondsSinceLastHumanInput: Int?
    }

    struct ActivityContext: Codable, Equatable, Sendable {
        let state: String
        let evidence: String
        let hasUnreadNotification: Bool
        let processState: String
        let exitCode: Int32?
    }

    let schemaVersion: Int
    let id: UUID
    let recordedAt: Date
    let event: TerminalAttentionObservationEvent
    let label: TerminalAttentionLabel?
    let scenarioID: String?
    let checkpoint: String?
    let session: SessionContext
    let terminal: TerminalContext
    let timing: TimingContext
    let activity: ActivityContext
    let outputVersion: Int
    let contentVersion: Int
}

enum TerminalAttentionRecordingError: LocalizedError, Equatable {
    case disabled

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Terminal attention recording is disabled. Enable Attention Study in Terminal settings or set CHERRY_ATTENTION_RECORDING_DIR."
        }
    }
}

final class TerminalAttentionObservationRecorder: @unchecked Sendable {
    static let environmentKey = "CHERRY_ATTENTION_RECORDING_DIR"

    static var configuredDirectoryURL: URL? {
        TerminalAttentionStudy.configuredDirectoryURL()
    }

    let outputURL: URL

    private let queue: DispatchQueue
    private let outputHandle: FileHandle

    init?(directoryURL: URL?, sessionID: UUID, harness: String?) {
        guard let directoryURL else { return nil }

        do {
            try TerminalAttentionStudy.prepareDirectoryIfNeeded(directoryURL)
        } catch {
            fputs("[attention recording] failed to create \(directoryURL.path): \(error.localizedDescription)\n", stderr)
            return nil
        }

        let filename = "\(Self.timestamp())-\(Self.safeFilename(harness ?? "terminal"))-\(sessionID.uuidString.prefix(8)).jsonl"
        outputURL = directoryURL.appendingPathComponent(filename)
        queue = DispatchQueue(label: "Cherry.TerminalAttentionObservationRecorder.\(sessionID.uuidString)", qos: .utility)

        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: Data(),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            fputs("[attention recording] failed to create \(outputURL.path)\n", stderr)
            return nil
        }

        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            fputs("[attention recording] failed to open \(outputURL.path): \(error.localizedDescription)\n", stderr)
            return nil
        }

        fputs("[attention recording] writing observations to \(outputURL.path)\n", stderr)
    }

    deinit {
        queue.sync {
            try? outputHandle.synchronize()
            try? outputHandle.close()
        }
    }

    func record(_ observation: TerminalAttentionObservation, synchronously: Bool = false) {
        let operation: @Sendable () -> Void = { [outputHandle] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

            guard var data = try? encoder.encode(observation) else { return }
            data.append(0x0A)
            try? outputHandle.write(contentsOf: data)
            if synchronously {
                try? outputHandle.synchronize()
            }
        }

        if synchronously {
            queue.sync(execute: operation)
        } else {
            queue.async(execute: operation)
        }
    }

    func flush() {
        queue.sync {
            try? outputHandle.synchronize()
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitized = value.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitized.isEmpty ? "session" : String(sanitized.prefix(48))
    }
}
