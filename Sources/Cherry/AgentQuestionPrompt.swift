import Foundation

/// Recognizes an agent CLI asking the user a question with a choice menu
/// (Claude Code's AskUserQuestion, Codex's request_user_input picker) at
/// the bottom of its screen, for an agent that reports no status (one that
/// does says it is blocked on a question, OSC 7501). MCP input is refused
/// there, since Enter picks the highlighted option.
///
/// Only a menu counts, not prose: the last lines must hold at least two
/// numbered options, one of them marked by a selection cursor, and, below
/// the first option and among the last few lines, a phrase only such
/// pickers show ("enter to select", "↑/↓ to navigate", "type something",
/// …). A numbered list in an agent's answer, or a numbered message the
/// user sent (echoed after a `›`/`❯`), has no such footer under it, and an
/// empty composer under the options means they are transcript. A
/// permission menu (`AgentPermissionPrompt`) is checked first by every
/// caller and is not a question.
///
/// Also one of the menus `AgentScreenActivity` tells from a composer when a
/// task's kickoff is typed.
enum AgentQuestionPrompt {
    private static let pickerPhrases = [
        "enter to select",
        "enter to confirm",
        "enter to submit",
        "to navigate",
        "type something",
        "chat about this",
        "esc to cancel"
    ]

    private static let cursors: Set<Character> = ["❯", "›", "▶", "▸", "►", "→", "➤", ">"]

    /// How many of the last non-blank lines may hold the picker phrase: the
    /// key-hint footer, or the last options ("Type something.", "Chat
    /// about this") just above it.
    static let footerLineLimit = 4

    /// Whether `lines` (a screen, oldest first) end with a question menu.
    static func isShowing(in lines: [String]) -> Bool {
        let tail = AgentPermissionPrompt.tail(of: lines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│┃║|").union(.whitespaces)) }
            .filter { !$0.isEmpty }
        guard !tail.isEmpty else { return false }
        let footerStart = max(0, tail.count - footerLineLimit)
        var optionCount = 0
        var hasSelectedOption = false
        var hasPickerPhrase = false
        for (index, trimmed) in tail.enumerated() {
            var isOption = false
            if let first = trimmed.first, cursors.contains(first),
               isNumberedOption(trimmed.dropFirst().drop { $0.isWhitespace }) {
                isOption = true
                hasSelectedOption = true
            } else if isNumberedOption(Substring(trimmed)) {
                isOption = true
            }
            if isOption {
                optionCount += 1
            } else if optionCount > 0, trimmed.count == 1, let first = trimmed.first, cursors.contains(first) {
                // An empty composer under the options: they are a
                // numbered message in the transcript, not a live menu.
                return false
            }
            // The phrase belongs to the menu: under its first option, at
            // the bottom of the screen.
            if !hasPickerPhrase, optionCount > 0, index >= footerStart {
                let lowered = trimmed.lowercased()
                hasPickerPhrase = pickerPhrases.contains { lowered.contains($0) }
            }
        }
        return optionCount >= 2 && hasSelectedOption && hasPickerPhrase
    }

    /// "1. Text" or "2) Text".
    private static func isNumberedOption(_ text: Substring) -> Bool {
        var index = text.startIndex
        var digits = 0
        while index < text.endIndex, text[index].isASCII, text[index].isNumber, digits < 2 {
            index = text.index(after: index)
            digits += 1
        }
        guard digits > 0, index < text.endIndex, text[index] == "." || text[index] == ")" else { return false }
        let next = text.index(after: index)
        return next < text.endIndex && text[next] == " "
    }
}
