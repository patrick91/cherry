import Foundation

/// A numbered choice menu an agent shows at the bottom of its screen
/// (Claude Code's permission prompt and AskUserQuestion, Codex's approval),
/// so the phone can offer its options as buttons. An agent picks an option
/// on its digit alone, so a button sends just the digit.
public struct ScreenMenu: Hashable, Sendable {
    public struct Option: Hashable, Sendable {
        public var number: Int
        public var label: String
        /// The option the menu's cursor is on (`❯ 1. Yes`).
        public var isSelected: Bool

        public init(number: Int, label: String, isSelected: Bool) {
            self.number = number
            self.label = label
            self.isSelected = isSelected
        }

        /// What choosing it types.
        public var keys: [MobileKey] {
            [.text(String(number))]
        }
    }

    public var options: [Option]
    /// The line asking, just above the options, when there is one.
    public var question: String?

    public init(options: [Option], question: String?) {
        self.options = options
        self.question = question
    }

    /// How far from the bottom a menu may start: below it, an agent shows
    /// only a hint line or two and its box.
    static let searchedLines = 30
    /// Lines of description an option may have under it.
    static let maximumGap = 3

    /// The menu at the bottom of `lines`: options numbered 1, 2, 3… in order
    /// (at least two), the last of them among the last lines, each at most
    /// a few lines below the one before. A numbered list in prose is not a
    /// menu, so one option must carry the cursor or a question must end
    /// just above the first.
    public static func find(in lines: [String]) -> ScreenMenu? {
        let window = Array(lines.suffix(searchedLines))
        let parsed = window.map(parse)
        guard let last = parsed.lastIndex(where: { $0 != nil }) else { return nil }

        // Walk up from the last option, keeping a run that counts down to 1.
        var run: [(index: Int, option: Option)] = []
        var index = last
        var gap = 0
        while index >= 0 {
            if let option = parsed[index] {
                let expected = (run.first?.option.number ?? option.number + 1) - 1
                guard option.number == expected else { break }
                run.insert((index, option), at: 0)
                gap = 0
                if option.number == 1 { break }
            } else {
                gap += 1
                if gap > maximumGap { break }
            }
            index -= 1
        }
        guard run.count >= 2, run.first?.option.number == 1 else { return nil }

        let question = questionLine(above: run[0].index, in: window)
        let hasCursor = run.contains { $0.option.isSelected }
        guard hasCursor || question?.hasSuffix("?") == true else { return nil }
        return ScreenMenu(options: run.map(\.option), question: question)
    }

    /// Box drawing a menu's frame puts at the start and end of its lines.
    private static let frame = CharacterSet(charactersIn: "│┃║╎╏|")
    /// What agents mark the selected option with.
    private static let cursors: Set<Character> = ["❯", "›", ">", "▶", "▸", "➜", "→", "●"]

    /// `line` as an option, when it is one: an optional cursor, a number
    /// from 1 to 99 with `.` or `)`, and its label.
    static func parse(_ line: String) -> Option? {
        var text = Substring(unframed(line))
        var isSelected = false
        if let first = text.first, cursors.contains(first) {
            isSelected = true
            text = text.dropFirst().drop { $0 == " " }
        }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count), let number = Int(digits), number >= 1 else { return nil }
        var rest = text.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Option(number: number, label: label, isSelected: isSelected)
    }

    /// The nearest line with words above `index`, within a few lines.
    private static func questionLine(above index: Int, in lines: [String]) -> String? {
        var line = index - 1
        while line >= max(0, index - 4) {
            let text = unframed(lines[line])
            if text.contains(where: { $0.isLetter }) {
                return text
            }
            line -= 1
        }
        return nil
    }

    private static func unframed(_ line: String) -> String {
        line.trimmingCharacters(in: frame.union(.whitespaces))
    }
}
