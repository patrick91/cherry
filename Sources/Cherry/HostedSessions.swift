import CherryControl
import Darwin
import Foundation

/// An SSH destination is a normal OpenSSH alias (or user@host), never a shell command.
struct HostedSessionHost: Codable, Hashable, Identifiable, Sendable {
    var id: String { sshDestination.map { "ssh:\($0)" } ?? "local" }
    let sshDestination: String?

    static let local = HostedSessionHost(sshDestination: nil)
    var displayName: String { sshDestination ?? "This Mac" }

    static func ssh(_ input: String) throws -> HostedSessionHost {
        let destination = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:[%]")
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              destination.utf8.count <= 512,
              destination.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw HostedSessionError.message("Enter an SSH host alias or user@hostname, without options.")
        }
        return HostedSessionHost(sshDestination: destination)
    }

    /// The CLI's global options for this host. While the app's SSH master for
    /// the destination is up, `--ssh-control-path` makes the CLI's ssh share
    /// it. A process started with these arguments must hold a master lease
    /// (`HostSSHMasterManager`) for as long as it runs, or the master may
    /// stop under it.
    var arguments: [String] {
        arguments(sshControlPath: sshDestination.flatMap { HostSSHMasterManager.shared.controlPathIfUp(for: $0) })
    }

    /// `sshControlPath` is ignored for This Mac.
    func arguments(sshControlPath: String?) -> [String] {
        guard let sshDestination else { return [] }
        return ["--host", sshDestination] + (sshControlPath.map { ["--ssh-control-path", $0] } ?? [])
    }
}

enum HostedSessionState: String, Codable, Sendable {
    case running
    case exited
}

/// The terminal's foreground process group while a session runs.
struct HostedSessionForeground: Codable, Equatable, Sendable {
    /// The process group ID, which is its leader's process ID.
    let pid: UInt32
    /// The leader's name; empty when the host could not read it.
    let name: String
}

/// A working directory a program reported: an OSC 7 `file://host/path` URI
/// (percent-encoded), kitty's `kitty-shell-cwd://host/path` (not encoded) or
/// a plain absolute path (OSC 9;9, OSC 1337).
struct HostedReportedDirectory: Equatable, Sendable {
    /// The machine the report names, lowercased; nil when it names none
    /// (a plain path, `file:///path`) or `localhost`.
    let machine: String?
    let path: String

    init(machine: String?, path: String) {
        self.machine = machine
        self.path = path
    }

    /// Nil for anything but an absolute path or one of the URIs above.
    init?(reported: String) {
        if reported.hasPrefix("/") {
            self.init(machine: nil, path: reported)
            return
        }
        // Parsed by hand: shells emit unencoded spaces, which URL parsers refuse.
        let lowercased = reported.lowercased()
        for (scheme, isEncoded) in [("file://", true), ("kitty-shell-cwd://", false)] where lowercased.hasPrefix(scheme) {
            let afterScheme = reported.dropFirst(scheme.count)
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            let rawPath = String(afterScheme[slash...])
            let rawMachine = String(afterScheme[..<slash])
            let path = isEncoded ? rawPath.removingPercentEncoding ?? rawPath : rawPath
            let machine = (rawMachine.removingPercentEncoding ?? rawMachine).lowercased()
            self.init(machine: machine.isEmpty || machine == "localhost" ? nil : machine, path: path)
            return
        }
        return nil
    }

    /// Whether this is on the machine that goes by one of `names`, or names
    /// no machine. A trailing `.local` (macOS's Bonjour name) is ignored.
    func isOnMachine(namedAnyOf names: Set<String>) -> Bool {
        guard let machine else { return true }
        return names.contains { Self.canonical($0) == Self.canonical(machine) }
    }

    /// This Mac's host name, as shells report it (`$HOST`, `$HOSTNAME`).
    /// Read each time: it changes with the network.
    static func thisMacNames() -> Set<String> {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return [] }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? [] : [name]
    }

    private static func canonical(_ name: String) -> String {
        var name = name.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name
    }
}

/// The host's `SessionInfo`. Fields added in protocol 4 decode with defaults
/// when absent.
struct HostedSessionInfo: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let cwd: String
    let command: [String]
    let cols: Int
    let rows: Int
    let state: HostedSessionState
    let pid: UInt32?
    let exitCode: UInt32?
    let exitSignal: Int32?
    let attached: Bool
    /// The title the program set (OSC 0 or 2), when it set a non-empty one.
    let title: String?
    /// The working directory exactly as the program reported it: a
    /// percent-encoded `file://host/path` URI (OSC 7) or a plain path. See
    /// `reportedWorkingDirectory`.
    let pwd: String?
    let foreground: HostedSessionForeground?
    /// How many clients are attached.
    let clients: Int
    /// The app variant that created the session.
    let owner: String?
    let tags: [String: String]
    /// Milliseconds since the Unix epoch; 0 when the host did not say.
    let createdAt: UInt64
    /// Whether the program shows its alternate screen (a full-screen TUI);
    /// nil when the host does not report it (an older host).
    let alternateScreen: Bool?
    /// The kitty keyboard protocol flags the program enabled (0 for none);
    /// nil when the host does not report them (an older host).
    let kittyKeyboardFlags: UInt32?
    /// Whether the program turned on application cursor keys (DECCKM,
    /// `ESC [ ? 1 h`, as `less` and `vim` do) on the screen it shows: in
    /// legacy key encoding (`kittyKeyboardFlags` 0), its unmodified arrow,
    /// Home and End keys are then `ESC O x`, not `ESC [ x`. Nil when the
    /// host does not report it (an older host); false also from a session
    /// whose holder does not report it.
    let applicationCursorKeys: Bool?
    /// Whether the program turned on bracketed paste (DECSET 2004, as
    /// shells, editors and agents do at their prompts): a paste is then
    /// wrapped in `ESC [ 200 ~` and `ESC [ 201 ~`. Nil when it is not
    /// known: from a host older than protocol 7, or for a session whose
    /// holder predates holder link 7.
    let bracketedPaste: Bool?
    /// The `request_id` of the Create that started the session; nil when
    /// the host does not report it (an older host).
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, cwd, command, cols, rows, state, pid, attached, title, pwd, foreground, clients, owner, tags
        case exitCode = "exit_code"
        case exitSignal = "exit_signal"
        case createdAt = "created_at"
        case alternateScreen = "alternate_screen"
        case kittyKeyboardFlags = "kitty_keyboard_flags"
        case applicationCursorKeys = "application_cursor_keys"
        case bracketedPaste = "bracketed_paste"
        case requestID = "request_id"
    }

    init(
        id: String,
        name: String,
        cwd: String,
        command: [String] = [],
        cols: Int = HostProtocol.defaultCols,
        rows: Int = HostProtocol.defaultRows,
        state: HostedSessionState = .running,
        pid: UInt32? = nil,
        exitCode: UInt32? = nil,
        exitSignal: Int32? = nil,
        attached: Bool? = nil,
        title: String? = nil,
        pwd: String? = nil,
        foreground: HostedSessionForeground? = nil,
        clients: Int = 0,
        owner: String? = nil,
        tags: [String: String] = [:],
        createdAt: UInt64 = 0,
        alternateScreen: Bool? = nil,
        kittyKeyboardFlags: UInt32? = nil,
        applicationCursorKeys: Bool? = nil,
        bracketedPaste: Bool? = nil,
        requestID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.cols = cols
        self.rows = rows
        self.state = state
        self.pid = pid
        self.exitCode = exitCode
        self.exitSignal = exitSignal
        self.attached = attached ?? (clients > 0)
        self.title = title
        self.pwd = pwd
        self.foreground = foreground
        self.clients = clients
        self.owner = owner
        self.tags = tags
        self.createdAt = createdAt
        self.alternateScreen = alternateScreen
        self.kittyKeyboardFlags = kittyKeyboardFlags
        self.applicationCursorKeys = applicationCursorKeys
        self.bracketedPaste = bracketedPaste
        self.requestID = requestID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let clients = try container.decodeIfPresent(Int.self, forKey: .clients) ?? 0
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            cwd: try container.decode(String.self, forKey: .cwd),
            command: try container.decode([String].self, forKey: .command),
            cols: try container.decode(Int.self, forKey: .cols),
            rows: try container.decode(Int.self, forKey: .rows),
            state: try container.decode(HostedSessionState.self, forKey: .state),
            pid: try container.decodeIfPresent(UInt32.self, forKey: .pid),
            exitCode: try container.decodeIfPresent(UInt32.self, forKey: .exitCode),
            exitSignal: try container.decodeIfPresent(Int32.self, forKey: .exitSignal),
            attached: try container.decodeIfPresent(Bool.self, forKey: .attached) ?? (clients > 0),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            pwd: try container.decodeIfPresent(String.self, forKey: .pwd),
            foreground: try container.decodeIfPresent(HostedSessionForeground.self, forKey: .foreground),
            clients: clients,
            owner: try container.decodeIfPresent(String.self, forKey: .owner),
            tags: try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:],
            createdAt: try container.decodeIfPresent(UInt64.self, forKey: .createdAt) ?? 0,
            alternateScreen: try container.decodeIfPresent(Bool.self, forKey: .alternateScreen),
            kittyKeyboardFlags: try container.decodeIfPresent(UInt32.self, forKey: .kittyKeyboardFlags),
            applicationCursorKeys: try container.decodeIfPresent(Bool.self, forKey: .applicationCursorKeys),
            bracketedPaste: try container.decodeIfPresent(Bool.self, forKey: .bracketedPaste),
            requestID: try container.decodeIfPresent(String.self, forKey: .requestID)
        )
    }

    /// The protocol's shape: every field, `null` for an absent value. The
    /// fields an older host leaves out are left out when unknown.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(command, forKey: .command)
        try container.encode(cols, forKey: .cols)
        try container.encode(rows, forKey: .rows)
        try container.encode(state, forKey: .state)
        try container.encode(pid, forKey: .pid)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(attached, forKey: .attached)
        try container.encode(exitSignal, forKey: .exitSignal)
        try container.encode(title, forKey: .title)
        try container.encode(pwd, forKey: .pwd)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(clients, forKey: .clients)
        try container.encode(owner, forKey: .owner)
        try container.encode(tags, forKey: .tags)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(alternateScreen, forKey: .alternateScreen)
        try container.encodeIfPresent(kittyKeyboardFlags, forKey: .kittyKeyboardFlags)
        try container.encodeIfPresent(applicationCursorKeys, forKey: .applicationCursorKeys)
        try container.encodeIfPresent(bracketedPaste, forKey: .bracketedPaste)
        try container.encodeIfPresent(requestID, forKey: .requestID)
    }

    var isRunning: Bool { state == .running }
    var displayName: String { name.isEmpty ? String(id.prefix(8)) : name }

    /// A program other than the session's own leader is in the foreground
    /// (a command runs in the shell).
    var isBusy: Bool {
        guard isRunning, let pid, let foreground else { return false }
        return foreground.pid != pid
    }

    var createdDate: Date? {
        createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAt) / 1_000) : nil
    }

    /// Where the program says it is (`pwd` decoded), on whichever machine it
    /// names. A shell reached with ssh from inside the session reports its
    /// own machine's directory: see `workingDirectory(onMachineNamed:)`.
    var reportedDirectory: HostedReportedDirectory? {
        pwd.flatMap(HostedReportedDirectory.init(reported:))
    }

    /// The reported path when it is on the machine that goes by one of
    /// `names`, or when the report names no machine.
    func workingDirectory(onMachineNamed names: Set<String>) -> String? {
        guard let reported = reportedDirectory, reported.isOnMachine(namedAnyOf: names) else { return nil }
        return reported.path
    }

    /// The reported path for a session on This Mac; nil when it is another
    /// machine's (as Ghostty ignores such an OSC 7).
    var localWorkingDirectory: String? {
        workingDirectory(onMachineNamed: HostedReportedDirectory.thisMacNames())
    }

    var statusText: String {
        if isRunning { return attached ? "Attached" : "Running" }
        if let exitSignal { return "Exited (signal \(exitSignal))" }
        if let exitCode { return "Exited (\(exitCode))" }
        return "Exited"
    }

    /// This session after the host reported it exited.
    func exited(code: UInt32, signal: Int32?) -> HostedSessionInfo {
        HostedSessionInfo(
            id: id, name: name, cwd: cwd, command: command, cols: cols, rows: rows,
            state: .exited, pid: pid, exitCode: code, exitSignal: signal, attached: attached,
            title: title, pwd: pwd, foreground: nil, clients: clients, owner: owner, tags: tags,
            createdAt: createdAt, alternateScreen: alternateScreen, kittyKeyboardFlags: kittyKeyboardFlags,
            applicationCursorKeys: applicationCursorKeys, bracketedPaste: bracketedPaste, requestID: requestID
        )
    }
}

struct HostedSessionList: Codable, Equatable, Sendable {
    let hostID: String
    let sessions: [HostedSessionInfo]
    /// Session holders a daemon that just restarted still expects to
    /// register again: their sessions may be missing from `sessions` for
    /// now. 0 when the list is complete; nil when the host does not say (an
    /// older host), so a missing session may still be a late holder's.
    let pendingHolders: Int?

    init(hostID: String, sessions: [HostedSessionInfo], pendingHolders: Int? = nil) {
        self.hostID = hostID
        self.sessions = sessions
        self.pendingHolders = pendingHolders
    }

    /// Every session the host has is listed.
    var isComplete: Bool { pendingHolders == 0 }

    /// Holders are still expected: sessions missing now may come back.
    var awaitsHolders: Bool { (pendingHolders ?? 0) > 0 }

    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case sessions
        case pendingHolders = "pending_holders"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostID: try container.decode(String.self, forKey: .hostID),
            sessions: try container.decode([HostedSessionInfo].self, forKey: .sessions),
            pendingHolders: try container.decodeIfPresent(UInt32.self, forKey: .pendingHolders).map(Int.init)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(pendingHolders.map { UInt32(clamping: max($0, 0)) }, forKey: .pendingHolders)
    }
}

/// Host-issued identity survives every local attachment and is never a local PID.
struct HostedSessionAttachment: Equatable, Sendable {
    let host: HostedSessionHost
    let hostID: String
    let sessionID: String
    let name: String
    let remoteWorkingDirectory: String
    let executablePath: String
    /// Variables from the user's login shell (SSH agent socket, PATH). The
    /// adapter runs ssh, so it needs what a terminal tab's shell would see.
    var environment: [String: String] = [:]

    /// The embedded adapter has no in-band detach key: Ctrl-] belongs to the
    /// program (Vim tag jumps), and the tab's Disconnect button detaches.
    ///
    /// While the app's SSH master for the host is up, a launch (named by its
    /// status file's private directory) shares it: the launch keeps the
    /// master running until `HostedAttachmentStatusFile.removeLaunchDirectory`
    /// removes that directory. Otherwise the adapter runs its own ssh, which
    /// can still prompt in the tab.
    ///
    /// Compute this only to launch the adapter: the result depends on the
    /// master's state at that moment. Once the launch directory is gone the
    /// launch has ended, and computing it again keeps no master running.
    func arguments(
        statusFile: URL?,
        takeover: Bool = false,
        clientID: String? = nil,
        masters: HostSSHMasterManager = .shared
    ) -> [String] {
        arguments(
            statusFile: statusFile,
            takeover: takeover,
            sshControlPath: statusFile.flatMap { registerAdapterLaunch(statusFile: $0, masters: masters) },
            clientID: clientID
        )
    }

    /// Registers one adapter launch (named by its status file's private
    /// directory) with the host's SSH master while the master is up, and
    /// returns the ControlPath the launch shares; nil for This Mac or when
    /// the adapter runs its own ssh. The launch keeps the master running
    /// until `HostedAttachmentStatusFile.removeLaunchDirectory` removes that
    /// directory. Call it once per launch, when it starts.
    func registerAdapterLaunch(statusFile: URL, masters: HostSSHMasterManager = .shared) -> String? {
        guard let destination = host.sshDestination else { return nil }
        let launch = HostedAttachmentStatusFile.launchKey(ofStatusFile: statusFile)
        return masters.controlPath(forLaunch: launch, destination: destination) {
            FileManager.default.fileExists(atPath: launch)
        }
    }

    /// The adapter's arguments for a launch registered with
    /// `registerAdapterLaunch` (`sshControlPath` is what it returned). Pure.
    ///
    /// `clientID` names the client the adapter attaches as (a tab passes
    /// its id): when an adapter attaches a session with the id of one of
    /// that session's attachments, the host drops the older attachment, so
    /// an adapter launched again (a relaunched surface, a reconnect, an app
    /// that quit without detaching) never leaves a stale client pinning the
    /// session's grid.
    func arguments(statusFile: URL?, takeover: Bool, sshControlPath: String?, clientID: String? = nil) -> [String] {
        var arguments = host.arguments(sshControlPath: sshControlPath)
            + ["--expected-host-id", hostID, "attach", sessionID]
        if takeover { arguments.append("--takeover") }
        arguments += ["--detach-key", "none"]
        if let clientID { arguments += ["--client-id", clientID] }
        if let statusFile { arguments += ["--status-file", statusFile.path] }
        return arguments
    }

    func execCommand(statusFile: URL?, takeover: Bool = false, clientID: String? = nil) -> String {
        ([executablePath] + arguments(statusFile: statusFile, takeover: takeover, clientID: clientID))
            .map(Self.shellQuote).joined(separator: " ")
    }

    /// `execCommand` for a launch registered with `registerAdapterLaunch`.
    /// Pure: computing it again gives the same command.
    func execCommand(statusFile: URL?, takeover: Bool, sshControlPath: String?, clientID: String? = nil) -> String {
        ([executablePath] + arguments(
            statusFile: statusFile, takeover: takeover, sshControlPath: sshControlPath, clientID: clientID
        ))
            .map(Self.shellQuote).joined(separator: " ")
    }

    var adapterEnvironment: [String: String] {
        environment.merging(["TERM": "xterm-256color", "COLORTERM": "truecolor"]) { _, adapter in adapter }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum HostedAttachmentStatus: Equatable, Sendable {
    /// The local adapter is running; the terminal shows connection diagnostics.
    case active
    /// The adapter stopped or lost its connection. The hosted program may still
    /// run. The message is the adapter's explanation, when it gave one: a lost
    /// connection, or a detach the host never confirmed (so input not yet
    /// delivered to the program was discarded).
    case disconnected(String?)
    /// Another client attached with takeover, which ended this attachment.
    case takenOver
    /// The adapter could not attach; the message says why.
    case failed(String)
    /// The hosted program ended on its host. Reconnecting cannot resume it.
    case exited(code: Int32?, signal: Int32?)

    var sessionEnded: Bool {
        if case .exited = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .active:
            "Connected"
        case .disconnected(let message):
            message.map { "Disconnected: \($0)" } ?? "Disconnected"
        case .takenOver:
            "Another client took over"
        case .failed(let message):
            message
        case .exited(let code, let signal):
            if let signal {
                "Session ended (signal \(signal))"
            } else if let code {
                "Session ended (exit \(code))"
            } else {
                "Session ended"
            }
        }
    }

    var sidebarLabel: String? {
        switch self {
        case .active: nil
        case .disconnected: "disconnected"
        case .takenOver: "taken over"
        case .failed: "not attached"
        case .exited: "ended"
        }
    }
}

/// What a running attach adapter reports in its status file (`outcome`
/// "attached"): it rewrites the file whenever one of these changes.
struct HostedAdapterLiveStatus: Equatable, Sendable {
    /// The adapter shows only a viewport of the session's screen (another
    /// client made it larger than this terminal), so its surface is not
    /// the whole screen.
    var viewport: Bool
    /// The adapter lost the host (its daemon restarted or was replaced) and
    /// reconnects by itself; its surface keeps what it last showed, and
    /// the program's output does not reach it meanwhile.
    var reconnecting: Bool

    init(viewport: Bool = false, reconnecting: Bool = false) {
        self.viewport = viewport
        self.reconnecting = reconnecting
    }

    /// Attached and following the program: its surface shows the program
    /// and passes its bells, notifications, title and directory through.
    var followsProgram: Bool { !reconnecting }

    /// Its surface shows the program's whole screen.
    var showsWholeScreen: Bool { !reconnecting && !viewport }
}

/// `cherry attach --status-file` reports the adapter's live state while it
/// runs (`outcome` "attached", with `viewport` and `reconnecting`), and why
/// it exited (any other outcome) when it ends. Each adapter launch gets a
/// fresh private directory: the CLI writes the file atomically (temporary
/// file + rename) beside it, and the app deletes the directory once the
/// final outcome is read.
///
/// Directory names carry the owning app's PID. An app that quits with hosted
/// tabs attached never reads their outcomes (the adapters write them after
/// the app is gone), so each app run removes directories whose owner is no
/// longer running before its first launch. Another running Cherry keeps its own.
enum HostedAttachmentStatusFile {
    static let fileName = "status.json"
    private static let directoryPrefix = "cherry-attach-"
    private static let abandonedDirectoriesRemoved: Void = removeAbandonedLaunchDirectories(
        in: FileManager.default.temporaryDirectory
    )

    /// The outcome a running adapter writes; any other one is final.
    static let liveOutcome = "attached"

    private struct Record: Decodable {
        let outcome: String
        let exitCode: UInt32?
        let signal: Int32?
        let message: String?
        let viewport: Bool?
        let reconnecting: Bool?

        enum CodingKeys: String, CodingKey {
            case outcome, signal, message, viewport, reconnecting
            case exitCode = "exit_code"
        }
    }

    static func makeLaunchDirectory() throws -> URL {
        _ = abandonedDirectoriesRemoved
        return try makeLaunchDirectory(in: FileManager.default.temporaryDirectory)
    }

    static func makeLaunchDirectory(in parent: URL, ownerPID: pid_t = getpid()) throws -> URL {
        let directory = parent.appendingPathComponent(
            "\(directoryPrefix)\(ownerPID)-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    /// Removes launch directories whose owning app is no longer running.
    static func removeAbandonedLaunchDirectories(
        in parent: URL,
        currentPID: pid_t = getpid(),
        isRunning: (pid_t) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }
    ) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(directoryPrefix) {
            let parts = name.dropFirst(directoryPrefix.count).split(separator: "-", maxSplits: 1)
            guard parts.count == 2, UUID(uuidString: String(parts[1])) != nil,
                  let pid = pid_t(parts[0]), pid > 0, pid != currentPID, !isRunning(pid)
            else { continue }
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
        }
    }

    static func statusFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Names one adapter launch: its private directory.
    static func launchKey(ofDirectory directory: URL) -> String {
        directory.standardizedFileURL.path
    }

    static func launchKey(ofStatusFile statusFile: URL) -> String {
        launchKey(ofDirectory: statusFile.deletingLastPathComponent())
    }

    /// The adapter's final outcome; nil when it has not written one yet
    /// (nothing, or its live "attached" state: it still runs).
    static func read(from directory: URL) -> HostedAttachmentStatus? {
        guard let data = try? Data(contentsOf: statusFileURL(in: directory)) else { return nil }
        if liveStatus(from: data) != nil { return nil }
        return status(from: data)
    }

    /// The adapter's live state, when the file holds it (`outcome`
    /// "attached"); nil for nothing yet, a final outcome or an unreadable file.
    static func readLive(from directory: URL) -> HostedAdapterLiveStatus? {
        guard let data = try? Data(contentsOf: statusFileURL(in: directory)) else { return nil }
        return liveStatus(from: data)
    }

    static func liveStatus(from data: Data) -> HostedAdapterLiveStatus? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.outcome == liveOutcome else {
            return nil
        }
        return HostedAdapterLiveStatus(viewport: record.viewport ?? false, reconnecting: record.reconnecting ?? false)
    }

    /// The outcome of an adapter that ended. An unreadable status is only
    /// evidence that the attachment ended, and so is a live one the adapter
    /// never replaced (it was killed).
    static func status(from data: Data) -> HostedAttachmentStatus {
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return .disconnected(nil) }
        let message = record.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch record.outcome {
        case "exited":
            return .exited(code: record.exitCode.map { Int32(clamping: $0) }, signal: record.signal)
        case "taken_over":
            return .takenOver
        case "failed":
            return .failed(message ?? "The session could not be attached.")
        default:
            // "detached", "disconnected", a live "attached" left behind and
            // outcomes this app does not know. A confirmed detach has no
            // message; a detach the host never confirmed, or a lost
            // connection, says what happened.
            return .disconnected(message)
        }
    }

    /// An adapter that is being stopped may still write its status while it
    /// handles the hangup, so a stopped launch is removed after a delay. The
    /// launch then stops keeping its host's SSH master running.
    static func removeLaunchDirectory(
        _ directory: URL,
        after delay: TimeInterval,
        masters: HostSSHMasterManager = .shared
    ) {
        let launch = launchKey(ofDirectory: directory)
        guard delay > 0 else {
            try? FileManager.default.removeItem(at: directory)
            masters.endLaunch(launch)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: directory)
            masters.endLaunch(launch)
        }
    }
}

/// Follows one adapter launch's status file while the adapter runs, and
/// reports each new live state (`HostedAdapterLiveStatus`) on the main
/// actor. The adapter replaces the file atomically (a rename in the launch's
/// private directory), which the directory's vnode reports; final outcomes
/// are left to whoever handles the adapter's exit.
@MainActor
final class HostedAdapterStatusWatcher {
    private let directory: URL
    private let onChange: @MainActor (HostedAdapterLiveStatus) -> Void
    private var source: DispatchSourceFileSystemObject?
    private(set) var latest: HostedAdapterLiveStatus?

    /// Starts watching `directory` (a launch's private directory); nil when
    /// it cannot be opened.
    init?(directory: URL, onChange: @escaping @MainActor (HostedAdapterLiveStatus) -> Void) {
        self.directory = directory
        self.onChange = onChange
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .link], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source
        source.resume()
        check()
    }

    isolated deinit {
        source?.cancel()
    }

    /// Stops watching; nothing is reported afterwards.
    func cancel() {
        source?.cancel()
        source = nil
    }

    /// Reads the file now (the vnode event, or a caller that wants the
    /// latest state at once).
    func check() {
        guard source != nil, let status = HostedAttachmentStatusFile.readLive(from: directory), status != latest else {
            return
        }
        latest = status
        onChange(status)
    }
}

enum HostedSessionError: LocalizedError, Equatable {
    /// A definite failure decided in the app, such as invalid input or a
    /// missing helper. Nothing reached the host.
    case message(String)
    /// The host answered the request with an error (`code` is the protocol's
    /// error code, such as `unknown_session` or `not_running`). Definite.
    case rejected(code: String, message: String)
    /// The request was sent, but no definite answer came back: the
    /// connection failed, timed out or was interrupted. A requested change
    /// may or may not have happened.
    case transport(String)
    /// The host answered with an identity other than the one this Mac trusts.
    /// Nothing was sent to it.
    case identityMismatch(String)
    /// No connection to the host could be made (or it is not allowed, as from
    /// a disk image). Nothing was sent.
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .message(let message), .rejected(_, let message), .transport(let message),
             .identityMismatch(let message), .unavailable(let message):
            message
        }
    }

    var isTransportFailure: Bool {
        if case .transport = self { return true }
        return false
    }

    var isIdentityMismatch: Bool {
        if case .identityMismatch = self { return true }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// The host's error code for a rejected request.
    var hostErrorCode: String? {
        if case .rejected(let code, _) = self { return code }
        return nil
    }
}

@MainActor
final class HostedSessionHostStore: ObservableObject {
    static let shared = HostedSessionHostStore()
    @Published private(set) var hosts: [HostedSessionHost]
    /// The host identity first seen for each SSH destination (keyed by
    /// host.id). Refreshes require it until the user trusts a new one.
    ///
    /// "This Mac" is never pinned: the CLI already refuses a local socket or
    /// peer owned by another user, so only this user's own host can answer.
    /// A host keeps its identity in its state directory
    /// (~/Library/Application Support/cherry-host on macOS,
    /// ${XDG_STATE_HOME:-~/.local/state}/cherry-host elsewhere, one directory
    /// per socket path), so an SSH host's identity survives restarts. It
    /// changes when that directory is deleted or reset, when the host runs as
    /// another user or with another state directory or socket path, or when a
    /// different machine answers for the destination.
    @Published private(set) var trustedHostIDs: [String: String]
    private let defaults: UserDefaults
    private static let key = "hostedSessions.sshHosts"
    private static let trustedHostIDsKey = "hostedSessions.trustedHostIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hosts = (defaults.stringArray(forKey: Self.key) ?? [])
            .compactMap { try? HostedSessionHost.ssh($0) }
        trustedHostIDs = defaults.dictionary(forKey: Self.trustedHostIDsKey)?
            .compactMapValues { $0 as? String } ?? [:]
    }

    @discardableResult
    func add(_ destination: String) throws -> HostedSessionHost {
        let host = try HostedSessionHost.ssh(destination)
        if !hosts.contains(host) {
            hosts.append(host)
            save()
        }
        return host
    }

    func remove(_ host: HostedSessionHost) {
        hosts.removeAll { $0 == host }
        trustedHostIDs[host.id] = nil
        save()
    }

    func trustedHostID(for host: HostedSessionHost) -> String? {
        guard host.sshDestination != nil else { return nil }
        return trustedHostIDs[host.id]
    }

    func trust(_ hostID: String, for host: HostedSessionHost) {
        guard host.sshDestination != nil, trustedHostIDs[host.id] != hostID else { return }
        trustedHostIDs[host.id] = hostID
        save()
    }

    private func save() {
        defaults.set(hosts.compactMap(\.sshDestination), forKey: Self.key)
        defaults.set(trustedHostIDs, forKey: Self.trustedHostIDsKey)
    }
}

/// The installed `cherry` helper and the environment it runs with. Control
/// actions go through the host's `HostControl`; attach adapters run the
/// executable directly.
struct HostedSessionClient: Sendable {
    let executableURL: URL
    /// Login-shell variables layered over Cherry's own environment for every
    /// helper process, and handed to attach adapters. Nil when none could be
    /// captured. `retryingNow` skips the wait after a failed capture. Can run
    /// the user's shell: never call it on the main actor.
    var loginEnvironment: @Sendable (_ retryingNow: Bool) -> HostedSessionLoginEnvironment.Capture? = {
        HostedSessionLoginEnvironment.shared.resolve(retryingNow: $0)
    }

    static let developmentSourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func installed() throws -> HostedSessionClient {
        try installed(
            environment: ProcessInfo.processInfo.environment,
            runningExecutable: Bundle.main.executableURL,
            bundleURL: Bundle.main.bundleURL
        )
    }

    /// Cargo's output directories for the Host workspace, most specific first:
    /// `CARGO_TARGET_DIR`, else `CARGO_BUILD_TARGET_DIR` (Cargo's precedence,
    /// which Scripts/build-host follows), then the workspace's own `Host/target`.
    /// A relative value is resolved against the current directory, as Cargo does.
    static func developmentTargetDirectories(environment: [String: String], sourceRoot: URL) -> [URL] {
        var directories: [URL] = []
        let configured = [environment["CARGO_TARGET_DIR"], environment["CARGO_BUILD_TARGET_DIR"]]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        if let configured {
            directories.append(URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL)
        }
        let workspaceTarget = sourceRoot.appendingPathComponent("Host/target", isDirectory: true).standardizedFileURL
        if !directories.contains(where: { $0.path == workspaceTarget.path }) {
            directories.append(workspaceTarget)
        }
        return directories
    }

    /// A packaged release app only uses the helper bundled beside it, so a
    /// missing helper fails here instead of silently running the build
    /// machine's tree or an unrelated `cherry` on PATH. Unbundled runs and
    /// debug builds (including script/build_and_run.sh's CherryDev.app when it
    /// was built without helpers) also look in the Host workspace's Cargo
    /// output and on PATH.
    static func installed(
        environment: [String: String],
        runningExecutable: URL?,
        bundleURL: URL,
        sourceRoot: URL = HostedSessionClient.developmentSourceRoot,
        isDebugBuild: Bool = HostedSessionClient.isDebugBuild
    ) throws -> HostedSessionClient {
        if let override = environment["CHERRY_CLI_PATH"], !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw HostedSessionError.message("CHERRY_CLI_PATH does not point to an executable cherry client.")
            }
            return HostedSessionClient(executableURL: URL(fileURLWithPath: override))
        }

        let isPackagedRelease = bundleURL.pathExtension == "app" && !isDebugBuild
        var candidates: [URL] = []
        if let runningExecutable {
            candidates.append(runningExecutable.deletingLastPathComponent().appendingPathComponent("cherry"))
        }
        if !isPackagedRelease {
            for directory in developmentTargetDirectories(environment: environment, sourceRoot: sourceRoot) {
                for configuration in ["debug", "release"] {
                    candidates.append(directory.appendingPathComponent("\(configuration)/cherry"))
                }
            }
            for directory in (environment["PATH"] ?? "").split(separator: ":") {
                candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("cherry"))
            }
        }
        guard let executable = candidates.first(where: { isHelper($0, runningExecutable: runningExecutable) }) else {
            if isPackagedRelease {
                throw HostedSessionError.message(
                    "This copy of Cherry is missing its bundled cherry session client; it may have been built "
                        + "with CHERRY_SKIP_HOST=1. Reinstall a build that includes the helpers, or quit Cherry and "
                        + "relaunch it with CHERRY_CLI_PATH set to a cherry executable that has cherry-host beside it: "
                        + "open --env CHERRY_CLI_PATH=/abs/path/to/cherry '\(bundleURL.path)'"
                )
            }
            throw HostedSessionError.message(
                "The cherry session client is missing. Run Scripts/build-host debug (it honours CARGO_TARGET_DIR), "
                    + "or set CHERRY_CLI_PATH to a cherry executable in Cherry's launch environment."
            )
        }
        return HostedSessionClient(executableURL: executable)
    }

    /// On a case-insensitive volume, `cherry` beside a SwiftPM-built `Cherry`
    /// GUI names the GUI itself. Only an exact-case directory entry that is a
    /// different file from the running executable is the helper.
    static func isHelper(_ candidate: URL, runningExecutable: URL?) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: candidate.path),
              let names = try? fileManager.contentsOfDirectory(atPath: candidate.deletingLastPathComponent().path),
              names.contains(candidate.lastPathComponent)
        else { return false }
        if let runningExecutable, isSameFile(candidate, runningExecutable) { return false }
        return true
    }

    private static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        var firstStatus = stat()
        var secondStatus = stat()
        guard stat(first.path, &firstStatus) == 0, stat(second.path, &secondStatus) == 0 else { return false }
        return firstStatus.st_dev == secondStatus.st_dev && firstStatus.st_ino == secondStatus.st_ino
    }

    /// A working directory a person typed (the Persistent Sessions sheet):
    /// trimmed, then checked as `validatedHostWorkingDirectory` checks it.
    static func hostWorkingDirectory(_ input: String) throws -> String {
        try validatedHostWorkingDirectory(input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The host expands `~` and `~/…` with its own HOME and rejects relative
    /// paths. Checking here names the field instead of showing a host error.
    /// The path is kept exactly as given (a directory name may end in a
    /// space); empty means `~`.
    static func validatedHostWorkingDirectory(_ path: String) throws -> String {
        if path.isEmpty { return "~" }
        guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else {
            throw HostedSessionError.message("Enter the working directory as an absolute path or as ~/path on the selected host.")
        }
        return path
    }

    /// `loginEnvironment` resolved off the main actor.
    func resolvedLoginEnvironment(retryingNow: Bool = false) async -> HostedSessionLoginEnvironment.Capture? {
        let loginEnvironment = loginEnvironment
        return await Task.detached(priority: .userInitiated) { loginEnvironment(retryingNow) }.value
    }
}

/// The environment a terminal tab's login shell sees. Cherry is usually
/// started by launchd, so variables exported from shell startup files
/// (SSH_AUTH_SOCK for 1Password, gpg or Secretive agents; PATH for
/// ProxyCommand tools; LANG) are missing from the app's own environment.
/// Terminal tabs get them by running `$SHELL -l`; the session helpers run ssh
/// without a shell, so they get the same variables from one captured run.
final class HostedSessionLoginEnvironment: @unchecked Sendable {
    static let shared = HostedSessionLoginEnvironment()

    struct Capture: Equatable, Sendable {
        var environment: [String: String]
        /// False when the user's shell printed nothing and only the POSIX
        /// `sh -l` fallback did: variables exported from the user's own shell
        /// startup files are missing.
        var fromUserShell = true
    }

    private let lock = NSLock()
    private var cached: Capture?
    /// The latest fallback-only capture, used until the user's shell works.
    private var fallback: Capture?
    private var failures = 0
    private var retryAt: TimeInterval?
    private var lastAttemptEndedAt: TimeInterval?
    private let captureEnvironment: @Sendable () -> Capture?
    private let now: @Sendable () -> TimeInterval

    convenience init(
        shellPath: String = ShellProcessController.defaultShellPath,
        fallbackShellPath: String? = "/bin/sh",
        timeout: TimeInterval = 10
    ) {
        self.init {
            Self.capture(
                shellPath: shellPath,
                fallbackShellPath: fallbackShellPath,
                baseEnvironment: ProcessInfo.processInfo.environment,
                timeout: timeout
            )
        }
    }

    init(
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        capture: @escaping @Sendable () -> Capture?
    ) {
        self.now = now
        captureEnvironment = capture
    }

    /// A capture from the user's shell is kept until Cherry quits. When that
    /// shell fails, the call returns the fallback's capture (or nil), and a
    /// later call tries the user's shell again once a backoff has passed, so
    /// a shell that was only slow at first, or whose startup files were
    /// fixed, is still captured, while one that always fails does not delay
    /// every helper command. `retryingNow` skips the backoff, for an explicit
    /// refresh. Blocks while the shell runs: call it off the main actor.
    func resolve(retryingNow: Bool = false) -> Capture? {
        let requestedAt = now()
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        // Another call's attempt ended while this one waited for it.
        if let lastAttemptEndedAt, lastAttemptEndedAt > requestedAt { return fallback }
        if !retryingNow, let retryAt, now() < retryAt { return fallback }
        let captured = captureEnvironment()
        let endedAt = now()
        lastAttemptEndedAt = endedAt
        if let captured, captured.fromUserShell {
            cached = captured
            fallback = nil
            return captured
        }
        if let captured { fallback = captured }
        failures += 1
        retryAt = endedAt + Self.retryDelay(afterFailures: failures)
        return fallback
    }

    /// 15 seconds after the first failure, doubling up to 5 minutes.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(15 * pow(2, Double(max(failures, 1) - 1)), 300)
    }

    /// Cherry's own variables minus terminal-specific and Cherry tab identity
    /// keys, with the login shell's values on top.
    static func helperEnvironment(base: [String: String], login: [String: String]?) -> [String: String] {
        base.filter { !isTabSpecific($0.key) }.merging(login ?? [:]) { _, login in login }
    }

    /// One way to start a shell for the capture: its argv and, for a shell
    /// that reads the command from standard input, that input.
    struct Invocation: Equatable {
        let path: String
        let arguments: [String]
        let input: String?
    }

    /// The user's shell as a login shell, like a terminal tab, then a POSIX
    /// `sh -l` in case that shell rejects the flags or dies before running
    /// the command. The command is plain enough for sh-family shells, csh,
    /// fish and nushell alike.
    static func invocations(shellPath: String, fallbackShellPath: String?, command: String) -> [Invocation] {
        var invocations: [Invocation]
        switch URL(fileURLWithPath: shellPath).lastPathComponent {
        case "csh", "tcsh":
            // csh accepts -l only as its sole flag. It then reads commands
            // from standard input, and reads .cshrc and .login as for a tab.
            invocations = [Invocation(path: shellPath, arguments: [shellPath, "-l"], input: command + "\n")]
        default:
            // Interactive too: agent sockets are often exported from .zshrc,
            // .bashrc or fish's config.
            invocations = [Invocation(path: shellPath, arguments: [shellPath, "-l", "-i", "-c", command], input: nil)]
        }
        if let fallbackShellPath, fallbackShellPath != shellPath {
            invocations.append(Invocation(
                path: fallbackShellPath, arguments: [fallbackShellPath, "-l", "-c", command], input: nil
            ))
        }
        return invocations
    }

    /// Prints the environment between two markers, which skip anything rc
    /// files print. Each marker is printed in two parts, so a shell that
    /// echoes the command line never shows a whole marker.
    static func command(marker: String) -> String {
        let split = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        let printMarker = "/usr/bin/printf '%s%s' '\(marker[..<split])' '\(marker[split...])'"
        return "\(printMarker); /usr/bin/env -0; \(printMarker)"
    }

    /// Runs each invocation in turn until one prints the environment. They
    /// share one deadline: after a shell that hangs, nothing else runs.
    static func capture(
        shellPath: String,
        fallbackShellPath: String? = nil,
        baseEnvironment: [String: String],
        timeout: TimeInterval
    ) -> Capture? {
        let marker = "__CHERRY_LOGIN_ENVIRONMENT_\(UUID().uuidString)__"
        let deadline = Date().addingTimeInterval(timeout)
        let environment = shellEnvironment(base: baseEnvironment)
        let attempts = invocations(shellPath: shellPath, fallbackShellPath: fallbackShellPath, command: command(marker: marker))
        for (index, invocation) in attempts.enumerated() {
            guard deadline.timeIntervalSinceNow > 0 else { return nil }
            guard let shell = DetachedShell.spawn(
                path: invocation.path,
                arguments: invocation.arguments,
                input: invocation.input.map { Data($0.utf8) },
                environment: environment,
                workingDirectory: NSHomeDirectory()
            ) else { continue }
            let output = shell.readOutput(until: Data(marker.utf8), deadline: deadline)
            shell.finish(completed: output != nil)
            if let captured = output.flatMap({ parse($0, marker: marker) }) {
                return Capture(environment: captured, fromUserShell: index == 0)
            }
        }
        return nil
    }

    static func parse(_ data: Data, marker: String) -> [String: String]? {
        let markerData = Data(marker.utf8)
        guard let start = data.range(of: markerData),
              let end = data.range(of: markerData, in: start.upperBound..<data.endIndex)
        else { return nil }
        var environment: [String: String] = [:]
        for entry in data[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8),
                  let equals = text.firstIndex(of: "="),
                  equals != text.startIndex
            else { continue }
            let key = String(text[..<equals])
            guard !isTabSpecific(key) else { continue }
            environment[key] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    /// Identity of the Cherry tab (or hosted session) Cherry itself may have
    /// been started from, plus its shell-integration plumbing. Helpers must
    /// not pass these on as if they described the new session. The same set
    /// `HostedLaunchSpec` drops.
    private static let cherryTabKeys = CherryTabEnvironment.keys

    /// Values that describe one terminal or one Cherry tab, never the user.
    private static func isTabSpecific(_ key: String) -> Bool {
        let terminalKeys: Set<String> = [
            "PWD", "OLDPWD", "SHLVL", "_", "TERM", "COLORTERM", "TERM_PROGRAM",
            "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "LINES", "COLUMNS", "ZDOTDIR"
        ]
        return terminalKeys.contains(key) || cherryTabKeys.contains(key) || key.hasPrefix("GHOSTTY_")
    }

    /// When Cherry itself runs inside a Cherry tab, its ZDOTDIR points at the
    /// shell-integration bootstrap; the capture must load the user's files.
    private static func shellEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        if let bootstrap = base["CHERRY_BOOTSTRAP_ZDOTDIR"], base["ZDOTDIR"] == bootstrap {
            environment["ZDOTDIR"] = base["CHERRY_ORIGINAL_ZDOTDIR"]
        }
        return environment.filter { !cherryTabKeys.contains($0.key) }
    }

    /// The capture shell runs in a new session without a controlling terminal.
    /// When Cherry was started from a terminal (`swift run Cherry`), an
    /// interactive shell sharing that terminal tries to become its foreground
    /// job and is stopped by SIGTTOU/SIGTTIN until the capture times out.
    private struct DetachedShell {
        let pid: pid_t
        let output: Int32

        /// `input`, when given, is the shell's whole standard input; it must
        /// fit in a pipe buffer. Otherwise standard input is /dev/null.
        static func spawn(
            path: String,
            arguments: [String],
            input: Data? = nil,
            environment: [String: String],
            workingDirectory: String
        ) -> DetachedShell? {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { return nil }
            let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
            // Keep both ends out of processes other threads start meanwhile.
            _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
            defer { close(writeEnd) }

            var inputEnd: Int32 = -1
            if let input {
                guard input.count <= 4_096, pipe(&descriptors) == 0 else {
                    close(readEnd)
                    return nil
                }
                inputEnd = descriptors[0]
                let inputWriteEnd = descriptors[1]
                _ = fcntl(inputEnd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(inputWriteEnd, F_SETFD, FD_CLOEXEC)
                // Written before the shell starts: an empty pipe takes it
                // whole, and the shell reads end of file after it.
                let written = input.withUnsafeBytes { write(inputWriteEnd, $0.baseAddress, $0.count) }
                close(inputWriteEnd)
                guard written == input.count else {
                    close(inputEnd)
                    close(readEnd)
                    return nil
                }
            }
            defer { if inputEnd >= 0 { close(inputEnd) } }

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            if inputEnd >= 0 {
                posix_spawn_file_actions_adddup2(&actions, inputEnd, 0)
            } else {
                posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            }
            posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addchdir(&actions, workingDirectory)

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var noSignals = sigset_t()
            var allSignals = sigset_t()
            sigemptyset(&noSignals)
            sigfillset(&allSignals)
            posix_spawnattr_setsigmask(&attributes, &noSignals)
            posix_spawnattr_setsigdefault(&attributes, &allSignals)
            // CLOEXEC_DEFAULT passes on only the three descriptors set up above.
            posix_spawnattr_setflags(&attributes, Int16(
                POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
            ))

            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var pid: pid_t = 0
            guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0, pid > 1 else {
                close(readEnd)
                return nil
            }
            return DetachedShell(pid: pid, output: readEnd)
        }

        /// Everything up to the second `marker`, or nil if the shell ends or
        /// the deadline passes first. A daemon started from an rc file can
        /// keep the pipe open after the shell exits, so completion is the
        /// closing marker, not EOF.
        func readOutput(until marker: Data, deadline: Date) -> Data? {
            defer { close(output) }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1_000) + 1)
                if ready < 0, errno != EINTR { return nil }
                guard ready > 0 else { continue }
                let count = read(output, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return nil
                }
                guard count > 0, collected.count + count <= 4 * 1_024 * 1_024 else { return nil }
                collected.append(contentsOf: buffer[..<count])
                if let start = collected.range(of: marker),
                   collected.range(of: marker, in: start.upperBound..<collected.endIndex) != nil {
                    return collected
                }
            }
        }

        /// A completed shell only has to exit; one that timed out is killed
        /// with its process group (interactive shells ignore SIGTERM). The
        /// child is reaped off the calling thread.
        func finish(completed: Bool) {
            let pid = pid
            if !completed { _ = kill(-pid, SIGKILL) }
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(2)
                var status: Int32 = 0
                while waitpid(pid, &status, WNOHANG) == 0 {
                    guard Date() < deadline else {
                        _ = kill(pid, SIGKILL)
                        _ = waitpid(pid, &status, 0)
                        return
                    }
                    usleep(20_000)
                }
            }
        }
    }
}

/// Where the running app lives decides whether a local session daemon it
/// starts can outlive it.
enum HostedSessionInstallation {
    /// An app opened from a mounted disk image (or run App Translocated from
    /// Downloads) starts the session daemon from that read-only location;
    /// ejecting the image removes the daemon's executable under running sessions.
    static func runsFromDiskImage(
        bundleURL: URL = Bundle.main.bundleURL,
        volumeIsReadOnly: (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        }
    ) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return true }
        return path.hasPrefix("/Volumes/") && volumeIsReadOnly(bundleURL)
    }

    static func diskImageWarning(bundleURL: URL = Bundle.main.bundleURL) -> String {
        let name = bundleURL.pathExtension == "app" ? bundleURL.deletingPathExtension().lastPathComponent : "Cherry"
        return "Move \(name) to Applications first; sessions started from the disk image stop working when it is ejected."
    }

    /// Every local `cherry control` and `attach` starts the session daemon
    /// from this app's bundle when none is running, so "This Mac" stays
    /// unavailable while that bundle is on a disk image. SSH hosts run their
    /// own daemon and are unaffected.
    static func localHostUnavailableReason(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        runsFromDiskImage(bundleURL: bundleURL) ? diskImageWarning(bundleURL: bundleURL) : nil
    }
}
