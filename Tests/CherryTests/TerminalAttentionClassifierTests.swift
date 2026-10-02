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
        #expect(!SidebarAgentWorkingPresentation.shouldShow(prediction: prediction))
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
            ),
            turnState: .active
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
        #expect(SidebarAgentWorkingPresentation.shouldShow(prediction: prediction))
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

    @Test func workingIndicatorRequiresActiveClassifierPrediction() {
        let completed = TerminalAttentionClassifier.shared.predict(fixture(
            event: .activityStateChanged,
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
            turnState: .completed
        ))

        #expect(!SidebarAgentWorkingPresentation.shouldShow(prediction: completed))
        #expect(!SidebarAgentWorkingPresentation.shouldShow(prediction: nil))
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
            ),
            turnState: .active
        ))
        let completedTurnWobble = TerminalAttentionClassifier.shared.predict(fixture(
            event: .activityStateChanged,
            activityState: "working",
            evidence: "output_activity",
            grid: ["• Result ready", "> "],
            hasUnsubmittedInput: false,
            millisecondsSinceLastKeystroke: 5_000,
            terminalFocused: false,
            timing: .init(
                millisecondsSinceStarted: 60_000,
                millisecondsSinceLastOutput: 100,
                millisecondsSinceLastContentChange: 100,
                millisecondsSinceLastHumanInput: 5_000
            ),
            turnState: .completed
        ))
        #expect(!completedTurnWobble.needsAttention)
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
        let acknowledgedEpisodeRefresh = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: true
        )
        #expect(!acknowledgedEpisodeRefresh)

        let completedTurnWobbleNotification = gate.shouldNotify(
            prediction: completedTurnWobble,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: false
        )
        #expect(!completedTurnWobbleNotification)
        let sameCompletedTurnNotification = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: true
        )
        #expect(!sameCompletedTurnNotification)

        let composingNotification = gate.shouldNotify(
            prediction: composing,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: false
        )
        #expect(!composingNotification)
        let nextEpisodeNotification = gate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: false,
            hasUnacknowledgedAttention: true
        )
        #expect(nextEpisodeNotification)

        var nativeGate = TerminalAttentionNotificationGate()
        let nativeDuplicate = nativeGate.shouldNotify(
            prediction: attention,
            isTopLevelAgent: true,
            hasUnreadNativeNotification: true,
            hasUnacknowledgedAttention: true
        )
        #expect(!nativeDuplicate)
        let afterNativeNotification = nativeGate.shouldNotify(
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

    @Test func acknowledgedAlertStaysConsumedThroughCompletedTurnClassifierWobble() async throws {
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
        #expect(session.attentionAlertGeneration == firstGeneration)
        #expect(!session.hasUnacknowledgedAttention)
        #expect(notificationProbabilities.count == 1)

        // A repaint/reflow can make an unchanged completed screen briefly look
        // like fresh working output. That classifier wobble is not a new turn.
        session.ingestTestingData(Data("\u{1B}[2J\u{1B}[H• Working (2s • esc to interrupt)\n› still working\n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))

        #expect(session.attentionClassifierPrediction?.needsAttention == false)
        #expect(session.attentionClassifierPrediction?.turnState == .completed)

        session.ingestTestingData(Data("\u{1B}[2J\u{1B}[H• The completed result is still ready\n› \n".utf8))
        session.ingestNativeNotification(title: nil, body: "Task complete")
        try await Task.sleep(for: .milliseconds(1_250))

        #expect(session.attentionClassifierPrediction?.needsAttention == true)
        #expect(session.attentionAlertGeneration == firstGeneration)
        #expect(!session.hasUnacknowledgedAttention)
        #expect(notificationProbabilities.count == 1)

        session.noteNativeHostInput(event: returnKey)
        session.ingestTestingData(Data("• Working on a new turn (2s • esc to interrupt)\n› still working\n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))

        #expect(session.attentionClassifierPrediction?.needsAttention == false)
        #expect(session.attentionClassifierPrediction?.turnState == .active)

        session.ingestTestingData(Data("\u{1B}[2J\u{1B}[H• A genuinely new result is ready\n› \n".utf8))
        session.ingestNativeNotification(title: nil, body: "Task complete")
        try await Task.sleep(for: .milliseconds(1_250))

        #expect(session.attentionAlertGeneration > firstGeneration)
        #expect(!session.hasUnreadNotification)
        #expect(notificationProbabilities.count == 1)
    }

    // MARK: Menus waiting on the user's answer

    private func screenData(_ lines: [String]) -> Data {
        Data(("\u{1B}[2J\u{1B}[H" + lines.joined(separator: "\r\n")).utf8)
    }

    private func digitKeyEvent(_ digit: Character) -> NSEvent? {
        let keyCodes: [Character: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21]
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(digit),
            charactersIgnoringModifiers: String(digit),
            isARepeat: false,
            keyCode: keyCodes[digit] ?? 18
        )
    }

    @Test func answerMenuStateAlwaysNeedsAttention() {
        let timing = TerminalAttentionObservation.TimingContext(
            millisecondsSinceStarted: 600_000,
            millisecondsSinceLastOutput: 0,
            millisecondsSinceLastContentChange: 0,
            millisecondsSinceLastHumanInput: 120_000
        )
        for state in ["needs_input", "permission"] {
            let prediction = TerminalAttentionClassifier.shared.predict(fixture(
                event: .activityStateChanged,
                activityState: state,
                evidence: TerminalAttentionPrediction.answerMenuEvidence,
                grid: AgentScreenActivityTests.claudeTallQuestion,
                hasUnsubmittedInput: false,
                millisecondsSinceLastKeystroke: 120_000,
                terminalFocused: true,
                timing: timing,
                turnState: .active
            ))
            #expect(prediction.needsAttention)
            #expect(prediction.isRaisedByAnswerMenu)
            #expect(prediction.confidence == 1)
            #expect(prediction.debugReport.contains("Rule: the turn waits on a menu's answer"))
            #expect(TerminalAttentionNotificationPolicy.shouldNotify(
                prediction: prediction,
                isTopLevelAgent: true,
                hasUnreadNativeNotification: false
            ))
            #expect(!TerminalAttentionNotificationPolicy.shouldNotify(
                prediction: prediction,
                isTopLevelAgent: true,
                hasUnreadNativeNotification: true
            ))
        }

        // A notified permission keeps the model's own verdict, and a menu
        // before the first turn (a startup dialog) never needs action.
        let notified = TerminalAttentionClassifier.shared.predict(fixture(
            event: .notification,
            activityState: "permission",
            evidence: "notification",
            grid: ["❯ 1. Yes", "  2. No"],
            hasUnsubmittedInput: false,
            millisecondsSinceLastKeystroke: 1_000,
            terminalFocused: false,
            timing: timing,
            turnState: .active
        ))
        #expect(!notified.isRaisedByAnswerMenu)
        let startup = TerminalAttentionClassifier.shared.predict(fixture(
            event: .activityStateChanged,
            activityState: "needs_input",
            evidence: TerminalAttentionPrediction.answerMenuEvidence,
            grid: ["❯ 1. Yes, proceed", "  2. No, exit"],
            hasUnsubmittedInput: false,
            millisecondsSinceLastKeystroke: 1_000,
            terminalFocused: false,
            timing: timing,
            turnState: .notStarted
        ))
        #expect(!startup.needsAttention)
    }

    @Test func questionMenuNeedsAttentionUntilItIsAnswered() async throws {
        var notified: [(TerminalAttentionPrediction, AgentActivityState)] = []
        let session = TerminalSession(
            title: "Question fixture",
            subtitle: "claude",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Claude",
            attentionObservationDirectoryProvider: { nil },
            attentionNotificationHandler: { prediction, session in
                notified.append((prediction, session.agentActivityState))
            }
        )
        defer {
            session.stop()
        }

        let returnKey = try #require(returnKeyEvent())
        session.noteNativeHostInput(event: returnKey)
        session.ingestTestingData(screenData([
            "❯ pick a storage backend for me",
            "",
            "✶ Reticulating… (3s · ↓ 120 tokens)",
            "",
            "❯ ",
            "  esc to interrupt",
        ]))
        try await Task.sleep(for: .milliseconds(1_250))
        #expect(session.agentActivityState == .working)
        #expect(session.attentionClassifierPrediction?.needsAttention == false)
        #expect(notified.isEmpty)

        // The tall menu: its cursor line is far above the last 8 lines.
        session.ingestTestingData(screenData(AgentScreenActivityTests.claudeTallQuestion))
        try await Task.sleep(for: .milliseconds(1_250))
        #expect(session.agentActivityState == .needsInput)
        #expect(session.agentActivityState.awaitsUserAnswer)
        let prediction = try #require(session.attentionClassifierPrediction)
        #expect(prediction.needsAttention)
        #expect(prediction.isRaisedByAnswerMenu)
        #expect(prediction.turnState == .active)
        #expect(session.hasUnacknowledgedAttention)
        #expect(notified.count == 1)
        #expect(notified.first?.1 == .needsInput)
        #expect(SidebarAgentAttentionPresentation.shouldShow(
            prediction: prediction,
            hasUnacknowledgedAttention: session.hasUnacknowledgedAttention,
            isFocused: false
        ))
        let questionGeneration = session.attentionAlertGeneration

        // Moving the cursor redraws the same menu: the same episode.
        var moved = AgentScreenActivityTests.claudeTallQuestion
        let cursor = try #require(moved.firstIndex { $0.hasPrefix("❯ 3.") })
        moved[cursor] = "  3." + moved[cursor].dropFirst(4)
        let next = try #require(moved.firstIndex { $0.hasPrefix("  4.") })
        moved[next] = "❯ 4." + moved[next].dropFirst(4)
        session.ingestTestingData(screenData(moved))
        try await Task.sleep(for: .milliseconds(1_250))
        #expect(session.agentActivityState == .needsInput)
        #expect(session.attentionAlertGeneration == questionGeneration)
        #expect(notified.count == 1)

        session.acknowledgeAttentionAlert()
        #expect(!session.hasUnacknowledgedAttention)

        // A digit answers the menu: no draft, no new turn.
        let turns = session.agentSubmittedTurnCount
        session.noteNativeHostInput(event: try #require(digitKeyEvent("1")))
        #expect(session.agentSubmittedTurnCount == turns)
        #expect(session.agentActivityState == .needsInput)

        // The menu gone, the paused turn goes on.
        session.ingestTestingData(screenData([
            "⏺ User answered Claude's questions:",
            "  ⎿  · How should existing data be migrated? → In place",
            "",
            "✶ Reticulating… (5s · ↓ 300 tokens)",
            "",
            "❯ ",
            "  esc to interrupt",
        ]))
        try await Task.sleep(for: .milliseconds(1_250))
        #expect(session.agentActivityState == .working)
        #expect(session.agentTurnState == .active)
        #expect(session.attentionClassifierPrediction?.needsAttention == false)
        #expect(!session.hasUnacknowledgedAttention)
        #expect(notified.count == 1)

        // The turn's result is a new episode. (A full screen of transcript:
        // the test buffer keeps the last screen's footer just above it.)
        session.ingestTestingData(screenData(Array(repeating: "  migrated a table", count: 32) + [
            "⏺ Migrated the store in place.",
            "",
            "✻ Worked for 12s",
            "",
            "❯ ",
            "  ? for shortcuts",
        ]))
        try await Task.sleep(for: .milliseconds(1_250))
        #expect(session.agentActivityState == .idle)
        #expect(session.agentTurnState == .completed)
        #expect(session.attentionAlertGeneration > questionGeneration)
        #expect(session.hasUnacknowledgedAttention)
    }

    @Test func menuLeftWithOnlyTheComposerConfirmsBeforeTheTurnEnds() async throws {
        let session = TerminalSession(
            title: "Question composer fixture",
            subtitle: "claude",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Claude",
            attentionObservationDirectoryProvider: { nil },
            attentionNotificationHandler: { _, _ in }
        )
        defer {
            session.stop()
        }

        session.noteNativeHostInput(event: try #require(returnKeyEvent()))
        session.ingestTestingData(screenData(AgentScreenActivityTests.claudeShortQuestion))
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.agentActivityState == .needsInput)

        // Enter answers it; the next frame shows only the composer: the
        // turn is still taken as going on at first.
        session.noteNativeHostInput(event: try #require(returnKeyEvent()))
        #expect(session.agentActivityState == .needsInput)
        session.ingestTestingData(screenData([
            "⏺ User answered Claude's questions:",
            "  ⎿  · Which storage backend should I use? → SQLite",
            "",
            "❯ ",
        ]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.agentActivityState == .working)
        #expect(session.agentTurnState == .active)
        // Still at the composer, it is then taken as the turn's end.
        try await Task.sleep(for: .milliseconds(900))
        #expect(session.agentActivityState == .idle)
        #expect(session.agentTurnState == .completed)
    }

    @Test func codexApprovalOnScreenIsAPermissionPrompt() async throws {
        var notified: [AgentActivityState] = []
        let session = TerminalSession(
            title: "Approval fixture",
            subtitle: "codex",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Codex",
            attentionObservationDirectoryProvider: { nil },
            attentionNotificationHandler: { _, session in
                notified.append(session.agentActivityState)
            }
        )
        defer {
            session.stop()
        }

        session.noteNativeHostInput(event: try #require(returnKeyEvent()))
        session.ingestTestingData(screenData(["• Working (2s • esc to interrupt)", "", "› "]))
        try await Task.sleep(for: .milliseconds(300))
        session.ingestTestingData(screenData(AgentScreenActivityTests.codexApproval))
        try await Task.sleep(for: .milliseconds(1_250))
        #expect(session.agentActivityState == .permission)
        #expect(session.attentionClassifierPrediction?.isRaisedByAnswerMenu == true)
        #expect(notified == [.permission])
        #expect(TerminalNotificationCenter.attentionBody(for: .permission).contains("permission"))
        #expect(TerminalNotificationCenter.attentionBody(for: .needsInput).contains("question"))
    }

    @Test func menuBarCountsAQuestionAsAttention() {
        let item = MenuBarAgentItem(
            id: UUID(), projectRoot: "/project", title: "Claude", agentKey: "claude", activity: .needsInput
        )
        #expect(MenuBarAggregateState(items: [item]) == .attention)
        #expect(AgentActivityState.needsInput.rawValue == "needs_input")
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

    @Test func noTurnSubmittedYetNeverNeedsAttention() {
        // A fresh agent at its composer or a startup dialog (folder trust,
        // resume picker): users corrected these to "idle / no active task".
        let timing = TerminalAttentionObservation.TimingContext(
            millisecondsSinceStarted: 60_000,
            millisecondsSinceLastOutput: 1_000,
            millisecondsSinceLastContentChange: 1_000,
            millisecondsSinceLastHumanInput: 5_000
        )
        let fresh = TerminalAttentionClassifier.shared.predict(fixture(
            event: .activityStateChanged,
            activityState: "idle",
            evidence: "prompt_marker",
            grid: ["❯ 1. Yes, I trust this folder", "  2. No, exit"],
            hasUnsubmittedInput: false,
            millisecondsSinceLastKeystroke: 5_000,
            terminalFocused: false,
            timing: timing,
            turnState: .notStarted
        ))
        #expect(fresh.attentionProbability >= 0.5)
        #expect(!fresh.needsAttention)
        #expect(fresh.label == .noAttentionNeeded)
        #expect(fresh.confidence == 1)
        #expect(fresh.debugReport.contains("Gate: no turn submitted yet"))

        let finished = TerminalAttentionClassifier.shared.predict(fixture(
            event: .activityStateChanged,
            activityState: "idle",
            evidence: "prompt_marker",
            grid: ["• Result ready", "› "],
            hasUnsubmittedInput: false,
            millisecondsSinceLastKeystroke: 5_000,
            terminalFocused: false,
            timing: timing,
            turnState: .completed
        ))
        #expect(finished.needsAttention)
    }

    @Test func liveWorkOnScreenNeverNeedsAttention() {
        // A completed turn's agent back at work by itself: the model alone
        // scored it just over the threshold.
        let timing = TerminalAttentionObservation.TimingContext(
            millisecondsSinceStarted: 11_867_400,
            millisecondsSinceLastOutput: 0,
            millisecondsSinceLastContentChange: 0,
            millisecondsSinceLastHumanInput: 11_201_085
        )
        for evidence in ["working_marker", "title_spinner"] {
            let prediction = TerminalAttentionClassifier.shared.predict(fixture(
                event: .contentChanged,
                activityState: "working",
                evidence: evidence,
                grid: ["✻ Frosting… (1m 28s · ↓ 585 tokens)", "❯ "],
                hasUnsubmittedInput: false,
                millisecondsSinceLastKeystroke: 11_201_085,
                terminalFocused: false,
                timing: timing,
                turnState: .completed
            ))
            #expect(!prediction.needsAttention)
            #expect(prediction.isGatedByLiveWork)
        }

        let weak = TerminalAttentionClassifier.shared.predict(fixture(
            event: .contentChanged,
            activityState: "working",
            evidence: "output_activity",
            grid: ["❯ "],
            hasUnsubmittedInput: false,
            millisecondsSinceLastKeystroke: 1_000,
            terminalFocused: false,
            timing: timing,
            turnState: .completed
        ))
        #expect(!weak.isGatedByLiveWork)
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
