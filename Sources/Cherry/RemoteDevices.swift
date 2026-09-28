import CherryControl
import Combine
import Foundation

// The user's other Macs ("devices", docs/specs/remote-devices.md): what
// Cherry keeps about each (`RemoteDeviceStore`, devices.json), what their
// hosts report (projects by `cherry.project` tag, `RemoteDeviceDiscovery`),
// how they stand (`RemoteDeviceConnectionState`) and the SSH aliases Add
// Mac… suggests (`SSHConfigHosts`).

/// Another Mac this Cherry reaches over SSH.
struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    /// Assigned by this Cherry; part of every project key on the device
    /// (`ProjectLocation.remote`).
    var id: UUID
    var name: String
    /// An OpenSSH alias or `user@host` (`HostedSessionHost.ssh`).
    var sshDestination: String
    /// The device's `cherry-host` when it is not on its login shell's PATH
    /// (absolute, or `~/…`): `cherry --remote-host-path`.
    var remoteHostPath: String?
    /// The names its programs' directory reports (OSC 7) may give it.
    var machineNames: [String]
    /// Its home directory (Open Home Folder), as the check found it.
    var homeDirectory: String?
    /// Folders added with Add Project on <Mac>… (absolute paths there).
    var addedProjects: [String]
    /// Folders the picker leaves out, even while sessions name them.
    var hiddenProjects: [String]
    /// When its host last answered.
    var lastSeen: Date?
    /// Its host's identity when it was added (`status --json`), which tells
    /// another alias of the same Mac apart.
    var hostID: String?
    /// Add Mac… made its SSH destination a saved host (it was not one
    /// already): Remove forgets that host (and its trusted identity) only
    /// then, never a host the user had saved.
    var createdHostEntry: Bool

    init(
        id: UUID = UUID(),
        name: String,
        sshDestination: String,
        remoteHostPath: String? = nil,
        machineNames: [String] = [],
        homeDirectory: String? = nil,
        addedProjects: [String] = [],
        hiddenProjects: [String] = [],
        lastSeen: Date? = nil,
        hostID: String? = nil,
        createdHostEntry: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sshDestination = sshDestination
        self.remoteHostPath = remoteHostPath
        self.machineNames = machineNames
        self.homeDirectory = homeDirectory
        self.addedProjects = addedProjects
        self.hiddenProjects = hiddenProjects
        self.lastSeen = lastSeen
        self.hostID = hostID
        self.createdHostEntry = createdHostEntry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sshDestination = try container.decode(String.self, forKey: .sshDestination)
        remoteHostPath = try container.decodeIfPresent(String.self, forKey: .remoteHostPath)
        machineNames = try container.decodeIfPresent([String].self, forKey: .machineNames) ?? []
        homeDirectory = try container.decodeIfPresent(String.self, forKey: .homeDirectory)
        addedProjects = try container.decodeIfPresent([String].self, forKey: .addedProjects) ?? []
        hiddenProjects = try container.decodeIfPresent([String].self, forKey: .hiddenProjects) ?? []
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
        hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
        createdHostEntry = try container.decodeIfPresent(Bool.self, forKey: .createdHostEntry) ?? false
    }

    /// Its host, when the destination is valid.
    var host: HostedSessionHost? { try? HostedSessionHost.ssh(sshDestination) }

    /// The key of the project at `path` on this device.
    func projectKey(path: String) -> String {
        ProjectLocation.remote(deviceID: id, path: path).key
    }
}

/// devices.json.
struct RemoteDevicesRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var devices: [RemoteDevice]

    init(version: Int = RemoteDevicesRecord.currentVersion, devices: [RemoteDevice]) {
        self.version = version
        self.devices = devices
    }
}

/// The devices this Cherry knows, kept in `devices.json` in the app
/// identity's Application Support folder, next to `installation.json`.
/// Only the copy of the app that holds the instance lock writes it; another
/// copy reads it and runs no device's tabs (its hostings refuse, as This
/// Mac's do). Each device's SSH destination is also a saved host of
/// `HostedSessionHostStore`, whose trusted host identities pin the device's
/// host. The store sets `HostedRemoteHostPaths.shared`'s resolver (each
/// destination's `remoteHostPath`) and registers one
/// `PersistentHostSessions.remote(…)` per device in
/// `PersistentHostingRegistry` when a window first needs it.
@MainActor
final class RemoteDeviceStore: ObservableObject {
    static let fileName = "devices.json"

    static let shared = RemoteDeviceStore(
        fileURL: AppInstanceLock.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent(RemoteDeviceStore.fileName, isDirectory: false),
        canWrite: { AppInstanceLock.shared.isHeld },
        hostStore: .shared,
        installationID: { CherryInstallation.shared.id() },
        registry: .shared,
        remoteHostPaths: .shared
    )

    /// Makes a device's hosting: its profile, and this installation's id
    /// (the remote owner). Tests replace it.
    typealias HostingFactory = @MainActor (_ profile: PersistentHostProfile, _ installationID: UUID) -> PersistentHostSessions

    @Published private(set) var devices: [RemoteDevice] = []

    let fileURL: URL
    private let canWrite: @MainActor () -> Bool
    private let hostStore: HostedSessionHostStore
    private let installationID: @MainActor () -> UUID?
    private let registry: PersistentHostingRegistry
    private let remoteHostPaths: HostedRemoteHostPaths
    private let makeHosting: HostingFactory
    private var hostings: [UUID: PersistentHostSessions] = [:]
    /// The app's saved-state store: each hosting records the sessions it
    /// ends on purpose, and those its host reports lost, there, and
    /// finishes the ends it could not do while its device was offline.
    var endedSessionsStore: WorkspaceStateStore?

    init(
        fileURL: URL,
        canWrite: @escaping @MainActor () -> Bool = { true },
        hostStore: HostedSessionHostStore,
        installationID: @escaping @MainActor () -> UUID?,
        registry: PersistentHostingRegistry,
        remoteHostPaths: HostedRemoteHostPaths,
        makeHosting: @escaping HostingFactory = { profile, installationID in
            PersistentHostSessions.remote(profile: profile, installationID: installationID)
        }
    ) {
        self.fileURL = fileURL
        self.canWrite = canWrite
        self.hostStore = hostStore
        self.installationID = installationID
        self.registry = registry
        self.remoteHostPaths = remoteHostPaths
        self.makeHosting = makeHosting
        devices = Self.load(from: fileURL)
        updateRemoteHostPaths()
    }

    // MARK: Lookup

    func device(id: UUID) -> RemoteDevice? {
        devices.first { $0.id == id }
    }

    /// The device a project key (`device:<uuid>:<path>`) names.
    func device(forProjectKey key: String) -> RemoteDevice? {
        ProjectLocation(key: key).deviceID.flatMap(device(id:))
    }

    /// The device whose host answered with `hostID` (another alias of the
    /// same Mac): recorded when it was added, or its trusted identity.
    func device(withHostID hostID: String) -> RemoteDevice? {
        devices.first { device in
            device.hostID == hostID || device.host.flatMap { hostStore.trustedHostID(for: $0) } == hostID
        }
    }

    // MARK: Changes

    /// Whether this copy may change the devices (it holds the instance
    /// lock): the picker's and sheets' changing items are off otherwise.
    var canModify: Bool { canWrite() }

    static let readOnlyReason = "Another copy of Cherry keeps your Macs now; change them there."

    /// Adds a device (Add Mac…). Its destination becomes a saved SSH host
    /// unless it was one already. `hostID`: its host's identity, when the
    /// check found its daemon running: an alias of a Mac already added is
    /// refused.
    @discardableResult
    func add(
        name: String,
        sshDestination: String,
        remoteHostPath: String? = nil,
        machineNames: [String] = [],
        homeDirectory: String? = nil,
        hostID: String? = nil
    ) throws -> RemoteDevice {
        guard canWrite() else { throw HostedSessionError.message(Self.readOnlyReason) }
        let host = try HostedSessionHost.ssh(sshDestination)
        guard let destination = host.sshDestination else { throw HostedSessionError.message("Enter an SSH host.") }
        guard !devices.contains(where: { $0.sshDestination == destination }) else {
            throw HostedSessionError.message("\(destination) is already one of your Macs.")
        }
        if let hostID = hostID?.nilIfEmpty, let existing = device(withHostID: hostID) {
            throw HostedSessionError.message(
                "\(destination) is the same Mac as \(existing.name) (\(existing.sshDestination)): its session host has the same identity."
            )
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = RemoteDevice(
            name: trimmed.isEmpty ? destination : trimmed,
            sshDestination: destination,
            remoteHostPath: remoteHostPath?.nilIfEmpty,
            machineNames: machineNames.filter { !$0.isEmpty },
            homeDirectory: homeDirectory?.nilIfEmpty,
            // Saved to the second.
            lastSeen: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            hostID: hostID?.nilIfEmpty,
            createdHostEntry: !hostStore.hosts.contains(host)
        )
        if device.createdHostEntry { try hostStore.add(destination) }
        devices.append(device)
        save()
        return device
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    /// Forgets a device: ends nothing on it (its sessions keep running
    /// there), forgets its trusted identity, and unregisters its hosting
    /// unless a window still has its tabs.
    func remove(_ id: UUID) {
        guard canWrite(), let device = device(id: id) else { return }
        devices.removeAll { $0.id == id }
        // Only a saved host (and trusted identity) Add Mac… made.
        if device.createdHostEntry, let host = device.host { hostStore.remove(host) }
        if let hosting = hostings.removeValue(forKey: id), !hosting.isInUse {
            // One still in use stays registered: its windows and ends keep
            // it, and adding the Mac again takes it back.
            registry.unregister(hosting.profile.host)
        }
        save()
    }

    /// Add Project on <Mac>…: `path` as the device reported it (`pwd -P`).
    func addProject(path: String, to id: UUID) {
        let path = ProjectLocation.remote(deviceID: id, path: path).path
        update(id) { device in
            device.hiddenProjects.removeAll { $0 == path }
            if !device.addedProjects.contains(path) { device.addedProjects.append(path) }
        }
    }

    /// The picker leaves `path` out (Remove from the project's menu).
    func hideProject(path: String, on id: UUID) {
        update(id) { device in
            device.addedProjects.removeAll { $0 == path }
            if !device.hiddenProjects.contains(path) { device.hiddenProjects.append(path) }
        }
    }

    /// The device's host answered now.
    func noteSeen(_ id: UUID, at date: Date = Date()) {
        guard let device = device(id: id) else { return }
        // Saved at most once a minute.
        if let lastSeen = device.lastSeen, date.timeIntervalSince(lastSeen) < 60 { return }
        update(id) { $0.lastSeen = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
    }

    /// What a new check found about the device (Reconnect after a change).
    func update(_ id: UUID, change: (inout RemoteDevice) -> Void) {
        guard canWrite(), let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var device = devices[index]
        change(&device)
        guard device != devices[index] else { return }
        devices[index] = device
        // The same hosting, renamed: its tabs and windows keep it.
        if let hosting = hostings[id], hosting.profile.displayName != device.name {
            hosting.updateDisplayName(device.name)
        }
        save()
    }

    // MARK: Hostings

    /// The hosting that runs the device's tabs, registered in
    /// `PersistentHostingRegistry` on first use. Nil for a device this
    /// Cherry does not know, or while this copy has no installation id
    /// (another copy holds the instance lock).
    func hosting(for id: UUID) -> PersistentHostSessions? {
        if let hosting = hostings[id] { return hosting }
        guard let device = device(id: id), let host = device.host, let installation = installationID() else { return nil }
        if let live = registry.hosting(for: host), !live.profile.isThisMac, live.profile.isKnownDevice {
            // A Mac removed and added again while its hosting was still in
            // use: that hosting carries on (never two for one host).
            live.updateDisplayName(device.name)
            hostings[id] = live
            return live
        }
        let hosting = makeHosting(
            .remote(host: host, displayName: device.name, machineNames: Set(device.machineNames)),
            installation
        )
        hosting.endedSessionsStore = endedSessionsStore
        hosting.resumeRecordedEndsOnConnection()
        hostings[id] = hosting
        registry.register(hosting)
        return hosting
    }

    /// Registers every device's hosting (at launch, once the store has the
    /// app's saved-state store): each finishes, when its Mac next answers,
    /// the ends it could not do while it was offline.
    func registerHostings() {
        for device in devices { _ = hosting(for: device.id) }
    }

    /// A hosting for a device window whose device is not known (removed,
    /// or the list could not be read): its tabs fail, saying why, and
    /// nothing runs on This Mac instead.
    static func unavailableHosting(
        for key: String,
        reason: String,
        instanceLock: AppInstanceLock? = .shared
    ) -> PersistentHostSessions {
        let deviceID = ProjectLocation(key: key).deviceID ?? UUID()
        let host = HostedSessionHost(sshDestination: "unknown-\(deviceID.uuidString.lowercased().prefix(8))")
        var profile = PersistentHostProfile.remote(host: host, displayName: "an unknown Mac")
        profile.isKnownDevice = false
        return PersistentHostSessions.remote(
            profile: profile,
            installationID: UUID(),
            // Inert: it never runs a helper, so nothing reaches ssh for a
            // made-up destination.
            control: { inertControl(host: host, reason: reason) },
            installationUnavailableReason: { reason },
            instanceLock: instanceLock
        )
    }

    /// A control connection that never connects: every attempt fails with
    /// `reason` before any helper (or ssh) runs.
    static func inertControl(host: HostedSessionHost, reason: String) -> HostControl {
        HostControl(
            host: host,
            clientProvider: { throw HostedSessionError.unavailable(reason) },
            hostStore: HostedSessionHostStore(defaults: inertDefaults),
            masters: HostSSHMasterManager(configuration: .init(directory: { nil })),
            launcher: { _ in throw HostedSessionError.unavailable(reason) },
            localHostUnavailableReason: nil
        )
    }

    /// A defaults domain nothing writes: the inert control never connects,
    /// so it never trusts or saves a host.
    private static let inertDefaults = UserDefaults(suiteName: "Cherry.inert-host-store") ?? .standard

    /// A restore for a window whose device is not known: every saved tab is
    /// kept as it was (never restored attached, and so saved again as not
    /// owned) until the device is known again.
    static let keepingRestorer: WorkspaceSessionRestorer = { request in
        WorkspaceRestoreResult.keeping(request.records + request.unboundRecords)
    }

    // MARK: Files

    private func updateRemoteHostPaths() {
        let paths = Dictionary(
            devices.compactMap { device in device.remoteHostPath.map { (device.sshDestination, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        remoteHostPaths.setResolver { paths[$0] }
    }

    private func save() {
        updateRemoteHostPaths()
        guard canWrite() else { return }
        do {
            try WorkspaceStateStore.write(RemoteDevicesRecord(devices: devices), to: fileURL)
        } catch {
            SessionLog.error("could not save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    private static func load(from fileURL: URL) -> [RemoteDevice] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(RemoteDevicesRecord.self, from: data),
              record.version == RemoteDevicesRecord.currentVersion
        else {
            SessionLog.error("\(fileURL.path) cannot be used by this version; no devices are listed")
            return []
        }
        return record.devices
    }
}

// MARK: - Projects and sessions on a device

/// A project the picker lists under a device.
struct RemoteDeviceProject: Equatable, Sendable {
    /// Its folder on the device.
    let path: String
    /// Sessions of any owner whose `cherry.project` tag names it.
    let sessionCount: Int
    /// Added with Add Project on <Mac>… (listed with no sessions too).
    let isAdded: Bool

    var name: String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// Groups a device's sessions by project, as the picker lists them.
enum RemoteDeviceDiscovery {
    /// The folder on the device a session's `cherry.project` tag names: a
    /// device key's path (this or another installation's tab), the path
    /// itself (the other Mac's own Cherry), or nil (untagged: another
    /// client's, or the CLI's).
    static func projectPath(ofTag tag: String?) -> String? {
        guard let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else { return nil }
        if ProjectLocation.isRemoteKey(tag) { return ProjectLocation(key: tag).path }
        guard tag.hasPrefix("/") else { return nil }
        return ProjectLocation.remote(deviceID: UUID(), path: tag).path
    }

    static func projectPath(of info: HostedSessionInfo) -> String? {
        projectPath(ofTag: info.tags[PersistentSessionTag.project])
    }

    /// The device's projects: the folders its sessions name (every owner's:
    /// this Cherry's, the other Mac's own, other installations'), with how
    /// many sessions each has, and the added ones, minus the hidden ones,
    /// by name; and how many sessions name no project ("Other sessions").
    static func projects(
        sessions: [HostedSessionInfo],
        added: [String],
        hidden: [String]
    ) -> (projects: [RemoteDeviceProject], otherSessionCount: Int) {
        let hiddenPaths = Set(hidden)
        var counts: [String: Int] = [:]
        var other = 0
        for info in sessions {
            guard let path = projectPath(of: info) else {
                other += 1
                continue
            }
            counts[path, default: 0] += 1
        }
        let addedPaths = Set(added)
        let paths = Set(counts.keys).union(addedPaths).subtracting(hiddenPaths)
        let projects = paths.map { path in
            RemoteDeviceProject(path: path, sessionCount: counts[path] ?? 0, isAdded: addedPaths.contains(path))
        }
        .sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
        return (projects, other)
    }

    /// A device project window's "Not open here" group: the project's
    /// sessions that no open tab shows, this Cherry's own (Reopen: the
    /// window owns them again) and other owners' (Attach: shown without
    /// owning them, so closing the tab only disconnects).
    struct NotOpenSessions: Equatable {
        var own: [HostedSessionInfo] = []
        var others: [HostedSessionInfo] = []

        var isEmpty: Bool { own.isEmpty && others.isEmpty }
    }

    /// `isShown`: an open tab shows the session, or is about to
    /// (`PersistentHostSessions.isShownByOpenTab`). `isEnding`: this app is
    /// ending it. Ended sessions of other owners are left out.
    static func notOpenSessions(
        in sessions: [HostedSessionInfo],
        projectPath: String,
        owner: String,
        isShown: (HostedSessionInfo) -> Bool,
        isEnding: (HostedSessionInfo) -> Bool
    ) -> NotOpenSessions {
        var result = NotOpenSessions()
        for info in sessions where self.projectPath(of: info) == projectPath && !isShown(info) && !isEnding(info) {
            if info.owner == owner {
                result.own.append(info)
            } else if info.isRunning {
                result.others.append(info)
            }
        }
        let byCreation: (HostedSessionInfo, HostedSessionInfo) -> Bool = { $0.createdAt < $1.createdAt }
        result.own.sort(by: byCreation)
        result.others.sort(by: byCreation)
        return result
    }
}

// MARK: - How a device stands

/// What the picker says of a device, from its control connection.
enum RemoteDeviceConnectionState: Equatable {
    /// Not reached during this run.
    case unknown(lastSeen: Date?)
    case connecting
    case connected(sessionCount: Int)
    /// Unreachable now (it keeps being tried while a window leases it).
    case offline(reason: String)
    /// Another host identity answered: Trust New Identity.
    case identityChanged(reason: String)
    /// SSH refused the login or the host key: not retried by itself.
    case loginRefused(reason: String)
    /// Its cherry-host speaks another protocol.
    case incompatible(reason: String)

    init(control state: HostControl.ConnectionState, sessionCount: Int, lastSeen: Date?) {
        switch state {
        case .idle:
            self = .unknown(lastSeen: lastSeen)
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected(sessionCount: sessionCount)
        case .waitingToReconnect(let error), .failed(let error):
            self = Self.failure(error)
        }
    }

    static func failure(_ error: HostedSessionError) -> Self {
        let reason = error.errorDescription ?? "The Mac could not be reached."
        if error.isIdentityMismatch { return .identityChanged(reason: reason) }
        if error.isVersionMismatch { return .incompatible(reason: reason) }
        if error.isAuthenticationFailure { return .loginRefused(reason: reason) }
        return .offline(reason: reason)
    }

    enum Dot: String, Equatable {
        case green, yellow, red, gray
    }

    var dot: Dot {
        switch self {
        case .connected: .green
        case .connecting: .yellow
        case .identityChanged, .loginRefused, .incompatible: .red
        case .offline, .unknown: .gray
        }
    }

    /// The device row's subtitle.
    func subtitle(now: Date = Date()) -> String {
        switch self {
        case .unknown(let lastSeen):
            guard let lastSeen else { return "Not checked yet" }
            return "Last seen \(Self.relative(lastSeen, now: now))"
        case .connecting:
            return "Connecting…"
        case .connected(let count):
            return count == 1 ? "Connected · 1 session" : "Connected · \(count) sessions"
        case .offline:
            return "Offline"
        case .identityChanged:
            return "Its identity changed"
        case .loginRefused:
            return "SSH login refused"
        case .incompatible:
            return "Needs the same Cherry version"
        }
    }

    /// The state row in the device's submenu.
    var detail: String {
        switch self {
        case .unknown(let lastSeen): lastSeen == nil ? "Not checked yet" : "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .offline(let reason): "Offline: \(reason)"
        case .identityChanged(let reason): "Identity changed: \(reason)"
        case .loginRefused(let reason): "SSH login refused: \(reason)"
        case .incompatible(let reason): reason
        }
    }

    /// Reconnect is offered unless connected or connecting.
    var offersReconnect: Bool {
        switch self {
        case .connected, .connecting, .identityChanged: false
        case .unknown, .offline, .loginRefused, .incompatible: true
        }
    }

    var offersTrustNewIdentity: Bool {
        if case .identityChanged = self { return true }
        return false
    }

    /// Its projects can be opened (from cached state while not connected;
    /// never while another identity or protocol answers).
    var allowsOpening: Bool {
        switch self {
        case .identityChanged, .incompatible: false
        default: true
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) h ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "yesterday" : "\(days) days ago"
        }
    }
}

// MARK: - SSH config aliases

/// The Host aliases of an OpenSSH config that Add Mac… suggests: every
/// name of every `Host` line that is not a pattern (`*`, `?`, `!`, ranges).
/// `Include` lines are followed (relative to `~/.ssh`, with globs) up to a
/// small depth. Nothing is connected to.
enum SSHConfigHosts {
    static func aliases(inConfig text: String) -> [String] {
        var aliases: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            guard let (keyword, value) = keywordAndValue(rawLine), keyword == "host" else { continue }
            for name in words(value) where isPlainAlias(name) && !aliases.contains(name) {
                aliases.append(name)
            }
        }
        return aliases
    }

    /// The aliases of the config at `url` and the files it includes.
    static func aliases(configAt url: URL, sshDirectory: URL? = nil, depth: Int = 0) -> [String] {
        guard depth < 8, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let directory = sshDirectory ?? url.deletingLastPathComponent()
        var aliases = aliases(inConfig: text)
        for rawLine in text.components(separatedBy: .newlines) {
            guard let (keyword, value) = keywordAndValue(rawLine), keyword == "include" else { continue }
            for pattern in words(value) {
                for included in expand(pattern, relativeTo: directory) {
                    for alias in Self.aliases(configAt: included, sshDirectory: directory, depth: depth + 1)
                    where !aliases.contains(alias) {
                        aliases.append(alias)
                    }
                }
            }
        }
        return aliases
    }

    /// The user's own config (`~/.ssh/config`).
    static func userAliases() -> [String] {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        return aliases(configAt: ssh.appendingPathComponent("config"), sshDirectory: ssh)
    }

    /// The aliases that start with what was typed (case-insensitive), the
    /// exact one first; all of them for nothing typed.
    static func suggestions(for typed: String, among aliases: [String]) -> [String] {
        let typed = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return aliases }
        let matching = aliases.filter { $0.lowercased().hasPrefix(typed) }
        return matching.sorted { lhs, rhs in
            (lhs.lowercased() == typed ? 0 : 1, lhs.count, lhs) < (rhs.lowercased() == typed ? 0 : 1, rhs.count, rhs)
        }
    }

    private static func keywordAndValue(_ rawLine: String) -> (String, String)? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        // `Keyword value`, `Keyword=value` or `Keyword = value`.
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let keyword = line[..<separator].lowercased()
        var value = line[separator...].drop { $0 == " " || $0 == "\t" }
        if value.first == "=" { value = value.dropFirst().drop { $0 == " " || $0 == "\t" } }
        return (keyword, String(value))
    }

    /// Words of a value, honouring double quotes; a `#` word ends it.
    private static func words(_ value: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == " " || character == "\t" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if !quoted, character == "#", current.isEmpty {
                break
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func isPlainAlias(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(where: { "*?![]".contains($0) }) && (try? HostedSessionHost.ssh(name)) != nil
    }

    private static func expand(_ pattern: String, relativeTo directory: URL) -> [URL] {
        let expanded = NSString(string: pattern).expandingTildeInPath
        let path = expanded.hasPrefix("/") ? expanded : directory.appendingPathComponent(expanded).path
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }
}
