import Foundation

/// How a tool call reads in a conversation: an SF Symbol, a verb ("Read",
/// "Ran") and what it acted on, its paths shortened.
public struct ToolPresentation: Equatable, Sendable {
    public var symbol: String
    public var title: String
    public var detail: String
    /// The detail is code (a command, a pattern): shown monospaced.
    public var isCode: Bool

    public init(symbol: String, title: String, detail: String, isCode: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.isCode = isCode
    }

    /// `entry`'s, its paths relative to `project` (the session's folder)
    /// or to the home folder.
    public init(_ entry: TranscriptEntry, project: String?) {
        let name = entry.name ?? "Tool"
        let summary = entry.summary ?? ""
        // A summary that is JSON (an input with no one line to show) shows
        // nothing.
        let plain = summary.hasPrefix("{") || summary.hasPrefix("[") ? "" : summary
        let path = DisplayPath.shorten(plain, project: project)
        let code = DisplayPath.shortenPaths(in: plain, project: project)
        let key = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        switch key {
        case "bash", "shell", "execcommand", "localshell", "terminal":
            self.init(symbol: "terminal", title: "Ran", detail: code, isCode: true)
        case "read", "readfile", "view", "cat":
            self.init(symbol: "doc.text", title: "Read", detail: path)
        case "write", "createfile", "writefile":
            self.init(symbol: "square.and.pencil", title: "Wrote", detail: path)
        case "edit", "multiedit", "applypatch", "strreplaceeditor", "editfile", "notebookedit":
            self.init(symbol: "pencil", title: "Edited", detail: path)
        case "grep", "glob", "search", "find", "rg", "ls", "list", "codebasesearch":
            self.init(symbol: "magnifyingglass", title: "Searched", detail: code, isCode: true)
        case "webfetch", "readwebpage", "fetch", "browse":
            self.init(symbol: "globe", title: "Fetched", detail: DisplayPath.shortenURL(plain))
        case "websearch":
            self.init(symbol: "globe", title: "Searched the web", detail: plain)
        case "task", "agent", "spawnagent", "subagent":
            self.init(symbol: "person.2", title: "Ran an agent", detail: plain)
        case "todowrite", "todoread", "todo", "updateplan":
            self.init(symbol: "checklist", title: "Updated the plan", detail: "")
        case "askuserquestion", "askquestion":
            self.init(symbol: "questionmark.bubble", title: "Asked a question", detail: plain)
        case "viewimage":
            self.init(symbol: "photo", title: "Viewed", detail: path)
        default:
            self.init(symbol: "wrench.and.screwdriver", title: Self.title(of: name), detail: plain)
        }
    }

    /// An MCP tool (`mcp__server__tool`) as `server: tool`.
    private static func title(of name: String) -> String {
        let parts = name.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp" {
            return "\(parts[1]): \(parts[2...].joined(separator: " "))"
        }
        return name
    }
}

/// Paths as short as they still say where: in the session's folder
/// relative to it, under a home folder from `~`, long ones from their last
/// two components.
public enum DisplayPath {
    public static func shorten(_ path: String, project: String?) -> String {
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return path }
        var short = abbreviatingHome(path)
        if let project = project.map(abbreviatingHome)?.trimmingSuffix("/"), !project.isEmpty {
            if short == project {
                short = "."
            } else if short.hasPrefix(project + "/") {
                short = String(short.dropFirst(project.count + 1))
            }
        }
        let parts = short.split(separator: "/")
        if short.count > 48, parts.count > 2 {
            short = "…/" + parts.suffix(2).joined(separator: "/")
        }
        return short
    }

    /// Every path in a command line shortened the same way: the session's
    /// folder dropped, a home folder written `~`.
    public static func shortenPaths(in text: String, project: String?) -> String {
        var text = abbreviatingHome(text)
        if let project = project.map(abbreviatingHome)?.trimmingSuffix("/"), project.count > 2 {
            // Agents start many commands in the session's folder.
            for prefix in ["cd \(project) && ", "cd \(project); "] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
            text = text.replacingOccurrences(of: project + "/", with: "")
        }
        return text
    }

    /// A URL without its scheme and `www.`.
    public static func shortenURL(_ url: String) -> String {
        var url = url
        for prefix in ["https://", "http://"] where url.hasPrefix(prefix) {
            url = String(url.dropFirst(prefix.count))
        }
        if url.hasPrefix("www.") { url = String(url.dropFirst(4)) }
        return url
    }

    /// `/Users/<name>/…` (and `/home/<name>/…`) as `~/…`.
    static func abbreviatingHome(_ text: String) -> String {
        text.replacingOccurrences(of: #"/(Users|home)/[^/\s'"]+(?=/|\s|$)"#, with: "~", options: .regularExpression)
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}

/// A conversation as rows: each message or note, and each run of tool calls
/// between them as one group.
public enum ConversationRow: Identifiable, Equatable, Sendable {
    case entry(TranscriptEntry)
    case tools([TranscriptEntry])

    public var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .tools(let tools): "tools-" + (tools.first?.id ?? "")
        }
    }

    public static func rows(of entries: [TranscriptEntry]) -> [ConversationRow] {
        var rows: [ConversationRow] = []
        for entry in entries {
            switch entry.kind {
            case .tool:
                if case .tools(let tools) = rows.last {
                    rows[rows.count - 1] = .tools(tools + [entry])
                } else {
                    rows.append(.tools([entry]))
                }
            case .user, .assistant, .note:
                rows.append(.entry(entry))
            case .toolResult, .unknown:
                continue
            }
        }
        return rows
    }
}
