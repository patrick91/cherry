import CherryControl
import Foundation
import GhosttyTerminal

// Quick View (⌘-click on a file's path in terminal output): what a click
// asked to see, on which Mac. Nothing here reads a file; `QuickViewFileSource`
// does, This Mac's in place and another Mac's over its SSH master.

/// The Mac whose files a tab's paths name.
enum QuickViewMachine: Equatable, Hashable, Sendable {
    case thisMac
    /// Another Mac (a device, or an SSH host a tab is attached to), by the
    /// name Cherry shows for it and the ssh destination its files are read
    /// through.
    case remote(name: String, destination: String)

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    /// "This Mac", or the other Mac's name.
    var name: String {
        switch self {
        case .thisMac: "This Mac"
        case let .remote(name, _): name
        }
    }
}

/// One path a click may mean: absolute (or `~/…` on another Mac whose home
/// Cherry does not know, expanded there), with the line a `path:12` suffix
/// named.
struct QuickViewCandidate: Equatable, Hashable, Sendable {
    let path: String
    var line: Int?
}

/// What a ⌘-click asked to see.
struct QuickViewRequest: Equatable, Sendable {
    let machine: QuickViewMachine
    /// The link as it was clicked, shown while its file is looked for and
    /// when none is found.
    let linkText: String
    /// The paths it may name, the likeliest first.
    let candidates: [QuickViewCandidate]

    /// The request for one path Cherry already knows (an entry of a folder
    /// Quick View lists).
    static func path(_ path: String, on machine: QuickViewMachine) -> QuickViewRequest {
        QuickViewRequest(machine: machine, linkText: path, candidates: [QuickViewCandidate(path: path)])
    }
}

/// Where a tab's relative paths start, and what `~` is, on its Mac.
struct QuickViewContext: Equatable, Sendable {
    var machine: QuickViewMachine
    /// The tab's directory there (absolute), as its shell or host reports it.
    var workingDirectory: String?
    /// The tab's project folder there (absolute): agents print paths
    /// relative to the repository while their tab may be in a subfolder.
    var projectRoot: String?
    /// The home folder there, when Cherry knows it; another Mac's `~` is
    /// otherwise expanded there.
    var homeDirectory: String?
}

/// Reads the path a link names.
enum QuickViewLink {
    /// The path a link of `kind` names, as printed; nil when it names none:
    /// a web or mail link, another scheme, a link Ghostty itself names
    /// (`text`, `html`), or text with characters that hide what it says
    /// (`TerminalLinkOpening` refuses those and says why).
    static func path(of text: String, kind: TerminalOpenURLKind) -> String? {
        guard kind.isUntrusted, !text.isEmpty, !UntrustedLink.containsUnsafeCharacters(text) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty {
            // A file URL's path (an OSC 8 hyperlink's `file://host/path`:
            // the host is the Mac the program runs on, the tab's own).
            guard scheme.lowercased() == "file", url.query == nil else { return nil }
            let path = url.path(percentEncoded: false)
            return path.hasPrefix("/") ? path : nil
        }
        // An OSC 8 target is a URL or nothing.
        guard kind == .unknown else { return nil }
        return text
    }

    /// The forms of a printed path a click may mean, in order: as printed;
    /// without a `:line` or `:line:column` suffix (compilers', linters' and
    /// agents' `src/main.swift:42:7`); without punctuation that ended its
    /// sentence (`notes.md.`).
    static func variants(of path: String) -> [QuickViewCandidate] {
        var forms = [QuickViewCandidate(path: path)]
        if let (stripped, line) = withoutLineSuffix(path) {
            forms.append(QuickViewCandidate(path: stripped, line: line))
        }
        for form in forms {
            if let trimmed = withoutTrailingPunctuation(form.path) {
                forms.append(QuickViewCandidate(path: trimmed, line: form.line))
            }
        }
        return unique(forms)
    }

    /// `path` without a `:line[:column]` suffix, and the line; nil when it
    /// has none.
    static func withoutLineSuffix(_ path: String) -> (String, Int)? {
        var parts = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2, let last = parts.last, !last.isEmpty,
              last.allSatisfy(\.isASCIIDigit), let number = Int(last) {
            numbers.insert(number, at: 0)
            parts.removeLast()
        }
        let rest = parts.joined(separator: ":")
        guard let line = numbers.first, line > 0, !rest.isEmpty, !rest.hasSuffix("/") else { return nil }
        return (rest, line)
    }

    /// `path` without the punctuation a sentence ends it with; nil when it
    /// ends with none, or when what is left would name no file (`./`, `..`).
    static func withoutTrailingPunctuation(_ path: String) -> String? {
        var trimmed = Substring(path)
        while let last = trimmed.last, ".,;:!?'\"".contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard trimmed.count < path.count, !trimmed.isEmpty, !trimmed.hasSuffix("/") else { return nil }
        let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
        guard !name.isEmpty, name != ".", name != "..", name != "~" else { return nil }
        return String(trimmed)
    }

    /// The paths `form` may name on its Mac, absolute: as it is when it is
    /// absolute; `~` from the home folder (left as `~/…` when it is another
    /// Mac's and not known); else from the tab's directory, then its project
    /// folder.
    static func candidates(for form: QuickViewCandidate, in context: QuickViewContext) -> [QuickViewCandidate] {
        let path = form.path
        func at(_ absolute: String) -> QuickViewCandidate {
            QuickViewCandidate(path: normalized(absolute), line: form.line)
        }
        if path.hasPrefix("/") { return [at(path)] }
        let homeRelative: String? = if path == "~" || path == "$HOME" {
            ""
        } else if path.hasPrefix("~/") {
            String(path.dropFirst(2))
        } else if path.hasPrefix("$HOME/") {
            String(path.dropFirst(6))
        } else {
            nil
        }
        if let homeRelative {
            if let home = context.homeDirectory, home.hasPrefix("/") {
                return [at(home + "/" + homeRelative)]
            }
            // Another Mac's home, expanded there (`QuickViewRemoteFiles`).
            let rest = normalized("/" + homeRelative)
            return [QuickViewCandidate(path: rest == "/" ? "~" : "~" + rest, line: form.line)]
        }
        // `~user/…` and other variables name nothing Cherry can look up.
        guard !path.hasPrefix("~"), !path.hasPrefix("$") else { return [] }
        return [context.workingDirectory, context.projectRoot]
            .compactMap { $0 }
            .filter { $0.hasPrefix("/") }
            .map { at($0 + "/" + path) }
    }

    /// What a click on `text` asks to see in a tab of `context`'s Mac; nil
    /// when it names no file.
    static func request(text: String, kind: TerminalOpenURLKind, context: QuickViewContext) -> QuickViewRequest? {
        guard let path = path(of: text, kind: kind) else { return nil }
        let paths = unique(variants(of: path).flatMap { Self.candidates(for: $0, in: context) })
        guard !paths.isEmpty else { return nil }
        return QuickViewRequest(machine: context.machine, linkText: text, candidates: paths)
    }

    /// `path` (absolute) without empty or `.` components. `..` stays: on
    /// another Mac a link can make it mean something else, so that Mac
    /// resolves it (and FileManager does here).
    static func normalized(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return "/" + components.joined(separator: "/")
    }

    /// Each path once, the first of its line kept.
    private static func unique(_ candidates: [QuickViewCandidate]) -> [QuickViewCandidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.path).inserted }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
