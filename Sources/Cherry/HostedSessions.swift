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

    var arguments: [String] {
        sshDestination.map { ["--host", $0] } ?? []
    }
}

enum HostedSessionState: String, Decodable, Sendable {
    case running
    case exited
}

struct HostedSessionInfo: Decodable, Equatable, Identifiable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case id, name, cwd, command, cols, rows, state, pid, attached
        case exitCode = "exit_code"
        case exitSignal = "exit_signal"
    }

    var isRunning: Bool { state == .running }
    var displayName: String { name.isEmpty ? String(id.prefix(8)) : name }

    var statusText: String {
        if isRunning { return attached ? "Attached" : "Running" }
        if let exitSignal { return "Exited (signal \(exitSignal))" }
        if let exitCode { return "Exited (\(exitCode))" }
        return "Exited"
    }
}

struct HostedSessionList: Decodable, Sendable {
    let hostID: String
    let sessions: [HostedSessionInfo]

    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case sessions
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
    func arguments(statusFile: URL?, takeover: Bool = false) -> [String] {
        var arguments = host.arguments + ["--expected-host-id", hostID, "attach", sessionID]
        if takeover { arguments.append("--takeover") }
        arguments += ["--detach-key", "none"]
        if let statusFile { arguments += ["--status-file", statusFile.path] }
        return arguments
    }

    func execCommand(statusFile: URL?, takeover: Bool = false) -> String {
        ([executablePath] + arguments(statusFile: statusFile, takeover: takeover))
            .map(Self.shellQuote).joined(separator: " ")
    }

    var adapterEnvironment: [String: String] {
        environment.merging(["TERM": "xterm-256color", "COLORTERM": "truecolor"]) { _, adapter in adapter }
    }

    /// A client for one-off operations on this session's host, pinned to the
    /// identity the tab attached to.
    var client: HostedSessionClient {
        let environment = environment
        return HostedSessionClient(
            executableURL: URL(fileURLWithPath: executablePath),
            loginEnvironment: { _ in .init(environment: environment) }
        )
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

/// `cherry attach --status-file` reports why the adapter exited. Each adapter
/// launch gets a fresh private directory: the CLI writes the file atomically
/// (temporary file + rename) beside it, and the app deletes the directory
/// once the outcome is read.
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

    private struct Record: Decodable {
        let outcome: String
        let exitCode: UInt32?
        let signal: Int32?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case outcome, signal, message
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

    /// nil when the adapter has not written a status yet.
    static func read(from directory: URL) -> HostedAttachmentStatus? {
        guard let data = try? Data(contentsOf: statusFileURL(in: directory)) else { return nil }
        return status(from: data)
    }

    /// An unreadable status is only evidence that the attachment ended.
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
            // "detached", "disconnected" and outcomes this app does not know.
            // A confirmed detach has no message; a detach the host never
            // confirmed, or a lost connection, says what happened.
            return .disconnected(message)
        }
    }

    /// An adapter that is being stopped may still write its status while it
    /// handles the hangup, so a stopped launch is removed after a delay.
    static func removeLaunchDirectory(_ directory: URL, after delay: TimeInterval) {
        guard delay > 0 else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

enum HostedSessionError: LocalizedError, Equatable {
    case message(String)
    /// The helper got no definite answer: the connection failed, timed out or
    /// was interrupted. A requested change may or may not have happened.
    case transport(String)
    /// The host answered with an identity other than the one this Mac trusts.
    case identityMismatch(String)

    var errorDescription: String? {
        switch self {
        case .message(let message), .transport(let message), .identityMismatch(let message):
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

struct HostedSessionClient: Sendable {
    let executableURL: URL
    var timeout: TimeInterval = 35
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

    /// The host expands `~` and `~/…` with its own HOME and rejects relative
    /// paths. Checking here names the field instead of showing a host error.
    static func hostWorkingDirectory(_ input: String) throws -> String {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return "~" }
        guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else {
            throw HostedSessionError.message("Enter the working directory as an absolute path or as ~/path on the selected host.")
        }
        return path
    }

    func list(on host: HostedSessionHost, expectedHostID: String? = nil) async throws -> HostedSessionList {
        let identityArguments = expectedHostID.map { ["--expected-host-id", $0] } ?? []
        return try Self.decode(HostedSessionList.self, from: await run(host.arguments + identityArguments + ["list", "--json"]))
    }

    /// The host creates at most one session per `requestID`, so a retry after
    /// a lost response returns the session the first attempt created.
    func create(
        on host: HostedSessionHost,
        expectedHostID: String,
        name: String,
        cwd: String,
        requestID: UUID
    ) async throws -> HostedSessionInfo {
        let arguments = host.arguments + [
            "--expected-host-id", expectedHostID, "new",
            // `=` keeps values that start with "-" from parsing as options.
            "--name=\(name)", "--cwd=\(try Self.hostWorkingDirectory(cwd))",
            "--request-id", requestID.uuidString.lowercased()
        ]
        return try Self.decode(HostedSessionInfo.self, from: await run(arguments))
    }

    func terminate(_ sessionID: String, on host: HostedSessionHost, expectedHostID: String) async throws {
        _ = try await run(host.arguments + ["--expected-host-id", expectedHostID, "kill", sessionID])
    }

    func remove(_ sessionID: String, on host: HostedSessionHost, expectedHostID: String) async throws {
        _ = try await run(host.arguments + ["--expected-host-id", expectedHostID, "remove", sessionID])
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HostedSessionError.message("The cherry session client returned a response this version of Cherry cannot read. Make sure the app and its cherry helper come from the same build.")
        }
    }

    /// `loginEnvironment` resolved off the main actor.
    func resolvedLoginEnvironment(retryingNow: Bool = false) async -> HostedSessionLoginEnvironment.Capture? {
        let loginEnvironment = loginEnvironment
        return await Task.detached(priority: .userInitiated) { loginEnvironment(retryingNow) }.value
    }

    private func run(_ arguments: [String]) async throws -> Data {
        let executableURL = executableURL
        let timeout = timeout
        let loginEnvironment = loginEnvironment
        return try await Task.detached(priority: .userInitiated) {
            // Resolving the login environment can run the user's shell, so it
            // stays off the main actor.
            let environment = HostedSessionLoginEnvironment.helperEnvironment(
                base: ProcessInfo.processInfo.environment,
                login: loginEnvironment(false)?.environment
            )
            return try HostedSessionCommand.run(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        }.value
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
    /// not pass these on as if they described the new session.
    private static let cherryTabKeys: Set<String> = [
        CherryControl.projectRootEnvironmentKey, CherryControl.processIDEnvironmentKey,
        CherryControl.agentIDEnvironmentKey, "CHERRY_SESSION_ID", "CHERRY_BOOTSTRAP_ZDOTDIR",
        "CHERRY_ORIGINAL_ZDOTDIR", "CHERRY_STARTUP_COMMAND", "CHERRY_EMIT_OSC133",
        "CHERRY_TERM_PROGRAM", "INSIDE_CHERRY"
    ]

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

    /// Every local `cherry list`, `new` and `attach` starts the session daemon
    /// from this app's bundle when none is running, so "This Mac" stays
    /// unavailable while that bundle is on a disk image. SSH hosts run their
    /// own daemon and are unaffected.
    static func localHostUnavailableReason(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        runsFromDiskImage(bundleURL: bundleURL) ? diskImageWarning(bundleURL: bundleURL) : nil
    }
}

private enum HostedSessionCommand {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var overflow = false

        func drain(_ handle: FileHandle) {
            while true {
                let chunk = handle.readData(ofLength: 16_384)
                if chunk.isEmpty { break }
                lock.withLock {
                    if storage.count + chunk.count <= 4 * 1_024 * 1_024 {
                        storage.append(chunk)
                    } else {
                        overflow = true
                    }
                }
            }
        }

        var result: (data: Data, overflow: Bool) { lock.withLock { (storage, overflow) } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        func set() { lock.withLock { storage = true } }
        var value: Bool { lock.withLock { storage } }
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let timedOut = Flag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            // The adapter handles TERM by closing its SSH transport and reaping
            // the child. Allow that cleanup before the final fallback.
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let stdout = Capture()
        let stderr = Capture()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.drain(errors.fileHandleForReading)
            group.leave()
        }
        stdout.drain(output.fileHandleForReading)
        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        if timedOut.value {
            // The helper's own interruption message describes its view of the
            // signal, not whether the host acted on the request.
            let seconds = max(1, Int(timeout.rounded(.up)))
            throw HostedSessionError.transport("The session host did not answer within \(seconds) second\(seconds == 1 ? "" : "s"). Check the host and your SSH connection.")
        }
        let result = stdout.result
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(String(decoding: stderr.result.data, as: UTF8.self).prefix(2_000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(
                status: process.terminationStatus,
                signaled: process.terminationReason != .exit,
                message: message
            )
        }
        guard !result.overflow else {
            throw HostedSessionError.message("The session host returned a response larger than the client limit.")
        }
        return result.data
    }

    /// A reply from the host (or a usage error) is definite; anything else
    /// means the request may or may not have reached the host.
    static func failure(status: Int32, signaled: Bool, message: String) -> HostedSessionError {
        let text = message.isEmpty
            ? "The session host could not be reached. Check the host installation and your SSH connection, then refresh the session list."
            : message
        if signaled { return .transport(text) }
        let lowered = message.lowercased()
        if lowered.contains("host identity") { return .identityMismatch(text) }
        if lowered.contains("host rejected request") || status == 2 { return .message(text) }
        return .transport(text)
    }
}
