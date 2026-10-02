import Foundation
import Testing
@testable import Cherry

/// Replays a directory of human-corrected attention observations (an
/// `attention-study-data` export or a Corrections folder) through the current
/// screen rules (`AgentScreenActivity`) and attention model, and reports
/// where they disagree with the user's label. Runs only with
/// `CHERRY_ATTENTION_CORRECTIONS_DIR` set; the report holds ids, dates,
/// labels and verdicts, never screen text. `CHERRY_ATTENTION_REPLAY_OUT`
/// also writes it to a file.
@Suite(.serialized)
struct AttentionCorrectionsReplayTests {
    /// What the replay says the session's activity was.
    struct ReplayedActivity: Equatable {
        let state: String
        let evidence: String
    }

    /// Mirrors the state machine's precedence for one recorded screen: a
    /// working marker, then a (recorded) title spinner, then a prompt, then an
    /// unsubmitted draft, then the content-quiet window, else output activity.
    /// Title text is not recorded, so a title-spinner state is taken as fresh.
    static func replay(_ observation: TerminalAttentionObservation) -> ReplayedActivity {
        let agent = AgentScreenActivity.agentKey(name: observation.session.harness, commandLine: nil)
        switch AgentScreenActivity.verdict(for: observation.terminal.grid, agent: agent) {
        case .working:
            return .init(state: "working", evidence: "working_marker")
        case .prompt:
            if observation.activity.evidence == "title_spinner" {
                return .init(state: "working", evidence: "title_spinner")
            }
            return .init(state: "idle", evidence: "prompt_marker")
        case .none:
            if observation.activity.evidence == "title_spinner" {
                return .init(state: "working", evidence: "title_spinner")
            }
            if observation.interaction?.hasUnsubmittedInput == true {
                return .init(state: "idle", evidence: "prompt_marker")
            }
            if (observation.timing.millisecondsSinceLastContentChange ?? 0) >= 4_000 {
                return .init(state: "idle", evidence: "quiet_window")
            }
            return .init(state: "working", evidence: "output_activity")
        }
    }

    /// The activity the user's label implies, when it implies one: action
    /// needed means the agent is not at work; "agent is working" means it is.
    static func expectedActivity(_ observation: TerminalAttentionObservation) -> String? {
        switch observation.label {
        case .attentionNeeded, .approvalRequired, .waitingForInput, .readyForReview:
            return "idle"
        case .noAttentionNeeded:
            switch observation.annotation?.reason {
            case .agentWorking: return "working"
            case .userResponding, .idleNoActiveTask: return "idle"
            default: return nil
            }
        case .unknown, nil:
            return nil
        }
    }

    static func isActionNeeded(_ label: TerminalAttentionLabel?) -> Bool? {
        switch label {
        case .attentionNeeded, .approvalRequired, .waitingForInput, .readyForReview: true
        case .noAttentionNeeded: false
        case .unknown, nil: nil
        }
    }

    static func loadObservations(from directory: URL) throws -> [(TerminalAttentionObservation, Data)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        var result: [(TerminalAttentionObservation, Data)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.isEmpty {
                let data = Data(line.utf8)
                result.append((try decoder.decode(TerminalAttentionObservation.self, from: data), data))
            }
        }
        return result.sorted { $0.0.recordedAt < $1.0.recordedAt }
    }

    /// The observation with its activity replaced by the replayed one, so the
    /// attention model sees what the current rules would have reported.
    static func withActivity(_ data: Data, _ activity: ReplayedActivity) throws -> TerminalAttentionObservation {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var context = try #require(object["activity"] as? [String: Any])
        context["state"] = activity.state
        context["evidence"] = activity.evidence
        object["activity"] = context
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            TerminalAttentionObservation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    @Test func replayHumanCorrections() throws {
        guard let path = ProcessInfo.processInfo.environment["CHERRY_ATTENTION_CORRECTIONS_DIR"] else { return }
        let observations = try Self.loadObservations(from: URL(fileURLWithPath: path, isDirectory: true))
        #expect(!observations.isEmpty)

        struct Tally {
            var activityScored = 0, recordedActivityRight = 0, replayActivityRight = 0
            var attentionScored = 0, recordedAttentionRight = 0, replayAttentionRight = 0
        }
        var tallies: [String: Tally] = [:]
        var lines: [String] = []
        let recentCutoff = ISO8601DateFormatter().date(from: "2026-08-20T00:00:00Z")!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        for (index, (observation, data)) in observations.enumerated() {
            let harness = observation.session.harness?.replacingOccurrences(of: "-correction", with: "") ?? "?"
            let replayed = Self.replay(observation)
            let expected = Self.expectedActivity(observation)
            let reasonName = observation.annotation?.reason?.rawValue ?? "-"
            let recordedPrediction = TerminalAttentionClassifier.shared.predict(observation)
            let replayPrediction = TerminalAttentionClassifier.shared.predict(try Self.withActivity(data, replayed))
            let wantsAction = Self.isActionNeeded(observation.label)

            let era = observation.recordedAt >= recentCutoff ? "recent" : "older"
            for key in [harness, "\(harness) (\(era))", "ALL", "ALL (\(era))"] {
                var tally = tallies[key, default: Tally()]
                if let expected {
                    tally.activityScored += 1
                    if observation.activity.state == expected { tally.recordedActivityRight += 1 }
                    if replayed.state == expected { tally.replayActivityRight += 1 }
                }
                if let wantsAction {
                    tally.attentionScored += 1
                    if recordedPrediction.needsAttention == wantsAction { tally.recordedAttentionRight += 1 }
                    if replayPrediction.needsAttention == wantsAction { tally.replayAttentionRight += 1 }
                }
                tallies[key] = tally
            }

            let activityMark = expected.map { replayed.state == $0 ? "ok " : "BAD" } ?? " - "
            let attentionMark = wantsAction.map { replayPrediction.needsAttention == $0 ? "ok " : "BAD" } ?? " - "
            lines.append(
                String(format: "#%02d", index)
                + " \(formatter.string(from: observation.recordedAt)) \(harness.padding(toLength: 6, withPad: " ", startingAt: 0))"
                + " label=\(observation.label?.rawValue ?? "nil")/\(reasonName)"
                + " recorded=\(observation.activity.state)/\(observation.activity.evidence)"
                + " replay=\(replayed.state)/\(replayed.evidence)"
                + " activity:\(activityMark) attention:\(attentionMark)"
                + String(format: " p=%.2f", replayPrediction.attentionProbability)
                + " id=\(observation.id.uuidString.prefix(8))"
            )
        }

        lines.append("")
        lines.append("group                 activity(recorded→replay)   attention model(recorded→replay)")
        for key in tallies.keys.sorted() {
            let tally = tallies[key]!
            lines.append(
                key.padding(toLength: 22, withPad: " ", startingAt: 0)
                + "\(tally.recordedActivityRight)/\(tally.activityScored) → \(tally.replayActivityRight)/\(tally.activityScored)".padding(toLength: 28, withPad: " ", startingAt: 0)
                + "\(tally.recordedAttentionRight)/\(tally.attentionScored) → \(tally.replayAttentionRight)/\(tally.attentionScored)"
            )
        }

        let report = lines.joined(separator: "\n")
        print(report)
        if let out = ProcessInfo.processInfo.environment["CHERRY_ATTENTION_REPLAY_OUT"] {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
