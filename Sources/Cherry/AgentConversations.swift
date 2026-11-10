import CherryControl
import Foundation

/// The conversation an agent tab's CLI keeps on disk, which Restart resumes
/// once the system ended the tab's program (a restart, a log out or a lost
/// holder: `SystemEndedSessions`, `HostSessionEnd.isHolderLost`) instead of
/// starting a new one (`TerminalSession.conversationToResume`). Saved with
/// the tab (`WorkspaceSessionRecord.agentConversation`).
struct AgentConversation: Equatable, Sendable {
    /// Claude Code or Codex.
    let cli: AgentLaunch.CLI
    /// Claude Code's session id or Codex's thread id: a UUID, as the CLI
    /// writes it.
    let id: String

    /// Nil unless `id` is a UUID of Claude Code's or Codex's: what goes on
    /// a command line is never anything else.
    init?(cli: AgentLaunch.CLI, id: String) {
        guard cli != .pi, UUID(uuidString: id) != nil else { return nil }
        self.cli = cli
        self.id = id
    }

    /// The conversation a record names; nil for none, or one this build
    /// cannot resume.
    init?(_ record: AgentConversationRecord?) {
        guard let record, let cli = AgentLaunch.CLI(rawValue: record.cli) else { return nil }
        self.init(cli: cli, id: record.id)
    }

    var record: AgentConversationRecord {
        AgentConversationRecord(cli: cli.rawValue, id: id)
    }
}

/// An `AgentConversation` as a tab's record saves it: two strings, so a
/// record never fails to read over it (another build's CLI, a damaged id).
struct AgentConversationRecord: Codable, Equatable, Sendable {
    /// `AgentLaunch.CLI`'s raw value: `claudeCode` or `codex`.
    var cli: String
    var id: String
}

/// Where This Mac's agent CLIs keep their conversations, and how Cherry
/// reads them (`SessionBackendPolicy.agentConversations`: the app's This
/// Mac windows only; tests give temporary folders; a device's tabs are
/// `DeviceAgentConversations`', by the same rules). These are the CLIs' own
/// files, read only, never written:
/// - Claude Code writes `<config>/sessions/<pid>.json` for each running
///   session (`sessionId`, which follows `/clear` and `/resume`, and
///   `startedAt`) and keeps each conversation in
///   `<config>/projects/<folder>/<sessionId>.jsonl`.
/// - Codex keeps each thread in `<home>/sessions/YYYY/MM/DD/rollout-*.jsonl`,
///   whose first lines are its metadata (`session_meta`) and its developer
///   messages, among them Cherry's instructions line, which names the tab
///   (`AgentCLILaunch.instructionLine`). Its threads run in a background
///   server shared by every tab, so nothing else ties one to its tab.
/// Checked with Claude Code 2.1.319 and Codex 0.166.0; recheck after an
/// upgrade. When a CLI changes them Cherry finds nothing, and Restart
/// starts a new conversation, as it did before.
struct AgentConversations: Sendable {
    /// Claude Code's configuration folder: `~/.claude`, or `CLAUDE_CONFIG_DIR`.
    var claudeConfigDirectory: URL
    /// Codex's home: `~/.codex`, or `CODEX_HOME`.
    var codexHome: URL

    /// The app's: the user's home folder's.
    static var app: AgentConversations {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return AgentConversations(
            claudeConfigDirectory: home.appendingPathComponent(".claude", isDirectory: true),
            codexHome: home.appendingPathComponent(".codex", isDirectory: true)
        )
    }

    /// These folders as a tab's own environment moves them
    /// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`: an agent definition's
    /// variables; only absolute paths count).
    func applying(environment: [String: String]) -> AgentConversations {
        func folder(_ key: String) -> URL? {
            guard let path = environment[key], path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return AgentConversations(
            claudeConfigDirectory: folder("CLAUDE_CONFIG_DIR") ?? claudeConfigDirectory,
            codexHome: folder("CODEX_HOME") ?? codexHome
        )
    }

    // MARK: Claude Code

    /// The session of the Claude Code that runs as `rootPID` or under it
    /// (an alias or a wrapper may start it as a child), the one closest to
    /// `rootPID`: its registry file names it. A file the process did not
    /// write (one left by an earlier process with the same pid, started
    /// before this one) does not count.
    func claudeSession(
        runningUnder rootPID: Int32,
        processes: [ShellProcessController.ProcessSnapshotEntry],
        startTime: (Int32) -> TimeInterval? = AgentConversations.processStartTime
    ) -> String? {
        guard rootPID > 0 else { return nil }
        var children: [Int32: [Int32]] = [:]
        for process in processes where process.pid != process.parentPID {
            children[process.parentPID, default: []].append(process.pid)
        }
        var visited = Set<Int32>()
        var queue = [rootPID]
        var index = 0
        while index < queue.count {
            let pid = queue[index]
            index += 1
            guard visited.insert(pid).inserted else { continue }
            if let session = claudeRegisteredSession(of: pid, startedAt: startTime(pid)) {
                return session
            }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return nil
    }

    /// What `<config>/sessions/<pid>.json` says the session of process
    /// `pid` is, when that process wrote it: its `pid`, and a `startedAt`
    /// (milliseconds) no earlier than `processStart` (less a few seconds,
    /// for clocks rounding apart).
    func claudeRegisteredSession(of pid: Int32, startedAt processStart: TimeInterval?) -> String? {
        let url = claudeConfigDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(pid).json", isDirectory: false)
        guard let data = Self.readRegularFile(url, limit: 64 * 1024) else { return nil }
        return Self.claudeSession(inRegistry: data, pid: pid, processStart: processStart)
    }

    /// The session a registry file names, when process `pid` wrote it (see
    /// `claudeRegisteredSession`; a device's are read there,
    /// `DeviceAgentConversations`).
    static func claudeSession(inRegistry data: Data, pid: Int32, processStart: TimeInterval?) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["pid"] as? NSNumber)?.int32Value == pid,
              let session = object["sessionId"] as? String,
              UUID(uuidString: session) != nil
        else { return nil }
        if let processStart {
            guard let startedAt = (object["startedAt"] as? NSNumber)?.doubleValue,
                  startedAt / 1000 >= processStart - 5
            else { return nil }
        }
        return session
    }

    /// Whether Claude Code still has the conversation `session`: a
    /// `<session>.jsonl` with something in it in one of its project folders
    /// (`claude --resume` of one it does not have says so and exits).
    func claudeHasConversation(_ session: String) -> Bool {
        guard UUID(uuidString: session) != nil else { return false }
        let projects = claudeConfigDirectory.appendingPathComponent("projects", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return folders.contains { folder in
            let transcript = folder.appendingPathComponent("\(session).jsonl", isDirectory: false)
            guard let values = try? transcript.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    // MARK: Codex

    /// How far back Codex's threads are looked at: by when their rollout
    /// last changed.
    static let codexThreadsLookBack: TimeInterval = 30 * 24 * 60 * 60
    /// How much of a rollout is read: its metadata and developer messages
    /// come first (about 110 KB with Codex 0.166's tools).
    static let codexRolloutPrefixLimit = 1024 * 1024

    /// The latest thread of the Codex that tab `tabID` started: the
    /// rollout changed last whose developer messages carry Cherry's
    /// instructions line naming that tab (a `/new` there starts a thread
    /// with the line too), not a subagent's (Codex's reviewer threads quote
    /// their parent's). Nil when none does: the Codex started without the
    /// line (its configuration sets its own instructions, or its version was
    /// not known yet).
    ///
    /// `createdSince`: when the tab's agent last started; a rollout made
    /// before (an earlier launch's thread, or one this launch resumed) is
    /// not this launch's new thread.
    func codexThread(launchedInTab tabID: UUID, createdSince: Date? = nil, now: Date = Date()) -> String? {
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let since = now.addingTimeInterval(-Self.codexThreadsLookBack)
        var rollouts: [(url: URL, modified: Date)] = []
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since
            else { continue }
            // Clocks and file times round apart by a little.
            if let createdSince, let created = values.creationDate, created < createdSince.addingTimeInterval(-5) {
                continue
            }
            rollouts.append((url, modified))
        }
        let needle = Data(Self.codexTabMarker(tabID).utf8)
        for rollout in rollouts.sorted(by: { $0.modified > $1.modified }) {
            guard let prefix = Self.readRegularFile(rollout.url, limit: Self.codexRolloutPrefixLimit),
                  prefix.range(of: needle) != nil,
                  let thread = Self.codexThread(inRolloutPrefix: prefix, marker: needle)
            else { continue }
            return thread
        }
        return nil
    }

    /// What Cherry's instructions line says of tab `tabID`.
    static func codexTabMarker(_ tabID: UUID) -> String {
        "(CHERRY_PROCESS_ID \(tabID.uuidString))"
    }

    /// The thread id of a rollout whose first line is its metadata, when
    /// it is not a subagent's (its `source` is a word, not an object) and
    /// a developer message among its complete lines carries `marker`.
    static func codexThread(inRolloutPrefix prefix: Data, marker: Data) -> String? {
        var lines = prefix.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // The last line may be cut where the read stopped.
        if prefix.last != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeLast() }
        guard let first = lines.first,
              let meta = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any],
              payload["source"] is String,
              let thread = payload["id"] as? String,
              UUID(uuidString: thread) != nil
        else { return nil }
        let carriesMarker = lines.dropFirst().contains { line in
            guard Data(line).range(of: marker) != nil,
                  let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  item["type"] as? String == "response_item",
                  let message = item["payload"] as? [String: Any]
            else { return false }
            return message["role"] as? String == "developer"
        }
        return carriesMarker ? thread : nil
    }

    // MARK: Files and processes

    /// When process `pid` started (seconds since 1970), nil when it is gone.
    static func processStartTime(_ pid: Int32) -> TimeInterval? {
        UnixIO.processStartIdentity(pid).flatMap(TimeInterval.init)
    }

    /// Up to `limit` bytes of a regular file this user owns, without
    /// following a link.
    static func readRegularFile(_ url: URL, limit: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid() else {
            return nil
        }
        return try? handle.read(upToCount: limit)
    }
}

/// An agent's command line that resumes its conversation instead of
/// starting one: Claude Code's `--resume <id>` and Codex's `resume <id>`,
/// appended to the tab's command (Codex takes its options before the
/// subcommand), before Cherry's flags (`TerminalSession.commandWithAgentFlags`).
enum AgentConversationResume {
    /// `commandLine` resuming `conversation`; nil unless it is a plain
    /// command of that conversation's CLI (`AgentLaunch.detection`) whose
    /// words are all options and their values: a word that is neither (a
    /// prompt, a subcommand, a value of an option Cherry does not know)
    /// would be read again or misread, and an option that picks the session
    /// itself (Claude Code's `--continue`, `--resume`, `--session-id`,
    /// `--fork-session`, `--print`) would fight the one appended.
    static func commandLine(resuming conversation: AgentConversation, from commandLine: String) -> String? {
        guard case .cli(let cli, _) = AgentLaunch.detection(commandLine: commandLine), cli == conversation.cli,
              let words = AgentLaunch.plainWords(commandLine),
              onlyOptions(Array(words.dropFirst()), of: cli)
        else { return nil }
        switch cli {
        case .claudeCode:
            return commandLine + AgentLaunch.shellSuffix(["--resume", conversation.id])
        case .codex:
            return commandLine + AgentLaunch.shellSuffix(["resume", conversation.id])
        case .pi:
            return nil
        }
    }

    /// Claude Code's options that pick or start a session of their own.
    static let claudeSessionOptions: Set<String> = [
        "-c", "--continue", "-r", "--resume", "--session-id", "--fork-session", "-p", "--print", "--from-pr",
    ]

    /// Whether `arguments` are only options, each value-taking one
    /// (`AgentLaunch.CLI.optionsTakingValue`) followed by its value.
    static func onlyOptions(_ arguments: [String], of cli: AgentLaunch.CLI) -> Bool {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            guard word.hasPrefix("-"), word.count > 1 else { return false }
            let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
            if cli == .claudeCode, claudeSessionOptions.contains(name) { return false }
            if !word.contains("="), cli.optionsTakingValue.contains(word) {
                guard index + 1 < arguments.count else { return false }
                index += 2
            } else {
                index += 1
            }
        }
        return true
    }
}
