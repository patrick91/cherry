import AppKit
import CherryControl
import Darwin
import Foundation

// Ports, URLs and previews for tabs of another Mac (docs/specs/remote-devices.md,
// phase 4a). A device tab's program listens on that Mac, and no pid of that
// Mac means anything here (rule 4), so that Mac's cherry-host says which
// ports the program's process tree listens on (`cherry-host ports --json`,
// run over the device's SSH master like `project-info`), and Cherry forwards
// the ones it shows through that master (`ssh -O forward -L …`): a click on
// a localhost URL in the tab, and the URLs MCP reports for its services,
// open the forwarded port here.

// MARK: - cherry-host ports

/// `cherry-host ports --json PID…`.
struct RemotePortReport: Decodable, Equatable, Sendable {
    static let supportedVersion = 1

    struct Listener: Decodable, Equatable, Sendable {
        var port: Int
        /// `127.0.0.1`, `::1`, `*` (every address), or another address.
        var host: String
        /// The process that listens there (the asked pid or a descendant).
        var pid: Int32
        var command: String?
    }

    struct Process: Decodable, Equatable, Sendable {
        var pid: Int32
        var alive: Bool
        var ports: [Listener]
    }

    var version: Int
    var processes: [Process]
    /// Why the listening sockets could not be read there.
    var error: String?

    func ports(of pid: Int32) -> [Listener] {
        processes.first { $0.pid == pid }?.ports ?? []
    }
}

/// Asks a device which ports its sessions' programs listen on: a `sh -s`
/// script over its ssh (the master's ControlPath while it is up) that runs
/// its cherry-host's `ports --json`.
struct RemotePortScanner: Sendable {
    /// The most bytes of an answer read.
    static let reportLimit = 1024 * 1024
    static let begin = "CHERRY-PORTS 1"

    let deviceName: String
    let destination: String
    /// The device's cherry-host (`~/…` or absolute), else the one on its PATH.
    let remoteHostPath: String?
    let shell: @Sendable () async -> RemoteDeviceShell

    static func app(_ device: RemoteDevice, masters: HostSSHMasterManager = .shared) -> RemotePortScanner {
        let destination = device.sshDestination
        return RemotePortScanner(
            deviceName: device.name,
            destination: destination,
            remoteHostPath: device.remoteHostPath,
            shell: {
                var shell = await RemoteDeviceShell.app()
                shell.controlPath = masters.controlPathIfUp(for: destination)
                shell.timeout = 20
                return shell
            }
        )
    }

    static func script(pids: [Int32], remoteHostPath: String?) -> String {
        var lines: [String] = []
        if let path = remoteHostPath?.nilIfEmpty {
            lines.append("host=\(RemoteDeviceProbe.shellWord(path))")
        } else {
            lines.append("host=cherry-host")
        }
        lines.append("printf '%s\\n' '\(begin)'")
        lines.append("exec \"$host\" ports --json " + pids.map { String($0) }.joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parses what the script printed (`RemoteProjectError` as
    /// `project-info`'s: unreachable, a cherry-host without `ports`, or an
    /// answer this Cherry cannot read).
    static func parse(_ output: RemoteDeviceShell.DataOutput, machine: String) throws -> RemotePortReport {
        let text = output.standardOutput.prefix(reportLimit + 64)
        guard let marker = text.range(of: Data((begin + "\n").utf8)) else {
            if output.status == 255 || output.timedOut {
                throw RemoteProjectError.unreachable(RemoteDeviceSSHFailure.classify(output.standardError, timedOut: output.timedOut).message)
            }
            throw RemoteProjectError.invalid("\(machine) did not look for ports (exit \(output.status)): \(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if output.status != 0 {
            let error = output.standardError.lowercased()
            if error.contains("unrecognized subcommand") || error.contains("no such file") || error.contains("not found") {
                throw RemoteProjectError.invalid("The session host on \(machine) is too old to report ports; update it (Update Session Host…).")
            }
            throw RemoteProjectError.invalid("cherry-host ports on \(machine) failed (exit \(output.status)): \(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let body = text[marker.upperBound...]
        guard body.count <= reportLimit,
              let report = try? JSONDecoder().decode(RemotePortReport.self, from: Data(body)),
              report.version == RemotePortReport.supportedVersion
        else {
            throw RemoteProjectError.invalid("\(machine) reported its ports in a way this Cherry cannot read.")
        }
        return report
    }

    func ports(of pids: [Int32]) async throws -> RemotePortReport {
        let shell = await shell()
        let script = Self.script(pids: pids, remoteHostPath: remoteHostPath)
        let destination = destination
        let output = await Task.detached(priority: .userInitiated) {
            shell.runSynchronously(script, on: destination)
        }.value
        return try Self.parse(output, machine: deviceName)
    }
}

// MARK: - Forwards

/// A port of another Mac forwarded here.
struct RemotePortForward: Equatable, Sendable {
    /// The device's SSH destination (its first master carries the forward).
    let destination: String
    /// The Mac's name ("Studio").
    let machine: String
    /// Where that Mac connects: `localhost`, `127.0.0.1` or `::1`.
    let remoteHost: String
    let remotePort: Int
    /// The port on This Mac's loopback.
    let localPort: Int

    /// `-L` of ssh: `127.0.0.1:<local port>:<remote host>:<remote port>`
    /// (an IPv6 host in brackets). The explicit bind keeps it on This Mac's
    /// IPv4 loopback whatever `GatewayPorts` says (the master also runs
    /// with `GatewayPorts=no`).
    var specification: String {
        let host = remoteHost.contains(":") ? "[\(remoteHost)]" : remoteHost
        return "\(Self.bindAddress):\(localPort):\(host):\(remotePort)"
    }

    static let bindAddress = "127.0.0.1"

    /// The forward's URL here: `http://127.0.0.1:<local port>`.
    var localURL: String { "http://\(Self.bindAddress):\(localPort)" }

    /// "Forwarded from Studio".
    var label: String { "Forwarded from \(machine)" }
}

enum RemotePortForwardError: LocalizedError, Equatable {
    case noConnection(machine: String)
    case failed(machine: String, port: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .noConnection(let machine):
            "Cherry has no SSH connection to \(machine) to forward the port through."
        case .failed(let machine, let port, let reason):
            "Port \(port) of \(machine) could not be forwarded: \(reason)"
        }
    }
}

/// The forwards of devices' ports, made through each device's SSH master
/// (`ssh -O forward`, which the master's `ClearAllForwardings=yes` does not
/// refuse: that option clears only forwards given at its start). One forward
/// per device port, shared by the tabs that asked for it (its owners); it
/// is cancelled (`ssh -O cancel`) once no tab needs it (each tab's are
/// released when it closes, and a window's when it closes), and dropped when
/// the master stops (the forward went with it). A lease keeps the master
/// running while the device has forwards.
@MainActor
final class RemotePortForwards {
    /// The app's, made when first needed (tests put their own in its
    /// place).
    static var shared: RemotePortForwards {
        get {
            if let made { return made }
            let forwards = RemotePortForwards()
            made = forwards
            return forwards
        }
        set { made = newValue }
    }
    private static var made: RemotePortForwards?

    /// The app's if any forward was asked for: a tab's close releases its
    /// forwards without making the app's (and its SSH master manager).
    static var existing: RemotePortForwards? {
        get { made }
        set { made = newValue }
    }

    struct Key: Hashable {
        var destination: String
        var remoteHost: String
        var remotePort: Int
    }

    /// Runs `ssh <arguments>` (off the main actor); its exit status and
    /// standard error.
    typealias SSHRunner = @Sendable (_ arguments: [String]) async -> (status: Int32?, errors: String)

    let masters: HostSSHMasterManager
    /// The ssh and the environment it runs with (the login shell's).
    let shell: @MainActor () async -> RemoteDeviceShell
    /// A port nothing listens on here, for the next forward.
    let freePort: @MainActor () -> Int?
    /// How long a start of the master is waited for.
    var masterTimeout: TimeInterval = 20

    private(set) var forwards: [Key: RemotePortForward] = [:]
    private var owners: [Key: Set<UUID>] = [:]
    private var leases: [String: HostSSHMasterLease] = [:]
    private nonisolated(unsafe) var stopObserver: NSObjectProtocol?

    init(
        masters: HostSSHMasterManager = .shared,
        shell: @escaping @MainActor () async -> RemoteDeviceShell = { await RemoteDeviceShell.app() },
        freePort: @escaping @MainActor () -> Int? = { RemotePortForwards.unusedLocalPort() }
    ) {
        self.masters = masters
        self.shell = shell
        self.freePort = freePort
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

    /// A forward of the device's `remotePort` there is (whichever address
    /// it reaches it at), without making one.
    func existing(remotePort: Int, destination: String) -> RemotePortForward? {
        forwards.values
            .filter { $0.destination == destination && $0.remotePort == remotePort }
            .min { $0.localPort < $1.localPort }
    }

    /// The forwards `owner` (a tab) uses.
    func forwards(of owner: UUID) -> [RemotePortForward] {
        owners.filter { $0.value.contains(owner) }.compactMap { forwards[$0.key] }
            .sorted { $0.remotePort < $1.remotePort }
    }

    /// The forward of `remoteHost:remotePort` on the device at
    /// `destination` for `owner`: the one there is, else a new one on a
    /// free local port (up to three tries when a port is taken meanwhile).
    func forward(
        remotePort: Int,
        remoteHost: String = "localhost",
        destination: String,
        machine: String,
        owner: UUID
    ) async throws -> RemotePortForward {
        let key = Key(destination: destination, remoteHost: remoteHost, remotePort: remotePort)
        if let existing = forwards[key] {
            owners[key, default: []].insert(owner)
            return existing
        }
        // One forward per port even when two ask at once.
        let making: Task<RemotePortForward, Error>
        if let pending = pending[key] {
            making = pending
        } else {
            making = Task { @MainActor in
                try await self.makeForward(key: key, machine: machine)
            }
            pending[key] = making
        }
        // A tab that closes while this runs must not own the forward.
        let releasesBefore = releases[owner, default: 0]
        waiting[key, default: 0] += 1
        let result = await making.result
        pending[key] = nil
        waiting[key, default: 1] -= 1
        if waiting[key] == 0 { waiting[key] = nil }
        switch result {
        case .success(let forward):
            if releases[owner, default: 0] == releasesBefore {
                owners[key, default: []].insert(owner)
            } else {
                dropIfUnowned(key)
            }
            return forward
        case .failure(let error):
            releaseLeaseIfUnused(destination)
            throw error
        }
    }

    /// Forwards being made, and how many callers wait for each.
    private var pending: [Key: Task<RemotePortForward, Error>] = [:]
    private var waiting: [Key: Int] = [:]
    /// How many times each owner was released, so a forward finished after
    /// its owner closed is not kept for it.
    private var releases: [UUID: Int] = [:]

    /// Whether a forward of `destination` is being made (tests).
    func isMaking(_ destination: String) -> Bool {
        pending.keys.contains { $0.destination == destination } || waiting.keys.contains { $0.destination == destination }
    }

    /// Cancels a forward no tab owns once nobody waits for it.
    private func dropIfUnowned(_ key: Key) {
        guard owners[key]?.isEmpty ?? true, waiting[key] == nil, pending[key] == nil else { return }
        owners[key] = nil
        if let forward = forwards.removeValue(forKey: key) { cancel(forward) }
        releaseLeaseIfUnused(key.destination)
    }

    private func makeForward(key: Key, machine: String) async throws -> RemotePortForward {
        let destination = key.destination
        let remoteHost = key.remoteHost
        let remotePort = key.remotePort
        let shell = await shell()
        if leases[destination] == nil {
            leases[destination] = masters.acquire(destination, environment: shell.environment)
        }
        guard let controlPath = await masters.waitUntilUp(destination, timeout: masterTimeout) else {
            throw RemotePortForwardError.noConnection(machine: machine)
        }
        var lastReason = "no free port here"
        for _ in 0..<3 {
            guard let localPort = freePort() else { break }
            let forward = RemotePortForward(
                destination: destination, machine: machine, remoteHost: remoteHost,
                remotePort: remotePort, localPort: localPort
            )
            let result = await Self.runSSH(
                shell: shell,
                arguments: Self.commandArguments("forward", forward: forward, controlPath: controlPath)
            )
            if result.status == 0 {
                forwards[key] = forward
                return forward
            }
            lastReason = result.errors.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "ssh exited with \(result.status.map(String.init) ?? "no status")"
            // A local port taken meanwhile: another one.
            guard lastReason.contains("forwarding failed") || lastReason.contains("Port forwarding failed") else { break }
        }
        throw RemotePortForwardError.failed(machine: machine, port: remotePort, reason: lastReason)
    }

    /// `owner` (a tab that closed) needs none of its forwards any more.
    func release(owner: UUID) {
        releases[owner, default: 0] += 1
        for (key, set) in owners where set.contains(owner) {
            var remaining = set
            remaining.remove(owner)
            if remaining.isEmpty {
                owners[key] = nil
                if let forward = forwards.removeValue(forKey: key) { cancel(forward) }
            } else {
                owners[key] = remaining
            }
        }
        for destination in Set(leases.keys) { releaseLeaseIfUnused(destination) }
    }

    /// Cancels every forward (tests; the app's quit stops the masters).
    func releaseAll() {
        for forward in forwards.values { cancel(forward) }
        forwards.removeAll()
        owners.removeAll()
        for lease in leases.values { lease.release() }
        leases.removeAll()
    }

    /// The master stopped: its forwards went with it.
    func masterStopped(_ destination: String) {
        for key in forwards.keys where key.destination == destination {
            forwards[key] = nil
            owners[key] = nil
        }
        releaseLeaseIfUnused(destination)
    }

    private func releaseLeaseIfUnused(_ destination: String) {
        guard !forwards.keys.contains(where: { $0.destination == destination }), !isMaking(destination) else { return }
        leases.removeValue(forKey: destination)?.release()
    }

    private func cancel(_ forward: RemotePortForward) {
        guard let controlPath = masters.controlPathIfUp(for: forward.destination) else { return }
        let shell = shell
        Task { @MainActor in
            _ = await Self.runSSH(
                shell: await shell(),
                arguments: Self.commandArguments("cancel", forward: forward, controlPath: controlPath)
            )
        }
    }

    /// `ssh -o ControlPath=<master> -O forward|cancel -L <spec> -- <destination>`.
    static func commandArguments(_ command: String, forward: RemotePortForward, controlPath: String) -> [String] {
        [
            "-o", HostSSHMasterManager.controlPathOption(controlPath),
            "-o", "BatchMode=yes",
            "-O", command,
            "-L", forward.specification,
            "--", forward.destination,
        ]
    }

    private static func runSSH(shell: RemoteDeviceShell, arguments: [String]) async -> (status: Int32?, errors: String) {
        await Task.detached(priority: .userInitiated) {
            let result = HostSpawnedProcess.run(
                executable: shell.sshExecutable, arguments: arguments, environment: shell.environment, timeout: 15
            )
            return (status: result.exitCode, errors: result.errors)
        }.value
    }

    /// A TCP port no one listens on at This Mac's IPv4 loopback (where
    /// forwards listen): the kernel's choice for port 0.
    static func unusedLocalPort() -> Int? {
        bindLoopback(port: 0, ipv6: false)
    }

    /// Binds (and closes) a socket on the loopback; the port it had.
    private static func bindLoopback(port: Int, ipv6: Bool) -> Int? {
        let descriptor = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            address.sin6_addr = in6addr_loopback
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            guard bound == 0 else { return nil }
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard withUnsafeMutablePointer(to: &address, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }) == 0 else { return nil }
            return Int(UInt16(bigEndian: address.sin6_port))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: in_addr_t(UInt32(0x7F00_0001).bigEndian))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }) == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

// MARK: - Localhost URLs in a device tab

/// A click on a URL in a tab of another Mac: a URL of that Mac's loopback
/// (`localhost`, `127.0.0.1`, `0.0.0.0`, `[::1]`) means a port there, so the
/// port is forwarded (`RemotePortForwards`) and the forwarded URL opened
/// here, with a toast "Forwarded from <Mac>". Any other URL opens as it
/// does for a tab of This Mac.
@MainActor
enum RemoteURLOpening {
    /// Test seams.
    static var opener: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    static var forwards: @MainActor () -> RemotePortForwards = { .shared }
    static var device: @MainActor (HostedSessionHost) -> RemoteDevice? = { host in
        RemoteDeviceStore.shared.devices.first { $0.host == host }
    }
    static var showToast: @MainActor (ProjectWindowToast, NSWindow?) -> Void = { toast, window in
        guard let window, let chromeState = ProjectWindowRegistry.shared.chromeState(for: window) else { return }
        chromeState.toasts.show(toast)
    }
    private(set) static var lastOpen: Task<Void, Never>?

    /// The host (as the forward reaches it there) and port a loopback URL
    /// names: `http` or `https` to `localhost`, an IPv4 literal of
    /// 127.0.0.0/8 or `0.0.0.0`, or `[::1]`/`[::]`. Nil for any other URL
    /// (a name that only starts like an address, `127.evil.example`, is
    /// not the loopback).
    static func loopbackTarget(of url: URL) -> (remoteHost: String, port: Int)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased()
        else { return nil }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let remoteHost: String
        if bare == "localhost" {
            remoteHost = "localhost"
        } else if let octets = ipv4Octets(bare) {
            if octets == [0, 0, 0, 0] {
                remoteHost = "localhost"
            } else if octets[0] == 127 {
                remoteHost = bare
            } else {
                return nil
            }
        } else if let v6 = ipv6Address(bare) {
            if v6 == in6addr_loopback.bytes {
                remoteHost = "::1"
            } else if v6 == in6addr_any.bytes {
                remoteHost = "localhost"
            } else {
                return nil
            }
        } else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { return nil }
        return (remoteHost, port)
    }

    /// The four octets of a dotted-quad IPv4 literal (`inet_pton`), else nil.
    static func ipv4Octets(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func ipv6Address(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return address.bytes
    }

    /// `url` with its host and port replaced by the forward's: `127.0.0.1`
    /// (where the forward listens: `localhost` could resolve to `::1`
    /// first, where it does not) and the local port; its path, query and
    /// fragment kept.
    static func forwardedURL(_ url: URL, localPort: Int) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = RemotePortForward.bindAddress
        components.port = localPort
        return components.url
    }

    /// The toast after a forward opened.
    static func forwardedToast(_ forward: RemotePortForward) -> ProjectWindowToast {
        ProjectWindowToast(
            title: forward.label,
            message: "localhost:\(forward.remotePort) on \(forward.machine) opens here as 127.0.0.1:\(forward.localPort).",
            action: nil
        )
    }

    /// Takes the click when `session` runs on another Mac and `urlString`
    /// names that Mac's loopback: true (the forward and the opening follow).
    /// False otherwise (the URL opens as usual).
    @discardableResult
    static func open(_ urlString: String, for session: TerminalSession, window: NSWindow?) -> Bool {
        guard let hosting = session.persistentHosting, !hosting.profile.isThisMac,
              let url = URL(string: urlString), let target = loopbackTarget(of: url)
        else { return false }
        let machine = hosting.profile.displayName
        let host = hosting.profile.host
        let owner = session.id
        lastOpen = Task { @MainActor in
            guard let device = device(host) else {
                showToast(ProjectWindowToast(title: "Couldn’t open \(url.host() ?? "localhost"):\(target.port) of \(machine)", message: "Cherry no longer knows that Mac."), window)
                return
            }
            do {
                let forward = try await forwards().forward(
                    remotePort: target.port, remoteHost: target.remoteHost,
                    destination: device.sshDestination, machine: machine, owner: owner
                )
                guard let local = forwardedURL(url, localPort: forward.localPort) else { return }
                opener(local)
                showToast(forwardedToast(forward), window)
            } catch {
                showToast(ProjectWindowToast(
                    title: "Couldn’t open localhost:\(target.port) of \(machine)",
                    message: error.localizedDescription
                ), window)
            }
        }
        return true
    }
}

// MARK: - Services of device tabs (MCP)

/// A device tab whose ports MCP asks for.
struct RemoteInspectableProcess {
    let process: InspectableProcess
    let tabID: UUID
    let host: HostedSessionHost
    let machine: String
    /// The program's pid there (`SessionInfo.pid`).
    let remotePID: Int32
}

/// The services of tabs of other Macs, for MCP's `get_process_ports`,
/// `services_list` and `wait_for_bound_port`. `forwarding`: forward each
/// port found (only for an explicit probe, `wait_for_bound_port` with
/// `probe_http`); otherwise nothing is forwarded.
@MainActor
protocol RemoteServiceDetecting {
    func detectServices(processes: [RemoteInspectableProcess], forwarding: Bool) async throws -> [ServiceRecord]
}

/// Asks each device (`RemotePortScanner`) which ports its tabs' programs
/// listen on. A record names the Mac (`machine`) and the URL there
/// (`remoteURL`); listing forwards nothing, so its `url` is the forwarded
/// one only when the port is forwarded already (a clicked link) or
/// `forwarding` asks for it (an HTTP probe), with `forwardedFrom` naming
/// the Mac; otherwise it is the URL there. A port that could not be
/// forwarded says why (`forwardError`).
@MainActor
struct DeviceServiceDetector: RemoteServiceDetecting {
    var device: @MainActor (HostedSessionHost) -> RemoteDevice? = { host in
        RemoteDeviceStore.shared.devices.first { $0.host == host }
    }
    var scanner: @MainActor (RemoteDevice) -> RemotePortScanner = { RemotePortScanner.app($0) }
    /// The forwards to make new ones with (`forwarding`).
    var forwards: @MainActor () -> RemotePortForwards = { .shared }
    /// The forwards there are, if any (never made just to look).
    var existingForwards: @MainActor () -> RemotePortForwards? = { RemotePortForwards.existing }

    func detectServices(processes: [RemoteInspectableProcess], forwarding: Bool) async throws -> [ServiceRecord] {
        var records: [ServiceRecord] = []
        var failures: [String] = []
        let byHost = Dictionary(grouping: processes, by: \.host)
        for (host, tabs) in byHost.sorted(by: { $0.key.id < $1.key.id }) {
            guard let device = device(host) else {
                failures.append("\(tabs.first?.machine ?? "A Mac") is no longer known")
                continue
            }
            let report: RemotePortReport
            do {
                report = try await scanner(device).ports(of: tabs.map(\.remotePID))
            } catch {
                failures.append(error.localizedDescription)
                continue
            }
            if let error = report.error { failures.append("\(device.name): \(error)") }
            for tab in tabs {
                // One record per port (a server listens on 127.0.0.1 and
                // ::1 alike), reached where it listens.
                let byPort = Dictionary(grouping: report.ports(of: tab.remotePID), by: \.port)
                for (_, listeners) in byPort.sorted(by: { $0.key < $1.key }) {
                    let listener = listeners[0]
                    let remoteHost = Self.forwardHost(forListenerHosts: listeners.map(\.host))
                    let remoteURL = "http://localhost:\(listener.port)"
                    var url = remoteURL
                    var forwardedFrom: String?
                    var forwardError: String?
                    if forwarding {
                        do {
                            let forward = try await forwards().forward(
                                remotePort: listener.port, remoteHost: remoteHost,
                                destination: device.sshDestination, machine: device.name, owner: tab.tabID
                            )
                            url = forward.localURL
                            forwardedFrom = device.name
                        } catch {
                            forwardError = error.localizedDescription
                        }
                    } else if let forward = existingForwards()?.existing(remotePort: listener.port, destination: device.sshDestination) {
                        url = forward.localURL
                        forwardedFrom = device.name
                    }
                    records.append(ServiceRecord(
                        processID: tab.process.id,
                        processName: tab.process.name,
                        kind: tab.process.kind,
                        pid: nil,
                        port: listener.port,
                        host: listener.host,
                        url: url,
                        attribution: .processTree,
                        protocolGuess: MacOSServiceDetector.protocolGuess(port: listener.port),
                        readiness: .bound,
                        lastSeenAt: Date(),
                        commandName: tab.process.commandName,
                        agentName: tab.process.agentName,
                        machine: device.name,
                        remoteURL: remoteURL,
                        forwardedFrom: forwardedFrom,
                        forwardError: forwardError
                    ))
                }
            }
        }
        if records.isEmpty, !failures.isEmpty {
            throw CherryControlError(code: "service_detection_failed", message: failures.joined(separator: "; "))
        }
        return records
    }

    /// Where a forward reaches a port there: its IPv6 loopback when it
    /// listens only there, `127.0.0.1` when only there, else `localhost`
    /// (sshd there tries each of its addresses).
    static func forwardHost(forListenerHosts hosts: [String]) -> String {
        let normalized = Set(hosts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) })
        if normalized == ["::1"] { return "::1" }
        if normalized == ["127.0.0.1"] { return "127.0.0.1" }
        return "localhost"
    }
}

private extension in6_addr {
    var bytes: [UInt8] { withUnsafeBytes(of: self) { Array($0) } }
}
