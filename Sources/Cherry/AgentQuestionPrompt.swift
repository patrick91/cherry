import Foundation

/// Recognizes an agent CLI asking the user a question with a choice menu
/// (Claude Code's AskUserQuestion, Codex's request_user_input picker) at
/// the bottom of its screen. The agent's turn is paused on the answer: MCP
/// waits end with `needs_input` instead of waiting for a turn that cannot
/// end by itself, and MCP input is refused there, since Enter picks the
/// highlighted option.
///
/// Only a menu counts, not prose: the last lines must hold at least two
/// numbered options, one of them marked by a selection cursor, and a
/// phrase only such pickers show ("enter to select", "↑/↓ to navigate",
/// "type something", …). A permission menu (`AgentPermissionPrompt`) is
/// checked first by every caller and is not a question.
///
/// MCP-side only: the app's activity state machine and the attention
/// classifier do not use it.
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

    /// Whether `lines` (a screen, oldest first) end with a question menu.
    static func isShowing(in lines: [String]) -> Bool {
        let tail = AgentPermissionPrompt.tail(of: lines)
        guard !tail.isEmpty else { return false }
        var optionCount = 0
        var hasSelectedOption = false
        var hasPickerPhrase = false
        for line in tail {
            let trimmed = line
                .trimmingCharacters(in: CharacterSet(charactersIn: "│┃║|").union(.whitespaces))
            guard !trimmed.isEmpty else { continue }
            if let first = trimmed.first, cursors.contains(first) {
                let rest = trimmed.dropFirst().drop { $0.isWhitespace }
                if isNumberedOption(rest) {
                    optionCount += 1
                    hasSelectedOption = true
                    continue
                }
            }
            if isNumberedOption(Substring(trimmed)) {
                optionCount += 1
            }
            if !hasPickerPhrase {
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
