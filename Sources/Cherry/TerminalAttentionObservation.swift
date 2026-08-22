import Foundation

enum TerminalAttentionLabel: String, Codable, CaseIterable, Equatable, Sendable {
    case attentionNeeded = "attention_needed"
    case approvalRequired = "approval_required"
    case waitingForInput = "waiting_for_input"
    case readyForReview = "ready_for_review"
    case noAttentionNeeded = "no_attention_needed"
    case unknown
}

enum TerminalAttentionReason: String, Codable, CaseIterable, Equatable, Sendable {
    case resultReady = "result_ready"
    case waitingForInput = "waiting_for_input"
    case waitingForApproval = "waiting_for_approval"
    case blockedOrError = "blocked_or_error"
    case agentWorking = "agent_working"
    case userResponding = "user_responding"
    case idleNoActiveTask = "idle_no_active_task"
}

enum TerminalAttentionCorrection: CaseIterable, Equatable, Sendable {
    case resultReady
    case waitingForInput
    case waitingForApproval
    case blockedOrError
    case agentWorking
    case userResponding
    case idleNoActiveTask
    case unknown

    var title: String {
        switch self {
        case .resultReady:
            "Result ready for review"
        case .waitingForInput:
            "Needs my input"
        case .waitingForApproval:
            "Needs my approval"
        case .blockedOrError:
            "Blocked or errored"
        case .agentWorking:
            "Agent is working"
        case .userResponding:
            "I'm already responding"
        case .idleNoActiveTask:
            "Idle / no active task"
        case .unknown:
            "Not sure"
        }
    }

    var label: TerminalAttentionLabel {
        switch self {
        case .resultReady, .waitingForInput, .waitingForApproval, .blockedOrError:
            .attentionNeeded
        case .agentWorking, .userResponding, .idleNoActiveTask:
            .noAttentionNeeded
        case .unknown:
            .unknown
        }
    }

    var reason: TerminalAttentionReason? {
        switch self {
        case .resultReady:
            .resultReady
        case .waitingForInput:
            .waitingForInput
        case .waitingForApproval:
            .waitingForApproval
        case .blockedOrError:
            .blockedOrError
        case .agentWorking:
            .agentWorking
        case .userResponding:
            .userResponding
        case .idleNoActiveTask:
            .idleNoActiveTask
        case .unknown:
            nil
        }
    }
}

enum TerminalAttentionObservationEvent: String, Codable, Equatable, Sendable {
    case contentChanged = "content_changed"
    case inputChanged = "input_changed"
    case inputSubmitted = "input_submitted"
    case turnInterrupted = "turn_interrupted"
    case activityStateChanged = "activity_state_changed"
    case notification
    case processExited = "process_exited"
    case labeledCheckpoint = "labeled_checkpoint"
}

enum TerminalAttentionTurnState: String, Codable, Equatable, Sendable {
    /// Cherry has not observed a submitted turn in this terminal process yet.
    case notStarted = "not_started"
    /// A submitted turn is still running.
    case active
    /// The agent has yielded control after a submitted turn.
    case completed
    /// The user explicitly interrupted the active turn.
    case userInterrupted = "user_interrupted"
}

struct TerminalAttentionObservation: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct AnnotationContext: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let provenance: String
        let confidence: Double
        let rationale: String
        let reason: TerminalAttentionReason?
    }

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

    struct InteractionContext: Codable, Equatable, Sendable {
        let hasUnsubmittedInput: Bool
        let millisecondsSinceLastKeystroke: Int?
        let terminalFocused: Bool
    }

    struct TurnContext: Codable, Equatable, Sendable {
        let state: TerminalAttentionTurnState
    }

    /// Metadata captured only for an in-app human correction. Keeping it out of
    /// `annotation` makes the human target and the source model verdict
    /// independently available to the dataset exporter.
    struct CorrectionContext: Codable, Equatable, Sendable {
        let sourceEvent: TerminalAttentionObservationEvent
        let modelID: String?
        let modelLabel: TerminalAttentionLabel?
        let attentionProbability: Double?
        let threshold: Double?
        /// The previous correction for this unchanged screen, if the user
        /// selected a different (or replacement) label.
        let supersedesObservationID: UUID?
    }

    let schemaVersion: Int
    let id: UUID
    let recordedAt: Date
    let event: TerminalAttentionObservationEvent
    let label: TerminalAttentionLabel?
    /// Optional review metadata. Its absence keeps older schema-1 observations
    /// decodable, while explicit human checkpoints remain distinguishable from
    /// automatic or synthetic labels.
    let annotation: AnnotationContext?
    let scenarioID: String?
    let checkpoint: String?
    let session: SessionContext
    let terminal: TerminalContext
    let timing: TimingContext
    let activity: ActivityContext
    /// Optional so schema-1 observations captured before interaction tracking
    /// remain decodable and uploadable.
    let interaction: InteractionContext?
    /// Optional so existing schema-1 observations remain decodable.
    let turn: TurnContext?
    /// Optional, correction-only source prediction and replacement metadata.
    let correction: CorrectionContext?
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
