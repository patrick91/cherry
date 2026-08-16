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

        #expect(abs(prediction.attentionProbability - 0.8813556985113804) < 1e-12)
        #expect(prediction.needsAttention)
        #expect(prediction.label == .attentionNeeded)
        #expect(prediction.confidenceDescription == "88% confidence")
        #expect(SidebarAgentAttentionPresentation.shouldShow(
            prediction: prediction,
            hasUnacknowledgedAttention: true,
            isFocused: false
        ))
        #expect(!SidebarAgentAttentionPresentation.shouldShow(
            prediction: prediction,
            hasUnacknowledgedAttention: true,
            isFocused: true
        ))
        #expect(!SidebarAgentAttentionPresentation.shouldShow(
            prediction: prediction,
            hasUnacknowledgedAttention: false,
            isFocused: false
        ))
        #expect(TerminalAttentionClassifier.parameterCount == 47)
        #expect(prediction.debugReport.contains("Native evidence: prompt_marker"))
        #expect(prediction.contributions.first?.name == "boolean.interaction.hasUnsubmittedInput=false")
        #expect(!prediction.contributions.contains { $0.name.contains("terminal.marker") })
        #expect(!TerminalAttentionNotificationPolicy.shouldNotify(
            prediction: prediction,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false
        ))
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

        #expect(abs(prediction.attentionProbability - 0.0012610420511587517) < 1e-12)
        #expect(!prediction.needsAttention)
        #expect(prediction.label == .noAttentionNeeded)
        #expect(prediction.confidenceDescription == "100% confidence")
        #expect(!SidebarAgentAttentionPresentation.shouldShow(
            prediction: prediction,
            hasUnacknowledgedAttention: false,
            isFocused: false
        ))
    }

    @Test func classifierUsesTurnStatesAddedByCorrectionRetraining() {
        for state in [TerminalAttentionTurnState.completed, .notStarted] {
            let prediction = TerminalAttentionClassifier.shared.predict(fixture(
                event: .contentChanged,
                activityState: "idle",
                evidence: "prompt_marker",
                grid: ["› "],
                hasUnsubmittedInput: false,
                millisecondsSinceLastKeystroke: 1_000,
                terminalFocused: false,
                timing: .init(
                    millisecondsSinceStarted: 30_000,
                    millisecondsSinceLastOutput: 1_000,
                    millisecondsSinceLastContentChange: 1_000,
                    millisecondsSinceLastHumanInput: 1_000
                ),
                turnState: state
            ))

            #expect(prediction.contributions.contains {
                $0.name == "category.turn.state=\(state.rawValue)"
            })
        }
    }

    @Test func attentionNotificationGateDeduplicatesAndRearms() {
        let attention = TerminalAttentionClassifier.shared.predict(fixture(
            event: .activityStateChanged,
            activityState: "idle",
            evidence: "prompt_marker",
            grid: ["• Result ready", "› "],
            hasUnsubmittedInput: false,
            millisecondsSinceLastKeystroke: 5_000,
            terminalFocused: false,
            timing: .init(
                millisecondsSinceStarted: 60_000,
                millisecondsSinceLastOutput: 1_000,
                millisecondsSinceLastContentChange: 1_000,
                millisecondsSinceLastHumanInput: 5_000
            ),
            turnState: .completed
        ))
        let composing = TerminalAttentionClassifier.shared.predict(fixture(
            event: .contentChanged,
            activityState: "working",
            evidence: "title_spinner",
            grid: ["• Working", "› still typing"],
            hasUnsubmittedInput: true,
            millisecondsSinceLastKeystroke: 200,
            terminalFocused: true,
            timing: .init(
                millisecondsSinceStarted: 10_000,
                millisecondsSinceLastOutput: 100,
                millisecondsSinceLastContentChange: 100,
                millisecondsSinceLastHumanInput: 200
            )
        ))
        var gate = TerminalAttentionNotificationGate()

        #expect(TerminalAttentionNotificationPolicy.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false
        ))
        #expect(!TerminalAttentionNotificationPolicy.shouldNotify(
            prediction: attention,
            isTopLevelAgent: false,
            hasUnreadNativeNotification: false
        ))
        #expect(!TerminalAttentionNotificationPolicy.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: true
        ))

        let initialNotification = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: true
        )
        #expect(initialNotification)
        let duplicateNotification = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: true
        )
        #expect(!duplicateNotification)

        gate.acknowledge()
        let draftRefreshNotification = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: false
        )
        #expect(!draftRefreshNotification)
        let rearmedNotification = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: true
        )
        #expect(rearmedNotification)

        let composingNotification = gate.shouldNotify(
            prediction: composing,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: false
        )
        #expect(!composingNotification)
        let nativeDuplicate = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: true,
            hasUnacknowledgedAttention: true
        )
        #expect(!nativeDuplicate)
        let afterNativeNotification = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: true
        )
        #expect(!afterNativeNotification)
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

        let returnKey = try #require(returnKeyEvent())
        session.noteNativeHostInput(event: returnKey)
        session.ingestTestingData(Data("• Baked for 1m\n› \n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))

        let prediction = try #require(session.attentionClassifierPrediction)
        #expect(prediction.needsAttention)
        #expect(prediction.modelID == TerminalAttentionClassifier.modelID)
    }

    @Test func acknowledgedAlertOnlyRearmsForFreshAgentActivity() async throws {
        var notificationProbabilities: [Double] = []
        let session = TerminalSession(
            title: "Acknowledgement fixture",
            subtitle: "fixture-agent",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Fixture",
            attentionObservationDirectoryProvider: { nil },
            attentionNotificationHandler: { prediction, _ in
                notificationProbabilities.append(prediction.attentionProbability)
            }
        )
        defer {
            session.stop()
        }

        let returnKey = try #require(returnKeyEvent())
        session.noteNativeHostInput(event: returnKey)
        session.ingestTestingData(Data("• Baked for 1m\n› \n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))

        #expect(session.attentionClassifierPrediction?.needsAttention == true)
        #expect(session.hasUnacknowledgedAttention)
        #expect(notificationProbabilities.count == 1)
        let firstGeneration = session.attentionAlertGeneration

        session.ingestTestingData(Data("The same result is still ready\n› \n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))

        #expect(notificationProbabilities.count == 1)

        session.acknowledgeAttentionAlert()
        #expect(!session.hasUnacknowledgedAttention)

        session.ingestTestingData(Data("A second result is ready\n› \n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))

        #expect(session.attentionClassifierPrediction?.needsAttention == true)
        #expect(session.attentionAlertGeneration > firstGeneration)
        #expect(session.hasUnacknowledgedAttention)
    }

    private func returnKeyEvent() -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )
    }

    private func fixture(
        event: TerminalAttentionObservationEvent,
        activityState: String,
        evidence: String,
        grid: [String],
        hasUnsubmittedInput: Bool,
        millisecondsSinceLastKeystroke: Int,
        terminalFocused: Bool,
        timing: TerminalAttentionObservation.TimingContext,
        turnState: TerminalAttentionTurnState? = nil
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
            turn: turnState.map(TerminalAttentionObservation.TurnContext.init(state:)),
            correction: nil,
            outputVersion: 1,
            contentVersion: 1
        )
    }
}
