import Foundation

/// A block of an agent's Markdown, as the app lays it out; the text of each
/// is inline Markdown (emphasis, code, links).
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, items: [String])
    /// A fenced code block; a table is one too (`language` "table"), as
    /// its columns line up only in a monospaced font.
    case code(language: String?, text: String)
    case quote(String)
    case rule
}

public enum Markdown {
    /// The blocks of `text`: fenced code, headings, lists, quotes, tables,
    /// rules and paragraphs (their lines joined as Markdown joins them).
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && paragraph.isEmpty {
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                var rows: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.code(language: "table", text: rows.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    quoted.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: " ")))
                continue
            }
            if let first = Self.listItem(line) {
                flushParagraph()
                var items = [first.text]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    if let item = Self.listItem(next), item.ordered == first.ordered {
                        items.append(item.text)
                    } else if next.hasPrefix("  "), !next.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A continuation, or a nested item, of the last one.
                        items[items.count - 1] += " " + next.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(ordered: first.ordered, items: items))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    /// `- item`, `* item`, `+ item`, `1. item` or `1) item`, at most three
    /// spaces in.
    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
            return (false, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let marker = after.first, marker == "." || marker == ")", after.dropFirst().first == " " else { return nil }
        return (true, after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
