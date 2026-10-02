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

    // MARK: Menus waiting on the user's answer

    /// Claude Code's AskUserQuestion, short: the cursor on the first option.
    static let claudeShortQuestion = [
        "⏺ I need one decision before I continue.",
        "",
        "────────────────────────────────────────────────",
        " ☐ Storage",
        "",
        "Which storage backend should I use?",
        "",
        "❯ 1. SQLite",
        "     Embedded, no server",
        "  2. Postgres",
        "     Needs a running server",
        "  3. Type something.",
        "────────────────────────────────────────────────",
        "  4. Chat about this",
        "",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ]

    /// Claude Code's AskUserQuestion, tall: several questions, long
    /// descriptions, the cursor moved to the third option, which sits well
    /// above the last 8 lines.
    static let claudeTallQuestion = [
        "⏺ Read(Sources/App/Store.swift)",
        "  ⎿  Read 412 lines",
        "",
        "⏺ Before I migrate the store I need to know how you want it done.",
        "",
        "────────────────────────────────────────────────────────────────",
        " ←  ☒ Storage  ☐ Migration  ✔ Submit  →",
        "",
        "How should existing data be migrated?",
        "",
        "  1. In place",
        "     Rewrite the tables on first launch. Fast, but a crash midway",
        "     leaves a half-migrated database.",
        "  2. Copy, then swap",
        "     Write a new database next to the old one and swap them when",
        "     the copy is complete. Needs twice the disk space.",
        "❯ 3. Export and re-import",
        "     Dump everything to JSON and import it into a fresh database.",
        "     Slowest, but the old file is never touched.",
        "  4. Don't migrate",
        "     Start with an empty database and keep the old file aside.",
        "  5. Type something.",
        "────────────────────────────────────────────────────────────────",
        "  6. Chat about this",
        "",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ]

    /// Codex's request_user_input picker: its footer still offers "esc to
    /// interrupt", which must not make it look at work.
    static let codexQuestion = [
        "• I can take this two ways.",
        "",
        "  Question 1/1",
        "  Which test runner should the new suite use?",
        "",
        "› 1. Swift Testing  Matches the rest of the package",
        "  2. XCTest         Works with the older CI image",
        "  3. None of the above  Optionally, add details in notes (tab)",
        "",
        "  tab to add notes | enter to submit answer | esc to interrupt",
    ]

    /// Codex asking to run a command: a permission menu.
    static let codexApproval = [
        "• I'll clean the build directory first.",
        "",
        "  Would you like to run the following command?",
        "",
        "  $ rm -rf build",
        "",
        "› 1. Yes, proceed (y)",
        "  2. Yes, and don't ask again for this command (p)",
        "  3. No, and tell Codex what to do differently (esc)",
        "",
        "  Press enter to confirm or esc to cancel",
    ]

    @Test func claudeQuestionMenusWaitOnTheUser() {
        #expect(verdict(Self.claudeShortQuestion, "claude") == .question)
        #expect(verdict(Self.claudeTallQuestion, "claude") == .question)
        #expect(Self.claudeTallQuestion.count > AgentScreenActivity.promptTailLineLimit + 8)
        // Trailing blank rows (a parked cursor) change nothing.
        #expect(verdict(Self.claudeTallQuestion + ["", "", ""], "claude") == .question)
        // The agent key does not matter: the recognizer is the same for all.
        #expect(verdict(Self.claudeShortQuestion, "fixture") == .question)
        #expect(AgentScreenActivity.answerMenu(in: Self.claudeTallQuestion) == .question)
        // A question outranks a background task row still at work.
        let withTask = Self.claudeShortQuestion.dropLast() + [
            "  ◯ general-purpose  Reading holder.rs",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        #expect(verdict(Array(withTask), "claude") == .question)
    }

    @Test func codexQuestionAndApprovalWaitOnTheUser() {
        #expect(verdict(Self.codexQuestion, "codex") == .question)
        #expect(verdict(Self.codexApproval, "codex") == .permission)
        #expect(AgentScreenActivity.answerMenu(in: Self.codexApproval) == .permission)
    }

    @Test func aMenuAnsweredLongAgoNoLongerCounts() {
        let scrolledAway = Self.claudeShortQuestion + Array(repeating: "  output line", count: 30) + claudeComposer
        #expect(verdict(scrolledAway, "claude") == .prompt)
        // The menu gone and the turn going on.
        let answered = [
            "⏺ User answered Claude's questions:",
            "  ⎿  · Which storage backend should I use? → SQLite",
            "",
            "✶ Reticulating… (3s · ↓ 120 tokens)",
            "",
        ] + claudeComposer + ["  esc to interrupt"]
        #expect(verdict(answered, "claude") == .working)
    }

    @Test func numberedProseIsNoMenu() {
        // An agent's answer with numbered lists, at its composer.
        let claudeAnswer = [
            "⏺ Here is the plan:",
            "",
            "  1. Move the store behind a protocol.",
            "  2. Add the SQLite backend.",
            "  3. Migrate the existing data.",
            "",
            "  Press Enter to select a default in the settings, or use ↑/↓ to navigate.",
            "",
            "✻ Worked for 41s",
            "",
        ] + claudeComposer + ["  ? for shortcuts"]
        #expect(verdict(claudeAnswer, "claude") == .prompt)
        #expect(AgentScreenActivity.answerMenu(in: claudeAnswer) == nil)

        // The user's own numbered message echoed after the prompt glyph.
        let echoedMessage = [
            "❯ 1. fix the flaky test",
            "  2. then add a regression test",
            "",
            "⏺ On it.",
            "",
            "✶ Reticulating… (3s · ↓ 120 tokens)",
            "",
        ] + claudeComposer + ["  esc to interrupt"]
        #expect(verdict(echoedMessage, "claude") == .working)

        let codexEcho = [
            "› 1. rename the module",
            "  2. update the imports",
            "",
            "• Working (8s • esc to interrupt)",
            "",
            "› ",
            "",
            "  enter to submit · esc to cancel",
        ]
        #expect(verdict(codexEcho, "codex") == .working)

        // A picker phrase above the options belongs to prose, not a footer.
        let phraseAbove = [
            "Use enter to select one of these:",
            "❯ 1. First",
            "  2. Second",
            "  3. Third",
            "  4. Fourth",
            "  5. Fifth",
        ]
        #expect(AgentScreenActivity.answerMenu(in: phraseAbove) == nil)

        // A Claude composer draft that starts with a number.
        let draft = [
            "⏺ Done.",
            "",
            "────────────────────────────────────────",
            "❯ 1. and also the docs",
            "  2. and the changelog",
            "────────────────────────────────────────",
            "  ⏵⏵ accept edits on (shift+tab to cycle)",
        ]
        #expect(verdict(draft, "claude") == .prompt)
    }

    @Test func piAndAmpScreensHaveNoQuestionMenus() {
        // Pi's selectors (model, resume) are not numbered and come from
        // the user's own commands.
        let piSelector = [
            " Select model",
            " → claude-sonnet-4-5   anthropic",
            "   gpt-5               openai",
            "   gemini-2.5-pro      google",
            "",
            " ↑↓ navigate · enter select · esc cancel",
        ]
        #expect(AgentScreenActivity.answerMenu(in: piSelector) == nil)
        #expect(verdict(piSelector, "pi") == .prompt)

        let ampAnswer = ["Options:", "1. Keep it", "2. Drop it", ""] + ampBox("")
        #expect(AgentScreenActivity.answerMenu(in: ampAnswer) == nil)
        #expect(verdict(ampAnswer, "amp") == .prompt)
    }

    @Test func startupDialogBeforeTheFirstTurnIsAPromptNotAQuestion() {
        let trust = [
            " Do you trust the files in this folder?",
            "",
            " /project",
            "",
            " ❯ 1. Yes, proceed",
            "   2. No, exit",
            "",
            " Enter to confirm · Esc to exit",
        ]
        #expect(verdict(trust, "claude") == .question)
        #expect(AgentScreenActivity.verdict(for: trust, agent: "claude", includesAnswerMenus: false) == .prompt)
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
