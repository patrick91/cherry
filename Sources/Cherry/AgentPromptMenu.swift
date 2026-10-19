import CherryControl
import Foundation

/// Reads the permission or question menu an agent CLI shows at the bottom
/// of its screen (one `AgentPermissionPrompt` or `AgentQuestionPrompt`
/// recognizes) into its options, for MCP: the refusals of input into it,
/// `needs_input`/`permission` events, get_process_status, and answer_prompt,
/// which picks one of them.
///
/// The options are the menu's last numbered run (1, 2, 3, …), the lines
/// between two options the first one's detail (Claude Code's descriptions
/// under each option), and a run of two or more spaces in an option's line
/// ends its label (Codex's descriptions beside it). The highlighted option
/// is the one a selection cursor marks; a menu may show none. The question
/// is the nearest line above the first option that ends with "?", else the
/// nearest line there.
enum AgentPromptMenu {
    static let maximumOptions = 20
    static let labelLimit = 200
    static let detailLimit = 300
    static let questionLimit = 300

    /// Characters that frame a menu's lines (box sides) and fill its
    /// separators.
    private static let frame = CharacterSet(charactersIn: "│┃║╎╏┆┇┊┋|▌▐")
    private static let separator = CharacterSet(charactersIn: "─━═┄┅┈┉╌╍-_╭╮╰╯┌┐└┘├┤")
    /// Marks of the highlighted option.
    private static let cursors: Set<Character> = ["❯", "›", "»", ">", "▶", "▸", "►", "→", "➤", "●", "◉"]
    /// Marks of an option that is not highlighted (radio buttons).
    private static let unselectedMarks: Set<Character> = ["○", "◯", "◦"]

    /// The menu `lines` (a screen, oldest first) end with; nil when they
    /// show none, or fewer than two options could be read.
    static func read(from lines: [String]) -> AgentPromptInfo? {
        let kind: String
        if AgentPermissionPrompt.isShowing(in: lines) {
            kind = AgentPromptInfo.permissionKind
        } else if AgentQuestionPrompt.isShowing(in: lines) {
            kind = AgentPromptInfo.questionKind
        } else {
            return nil
        }
        let tail = AgentPermissionPrompt.tail(of: lines).map(unframed)
        let parsed = tail.map(option)
        guard let start = parsed.lastIndex(where: { $0?.number == 1 }) else { return nil }

        var options: [(line: Int, option: ParsedOption)] = []
        for index in start..<tail.count {
            guard let option = parsed[index] else { continue }
            guard option.number == (options.last?.option.number ?? 0) + 1 else { break }
            options.append((index, option))
            if options.count == maximumOptions { break }
        }
        guard options.count >= 2 else { return nil }

        let infos = options.enumerated().map { position, entry in
            let detailEnd = position + 1 < options.count ? options[position + 1].line : entry.line + 1
            let detailLines = tail[(entry.line + 1)..<max(entry.line + 1, detailEnd)].filter { !isBlankOrSeparator($0) }
            let detail = ([entry.option.detail].compactMap { $0 } + detailLines).joined(separator: " ")
            return AgentPromptOption(
                number: entry.option.number,
                label: clip(entry.option.label, labelLimit),
                detail: detail.isEmpty ? nil : clip(detail, detailLimit),
                selected: entry.option.selected
            )
        }
        return AgentPromptInfo(kind: kind, question: question(above: start, in: tail), options: infos)
    }

    enum Match: Equatable {
        case option(AgentPromptOption)
        case ambiguous([AgentPromptOption])
        case none
    }

    /// The option `choice` names: its number, else its label without regard
    /// to case (the whole label, or the label without a trailing key hint
    /// such as "(esc)"), else a label it starts, else one it is part of.
    static func match(_ choice: String, in prompt: AgentPromptInfo) -> Match {
        let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed) {
            return prompt.options.first { $0.number == number }.map(Match.option) ?? .none
        }
        let wanted = normalized(trimmed)
        guard !wanted.isEmpty else { return .none }
        let tiers: [(String) -> Bool] = [
            { $0 == wanted },
            { $0.hasPrefix(wanted) },
            { $0.contains(wanted) }
        ]
        for matches in tiers {
            let found = prompt.options.filter { option in
                let label = normalized(option.label)
                return matches(label) || matches(withoutKeyHint(label))
            }
            if found.count == 1 { return .option(found[0]) }
            if found.count > 1 { return .ambiguous(found) }
        }
        return .none
    }

    /// The options as an error lists them: "1. Yes (selected); 2. No".
    static func describe(_ options: [AgentPromptOption]) -> String {
        options.map { "\($0.number). \($0.label)\($0.selected ? " (highlighted)" : "")" }.joined(separator: "; ")
    }

    // MARK: - Lines

    private struct ParsedOption {
        let number: Int
        let label: String
        let detail: String?
        let selected: Bool
    }

    private static func unframed(_ line: String) -> String {
        line.trimmingCharacters(in: frame.union(.whitespaces))
    }

    private static func isBlankOrSeparator(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { separator.contains($0) || CharacterSet.whitespaces.contains($0) }
    }

    private static func option(_ line: String) -> ParsedOption? {
        var text = Substring(line)
        var selected = false
        if let first = text.first, cursors.contains(first) {
            selected = true
            text = text.dropFirst().drop { $0.isWhitespace }
        } else if let first = text.first, unselectedMarks.contains(first) {
            text = text.dropFirst().drop { $0.isWhitespace }
        }
        guard let digits = text.prefix(while: { $0.isASCII && $0.isNumber }).nilIfEmpty,
              let number = Int(digits),
              let rest = AgentPermissionPrompt.optionText(text)
        else { return nil }
        let trimmed = rest.trimmingCharacters(in: frame.union(.whitespaces))
        // A run of spaces ends the label: what follows describes it.
        if let gap = trimmed.range(of: "  ") {
            let label = trimmed[..<gap.lowerBound].trimmingCharacters(in: .whitespaces)
            let detail = trimmed[gap.upperBound...].trimmingCharacters(in: .whitespaces)
            return ParsedOption(number: number, label: label, detail: detail.isEmpty ? nil : detail, selected: selected)
        }
        return ParsedOption(number: number, label: trimmed, detail: nil, selected: selected)
    }

    private static func question(above start: Int, in tail: [String]) -> String? {
        var nearest: String?
        var index = start - 1
        var looked = 0
        while index >= 0, looked < 8 {
            let line = tail[index].trimmingCharacters(in: .whitespaces)
            index -= 1
            guard !isBlankOrSeparator(line) else { continue }
            looked += 1
            if line.hasSuffix("?") { return clip(line, questionLimit) }
            if nearest == nil { nearest = line }
        }
        return nearest.map { clip($0, questionLimit) }
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// "no, and tell claude what to do differently (esc)" → without " (esc)".
    private static func withoutKeyHint(_ label: String) -> String {
        guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards) else { return label }
        return String(label[..<open.lowerBound])
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

private extension Substring {
    var nilIfEmpty: Substring? { isEmpty ? nil : self }
}
