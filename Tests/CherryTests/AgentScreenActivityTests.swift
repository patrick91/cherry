import Foundation
import Testing
@testable import Cherry

/// Synthetic, sanitized screens reproducing each pattern found in the
/// users' attention corrections (2026-07-31 … 2026-10-01). Each screen is
/// the bottom of a terminal, oldest line first.
struct AgentScreenActivityTests {
    private func verdict(_ screen: [String], _ agent: String) -> AgentScreenActivity.Verdict {
        AgentScreenActivity.verdict(for: screen, agent: agent)
    }

    private let claudeComposer = [
        "────────────────────────────────────────",
        "❯ ",
        "────────────────────────────────────────",
    ]

    // MARK: Claude: a background shell is not work

    @Test func claudeFinishedTurnWithBackgroundShellIsAtPrompt() {
        let screen = [
            "⏺ Done. The fix is merged and the summary is above.",
            "",
            "✻ Worked for 3m 10s · done 11:05 · 1 shell still running",
            "",
            "※ recap: The fix is merged. Next: review the follow-up.",
        ] + claudeComposer + [
            "  ⏵⏵ bypass permissions on · 1 shell · ← for agents · ↓ to manage",
        ]
        #expect(verdict(screen, "claude") == .prompt)

        let shellAndMonitor = [
            "✻ Baked for 1s · done 12:25 · 1 shell, 1 monitor still running",
        ] + claudeComposer
        #expect(verdict(shellAndMonitor, "claude") == .prompt)
    }

    // MARK: Claude: background agents and workflows in the task switcher

    @Test func claudeTaskRowWithDownArrowMeterIsWorking() {
        let screen = claudeComposer + [
            "  ⏵⏵ bypass permissions on · ← for agents · ↓ to manage",
            "",
            "  ⏺ main",
            "  ◯ code-review  Inspecting the retry handler                    1m 8s · ↓ 56.3k tokens",
        ]
        #expect(verdict(screen, "claude") == .working)
    }

    @Test func claudeWorkflowRowWithProgressBarIsWorking() {
        let screen = [
            "✻ Waiting for 1 dynamic workflow to finish",
        ] + claudeComposer + [
            "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents",
            "",
            "  ◯ fix-wave-2  █████████████████░░░  8/9 · 1h39m · ↓ 2.7m tokens",
        ]
        #expect(verdict(screen, "claude") == .working)
    }

    @Test func claudeNarrowTaskRowShowsOnlyItsActivity() {
        // Narrow screens drop the meter; the row still says what it does.
        let screen = [
            "✻ Baked for 1s · done 12:25",
        ] + claudeComposer + [
            "  ⏵⏵ bypass permissions on · ← for agents · ↓ to manage",
            "",
            "  ⏺ main",
            "  ◯ general-purpose  Updating the close-flow tests",
        ]
        #expect(verdict(screen, "claude") == .working)
    }

    @Test func claudeTaskRowRepeatingItsCommandIsNotWork() {
        let screen = claudeComposer + [
            "  ⏵⏵ bypass permissions on · ← for agents · ↓ to manage",
            "",
            "  ⏺ main",
            "  ◯ code-review  /code-review 4402",
        ]
        #expect(verdict(screen, "claude") == .prompt)
    }

    // MARK: Claude: the newest status line

    @Test func claudeWaitingForBackgroundAgentIsWorkingOnlyAsNewestStatus() {
        let waiting = [
            "⏺ I'll report when the background agent finishes.",
            "",
            "✻ Waiting for 1 background agent to finish",
            "",
        ] + claudeComposer
        #expect(verdict(waiting, "claude") == .working)

        let answeredSince = [
            "✻ Waiting for 1 background agent to finish",
            "",
            "⏺ Agent \"Fix the gaps\" finished · 21m 10s",
            "⏺ All fixed and committed.",
            "",
            "✻ Cooked for 4s",
            "",
        ] + claudeComposer
        #expect(verdict(answeredSince, "claude") == .prompt)
    }

    @Test func claudeInFlightStatusWithTruncatedFooterIsWorking() {
        let screen = [
            "⏺ Committing the change · 1m 22s",
            "",
            "✻ Frosting… (1m 28s · ↓ 585 tokens)",
            "",
        ] + claudeComposer + [
            "  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to …",
        ]
        #expect(verdict(screen, "claude") == .working)

        let footerOnly = claudeComposer + [
            "  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interr…",
        ]
        #expect(verdict(footerOnly, "claude") == .working)

        let statusOnly = ["✶ Contemplating… (2m 44s · ↓ 3.1k tokens)", ""] + claudeComposer
        #expect(verdict(statusOnly, "claude") == .working)
    }

    @Test func claudeProseIsNeverAWorkingMarker() {
        let screen = [
            "⏺ The daemon uses ~3–5% CPU while working (0% idle).",
            "  Press esc to cancel the export if it hangs.",
            "  - Reading the logs… found nothing.",
            "",
            "✻ Worked for 12s",
            "",
        ] + claudeComposer + [
            "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents",
        ]
        #expect(verdict(screen, "claude") == .prompt)
    }

    // MARK: Pi

    @Test func piCompactionSpinnerIsWorking() {
        let screen = [
            " Took 0.3s",
            "",
            " ⠧ Auto-compacting... (escape to cancel)",
            "",
            "  model  think:max   project   branch   256k/272k (94.3%)",
            " ──────────────────────────────────────",
            " >",
            " ──────────────────────────────────────",
            " ↳ a queued follow-up message",
        ]
        #expect(verdict(screen, "pi") == .working)

        var working = screen
        working[2] = " ⠙ Working..."
        #expect(verdict(working, "pi") == .working)

        var idle = screen
        idle.remove(at: 2)
        idle.removeLast()
        #expect(verdict(idle, "pi") == .prompt)
    }

    // MARK: Amp

    private func ampBox(_ status: String) -> [String] {
        [
            "╭──────────────────────────────────────── $0.004 ─ high ─╮",
            "│                                                        │",
            "│                                                        │",
            "╰ \(status)───────────────────── ~/project (main) ─╯",
        ]
    }

    @Test func ampIdleComposerBoxIsAPrompt() {
        let answer = ["I'd finish the current integration first.", ""]
        #expect(verdict(answer + ampBox(""), "amp") == .prompt)
        #expect(verdict(answer + ampBox("Enter to Reference Previous Thread "), "amp") == .prompt)
        #expect(verdict(answer + ampBox("◌ Reconnecting in 27s "), "amp") == .prompt)
    }

    @Test func ampBusyComposerBorderIsWorking() {
        let screen = ["✓ Ran 6 commands ▸", ""] + ampBox("∼ Thinking 27 tok ")
        #expect(verdict(screen, "amp") == .working)
    }

    // MARK: Pickers and dialogs

    @Test func resumePickerFooterWaitsForInput() {
        let screen = [
            "  Updated     Branch   Conversation",
            "› 2 days ago  main     Fix the flaky test",
            "──────────────────────────────────────────── 1 / 1 · 100% ─",
            " enter resume   esc exit   ctrl+c exit   tab focus sort/filter",
            " ctrl+o comfortable view   ctrl+t transcript   ↑/↓ browse",
        ]
        #expect(verdict(screen, "codex") == .prompt)

        let quoted = [
            "• The picker says \"enter resume   esc exit\" at the bottom.",
            "",
            "• Working (12s • esc to interrupt)",
            "",
            "",
            "› Summarize recent commits",
            "",
            "  model · ~/project",
        ]
        #expect(verdict(quoted, "codex") == .working)
    }

    // MARK: Agent keys

    @Test func agentKeyFallsBackToTheHarnessItNames() {
        #expect(AgentScreenActivity.agentKey(name: "Claude", commandLine: nil) == "claude")
        #expect(AgentScreenActivity.agentKey(name: "Claude (yolo)", commandLine: nil) == "claude")
        #expect(AgentScreenActivity.agentKey(name: "Reviewer", commandLine: "codex --yolo") == "codex")
        #expect(AgentScreenActivity.agentKey(name: "Pi", commandLine: nil) == "pi")
        #expect(AgentScreenActivity.agentKey(name: "My REPL", commandLine: "python3") == "my repl")
    }
}
