import Foundation

/// Recognizes an agent CLI's tool-permission prompt (a numbered menu asking
/// the user to approve a command, an edit or a fetch) at the bottom of its
/// screen. Typing into such a menu answers it: Enter (and, for some CLIs,
/// letters such as `y`) approves the pending action. MCP input to an agent
/// that reports no status (one that does says it is blocked on a
/// permission, OSC 7501) therefore never goes into one
/// (`CherryControlServer.refuseInputIntoPermissionPrompt`).
///
/// Only the menu counts, not prose about one: the last lines must hold a
/// numbered "Yes…" option and a numbered "No…" option, plus a phrase only
/// permission menus use ("…what to do differently", "don't ask again",
/// "allow once/always", …). Startup prompts such as "Do you trust the
/// files in this folder?" (whose Enter Cherry may press for an agent it
/// just started) are not permission prompts.
enum AgentPermissionPrompt {
    /// How many of the screen's last lines (blank ones at the bottom
    /// ignored) are looked at: more than the tallest permission box.
    static let tailLineLimit = 30

    /// Phrases that appear in tool-permission menus (Claude Code, Codex,
    /// Gemini and similar CLIs) and not in their startup or trust prompts.
    private static let permissionPhrases = [
        "what to do differently",
        "don't ask again",
        "allow once",
        "allow always",
        "allow for this session",
        "allow all edits",
        "suggest changes",
        "provide feedback",
        "would you like to run the following command",
        "would you like to make the following edits",
        "do you want to make this edit",
        "do you want to allow",
        // Plan approval: Enter starts the plan's edits.
        "keep planning",
        "auto-accept edits",
        "manually approve edits"
    ]

    /// Characters that frame or mark a menu line: box drawing, selection
    /// cursors and bullets.
    private static let decoration = CharacterSet(charactersIn: "│┃║╎╏┆┇┊┋|▌▐❯›»>▶▸►⏵→➤●○◉◯◦•*✔✓")
        .union(.whitespaces)

    /// Whether `lines` (a screen, oldest first) end with a permission menu.
    static func isShowing(in lines: [String]) -> Bool {
        let tail = Self.tail(of: lines)
        guard !tail.isEmpty else { return false }
        var hasYesOption = false
        var hasNoOption = false
        var hasPermissionPhrase = false
        for line in tail {
            let normalized = normalize(line)
            guard !normalized.isEmpty else { continue }
            if let option = optionText(normalized) {
                if option.hasPrefix("yes") { hasYesOption = true }
                if option == "no" || option.hasPrefix("no,") || option.hasPrefix("no ") || option.hasPrefix("no(") {
                    hasNoOption = true
                }
            }
            if !hasPermissionPhrase, permissionPhrases.contains(where: { normalized.contains($0) }) {
                hasPermissionPhrase = true
            }
        }
        return hasYesOption && hasNoOption && hasPermissionPhrase
    }

    /// The last `tailLineLimit` lines, blank lines at the bottom dropped.
    static func tail(of lines: [String]) -> ArraySlice<String> {
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return lines[max(0, end - tailLineLimit)..<end]
    }

    /// Lowercased, decoration trimmed from both ends, typographic
    /// apostrophes made plain and runs of whitespace collapsed.
    private static func normalize(_ line: String) -> String {
        let plain = line
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .lowercased()
            .trimmingCharacters(in: decoration)
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The text of a numbered menu option ("2. yes, and don't ask again" →
    /// "yes, and don't ask again"); nil for any other line.
    private static func optionText(_ normalized: String) -> String? {
        var index = normalized.startIndex
        var digits = 0
        while index < normalized.endIndex, normalized[index].isASCII, normalized[index].isNumber, digits < 2 {
            index = normalized.index(after: index)
            digits += 1
        }
        guard digits > 0, index < normalized.endIndex,
              normalized[index] == "." || normalized[index] == ")"
        else { return nil }
        let rest = normalized[normalized.index(after: index)...]
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }
}
