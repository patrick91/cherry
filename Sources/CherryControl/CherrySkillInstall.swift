import Foundation

// The `cherry` skill on disk (docs/specs/agent-cli.md, Teaching agents):
// SKILL.md in each agent CLI's skills folder, with a `.cherry-skill` marker
// beside it that says Cherry wrote it, and for Codex a rules file that lets
// `cherry`'s agent commands run outside its sandbox. `cherry skill
// setup|status|remove` and Connect Agents to Cherry… both run this; only
// the user's command or Connect's confirmation writes anything.
//
// Cherry's own files are recognised by their marker (a skill) or their
// first line (the rules file); anything else named `cherry` is the user's
// (`foreign`) and is left alone unless `force`. A link at the skill folder
// or at one of Cherry's files is never followed or replaced.

/// The skill's texts and the Codex rules.
public enum CherrySkill {
    /// The skill an agent CLI loads (`cherry skill show --skill-md`).
    public static let markdown = """
    ---
    name: cherry
    description: "Use when running inside Cherry (INSIDE_CHERRY=1) or when asked to work with Cherry tabs, agents, workers, tasks, terminals, commands or todos. The cherry command opens, reads, messages and waits for them."
    ---

    # Cherry

    You run in a tab of Cherry, a terminal app for agents. The `cherry` command
    lists, reads, messages and starts its tabs, runs workers and their tasks,
    and keeps the project's todos.

    - Without an ID a command acts on your own tab; a tab's name works as its ID.
    - Long text goes on standard input: `cherry send ID <<'EOF'` … `EOF`.
    - If your tab got a Cherry task kickoff, run `cherry task mine` first and
      finish with `cherry task report`.

    Run `cherry skill show` for the full guide before your first other `cherry` command.
    """

    /// The file beside SKILL.md that says Cherry wrote it: JSON with the
    /// SHA-256 of the SKILL.md it wrote, so an edit by hand makes the skill
    /// the user's.
    public static let markerFileName = ".cherry-skill"

    /// The rules file's first line, verbatim: how Cherry (and its launch,
    /// which gives Codex the CLI only with it) knows the file is its own.
    public static let rulesFirstLine = "# Written by Cherry: cherry's agent commands run outside Codex's sandbox; cherry host is forbidden."

    /// The agent commands an allowed Codex command may start with: every
    /// top-level word of `cherry`'s agent commands but `start` and
    /// `restart` (without a process ID they are the session host's, and a
    /// prefix rule cannot ask for one) and `skill` (its setup writes agent
    /// settings, which the sandbox should keep refusing; `skill show`
    /// needs no socket).
    public static let allowedWords = [
        "agents", "answer", "close", "commands", "events", "help", "keys", "link", "ls", "ports", "project",
        "read", "rename", "search", "select", "send", "services", "show", "spawn", "stop", "subscribe",
        "subscriptions", "task", "todo", "tool", "unsubscribe", "wait", "wait-port", "whoami",
    ]

    /// `cherry host` and the host commands' old top-level names.
    public static let forbiddenWords = [
        "host", "attach", "control", "new", "kill", "remove", "shutdown", "doctor", "list", "status",
    ]

    /// `${CODEX_HOME:-~/.codex}/rules/cherry.rules`.
    public static var rulesText: String {
        func list(_ words: [String]) -> String {
            "[" + words.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        }
        return """
        \(rulesFirstLine)
        # Cherry Connect (or `cherry skill setup`) wrote this file and `cherry skill remove` removes it.
        prefix_rule(
            pattern = ["cherry", \(list(allowedWords))],
            decision = "allow",
            justification = "Cherry's agent commands reach the Cherry app's socket, which the sandbox blocks.",
        )
        prefix_rule(
            pattern = ["cherry", \(list(forbiddenWords))],
            decision = "forbidden",
            justification = "cherry host is Cherry's session host: agents use cherry's agent commands (cherry skill show).",
        )

        """
    }
}

/// An agent CLI the skill is for.
public enum CherrySkillAgent: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case pi
    case opencode
    case amp

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .opencode: "OpenCode"
        case .amp: "Amp"
        }
    }

    public var executableName: String { rawValue }
}

/// A file (or folder) Cherry writes.
public enum CherrySkillTarget: String, CaseIterable, Codable, Sendable {
    /// `~/.claude/skills/cherry` (Claude Code reads no `~/.agents`).
    case claudeSkill = "claude_skill"
    /// `~/.agents/skills/cherry`, which Codex, Pi, OpenCode and Amp read.
    case agentsSkill = "agents_skill"
    /// Codex's `rules/cherry.rules`.
    case codexRules = "codex_rules"

    public var agents: [CherrySkillAgent] {
        switch self {
        case .claudeSkill: [.claude]
        case .agentsSkill: [.codex, .pi, .opencode, .amp]
        case .codexRules: [.codex]
        }
    }

    public var title: String {
        switch self {
        case .claudeSkill, .agentsSkill: "Cherry skill"
        case .codexRules: "Codex rules"
        }
    }
}

public enum CherrySkillStatus: String, Codable, Sendable {
    /// Cherry's, and what this build writes.
    case current
    /// Cherry's, from another build.
    case outdated
    case missing
    /// Not Cherry's (no marker, or edited since Cherry wrote it).
    case foreign
    /// A link, not a folder, or a read that failed.
    case unreadable
    /// None of the agents it is for was found.
    case unsupported
}

/// One target's state.
public struct CherrySkillItem: Codable, Equatable, Sendable {
    public var target: CherrySkillTarget
    /// The skill's folder, or the rules file.
    public var path: String
    /// The agents found (or asked for) that read it.
    public var agents: [CherrySkillAgent]
    public var status: CherrySkillStatus
    public var detail: String?
}

public enum CherrySkillChangeKind: String, Codable, Sendable {
    case wrote
    case replaced
    case unchanged
    case removed
    case skipped
    case failed
    case wouldWrite = "would_write"
    case wouldReplace = "would_replace"
    case wouldRemove = "would_remove"
}

/// What setup or remove did to one target.
public struct CherrySkillChange: Codable, Equatable, Sendable {
    public var item: CherrySkillItem
    public var change: CherrySkillChangeKind
    public var detail: String?

    public var failed: Bool { change == .failed }
}

/// A file a setup writes: its path and contents, as Connect's
/// confirmation shows them.
public struct CherrySkillFile: Equatable, Sendable {
    public var path: String
    public var contents: String
}

/// What is at a path, as `lstat` says (a link is never followed).
public enum CherrySkillEntry: String, Codable, Sendable {
    case none
    case link
    case directory
    case file
}

/// The file system the skill's files are on: This Mac's
/// (`LocalSkillFiles`), or that of the Mac whose `cherry` asked
/// (`cherry skill setup` in a `runCommand`, which reads and writes through
/// it). `begin` marks the steps of one target's write or removal: when one
/// fails, the target's later steps are not taken.
public protocol CherrySkillFiles: Sendable {
    /// What is at `path`, links not followed.
    func entry(_ path: String) -> CherrySkillEntry
    /// Whether `path` is a directory, links followed.
    func isDirectory(_ path: String) -> Bool
    /// Whether anything is at `path`, links followed.
    func exists(_ path: String) -> Bool
    /// Whether `path` is an executable file, links followed.
    func isExecutable(_ path: String) -> Bool
    func contents(_ path: String) -> Data?
    /// A directory's names, nil when it cannot be listed.
    func list(_ path: String) -> [String]?
    func begin(_ target: CherrySkillTarget)
    /// Creates `path` and the directories above it.
    func createDirectory(_ path: String) throws
    /// Replaces `path` with `text` atomically (a link there is replaced, never written through).
    func write(_ text: String, to path: String) throws
    /// Removes a file, a link or an empty directory.
    func remove(_ path: String) throws
}

/// This Mac's file system.
public struct LocalSkillFiles: CherrySkillFiles {
    public init() {}

    public func entry(_ path: String) -> CherrySkillEntry {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .none }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .directory
        default: return .file
        }
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    public func contents(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    public func list(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func begin(_ target: CherrySkillTarget) {}

    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

/// Where the agents' folders are and which agents are here.
public struct CherrySkillEnvironment: Sendable {
    public var home: URL
    public var variables: [String: String]
    /// `--project`: the repository whose `.claude`, `.agents` and `.codex`
    /// get the files instead of the account's.
    public var projectRoot: URL?
    /// Whether an executable of this name is on PATH.
    public var isOnPath: @Sendable (String) -> Bool
    /// Where the files are.
    public var files: any CherrySkillFiles

    public init(
        home: URL,
        variables: [String: String],
        projectRoot: URL? = nil,
        files: any CherrySkillFiles = LocalSkillFiles(),
        isOnPath: @escaping @Sendable (String) -> Bool
    ) {
        self.home = home
        self.variables = variables
        self.projectRoot = projectRoot
        self.files = files
        self.isOnPath = isOnPath
    }

    /// This process's: `HOME` (else the account's home), its variables and
    /// its PATH.
    public static func current(projectRoot: URL? = nil) -> CherrySkillEnvironment {
        let variables = ProcessInfo.processInfo.environment
        let home = variables["HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return caller(home: home, variables: variables, projectRoot: projectRoot, files: LocalSkillFiles())
    }

    /// A process's with `variables` (its PATH) at `home`, its files on
    /// `files`.
    public static func caller(
        home: URL,
        variables: [String: String],
        projectRoot: URL? = nil,
        files: any CherrySkillFiles
    ) -> CherrySkillEnvironment {
        let path = variables["PATH"] ?? ""
        return CherrySkillEnvironment(home: home, variables: variables, projectRoot: projectRoot, files: files) { name in
            searchPath(path, contains: name, files: files)
        }
    }

    /// Whether a directory of `path` (colon-separated) has an executable
    /// `name`.
    public static func searchPath(_ path: String, contains name: String, files: any CherrySkillFiles = LocalSkillFiles()) -> Bool {
        path.split(separator: ":").contains { directory in
            files.isExecutable(URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path)
        }
    }

    /// The repository `directory` is in (the nearest folder up with a
    /// `.git`), else `directory`.
    public static func projectRoot(from directory: URL, files: any CherrySkillFiles = LocalSkillFiles()) -> URL {
        var candidate = directory.standardizedFileURL
        while true {
            if files.exists(candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return directory.standardizedFileURL }
            candidate = parent
        }
    }

    /// An absolute directory from `name`, else nil (unset, empty or
    /// relative).
    func directory(_ name: String) -> URL? {
        guard let value = variables[name], value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value)
    }

    /// Whether `name` is set but not absolute: a folder Cherry can't place.
    func isRelative(_ name: String) -> Bool {
        guard let value = variables[name], !value.isEmpty else { return false }
        return !value.hasPrefix("/")
    }

    var claudeDirectory: URL { directory("CLAUDE_CONFIG_DIR") ?? home.appendingPathComponent(".claude") }
    var codexDirectory: URL { directory("CODEX_HOME") ?? home.appendingPathComponent(".codex") }
    var piDirectory: URL { directory("PI_CODING_AGENT_DIR") ?? home.appendingPathComponent(".pi/agent") }
    var configDirectory: URL { directory("XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config") }

    /// Whether `agent` is here: its settings folder exists or it is on PATH.
    func hasAgent(_ agent: CherrySkillAgent) -> Bool {
        let folder: URL = switch agent {
        case .claude: claudeDirectory
        case .codex: codexDirectory
        case .pi: piDirectory
        case .opencode: configDirectory.appendingPathComponent("opencode")
        case .amp: configDirectory.appendingPathComponent("amp")
        }
        return files.isDirectory(folder.path) || isOnPath(agent.executableName)
    }
}

/// Reads, writes and removes the skill and the rules file.
public struct CherrySkillInstaller: Sendable {
    public var environment: CherrySkillEnvironment
    public var skillMarkdown: String
    public var rulesText: String

    public init(
        environment: CherrySkillEnvironment,
        skillMarkdown: String = CherrySkill.markdown,
        rulesText: String = CherrySkill.rulesText
    ) {
        self.environment = environment
        self.skillMarkdown = skillMarkdown
        self.rulesText = rulesText
    }

    /// SKILL.md as written: the text and a final newline.
    var skillFileText: String { skillMarkdown.hasSuffix("\n") ? skillMarkdown : skillMarkdown + "\n" }

    /// The marker for `text`.
    static func markerText(for text: String) -> String {
        "{\"by\":\"Cherry\",\"sha256\":\"\(sha256Hex(text))\"}\n"
    }

    // MARK: Paths

    /// `target`'s path, or why it has none (a relative override).
    func location(of target: CherrySkillTarget) -> Result<URL, CherrySkillProblem> {
        if let root = environment.projectRoot {
            let relative = switch target {
            case .claudeSkill: ".claude/skills/cherry"
            case .agentsSkill: ".agents/skills/cherry"
            case .codexRules: ".codex/rules/cherry.rules"
            }
            return .success(root.appendingPathComponent(relative))
        }
        switch target {
        case .claudeSkill:
            if environment.isRelative("CLAUDE_CONFIG_DIR") {
                return .failure(CherrySkillProblem("CLAUDE_CONFIG_DIR is not an absolute path"))
            }
            return .success(environment.claudeDirectory.appendingPathComponent("skills/cherry"))
        case .agentsSkill:
            return .success(environment.home.appendingPathComponent(".agents/skills/cherry"))
        case .codexRules:
            if environment.isRelative("CODEX_HOME") {
                return .failure(CherrySkillProblem("CODEX_HOME is not an absolute path"))
            }
            return .success(environment.codexDirectory.appendingPathComponent("rules/cherry.rules"))
        }
    }

    func path(of target: CherrySkillTarget) -> String {
        switch location(of: target) {
        case .success(let url): url.path
        case .failure: ""
        }
    }

    // MARK: Status

    /// The targets for `agents` (all of them when nil), each with the
    /// agents found (or asked for) that read it.
    public func items(for agents: [CherrySkillAgent]? = nil) -> [CherrySkillItem] {
        targets(for: agents).map { item(for: $0, agents: agents) }
    }

    func targets(for agents: [CherrySkillAgent]?) -> [CherrySkillTarget] {
        guard let agents else { return CherrySkillTarget.allCases }
        return CherrySkillTarget.allCases.filter { !Set($0.agents).isDisjoint(with: agents) }
    }

    /// The agents of `target` that are here, or that the request named.
    func present(_ target: CherrySkillTarget, requested: [CherrySkillAgent]?) -> [CherrySkillAgent] {
        target.agents.filter { requested?.contains($0) == true || environment.hasAgent($0) }
    }

    func item(for target: CherrySkillTarget, agents requested: [CherrySkillAgent]?) -> CherrySkillItem {
        let agents = present(target, requested: requested)
        var item = onDisk(target)
        item.agents = agents
        if agents.isEmpty, item.status == .missing {
            item.status = .unsupported
            item.detail = target.agents.map(\.displayName).joined(separator: ", ") + " not found"
        }
        return item
    }

    /// `target` as it is on disk, whoever reads it.
    func onDisk(_ target: CherrySkillTarget) -> CherrySkillItem {
        switch location(of: target) {
        case .failure(let problem):
            return CherrySkillItem(target: target, path: "", agents: [], status: .unreadable, detail: problem.message)
        case .success(let url):
            let (status, detail) = target == .codexRules ? rulesStatus(at: url) : skillStatus(at: url)
            return CherrySkillItem(target: target, path: url.path, agents: [], status: status, detail: detail)
        }
    }

    var files: any CherrySkillFiles { environment.files }

    func entry(at url: URL) -> CherrySkillEntry {
        files.entry(url.path)
    }

    func skillStatus(at folder: URL) -> (CherrySkillStatus, String?) {
        switch entry(at: folder) {
        case .none: return (.missing, nil)
        case .link: return (.unreadable, "\(folder.path) is a link")
        case .file: return (.unreadable, "\(folder.path) is a file, not a folder")
        case .directory: break
        }
        let skill = folder.appendingPathComponent("SKILL.md")
        let marker = folder.appendingPathComponent(CherrySkill.markerFileName)
        for url in [skill, marker] where entry(at: url) == .link {
            return (.unreadable, "\(url.path) is a link")
        }
        let hasMarker = entry(at: marker) == .file
        guard entry(at: skill) == .file else {
            if hasMarker { return (.outdated, "SKILL.md is missing") }
            let contents = files.list(folder.path) ?? []
            return contents.isEmpty ? (.missing, nil) : (.foreign, "a cherry folder Cherry didn't write")
        }
        guard let data = files.contents(skill.path) else {
            return (.unreadable, "can't read \(skill.path)")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard hasMarker, let markerData = files.contents(marker.path),
              let object = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
              object["by"] as? String == "Cherry", let hash = object["sha256"] as? String
        else { return (.foreign, "a cherry skill Cherry didn't write") }
        guard hash == sha256Hex(text) else { return (.foreign, "changed since Cherry wrote it") }
        return text == skillFileText ? (.current, nil) : (.outdated, nil)
    }

    func rulesStatus(at file: URL) -> (CherrySkillStatus, String?) {
        switch entry(at: file) {
        case .none: return (.missing, nil)
        case .link: return (.unreadable, "\(file.path) is a link")
        case .directory: return (.unreadable, "\(file.path) is a folder")
        case .file: break
        }
        guard let data = files.contents(file.path) else {
            return (.unreadable, "can't read \(file.path)")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            == CherrySkill.rulesFirstLine
        else { return (.foreign, "a cherry.rules Cherry didn't write") }
        return text == rulesText ? (.current, nil) : (.outdated, nil)
    }

    // MARK: Setup

    /// What setup would write for `targets`, for a confirmation.
    public func files(for targets: [CherrySkillTarget]) -> [CherrySkillFile] {
        targets.flatMap { target -> [CherrySkillFile] in
            guard case .success(let url) = location(of: target) else { return [] }
            if target == .codexRules { return [CherrySkillFile(path: url.path, contents: rulesText)] }
            return [
                CherrySkillFile(path: url.appendingPathComponent("SKILL.md").path, contents: skillFileText),
                CherrySkillFile(
                    path: url.appendingPathComponent(CherrySkill.markerFileName).path,
                    contents: Self.markerText(for: skillFileText)
                ),
            ]
        }
    }

    /// Writes the targets of `agents` (all found when nil): missing and
    /// outdated ones, a foreign one only with `force`; never through a
    /// link. `dryRun` writes nothing and says what it would do; `targets`
    /// limits it to those (Connect writes what its confirmation showed).
    public func setup(
        agents: [CherrySkillAgent]? = nil,
        targets: [CherrySkillTarget]? = nil,
        force: Bool = false,
        dryRun: Bool = false
    ) -> [CherrySkillChange] {
        items(for: agents).filter { targets?.contains($0.target) ?? true }.map { item in
            switch item.status {
            case .current:
                return CherrySkillChange(item: item, change: .unchanged)
            case .unsupported:
                return CherrySkillChange(item: item, change: .skipped, detail: "\(item.detail ?? "not found"); name it with --agent")
            case .unreadable:
                return CherrySkillChange(item: item, change: .failed, detail: item.detail)
            case .foreign where !force:
                return CherrySkillChange(item: item, change: .skipped, detail: "\(item.detail ?? "not Cherry's"); --force replaces it")
            case .missing, .outdated, .foreign:
                let replaces = item.status != .missing
                if dryRun {
                    return CherrySkillChange(item: item, change: replaces ? .wouldReplace : .wouldWrite)
                }
                do {
                    try write(item.target)
                    var written = item
                    written.status = .current
                    written.detail = nil
                    return CherrySkillChange(item: written, change: replaces ? .replaced : .wrote)
                } catch {
                    return CherrySkillChange(item: item, change: .failed, detail: "\(error)")
                }
            }
        }
    }

    func write(_ target: CherrySkillTarget) throws {
        let url = try location(of: target).get()
        files.begin(target)
        if target == .codexRules {
            try files.createDirectory(url.deletingLastPathComponent().path)
            guard entry(at: url) != .link else { throw CherrySkillProblem("\(url.path) is a link") }
            try files.write(rulesText, to: url.path)
            return
        }
        guard entry(at: url) != .link else { throw CherrySkillProblem("\(url.path) is a link") }
        try files.createDirectory(url.path)
        let skill = url.appendingPathComponent("SKILL.md")
        let marker = url.appendingPathComponent(CherrySkill.markerFileName)
        for file in [skill, marker] where entry(at: file) == .link {
            throw CherrySkillProblem("\(file.path) is a link")
        }
        try files.write(skillFileText, to: skill.path)
        try files.write(Self.markerText(for: skillFileText), to: marker.path)
    }

    // MARK: Remove

    /// Removes Cherry's own files of `agents`' targets (all when nil),
    /// whether or not the agents are still here, and leaves anything else.
    /// The shared skill stays while an agent found that the request did not
    /// name still reads it.
    public func remove(agents: [CherrySkillAgent]? = nil, dryRun: Bool = false) -> [CherrySkillChange] {
        targets(for: agents).map { target in
            var item = onDisk(target)
            item.agents = present(target, requested: agents)
            switch item.status {
            case .missing, .unsupported:
                return CherrySkillChange(item: item, change: .unchanged, detail: "nothing to remove")
            case .foreign, .unreadable:
                return CherrySkillChange(item: item, change: .skipped, detail: item.detail)
            case .current, .outdated:
                if let agents {
                    let others = item.agents.filter { !agents.contains($0) && environment.hasAgent($0) }
                    if !others.isEmpty {
                        return CherrySkillChange(
                            item: item,
                            change: .skipped,
                            detail: "still read by " + others.map(\.displayName).joined(separator: ", ")
                        )
                    }
                }
                if dryRun { return CherrySkillChange(item: item, change: .wouldRemove) }
                do {
                    try delete(target, at: URL(fileURLWithPath: item.path))
                    item.status = .missing
                    item.detail = nil
                    return CherrySkillChange(item: item, change: .removed)
                } catch {
                    return CherrySkillChange(item: item, change: .failed, detail: "\(error)")
                }
            }
        }
    }

    func delete(_ target: CherrySkillTarget, at url: URL) throws {
        files.begin(target)
        if target == .codexRules {
            try files.remove(url.path)
            return
        }
        // What the folder holds besides Cherry's two files, read before
        // they go (a folder that cannot be listed stays).
        var left = files.list(url.path).map(Set.init)
        for name in ["SKILL.md", CherrySkill.markerFileName] {
            let file = url.appendingPathComponent(name)
            if entry(at: file) != .none {
                try files.remove(file.path)
                left?.remove(name)
            }
        }
        if left?.isEmpty == true {
            try files.remove(url.path)
        }
    }
}

public struct CherrySkillProblem: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
