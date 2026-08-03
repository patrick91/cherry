import AppKit
import Foundation
import Testing
@testable import Cherry

@MainActor
@Suite(.serialized)
struct TerminalAttentionClassifierTests {
    @Test func swiftInferenceMatchesPythonBaselineForAttentionFixture() {
        let observation = fixture(
            event: .activityStateChanged,
            activityState: "idle",
            evidence: "prompt_marker",
            grid: ["• Baked for 1m", "› "],
            hasUnsubmittedInput: false,
            millisecondsSinceLastKeystroke: 5_000,
            terminalFocused: false,
            timing: .init(
                millisecondsSinceStarted: 60_000,
                millisecondsSinceLastOutput: 1_000,
                millisecondsSinceLastContentChange: 1_000,
                millisecondsSinceLastHumanInput: 5_000
            )
        )

        let prediction = TerminalAttentionClassifier.shared.predict(observation)

        #expect(abs(prediction.attentionProbability - 0.9221480208723661) < 1e-12)
        #expect(prediction.needsAttention)
        #expect(prediction.label == .attentionNeeded)
        #expect(prediction.confidenceDescription == "92% confidence")
        #expect(SidebarAgentAttentionPresentation.shouldShow(
            prediction: prediction,
            isFocused: false
        ))
        #expect(!SidebarAgentAttentionPresentation.shouldShow(
            prediction: prediction,
            isFocused: true
        ))
        #expect(TerminalAttentionClassifier.parameterCount == 55)
        #expect(prediction.debugReport.contains("Native evidence: prompt_marker"))
        #expect(prediction.contributions.first?.name == "boolean.interaction.hasUnsubmittedInput=false")
    }

    @Test func swiftInferenceMatchesPythonBaselineForComposingFixture() {
        let observation = fixture(
            event: .contentChanged,
            activityState: "working",
            evidence: "title_spinner",
            grid: ["• Working (2s • esc to interrupt)", "› still typing"],
            hasUnsubmittedInput: true,
            millisecondsSinceLastKeystroke: 200,
            terminalFocused: true,
            timing: .init(
                millisecondsSinceStarted: 10_000,
                millisecondsSinceLastOutput: 100,
                millisecondsSinceLastContentChange: 100,
                millisecondsSinceLastHumanInput: 200
            )
        )

        let prediction = TerminalAttentionClassifier.shared.predict(observation)

        #expect(abs(prediction.attentionProbability - 0.0011094844877164) < 1e-12)
        #expect(!prediction.needsAttention)
        #expect(prediction.label == .noAttentionNeeded)
        #expect(prediction.confidenceDescription == "100% confidence")
        #expect(!SidebarAgentAttentionPresentation.shouldShow(
            prediction: prediction,
            isFocused: false
        ))
    }

    @Test func agentSessionRunsClassifierWithoutStudyRecording() async throws {
        let session = TerminalSession(
            title: "Classifier shadow fixture",
            subtitle: "fixture-agent",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Fixture",
            attentionObservationDirectoryProvider: { nil }
        )
        defer {
            session.stop()
        }

        session.ingestTestingData(Data("• Baked for 1m\n› \n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))

        let prediction = try #require(session.attentionClassifierPrediction)
        #expect(prediction.needsAttention)
        #expect(prediction.modelID == TerminalAttentionClassifier.modelID)
    }

    private func fixture(
        event: TerminalAttentionObservationEvent,
        activityState: String,
        evidence: String,
        grid: [String],
        hasUnsubmittedInput: Bool,
        millisecondsSinceLastKeystroke: Int,
        terminalFocused: Bool,
        timing: TerminalAttentionObservation.TimingContext
    ) -> TerminalAttentionObservation {
        TerminalAttentionObservation(
            schemaVersion: TerminalAttentionObservation.currentSchemaVersion,
            id: UUID(uuidString: "6594bade-c891-42cb-8cb1-e51c16f1ab95")!,
            recordedAt: Date(timeIntervalSince1970: 0),
            event: event,
            label: nil,
            annotation: nil,
            scenarioID: nil,
            checkpoint: nil,
            session: .init(
                id: "4c5d7267-f12c-4e8d-a821-65b9f8bf848c",
                kind: "agent",
                harness: "Fixture",
                harnessVersion: nil,
                runID: nil
            ),
            terminal: .init(
                columns: 120,
                rows: 32,
                usesAlternateScreen: false,
                cursor: .init(row: 0, column: 0, shape: "block", isVisible: true),
                grid: grid,
                styledGrid: nil,
                scrollbackLinesOmitted: 0
            ),
            timing: timing,
            activity: .init(
                state: activityState,
                evidence: evidence,
                hasUnreadNotification: false,
                processState: "live",
                exitCode: nil
            ),
            interaction: .init(
                hasUnsubmittedInput: hasUnsubmittedInput,
                millisecondsSinceLastKeystroke: millisecondsSinceLastKeystroke,
                terminalFocused: terminalFocused
            ),
            outputVersion: 1,
            contentVersion: 1
        )
    }
}
