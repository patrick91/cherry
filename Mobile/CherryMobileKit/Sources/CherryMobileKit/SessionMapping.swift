import Foundation

/// A host session as the phone lists it, read the way the Mac app reads its
/// tags (`PersistentSessionTag`: `cherry.tab`, `cherry.kind`,
/// `cherry.agent`, `cherry.command`).
enum SessionMapping {
    enum Tag {
        static let tab = "cherry.tab"
        static let kind = "cherry.kind"
        static let agent = "cherry.agent"
        static let command = "cherry.command"
    }

    static func session(_ info: HostWireSession, macID: UUID, states: AgentStates) -> MobileSession {
        let kind = kind(of: info)
        let state = states.state(forTab: info.tags[Tag.tab])
        var attention = AgentAttention.unknown
        if case .agent = kind, info.isRunning, let state {
            attention = state.attention
        }
        return MobileSession(
            id: info.id,
            macID: macID,
            title: title(of: info, kind: kind),
            directory: directory(of: info),
            kind: kind,
            isRunning: info.isRunning,
            attention: attention,
            detail: info.isRunning ? state?.detail : nil,
            size: TerminalSize(columns: info.cols, rows: info.rows),
            changedAt: state?.changedAt
        )
    }

    static func kind(of info: HostWireSession) -> SessionKind {
        switch info.tags[Tag.kind] {
        case "agent":
            .agent(info.tags[Tag.agent]?.nilIfBlank ?? info.foreground?.name.nilIfBlank ?? "agent")
        case "command":
            .command
        default:
            .terminal
        }
    }

    /// An agent's is its session's name (its settled task title, else its
    /// tool's) without status glyphs; a command's its name; a terminal's the
    /// title its program set, else the session's name.
    static func title(of info: HostWireSession, kind: SessionKind) -> String {
        let fallback = info.name.nilIfBlank ?? String(info.id.prefix(8))
        switch kind {
        case .agent(let agent):
            return strippingStatusGlyphs(info.name).nilIfBlank ?? agent
        case .command:
            return info.tags[Tag.command]?.nilIfBlank ?? fallback
        case .terminal:
            return info.title?.nilIfBlank ?? fallback
        }
    }

    /// Spinners and status symbols an agent's title starts with ("⠋ Fix
    /// tests", "✳ Claude Code").
    static func strippingStatusGlyphs(_ text: String) -> String {
        String(text.unicodeScalars.drop { scalar in
            !CharacterSet.alphanumerics.contains(scalar) && !"~/.([\"'".unicodeScalars.contains(scalar)
        }).trimmingCharacters(in: .whitespaces)
    }

    /// Where the program says it is (OSC 7, decoded), else where it started.
    static func directory(of info: HostWireSession) -> String? {
        if let pwd = info.pwd, let path = reportedPath(pwd) { return path }
        return info.cwd.nilIfBlank
    }

    /// The path of a plain path, `file://host/path` (percent-encoded) or
    /// `kitty-shell-cwd://host/path`; nil for anything else.
    static func reportedPath(_ reported: String) -> String? {
        if reported.hasPrefix("/") { return reported }
        let lowercased = reported.lowercased()
        for (scheme, isEncoded) in [("file://", true), ("kitty-shell-cwd://", false)] where lowercased.hasPrefix(scheme) {
            let rest = reported.dropFirst(scheme.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let path = String(rest[slash...])
            return isEncoded ? (path.removingPercentEncoding ?? path) : path
        }
        return nil
    }

    /// The screen text's lines, without the blank lines below the last one
    /// with text (the host keeps the whole grid).
    static func lines(of screen: HostWireScreenText) -> [String] {
        var lines = screen.text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 {
            lines.removeLast()
        }
        return lines
    }
}
