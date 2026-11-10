import CherryControl
import Foundation

/// `AgentConversations` for a device's tabs (docs/specs/remote-devices.md):
/// the same files of the same CLIs, by the same rules, read on that Mac by
/// a `sh -s` script over its ssh (the device's master while it is up),
/// never a file or a pid of This Mac. Claude Code's session comes from the
/// registry file of the program the host reports (`SessionInfo.pid`,
/// `TerminalSession.remoteProgramProcessID`) or of one under it; Codex's
/// thread from the rollouts that name the tab (a device's launches carry
/// Cherry's line too, `AgentCLILaunch.deviceArguments`). Times are that
/// Mac's: each answer says what time it is there, and This Mac's times are
/// moved onto that clock. The app's device windows only
/// (`SessionBackendPolicy.deviceAgentConversations`).
struct DeviceAgentConversations: Sendable {
    /// What a look on the device found.
    enum Answer<Value: Sendable>: Sendable {
        case answered(Value)
        /// The Mac could not be asked: offline, ssh failed or took too
        /// long, or a device Cherry no longer knows.
        case unreachable
    }

    /// The device's name, for the log.
    var machine: String
    /// Runs a script there and says what it printed; nil when the device
    /// is no longer known.
    var run: @Sendable (String) async -> RemoteDeviceShell.DataOutput?
    /// Claude Code's configuration folder there when the tab's environment
    /// names one (`CLAUDE_CONFIG_DIR`); else that Mac's `CLAUDE_CONFIG_DIR`
    /// or `~/.claude`.
    var claudeConfigDirectory: String?
    /// Codex's home there when the tab's environment names one
    /// (`CODEX_HOME`); else that Mac's `CODEX_HOME` or `~/.codex`.
    var codexHome: String?

    /// The first line the scripts print.
    static let begin = "CHERRY-AGENT-CONVERSATIONS 1"
    /// The most bytes of an answer read.
    static let answerLimit = 8 * 1024 * 1024

    /// The app's, for a device's hosting: through that device's ssh.
    @MainActor static func app(for hosting: PersistentHostSessions) -> DeviceAgentConversations {
        let host = hosting.profile.host
        return DeviceAgentConversations(machine: hosting.profile.displayName) { script in
            guard let destination = await MainActor.run(body: { RemoteDeviceStore.shared.device(for: host)?.sshDestination }) else {
                return nil
            }
            let shell = await RemoteDeviceShell.app(through: destination, timeout: 30)
            return await shell.runData(script, on: destination)
        }
    }

    /// These folders as a tab's own environment moves them (an agent
    /// definition's variables, which its launch there gets too; only
    /// absolute paths count).
    func applying(environment: [String: String]) -> DeviceAgentConversations {
        func folder(_ key: String) -> String? {
            guard let path = environment[key], path.hasPrefix("/") else { return nil }
            return path
        }
        var moved = self
        moved.claudeConfigDirectory = folder("CLAUDE_CONFIG_DIR") ?? claudeConfigDirectory
        moved.codexHome = folder("CODEX_HOME") ?? codexHome
        return moved
    }

    // MARK: Looks

    /// The session of the Claude Code that runs there as `rootPID` or under
    /// it, as `AgentConversations.claudeSession` finds it.
    func claudeSession(runningUnder rootPID: Int32) async -> Answer<String?> {
        guard rootPID > 0 else { return .answered(nil) }
        guard let body = Self.body(of: await run(Self.claudeSessionScript(rootPID: rootPID, configDirectory: claudeConfigDirectory))) else {
            return .unreachable
        }
        return .answered(Self.claudeSession(in: body))
    }

    /// Whether Claude Code there still has the conversation `session`, as
    /// `AgentConversations.claudeHasConversation` says.
    func claudeHasConversation(_ session: String) async -> Answer<Bool> {
        guard UUID(uuidString: session) != nil else { return .answered(false) }
        guard let body = Self.body(of: await run(Self.claudeTranscriptScript(session: session, configDirectory: claudeConfigDirectory))) else {
            return .unreachable
        }
        return .answered(Self.lines(of: body).contains { $0 == "transcript" })
    }

    /// The latest thread there of the Codex that tab `tabID` started, as
    /// `AgentConversations.codexThread` finds it: `createdSince` is This
    /// Mac's time, moved onto that Mac's clock.
    func codexThread(
        launchedInTab tabID: UUID,
        createdSince: Date? = nil,
        now: @Sendable () -> Date = { Date() }
    ) async -> Answer<String?> {
        let marker = AgentConversations.codexTabMarker(tabID)
        let output = await run(Self.codexScript(marker: marker, home: codexHome))
        let answeredAt = now()
        guard let body = Self.body(of: output) else { return .unreachable }
        return .answered(Self.codexThread(in: body, marker: marker, createdSince: createdSince, answeredAt: answeredAt))
    }

    // MARK: Scripts

    /// Sets `dir` to Claude Code's configuration folder there.
    private static func claudeDirectoryLine(_ configDirectory: String?) -> String {
        if let configDirectory {
            return "dir=\(ShellQuoting.singleQuoted(configDirectory))"
        }
        return #"case ${CLAUDE_CONFIG_DIR-} in /*) dir=$CLAUDE_CONFIG_DIR ;; *) dir=$HOME/.claude ;; esac"#
    }

    /// Prints the time there (`now <seconds>`), then, for `rootPID` and the
    /// processes under it (nearest first), each one that has a registry file
    /// this user owns, not a link: `claude <pid> <elapsed> <file, base64>`,
    /// its elapsed time as ps(1) says it.
    static func claudeSessionScript(rootPID: Int32, configDirectory: String?) -> String {
        """
        \(claudeDirectoryLine(configDirectory))
        uid=$(id -u)
        printf '%s\\n' '\(begin)'
        printf 'now %s\\n' "$(date +%s)"
        ps -Ao pid=,ppid=,etime= | /usr/bin/awk -v root=\(rootPID) '
        { pid[NR] = $1; parent[NR] = $2; elapsed[$1] = $3 }
        END {
            queue[1] = root; seen[root] = 1; head = 1; tail = 1
            while (head <= tail) {
                p = queue[head]; head++
                if (p in elapsed) print p, elapsed[p]
                for (i = 1; i <= NR; i++)
                    if (parent[i] == p && !(pid[i] in seen)) { seen[pid[i]] = 1; tail++; queue[tail] = pid[i] }
            }
        }' | while read -r pid elapsed; do
            file=$dir/sessions/$pid.json
            [ -f "$file" ] && [ ! -h "$file" ] || continue
            [ -n "$(find "$file" -prune -type f -user "$uid" 2>/dev/null)" ] || continue
            printf 'claude %s %s %s\\n' "$pid" "$elapsed" "$(head -c 65536 "$file" | base64 | tr -d '\\n')"
        done

        """
    }

    /// Prints `transcript` when a project folder has `<session>.jsonl`, a
    /// regular file with something in it.
    static func claudeTranscriptScript(session: String, configDirectory: String?) -> String {
        """
        \(claudeDirectoryLine(configDirectory))
        printf '%s\\n' '\(begin)'
        for file in "$dir"/projects/*/\(ShellQuoting.singleQuoted(session + ".jsonl")); do
            if [ -f "$file" ] && [ ! -h "$file" ] && [ -s "$file" ]; then printf 'transcript\\n'; break; fi
        done

        """
    }

    /// For each rollout of Codex there that changed within
    /// `AgentConversations.codexThreadsLookBack`, owned by this user, whose
    /// first `codexRolloutPrefixLimit` bytes have `marker`: `codex
    /// <modified> <created> <lines, base64>`, the lines being its first and
    /// those of that prefix that have `marker`. Then the time there (`now
    /// <seconds>`), after the reads.
    static func codexScript(marker: String, home: String?) -> String {
        let homeLine = home.map { "home=\(ShellQuoting.singleQuoted($0))" }
            ?? #"case ${CODEX_HOME-} in /*) home=$CODEX_HOME ;; *) home=$HOME/.codex ;; esac"#
        let days = Int(AgentConversations.codexThreadsLookBack / (24 * 60 * 60))
        let limit = AgentConversations.codexRolloutPrefixLimit
        return """
        \(homeLine)
        uid=$(id -u)
        marker=\(ShellQuoting.singleQuoted(marker))
        printf '%s\\n' '\(begin)'
        find "$home/sessions" -type f -name 'rollout-*.jsonl' -mtime -\(days) -user "$uid" 2>/dev/null | while IFS= read -r file; do
            head -c \(limit) "$file" | grep -q -F -e "$marker" || continue
            times=$(stat -f '%m %B' "$file" 2>/dev/null) || continue
            lines=$( { head -n 1 "$file" | head -c \(limit); printf '\\n'; head -c \(limit) "$file" | tail -n +2 | grep -F -e "$marker"; } | base64 | tr -d '\\n')
            printf 'codex %s %s\\n' "$times" "$lines"
        done
        printf 'now %s\\n' "$(date +%s)"

        """
    }

    // MARK: Answers

    /// What a script printed after its first line; nil when the Mac could
    /// not be asked (or the device is no longer known). A script that ran
    /// and printed nothing of its own answered nothing.
    static func body(of output: RemoteDeviceShell.DataOutput?) -> Data? {
        guard let output else { return nil }
        let text = output.standardOutput.prefix(answerLimit)
        guard let marker = text.range(of: Data((begin + "\n").utf8)) else {
            if output.status == 255 || output.timedOut { return nil }
            return Data()
        }
        return Data(text[marker.upperBound...])
    }

    static func lines(of body: Data) -> [Substring] {
        String(decoding: body, as: UTF8.self).split(separator: "\n")
    }

    /// The session `claudeSessionScript`'s answer names: of the nearest
    /// process whose registry file it wrote itself
    /// (`AgentConversations.claudeSession(inRegistry:pid:processStart:)`,
    /// its start being that Mac's time less its elapsed time).
    static func claudeSession(in body: Data) -> String? {
        var now: TimeInterval?
        for line in lines(of: body) {
            let words = line.split(separator: " ", maxSplits: 3)
            if words.count == 2, words[0] == "now" {
                now = TimeInterval(words[1])
                continue
            }
            guard words.count == 4, words[0] == "claude",
                  let pid = Int32(words[1]),
                  let registry = Data(base64Encoded: String(words[3]))
            else { continue }
            let start = now.flatMap { now in elapsedSeconds(String(words[2])).map { now - $0 } }
            if let session = AgentConversations.claudeSession(inRegistry: registry, pid: pid, processStart: start) {
                return session
            }
        }
        return nil
    }

    /// The thread `codexScript`'s answer gives: the rollout changed last
    /// that `AgentConversations.codexThread(inRolloutPrefix:marker:)` takes,
    /// not one made before `createdSince` (This Mac's time, moved onto
    /// that Mac's clock by what it said the time was when it answered at
    /// `answeredAt`).
    static func codexThread(in body: Data, marker: String, createdSince: Date?, answeredAt: Date) -> String? {
        var now: TimeInterval?
        var rollouts: [(modified: TimeInterval, created: TimeInterval, lines: Data)] = []
        for line in lines(of: body) {
            let words = line.split(separator: " ", maxSplits: 3)
            if words.count == 2, words[0] == "now" {
                now = TimeInterval(words[1])
                continue
            }
            guard words.count == 4, words[0] == "codex",
                  let modified = TimeInterval(words[1]),
                  let created = TimeInterval(words[2]),
                  let lines = Data(base64Encoded: String(words[3]))
            else { continue }
            rollouts.append((modified, created, lines))
        }
        if let createdSince {
            // Without that Mac's time its clock is taken for This Mac's.
            let offset = now.map { $0 - answeredAt.timeIntervalSince1970 } ?? 0
            let since = createdSince.timeIntervalSince1970 + offset - 5
            rollouts.removeAll { $0.created < since }
        }
        let needle = Data(marker.utf8)
        for rollout in rollouts.sorted(by: { $0.modified > $1.modified }) {
            if let thread = AgentConversations.codexThread(inRolloutPrefix: rollout.lines, marker: needle) {
                return thread
            }
        }
        return nil
    }

    /// ps(1)'s elapsed time, `[[dd-]hh:]mm:ss`, in seconds.
    static func elapsedSeconds(_ text: String) -> TimeInterval? {
        var days = 0
        var clock = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            guard let value = Int(text[..<dash]) else { return nil }
            days = value
            clock = text[text.index(after: dash)...]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1! }
        return TimeInterval(days * 24 * 60 * 60 + seconds)
    }
}

/// Where a tab's agent keeps its conversations: This Mac's files, or those
/// of the device the tab runs on (`TerminalSession.conversationCLI`).
enum AgentConversationReader: Sendable {
    case thisMac(AgentConversations)
    case device(DeviceAgentConversations)

    /// `AgentConversations.claudeSession`, or the device's; off the main
    /// thread.
    func claudeSession(runningUnder pid: Int32) async -> DeviceAgentConversations.Answer<String?> {
        switch self {
        case .thisMac(let conversations):
            return .answered(await Task.detached(priority: .utility) {
                conversations.claudeSession(runningUnder: pid, processes: ShellProcessController.enumerateProcesses())
            }.value)
        case .device(let device):
            return await device.claudeSession(runningUnder: pid)
        }
    }

    func claudeHasConversation(_ session: String) async -> DeviceAgentConversations.Answer<Bool> {
        switch self {
        case .thisMac(let conversations):
            return .answered(await Task.detached(priority: .utility) { conversations.claudeHasConversation(session) }.value)
        case .device(let device):
            return await device.claudeHasConversation(session)
        }
    }

    func codexThread(launchedInTab tabID: UUID, createdSince: Date?) async -> DeviceAgentConversations.Answer<String?> {
        switch self {
        case .thisMac(let conversations):
            return .answered(await Task.detached(priority: .utility) {
                conversations.codexThread(launchedInTab: tabID, createdSince: createdSince)
            }.value)
        case .device(let device):
            return await device.codexThread(launchedInTab: tabID, createdSince: createdSince)
        }
    }

    var isDevice: Bool {
        if case .device = self { return true }
        return false
    }
}
