import AppKit
import CherryControl
import CryptoKit
import Darwin
import Foundation
import Security

// Cherry MCP for agents running on another Mac (docs/specs/remote-devices.md,
// phase 4b).
//
// - Transport: the app listens on a socket of its own per device
//   (`CherryControlServer.addDeviceListener`), and the device's first SSH
//   master reverse-forwards a socket on that Mac to it (`ssh -O forward -R
//   <there>:<here>`, `RemoteMCPForwards`). A tab there finds it at
//   `CHERRY_CONTROL_SOCKET`.
// - Identity: every tab of a device gets a capability token in its
//   environment (`CHERRY_MCP_TOKEN`, with `CHERRY_PROCESS_ID`), which its
//   CherryMCP sends with every request. The device's listener refuses a
//   request without a valid one; This Mac's socket keeps identifying its
//   callers by process.
// - Setup: Claude Code and Codex on that Mac read their MCP servers from their
//   own configuration there; "Set Up Cherry MCP on <Mac>…" registers a
//   stable launcher there, only when the user confirms (`RemoteMCPSetup`).

// MARK: - Tokens

/// The capability tokens of tabs on other Macs: HMAC-SHA256 of the device
/// id, the tab id and the tab's launch generation under a random 256-bit
/// key kept in this identity's Application Support (`mcp-token-key`, mode
/// 0600).
///
/// The generation is a random nonce made for each launch of the tab's
/// program (`newGeneration`, called as its Create is built: a start, a
/// restart), so a token that leaked stops working once the tab's program
/// restarts. The generations are kept in `mcp-generations.json` next to the
/// key (0600), so a tab restored after Cherry relaunched (its program, and
/// the token in its environment, kept running on the device) is still
/// recognised. A token is also valid only while its tab is open in a window
/// of its device (`CherryControlServer.remoteCaller` looks the tab up):
/// closing the tab revokes it; a tab brought back by ⌘Z is the same tab
/// with the same program, and its token works again.
final class RemoteMCPTokens: @unchecked Sendable {
    static let shared = RemoteMCPTokens(
        keyURL: AppInstanceLock.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent("mcp-token-key", isDirectory: false)
    )

    private let keyURL: URL?
    private let generationsURL: URL?
    private let lock = NSLock()
    private var loadedKey: SymmetricKey?
    private var generations: [UUID: Generation]?

    struct Generation: Codable, Equatable {
        var nonce: String
        var madeAt: Date
    }

    /// Generations older than this are forgotten when the file is read.
    static let generationLifetime: TimeInterval = 90 * 86_400

    /// A key read from (or first written to) `keyURL`, and generations kept
    /// next to it; an in-memory key when it cannot be read or written.
    init(keyURL: URL?) {
        self.keyURL = keyURL
        generationsURL = keyURL?.deletingLastPathComponent().appendingPathComponent("mcp-generations.json")
    }

    /// A fixed key, generations in memory (tests).
    init(key: SymmetricKey) {
        keyURL = nil
        generationsURL = nil
        loadedKey = key
    }

    private var key: SymmetricKey {
        lock.withLock {
            if let loadedKey { return loadedKey }
            let key = keyURL.flatMap(Self.loadOrCreateKey(at:)) ?? SymmetricKey(size: .bits256)
            loadedKey = key
            return key
        }
    }

    /// A new launch of the tab's program: a new generation (the previous
    /// one's tokens stop working). Returns the tab's new token.
    @discardableResult
    func newGeneration(tabID: UUID, deviceID: UUID, now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        let snapshot: [UUID: Generation] = lock.withLock {
            var all = loadGenerationsLocked()
            all[tabID] = Generation(nonce: nonce, madeAt: now)
            generations = all
            return all
        }
        save(snapshot)
        return token(tabID: tabID, deviceID: deviceID, generation: nonce)
    }

    /// The token of the tab's current launch, when it has one.
    func currentToken(tabID: UUID, deviceID: UUID) -> String? {
        let nonce = lock.withLock { loadGenerationsLocked()[tabID]?.nonce }
        return nonce.map { token(tabID: tabID, deviceID: deviceID, generation: $0) }
    }

    /// The token of a launch: 64 hex digits.
    func token(tabID: UUID, deviceID: UUID, generation: String) -> String {
        let message = "cherry-mcp-v2\n\(deviceID.uuidString.lowercased())\n\(tabID.uuidString.lowercased())\n\(generation)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `token` is the one of the tab's current launch (compared in
    /// constant time).
    func isValid(_ token: String, tabID: UUID, deviceID: UUID) -> Bool {
        guard let current = currentToken(tabID: tabID, deviceID: deviceID) else { return false }
        let expected = Array(current.utf8)
        let given = Array(token.lowercased().utf8)
        guard given.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ given[index] }
        return difference == 0
    }

    private func loadGenerationsLocked() -> [UUID: Generation] {
        if let generations { return generations }
        var loaded: [UUID: Generation] = [:]
        if let url = generationsURL, Self.isPrivateFile(url.path),
           let data = FileManager.default.contents(atPath: url.path),
           let decoded = try? JSONDecoder().decode([String: Generation].self, from: data) {
            let oldest = Date().addingTimeInterval(-Self.generationLifetime)
            for (key, value) in decoded where value.madeAt > oldest {
                if let id = UUID(uuidString: key) { loaded[id] = value }
            }
        }
        generations = loaded
        return loaded
    }

    /// Written atomically, 0600.
    private func save(_ all: [UUID: Generation]) {
        guard let url = generationsURL else { return }
        let encoded = Dictionary(uniqueKeysWithValues: all.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".mcp-generations.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { unlink(temporary.path) }
    }

    private static func isPrivateFile(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid() && status.st_mode & 0o077 == 0
    }

    /// 32 random bytes in a file only this user can read: made with
    /// O_EXCL (another copy of the app making it at the same time keeps
    /// the first), refused when another account owns it or others can
    /// read it.
    static func loadOrCreateKey(at url: URL) -> SymmetricKey? {
        let path = url.path
        if let key = readKey(at: path) { return key }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 { return errno == EEXIST ? readKey(at: path) : nil }
        defer { close(fd) }
        let key = SymmetricKey(size: .bits256)
        let written = key.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
        guard written == 32 else {
            unlink(path)
            return nil
        }
        return key
    }

    private static func readKey(at path: String) -> SymmetricKey? {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_mode & 0o077 == 0,
              let data = FileManager.default.contents(atPath: path), data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }
}

// MARK: - Paths

enum RemoteMCPPaths {
    /// A Unix socket path holds at most this many bytes.
    static let maximumSocketPathBytes = 103

    /// 16 hex digits of the SHA-256 of `text`.
    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Names a device's listener here (`mcp-<name>.sock`).
    static func shortName(deviceID: UUID) -> String {
        shortHash(deviceID.uuidString.lowercased())
    }

    /// The private directory's name on the device: one per installation of
    /// Cherry and device, so two Macs using one device never share it.
    static func directoryName(installationID: UUID, deviceID: UUID) -> String {
        "cherry-mcp-\(shortHash("\(installationID.uuidString.lowercased())|\(deviceID.uuidString.lowercased())"))"
    }

    /// The longest per-user temporary directory a device may report.
    static let maximumTemporaryDirectoryBytes = 128

    /// Why the per-user temporary directory a device reported cannot be
    /// used, nil when it can: it goes into `ssh -O forward -R <there>:<here>`,
    /// whose spec OpenSSH splits at `:` and expands `${…}` in, and into
    /// scripts there. Allowed: an absolute path of `[A-Za-z0-9/_.+-]` only
    /// (a real `DARWIN_USER_TEMP_DIR` is `/var/folders/xx/…/T/`), with no
    /// `.` or `..` component, at most `maximumTemporaryDirectoryBytes`.
    static func temporaryDirectoryProblem(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "it is not an absolute path" }
        guard path.utf8.count <= maximumTemporaryDirectoryBytes else {
            return "it is longer than \(maximumTemporaryDirectoryBytes) bytes"
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_.+-".utf8)
        guard path.utf8.allSatisfy(allowed.contains) else {
            return "it has characters other than letters, digits and / _ . + -"
        }
        guard !ProjectLocation.hasDotComponents(path) else { return "it has a . or .. component" }
        return nil
    }

    /// `path` when it is a usable per-user temporary directory
    /// (`temporaryDirectoryProblem`), else nil, logging why (`source`: where
    /// it came from).
    static func validTemporaryDirectory(_ path: String?, source: String) -> String? {
        guard let path = path?.nilIfEmpty else { return nil }
        if let problem = temporaryDirectoryProblem(path) {
            SessionLog.error("Cherry MCP: ignoring the per-user temporary directory \(source) reported: \(problem)")
            return nil
        }
        return path
    }

    /// The directory there, in the account's per-user temporary directory
    /// (`getconf DARWIN_USER_TEMP_DIR`, which only that account can enter;
    /// never the shared /tmp). Nil when that is not a plain absolute path
    /// (`temporaryDirectoryProblem`: no Cherry MCP for that device), or the
    /// socket in it would be longer than a socket path may be
    /// (`~/Library/Application Support/…` is, for most homes).
    static func remoteDirectory(temporaryDirectory: String?, installationID: UUID, deviceID: UUID) -> String? {
        guard let temporaryDirectory, temporaryDirectoryProblem(temporaryDirectory) == nil else { return nil }
        let base = temporaryDirectory.hasSuffix("/") ? String(temporaryDirectory.dropLast()) : temporaryDirectory
        let directory = "\(base)/\(directoryName(installationID: installationID, deviceID: deviceID))"
        guard (directory + "/control.sock").utf8.count <= maximumSocketPathBytes else { return nil }
        return directory
    }

    /// The forwarded control socket there: its tabs' `CHERRY_CONTROL_SOCKET`.
    static func remoteSocket(temporaryDirectory: String?, installationID: UUID, deviceID: UUID) -> String? {
        remoteDirectory(temporaryDirectory: temporaryDirectory, installationID: installationID, deviceID: deviceID)
            .map { $0 + "/control.sock" }
    }

    /// The launcher Set Up Cherry MCP registers with the agents there,
    /// under the home folder: it runs the CherryMCP of the Cherry build
    /// that started the tab (`CHERRY_MCP_HELPER`), so a registration never
    /// names a build directory that an update collects later.
    static let launcherRelativePath = "Library/Application Support/cherry-host/mcp/cherry-mcp"

    /// CherryMCP's name in an install (next to cherry and cherry-host).
    static let helperName = "CherryMCP"

    /// The CherryMCP of the install a device's `remoteHostPath` names,
    /// under its home; nil when that is not one of ours.
    static func helperPath(remoteHostPath: String?, homeDirectory: String?) -> String? {
        RemoteLaunchSpec.Resources.of(remoteHostPath: remoteHostPath, homeDirectory: homeDirectory)
            .map { "\($0.root)/\(helperName)" }
    }
}

/// What a tab of a device needs for Cherry MCP (`RemoteLaunchSpec`).
struct RemoteMCPLaunch: Equatable, Sendable {
    var deviceID: UUID
    /// The forwarded control socket there.
    var socketPath: String
    /// The install's CherryMCP there, when it has one.
    var helperPath: String?
    /// This Mac's name, for "Cherry on <Mac> is not reachable".
    var controlMachine: String
    var tokens: RemoteMCPTokens

    static func == (lhs: RemoteMCPLaunch, rhs: RemoteMCPLaunch) -> Bool {
        lhs.deviceID == rhs.deviceID && lhs.socketPath == rhs.socketPath && lhs.helperPath == rhs.helperPath
            && lhs.controlMachine == rhs.controlMachine && lhs.tokens === rhs.tokens
    }

    /// The Cherry variables of a new launch of the tab `processID`.
    func environment(processID: String) -> [String: String] {
        var environment = [
            CherryControl.socketEnvironmentKey: socketPath,
            CherryControl.controlMachineEnvironmentKey: controlMachine,
        ]
        if let tabID = UUID(uuidString: processID) {
            // Built for each Create (a start or restart): a new generation.
            environment[CherryControl.mcpTokenEnvironmentKey] = tokens.newGeneration(tabID: tabID, deviceID: deviceID)
        }
        if let helperPath { environment[CherryControl.mcpHelperEnvironmentKey] = helperPath }
        return environment
    }

    /// This Mac's name (its ComputerName).
    @MainActor static var thisMacName: String {
        if let cached { return cached }
        let name = Host.current().localizedName?.nilIfEmpty ?? "This Mac"
        cached = name
        return name
    }
    @MainActor private static var cached: String?
}

// MARK: - Forwards

enum RemoteMCPForwardError: Error, Equatable, LocalizedError {
    case noServer
    case noConnection(machine: String)
    case prepare(machine: String, reason: String)
    case refused(machine: String, reason: String)
    case failed(machine: String, reason: String)
    /// The device was removed (or its forward stopped) while it was made.
    case stopped

    var errorDescription: String? {
        switch self {
        case .noServer: "Cherry's control server is not running."
        case .noConnection(let machine): "Cherry has no SSH connection to \(machine) now."
        case .prepare(let machine, let reason): "Could not prepare Cherry's control socket on \(machine): \(reason)"
        case .refused(let machine, let reason):
            "The SSH server on \(machine) refused to forward Cherry's control socket (its sshd_config must allow remote forwards: AllowStreamLocalForwarding and AllowTcpForwarding yes, the defaults): \(reason)"
        case .failed(let machine, let reason): "Could not forward Cherry's control socket to \(machine): \(reason)"
        case .stopped: "The forward was stopped."
        }
    }
}

/// The reverse forwards of Cherry's control server to devices: one per
/// device, on its first SSH master, made whenever the device's control
/// connects (`RemoteDeviceStore` asks), so a master that came back (a
/// reconnect, a wake) gets it again. Its forward goes with its master (a quit
/// stops the masters).
@MainActor
final class RemoteMCPForwards {
    static var shared: RemoteMCPForwards {
        get {
            if let made { return made }
            let forwards = RemoteMCPForwards()
            made = forwards
            return forwards
        }
        set { made = newValue }
    }
    private static var made: RemoteMCPForwards?
    static var existing: RemoteMCPForwards? { made }

    struct Target: Equatable, Sendable {
        var deviceID: UUID
        var destination: String
        /// The device's name, in messages.
        var machine: String
        var installationID: UUID
    }

    enum State: Equatable {
        case making
        /// Forwarded on the master at `controlPath`, from `remoteSocket`
        /// there to `localSocket` here.
        case up(controlPath: String, remoteSocket: String, localSocket: String)
        case failed(String)
    }

    let masters: HostSSHMasterManager
    let shell: @MainActor () async -> RemoteDeviceShell
    /// The server whose device listeners the forwards reach.
    let server: @MainActor () -> CherryControlServer?
    /// Told the device's per-user temporary directory as its forward's
    /// script found it (`RemoteDeviceStore` records it for launches).
    var temporaryDirectoryFound: @MainActor (_ deviceID: UUID, _ directory: String) -> Void = { _, _ in }
    var masterTimeout: TimeInterval = 20

    private(set) var states: [UUID: State] = [:]
    private var targets: [UUID: Target] = [:]
    private var pending: [UUID: Task<State, Never>] = [:]
    /// Increases with every stop of a device: a forward being made when it
    /// stops never takes effect (checked after each await).
    private var generations: [UUID: Int] = [:]
    private nonisolated(unsafe) var stopObserver: NSObjectProtocol?

    /// The app's server, once a window started it.
    static weak var appServer: CherryControlServer?

    init(
        masters: HostSSHMasterManager = .shared,
        shell: @escaping @MainActor () async -> RemoteDeviceShell = { await RemoteDeviceShell.app() },
        server: @escaping @MainActor () -> CherryControlServer? = { RemoteMCPForwards.appServer }
    ) {
        self.masters = masters
        self.shell = shell
        self.server = server
        stopObserver = NotificationCenter.default.addObserver(
            forName: HostSSHMasterManager.masterDidStopNotification, object: masters, queue: .main
        ) { [weak self] notification in
            guard let destination = notification.userInfo?[HostSSHMasterManager.destinationKey] as? String else { return }
            MainActor.assumeIsolated { self?.masterStopped(destination) }
        }
    }

    deinit {
        if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
    }

    /// The forward to `target`'s device: the one there is while its master
    /// is the same, else a new one. Never throws: the state says why not.
    @discardableResult
    func ensure(_ target: Target) async -> State {
        targets[target.deviceID] = target
        if case .up(let controlPath, _, _)? = states[target.deviceID],
           masters.controlPathIfUp(for: target.destination) == controlPath {
            return states[target.deviceID]!
        }
        if let pending = pending[target.deviceID] { return await pending.value }
        states[target.deviceID] = .making
        let generation = generations[target.deviceID, default: 0]
        let task = Task { @MainActor in
            let state: State
            do {
                state = try await self.make(target, generation: generation)
            } catch RemoteMCPForwardError.stopped {
                state = .failed(RemoteMCPForwardError.stopped.localizedDescription)
            } catch {
                state = .failed(error.localizedDescription)
                SessionLog.error("Cherry MCP forward to \(target.machine): \(error.localizedDescription)")
            }
            return state
        }
        pending[target.deviceID] = task
        let state = await task.value
        if generations[target.deviceID, default: 0] == generation {
            pending[target.deviceID] = nil
            states[target.deviceID] = state
        }
        return state
    }

    /// Throws `stopped` once the device's forward was stopped after
    /// `generation` began.
    private func checkNotStopped(_ deviceID: UUID, _ generation: Int) throws {
        guard generations[deviceID, default: 0] == generation else { throw RemoteMCPForwardError.stopped }
    }

    private func make(_ target: Target, generation: Int) async throws -> State {
        let deviceID = target.deviceID
        guard let server = server() else { throw RemoteMCPForwardError.noServer }
        var shell = await shell()
        try checkNotStopped(deviceID, generation)
        // Held only while the forward is made: the forward lives as long as
        // the master, which the device's control keeps.
        let lease = masters.acquire(target.destination, environment: shell.environment)
        defer { lease.release() }
        let controlPath = await masters.waitUntilUp(target.destination, timeout: masterTimeout)
        try checkNotStopped(deviceID, generation)
        guard let controlPath else { throw RemoteMCPForwardError.noConnection(machine: target.machine) }
        shell.controlPath = controlPath
        // sshd binds the socket and does not replace one a master that
        // died left there (its StreamLocalBindUnlink is off by default):
        // the directory is checked and the old socket removed first.
        let name = RemoteMCPPaths.directoryName(installationID: target.installationID, deviceID: deviceID)
        let prepared = await shell.run(Self.prepareScript(directoryName: name), on: target.destination)
        try checkNotStopped(deviceID, generation)
        let fields = RemoteHostInstaller.fields(prepared) ?? []
        guard fields.contains(where: { $0.key == "prepared" }),
              let temporary = fields.first(where: { $0.key == "usertmp" })?.value,
              let directory = RemoteMCPPaths.remoteDirectory(
                  temporaryDirectory: temporary, installationID: target.installationID, deviceID: deviceID
              ),
              fields.first(where: { $0.key == "dir" })?.value == directory
        else {
            let temporaryProblem = fields.first { $0.key == "usertmp" }
                .flatMap { RemoteMCPPaths.temporaryDirectoryProblem($0.value).map { "its per-user temporary directory cannot be used: \($0)" } }
            let reason = fields.first { $0.key == "error" }?.value
                ?? temporaryProblem
                ?? prepared.standardError.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? (prepared.status == 0 ? "its per-user temporary directory is not usable for a socket" : "exit \(prepared.status)")
            throw RemoteMCPForwardError.prepare(machine: target.machine, reason: reason)
        }
        temporaryDirectoryFound(deviceID, temporary)
        let remote = directory + "/control.sock"
        let local = try server.addDeviceListener(deviceID: deviceID)
        let result = await Self.runSSH(
            shell: shell,
            arguments: Self.commandArguments("forward", remote: remote, local: local.path, controlPath: controlPath, destination: target.destination)
        )
        guard generations[deviceID, default: 0] == generation else {
            // Stopped meanwhile: the forward just made goes too.
            if result.status == 0 {
                _ = await Self.runSSH(
                    shell: shell,
                    arguments: Self.commandArguments("cancel", remote: remote, local: local.path, controlPath: controlPath, destination: target.destination)
                )
                _ = await shell.run(Self.cleanupScript(directoryName: name), on: target.destination)
            }
            server.removeDeviceListener(deviceID: deviceID)
            throw RemoteMCPForwardError.stopped
        }
        guard result.status == 0 else {
            let reason = result.errors.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "ssh exited with \(result.status.map(String.init) ?? "no status")"
            throw Self.isRefusal(reason)
                ? RemoteMCPForwardError.refused(machine: target.machine, reason: reason)
                : RemoteMCPForwardError.failed(machine: target.machine, reason: reason)
        }
        return .up(controlPath: controlPath, remoteSocket: remote, localSocket: local.path)
    }

    /// Ends the device's forward (the device was removed, or tests): a
    /// forward being made never takes effect; one that is up is cancelled,
    /// its socket there removed, and the listener here stops.
    func stop(deviceID: UUID) async {
        generations[deviceID, default: 0] += 1
        pending[deviceID] = nil
        let target = targets.removeValue(forKey: deviceID)
        let state = states.removeValue(forKey: deviceID)
        server()?.removeDeviceListener(deviceID: deviceID)
        guard let target, case .up(let controlPath, let remote, let local)? = state,
              masters.controlPathIfUp(for: target.destination) == controlPath
        else { return }
        var shell = await shell()
        shell.controlPath = controlPath
        _ = await Self.runSSH(
            shell: shell,
            arguments: Self.commandArguments("cancel", remote: remote, local: local, controlPath: controlPath, destination: target.destination)
        )
        _ = await shell.run(
            Self.cleanupScript(directoryName: RemoteMCPPaths.directoryName(installationID: target.installationID, deviceID: deviceID)),
            on: target.destination
        )
    }

    /// Stops every forward (tests).
    func stopAll() async {
        for deviceID in Array(Set(targets.keys).union(states.keys)) { await stop(deviceID: deviceID) }
    }

    /// The master stopped: forwards made through it went with it (its
    /// socket there stays until the next forward removes it). The next
    /// connection of the device's control makes it again.
    func masterStopped(_ destination: String) {
        for (id, target) in targets where target.destination == destination {
            if case .up? = states[id] { states[id] = nil }
        }
    }

    /// `ssh -o ControlPath=<master> -O forward|cancel -R <there>:<here> -- <destination>`.
    nonisolated static func commandArguments(_ command: String, remote: String, local: String, controlPath: String, destination: String) -> [String] {
        [
            "-o", HostSSHMasterManager.controlPathOption(controlPath),
            "-o", "BatchMode=yes",
            "-O", command,
            "-R", "\(remote):\(local)",
            "--", destination,
        ]
    }

    /// Whether ssh's error says the server refused the forward (sshd's
    /// AllowStreamLocalForwarding, AllowTcpForwarding, DisableForwarding, a
    /// `restrict` key).
    nonisolated static func isRefusal(_ errors: String) -> Bool {
        let text = errors.lowercased()
        return text.contains("remote port forwarding failed") || text.contains("forwarding request failed")
            || text.contains("administratively prohibited")
    }

    /// The account's per-user temporary directory there (`getconf
    /// DARWIN_USER_TEMP_DIR`), the private directory in it (0700, this
    /// account's, not a link), made if needed, and an old socket in it
    /// removed. Reports `usertmp=` and `dir=`.
    nonisolated static func prepareScript(directoryName: String) -> String {
        [
            "printf '%s\\n' '\(RemoteDeviceProbe.beginMarker)'",
            "t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)",
            "printf 'usertmp=%s\\n' \"$t\"",
            "case \"$t\" in /*) ;; *) echo 'error=this Mac has no per-user temporary directory (getconf DARWIN_USER_TEMP_DIR)'; printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'; exit 0 ;; esac",
            "d=\"${t%/}\"/\(RemoteDeviceProbe.singleQuoted(directoryName))",
            "printf 'dir=%s\\n' \"$d\"",
            "umask 077",
            "[ -e \"$d\" ] || [ -L \"$d\" ] || mkdir -m 700 \"$d\" 2>/dev/null",
            "if [ -L \"$d\" ] || [ ! -d \"$d\" ] || [ ! -O \"$d\" ]; then",
            "  echo \"error=$d is not a folder of this account\"",
            "else",
            "  chmod 700 \"$d\" && /bin/rm -f \"$d/control.sock\" && echo prepared=1",
            "fi",
            "printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'",
        ].joined(separator: "\n") + "\n"
    }

    /// Removes the socket and its directory there.
    nonisolated static func cleanupScript(directoryName: String) -> String {
        [
            "t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)",
            "case \"$t\" in /*) ;; *) exit 0 ;; esac",
            "d=\"${t%/}\"/\(RemoteDeviceProbe.singleQuoted(directoryName))",
            "if [ -d \"$d\" ] && [ ! -L \"$d\" ] && [ -O \"$d\" ]; then /bin/rm -f \"$d/control.sock\"; /bin/rmdir \"$d\" 2>/dev/null; fi",
            "exit 0",
        ].joined(separator: "\n") + "\n"
    }

    private static func runSSH(shell: RemoteDeviceShell, arguments: [String]) async -> (status: Int32?, errors: String) {
        await Task.detached(priority: .userInitiated) {
            let result = HostSpawnedProcess.run(
                executable: shell.sshExecutable, arguments: arguments, environment: shell.environment, timeout: 15
            )
            return (status: result.exitCode, errors: result.errors)
        }.value
    }
}
