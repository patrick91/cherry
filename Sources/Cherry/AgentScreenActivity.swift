import Foundation

/// What an agent CLI's screen says about its turn: the screen-text half of
/// `TerminalSession`'s activity state machine (titles, notifications, input
/// and timing are the other half). Pure functions over screen lines so the
/// rules can be replayed against recorded observations and fixtures.
///
/// `agent` is the normalized agent key (`claude`, `codex`, `pi`, `amp`, …).
enum AgentScreenActivity {
    /// Lines (from the last non-blank one up) searched for working and
    /// harness-specific input markers.
    static let markerTailLineLimit = 32
    /// Lines (from the last non-blank one up) searched for a composer prompt.
    static let promptTailLineLimit = 8

    enum Verdict: String, Equatable, Sendable {
        /// The screen asks the user to approve an action
        /// (`AgentPermissionPrompt`).
        case permission
        /// The screen asks the user a question with a choice menu
        /// (`AgentQuestionPrompt`).
        case question
        /// The screen shows a turn in flight.
        case working
        /// The screen shows the agent waiting at its composer or a menu.
        case prompt
        /// The screen says neither.
        case none
    }

    /// Classifies a whole screen (oldest line first), the way the session's
    /// state machine reads it when no human-input floor applies.
    /// `includesAnswerMenus` false reads it as before the tab's first turn,
    /// when a menu is a startup dialog, not a paused turn.
    static func verdict(for screen: [String], agent: String, includesAnswerMenus: Bool = true) -> Verdict {
        var end = screen.count
        while end > 0, screen[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }
        guard end > 0 else { return .none }
        let markerLines = Array(screen[max(0, end - markerTailLineLimit)..<end])
        switch includesAnswerMenus ? answerMenu(in: markerLines) : nil {
        case .permission?: return .permission
        case .question?: return .question
        case nil: break
        }
        if showsWorkingMarker(markerLines, agent: agent) {
            return .working
        }
        let promptLines = markerLines.suffix(promptTailLineLimit)
        if promptLines.contains(where: { isInputPromptLine($0, agent: agent) })
            || showsInputMarker(markerLines, agent: agent) {
            return .prompt
        }
        return .none
    }

    // MARK: - Menus waiting on the user's answer

    /// A menu at the bottom of an agent's screen that its turn waits on.
    enum AnswerMenu: String, Equatable, Sendable {
        /// A tool-permission (approval) menu: `AgentPermissionPrompt`.
        case permission
        /// A question with a choice menu (Claude's AskUserQuestion,
        /// Codex's request_user_input): `AgentQuestionPrompt`.
        case question
    }

    /// The menu `lines` (a screen's tail, oldest first) end with, if any.
    /// It outranks working markers: the turn is paused on the user's
    /// answer even while a footer still says "esc to interrupt" or a
    /// background task row shows work. The recognizers are the ones MCP
    /// uses, so the sidebar and MCP agree.
    static func answerMenu(in lines: [String]) -> AnswerMenu? {
        if AgentPermissionPrompt.isShowing(in: lines) { return .permission }
        if AgentQuestionPrompt.isShowing(in: lines) { return .question }
        return nil
    }

    // MARK: - Composer prompts

    static func isInputPromptLine(_ line: String, agent: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if isPromptLine(trimmed, prompt: "\u{203A}") ||
            isPromptLine(trimmed, prompt: "\u{00BB}") ||
            isPromptLine(trimmed, prompt: "\u{276F}") {
            return true
        }

        if agent == "claude" || agent == "gemini" || agent == "pi" {
            return isPromptLine(trimmed, prompt: ">")
        }

        return false
    }

    // Claude Code separates the composer glyph from its ghost text with a
    // no-break space, so any Unicode whitespace counts as the separator.
    private static func isPromptLine(_ trimmed: String, prompt: String) -> Bool {
        guard trimmed.hasPrefix(prompt) else { return false }
        let rest = trimmed.dropFirst(prompt.count)
        guard let next = rest.first else { return true }
        return next.isWhitespace
    }

    /// Harness-specific screens that wait for the user without a plain
    /// composer prompt line.
    static func showsInputMarker(_ lines: [String], agent: String) -> Bool {
        if showsKeyHintMenu(lines) {
            return true
        }
        if agent == "amp", ampComposerBox(in: lines) != nil {
            return true
        }

        let output = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\n")

        switch agent {
        case "gemini":
            return output.contains("do you trust this folder?")
                || output.contains("how would you like to authenticate for this project?")
        case "opencode":
            return output.contains("ask anything...")
        case "pi":
            return output.contains("press ctrl+o to show full startup help")
                || output.contains("pi can explain its own features")
        default:
            return false
        }
    }

    /// A full-screen picker or dialog whose key-hint footer offers both Enter
    /// and Esc ("enter resume   esc exit", "Enter to confirm · Esc to
    /// cancel"): it waits for the user's choice. Only the last few lines
    /// count, so hints quoted in a transcript do not.
    private static func showsKeyHintMenu(_ lines: [String]) -> Bool {
        let footer = nonBlankSuffix(lines, count: 3)
        return footer.contains { line in
            let words = line.lowercased()
                .split { !$0.isLetter }
                .map(String.init)
            guard let enter = words.firstIndex(of: "enter"),
                  let escape = words.firstIndex(where: { $0 == "esc" || $0 == "escape" })
            else { return false }
            return enter + 1 < words.count && escape + 1 < words.count
                && !words.contains("interrupt")
        }
    }

    // MARK: - Working markers

    // Claude Code 2.x and Codex both surface "esc to interrupt" only while a
    // turn is in flight; older Codex status lines ("Working (Xs · esc to
    // interrupt)") contained it too. Markers must never trust transcript PROSE:
    // an agent narrating its own work ("~3–5% while working (0% idle)") pinned
    // its session to "working" forever, so there is no bare "working (" match.
    private static let claudeSpinnerGlyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "∗", "*"]

    static func showsWorkingMarker(_ lines: [String], agent: String) -> Bool {
        !workingLines(lines, agent: agent).isEmpty
    }

    /// The lines of `lines` (a screen's tail, oldest first) that show a turn
    /// in flight, trimmed, oldest first: the evidence `showsWorkingMarker`
    /// finds. While the agent works their text advances (a spinner glyph,
    /// an elapsed counter, a token meter) where they stand; a repaint of a
    /// finished screen leaves them frozen (`AgentResumedWorkDetector`).
    static func workingLines(_ lines: [String], agent: String) -> [String] {
        workingLineIndices(lines, agent: agent).map { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The indices in `lines` of its `workingLines`, ascending.
    static func workingLineIndices(_ lines: [String], agent: String) -> [Int] {
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var live = IndexSet(trimmedLines.indices.filter { showsInterruptHint(trimmedLines[$0]) })

        switch agent {
        case "pi":
            live.formUnion(IndexSet(trimmedLines.indices.filter { isPiSpinnerStatus(trimmedLines[$0]) }))
        case "amp":
            if let border = ampComposerBoxIndex(in: lines), ampStatusIsLive(trimmedLines[border]) {
                live.insert(border)
            }
        case "claude":
            live.formUnion(claudeLiveWorkLineIndices(trimmedLines))
        default:
            break
        }
        return Array(live)
    }

    /// "esc to interrupt", also when a narrow footer truncates it
    /// ("esc to interr…", "esc to …").
    private static func showsInterruptHint(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.contains("esc to interrupt") {
            return true
        }
        guard let range = lowered.range(of: "esc to ", options: .backwards) else { return false }
        let rest = lowered[range.upperBound...]
        guard rest.hasSuffix("…") || rest.hasSuffix("...") else { return false }
        let fragment = rest
            .trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespaces))
        return "interrupt".hasPrefix(fragment)
    }

    // MARK: Claude Code

    /// Claude Code's live work: its newest status line is in flight, or its
    /// task switcher lists a background agent or workflow at work. Claude
    /// keeps the composer up throughout, so the prompt never says idle.
    ///
    /// A background *shell* is not work: "✻ Worked for 3m · 1 shell still
    /// running" ends a turn whose result is ready (dev servers and watchers
    /// outlive turns), so only agents and workflows keep the session working.
    /// Returns the indices of those lines: the newest status line when it
    /// is live, and each live task row.
    private static func claudeLiveWorkLineIndices(_ lines: [String]) -> IndexSet {
        var live = IndexSet(lines.indices.filter { isLiveClaudeTaskRow(lines[$0]) })
        if let status = lines.lastIndex(where: isClaudeStatusLine), claudeStatusIsLive(lines[status]) {
            live.insert(status)
        }
        return live
    }

    private static func isClaudeStatusLine(_ line: String) -> Bool {
        guard let first = line.first, claudeSpinnerGlyphs.contains(first) else { return false }
        let rest = line.dropFirst()
        guard rest.first?.isWhitespace == true else { return false }
        return rest.drop(while: \.isWhitespace).first?.isUppercase == true
    }

    /// The newest status line ("✻ Frosting… (1m 28s · ↓ 585 tokens)",
    /// "✻ Waiting for 1 background agent to finish") rather than a finished
    /// one ("✻ Cooked for 4s", "✻ Worked for 3m 10s · done 11:05"). Older
    /// status lines above it are transcript and never count.
    private static func claudeStatusIsLive(_ line: String) -> Bool {
        let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
        let lowered = text.lowercased()
        let firstWord = text.prefix { !$0.isWhitespace }
        if firstWord.hasSuffix("…") || firstWord.hasSuffix("...") {
            return true
        }
        if lowered.hasPrefix("waiting for"), lowered.contains("to finish") {
            return true
        }
        return lowered.contains("whisking") || lowered.contains("still thinking")
    }

    /// A row of Claude's task switcher ("◯ <name>  <activity>  <meter>")
    /// for a background agent or workflow at work: it shows a live
    /// elapsed/token meter ("16m 22s · ↓ 169.2k tokens"), a progress bar, or
    /// what it is doing now ("Reading holder.rs"). Narrow screens drop the
    /// meter, so the activity alone counts. A row that only repeats its
    /// task's command ("◯ code-review  /code-review 4402") does not.
    private static func isLiveClaudeTaskRow(_ line: String) -> Bool {
        guard line.hasPrefix("◯") else { return false }
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        if (body.contains("· ↑") || body.contains("· ↓")), body.lowercased().contains(" tokens") {
            return true
        }
        if body.contains("█") || body.contains("░") {
            return true
        }
        let columns = body.components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard columns.count >= 2 else { return false }
        return isProgressiveVerb(columns[1].prefix { !$0.isWhitespace })
    }

    /// "Reading", "Updating", "Inspecting": a capitalized -ing word.
    private static func isProgressiveVerb(_ word: Substring) -> Bool {
        guard word.count > 4, word.first?.isUppercase == true else { return false }
        return word.hasSuffix("ing") && word.allSatisfy(\.isLetter)
    }

    // MARK: Pi

    /// Pi's status line: a braille spinner frame and an in-progress status
    /// ("⠋ Working...", "⠧ Auto-compacting... (escape to cancel)").
    private static func isPiSpinnerStatus(_ line: String) -> Bool {
        guard let first = line.unicodeScalars.first, (0x2800...0x28FF).contains(Int(first.value)) else {
            return false
        }
        let status = line.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
        return status.contains("...") || status.contains("…") || status.contains("escape to cancel")
    }

    // MARK: Amp

    /// Amp keeps a framed composer at the bottom of its screen (`╭─…─╮`,
    /// `│ … │` rows, `╰ <status> ─…─╯`); returns its bottom border.
    private static func ampComposerBox(in lines: [String]) -> String? {
        ampComposerBoxIndex(in: lines).map { lines[$0].trimmingCharacters(in: .whitespaces) }
    }

    /// The index in `lines` of Amp's composer's bottom border (above).
    private static func ampComposerBoxIndex(in lines: [String]) -> Int? {
        let nonBlank = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        func starts(_ index: Int, with prefix: String) -> Bool {
            lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }
        guard let bottom = nonBlank.suffix(3).last(where: { starts($0, with: "╰") }),
              nonBlank.suffix(12).contains(where: { starts($0, with: "╭") })
        else { return nil }
        return bottom
    }

    /// Amp's composer border names what it is doing while a turn runs
    /// ("╰ ∼ Thinking 27 tok ───"); idle borders are empty or show hints
    /// ("Enter to Reference Previous Thread", "◌ Reconnecting in 27s").
    private static let ampLiveStatusWords: Set<String> = [
        "thinking", "running", "streaming", "generating", "responding", "working"
    ]

    private static func ampStatusIsLive(_ bottomBorder: String) -> Bool {
        let label = bottomBorder.dropFirst()
            .prefix { $0 != "─" }
            .lowercased()
        let words = label.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if let tok = words.firstIndex(of: "tok"), tok > 0, words[tok - 1].allSatisfy(\.isNumber) {
            return true
        }
        return words.contains { ampLiveStatusWords.contains($0) }
    }

    // MARK: -

    /// The last `count` non-blank lines, trimmed.
    private static func nonBlankSuffix(_ lines: [String], count: Int) -> [String] {
        Array(
            lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(count)
        )
    }

    /// The key the screen rules use for an agent: its configured name when
    /// that is a known harness, else the harness its name or command line
    /// names ("Claude (yolo)" or `claude --resume` → `claude`).
    static func agentKey(name: String?, commandLine: String?) -> String {
        let normalized = AgentToolDefinition.normalizedName(name ?? "")
        if AgentToolBrand(rawValue: normalized) != nil {
            return normalized
        }
        return AgentToolBrand.detect(name: name, commandLine: commandLine)?.rawValue ?? normalized
    }
}
