import Foundation

/// How a session is named in lists that show many at once (the Omni bar):
/// its own name rather than its tool's, without the activity glyphs a
/// program puts in its title, and for a shell what it does rather than
/// "Shell 3". Pure, for tests.
enum SessionDisplayTitle {
    /// `title` without the spinner and status glyphs agents put at its
    /// ends (Claude's `✳ `/`⠐ `, Codex's braille frames, `◑ `, `● `), as
    /// the sidebar's task titles drop them (`AgentTerminalTitleParser`).
    /// Controls and runs of whitespace become one space.
    static func strippingStatusGlyphs(_ title: String) -> String {
        var value = normalized(title)
        while let first = value.unicodeScalars.first, isStatusGlyph(first) {
            let rest = value.unicodeScalars.dropFirst()
            // A braille frame may touch the text; any other glyph counts
            // only as a word of its own ("✳ Task", not "*nix" or "·foo").
            guard isBraille(first) || rest.first.map({ CharacterSet.whitespaces.contains($0) }) ?? true else { break }
            value = String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
        }
        while let last = value.unicodeScalars.last, isBraille(last) {
            value = String(String.UnicodeScalarView(value.unicodeScalars.dropLast())).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// Whether an agent's title shows its working spinner (a braille frame
    /// first), as `TerminalSession` counts one: a heartbeat only while it
    /// changes (`AgentTitleHeartbeat`).
    static func showsWorkingSpinner(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespaces).unicodeScalars.first.map(isBraille) ?? false
    }

    /// A shell's name, first that applies: the name the user gave it
    /// (`userName`); the command in its foreground (`foreground`, the
    /// process's name), shown as the title the shell set for it when that
    /// is a command line ("npm run dev"); the title the shell set (OSC 0/2)
    /// when it says more than a directory or the shell's own name; its
    /// directory's name, "~" at `home`.
    static func shell(
        userName: String?,
        foreground: String?,
        terminalTitle: String?,
        workingDirectory: String?,
        home: String?
    ) -> String {
        if let userName = userName.map(normalized), !userName.isEmpty { return userName }
        let title = terminalTitle.map(strippingStatusGlyphs) ?? ""
        let titleSaysMore = !title.isEmpty && !isPlaceholder(title) && !isShellName(title) && !isPathLike(title)
        if let foreground = foreground.map(normalized), !foreground.isEmpty, !isShellName(foreground) {
            return titleSaysMore ? title : foreground
        }
        if titleSaysMore { return title }
        if let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            return directoryName(directory, home: home)
        }
        if isPathLike(title), let path = pathInTitle(title) {
            return directoryName(path, home: home)
        }
        return "~"
    }

    /// An open tab's name: an agent's as the sidebar shows it (its task
    /// title once settled, `SidebarAgentTitleFormatter`), a command's own,
    /// a shell's per `shell` (a rename, `titleSource` `.explicit`, wins).
    /// Glyphs stripped.
    static func tab(
        kind: TerminalSession.SessionKind,
        title: String,
        titleSource: TerminalSession.TitleSource,
        agentName: String?,
        commandLine: String,
        foreground: String?,
        workingDirectory: String?,
        home: String?
    ) -> String {
        let named: String
        switch kind {
        case .agent:
            named = SidebarAgentTitleFormatter.title(
                title: title, titleSource: titleSource, agentName: agentName, commandLine: commandLine
            )
        case .command:
            named = title
        case .terminal:
            return shell(
                userName: titleSource == .explicit ? title : nil,
                foreground: foreground,
                terminalTitle: titleSource == .explicit ? nil : title,
                workingDirectory: workingDirectory,
                home: home
            )
        }
        let stripped = titleSource == .explicit ? normalized(named) : strippingStatusGlyphs(named)
        return stripped.isEmpty ? normalized(title) : stripped
    }

    /// A background session's name (`BackgroundSession.displayTitle`): an
    /// agent's is the session's own name, which holds its settled task
    /// title (else its tool's), glyphs stripped; a command's is its name;
    /// a shell's per `shell`, with the host's name as the user's when it
    /// is one (`isUserName`).
    static func background(_ info: HostedSessionInfo, kind: TerminalSession.SessionKind, home: String?) -> String {
        switch kind {
        case .agent:
            return strippingStatusGlyphs(info.name).nilIfEmpty
                ?? info.tags[PersistentSessionTag.agent]?.nilIfEmpty
                ?? info.displayName
        case .command:
            return info.tags[PersistentSessionTag.command]?.nilIfEmpty ?? info.displayName
        case .terminal:
            return shell(
                userName: isUserName(info.name, terminalTitle: info.title) ? info.name : nil,
                foreground: info.isBusy ? info.foreground?.name : nil,
                terminalTitle: info.title,
                workingDirectory: info.reportedDirectory?.path ?? info.cwd,
                home: home
            )
        }
    }

    /// Whether a background shell's host name is one the user gave it (an
    /// explicit rename reaches the host with `Update`): not the name a tab
    /// starts with ("Shell 3"), nor a directory, the shell's name or the
    /// title it shows, which a session created while its tab showed them
    /// was named after.
    static func isUserName(_ name: String, terminalTitle: String?) -> Bool {
        let name = normalized(name)
        guard !name.isEmpty, !isPlaceholder(name), !isShellName(name), !isPathLike(name) else { return false }
        if let terminalTitle, strippingStatusGlyphs(terminalTitle) == strippingStatusGlyphs(name) { return false }
        return true
    }

    /// A directory's name, "~" at `home` (when unknown, a `/Users/<name>`
    /// or `/home/<name>` directory counts as one), "/" at the root.
    static func directoryName(_ path: String, home: String?) -> String {
        let path = standardized(path)
        if isHome(path, home: home) { return "~" }
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }

    static func isHome(_ path: String, home: String?) -> Bool {
        let path = standardized(path)
        if path == "~" || path.isEmpty { return true }
        if let home = home.map(standardized), !home.isEmpty { return path == home }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return path == "/var/root" || (parts.count == 2 && (parts[0] == "Users" || parts[0] == "home"))
    }

    // MARK: Pieces

    /// The name a tab starts with ("Shell", "Shell 3").
    static func isPlaceholder(_ title: String) -> Bool {
        let words = normalized(title).split(separator: " ")
        guard words.first == "Shell" else { return false }
        return words.count == 1 || (words.count == 2 && words[1].allSatisfy(\.isNumber))
    }

    private static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login",
    ]

    /// "zsh", "-zsh" (a login shell), "/bin/zsh", "zsh login shell".
    static func isShellName(_ title: String) -> Bool {
        var name = normalized(title).lowercased()
        if name.hasSuffix(" login shell") { name.removeLast(" login shell".count) }
        if name.hasPrefix("-") { name.removeFirst() }
        name = (name as NSString).lastPathComponent
        return shellNames.contains(name)
    }

    /// A directory as shells title themselves: "~/code", "/usr", an
    /// abbreviated "…/github/code" (or ".../github/code"), or
    /// "user@host: ~/code" / "user@host:~/code". Not one with a space,
    /// which reads as a command line.
    static func isPathLike(_ title: String) -> Bool {
        pathInTitle(title) != nil
    }

    private static func pathInTitle(_ title: String) -> String? {
        let title = normalized(title)
        // A path with a space reads as a command line ("/usr/bin/env node").
        if startsLikePath(title) { return title.contains(" ") ? nil : title }
        if let colon = title.firstIndex(of: ":"), title[..<colon].contains("@"), !title[..<colon].contains(" ") {
            let rest = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if startsLikePath(rest) { return rest }
        }
        return nil
    }

    /// "/…", "~", "~/…", or a path shortened from the left ("…/a/b",
    /// ".../a/b"), as prompts and sidebars abbreviate long ones.
    private static func startsLikePath(_ value: String) -> Bool {
        value.hasPrefix("/") || value == "~" || value.hasPrefix("~/")
            || value.hasPrefix("…/") || value.hasPrefix(".../")
    }

    private static func normalized(_ value: String) -> String {
        value.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func standardized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func isBraille(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(scalar.value)
    }

    /// Braille spinners, geometric shapes (◐◑◒◓ ● ○ ◆), dingbats (✳ ✶ ✻ ✢)
    /// and the `*`/`·` Claude also draws.
    private static func isStatusGlyph(_ scalar: Unicode.Scalar) -> Bool {
        isBraille(scalar)
            || (0x25A0...0x25FF).contains(scalar.value)
            || (0x2700...0x27BF).contains(scalar.value)
            || scalar == "*" || scalar == "·" || scalar == "•"
    }
}

/// Whether background agents are at work, from the one signal the host
/// passes on: their title's spinner (a braille frame first). The spinner is
/// a heartbeat, not a state (an agent can settle and leave its last frame
/// behind), so it counts only while the title keeps changing: an agent is
/// working when its title shows a spinner that changed within `freshness`.
/// A title seen once is no evidence either way.
struct AgentTitleHeartbeat {
    static let freshness: TimeInterval = 3

    private var seen: [String: (title: String, changedAt: Date?)] = [:]

    mutating func isWorking(id: String, title: String?, now: Date) -> Bool {
        let title = title ?? ""
        if let previous = seen[id] {
            if previous.title != title { seen[id] = (title, now) }
        } else {
            seen[id] = (title, nil)
        }
        guard SessionDisplayTitle.showsWorkingSpinner(title), let changedAt = seen[id]?.changedAt else { return false }
        return now.timeIntervalSince(changedAt) < Self.freshness
    }

    /// Forgets the sessions no longer listed.
    mutating func keep(only ids: Set<String>) {
        seen = seen.filter { ids.contains($0.key) }
    }
}
