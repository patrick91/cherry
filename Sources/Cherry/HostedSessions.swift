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

struct HostedSessionInfo: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let cwd: String
    let command: [String]
    let cols: Int
    let rows: Int
    let state: String
    let pid: UInt32?
    let exitCode: UInt32?
    let attached: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, cwd, command, cols, rows, state, pid, attached
        case exitCode = "exit_code"
    }

    var isRunning: Bool { state == "running" || state == "starting" }
    var displayName: String { name.isEmpty ? String(id.prefix(8)) : name }
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

    var arguments: [String] { host.arguments + ["--expected-host-id", hostID, "attach", sessionID] }
    var execCommand: String {
        ([executablePath] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum HostedAttachmentStatus: Equatable {
    /// The local adapter is running; the terminal shows connection diagnostics.
    case active
    /// An adapter exit is not evidence that the hosted process exited.
    case disconnected(adapterExitCode: Int32?)
}

enum HostedSessionError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

@MainActor
final class HostedSessionHostStore: ObservableObject {
    static let shared = HostedSessionHostStore()
    @Published private(set) var hosts: [HostedSessionHost]
    private let defaults: UserDefaults
    private static let key = "hostedSessions.sshHosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hosts = (defaults.stringArray(forKey: Self.key) ?? [])
            .compactMap { try? HostedSessionHost.ssh($0) }
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
        save()
    }

    private func save() {
        defaults.set(hosts.compactMap(\.sshDestination), forKey: Self.key)
    }
}

struct HostedSessionClient: Sendable {
    let executableURL: URL
    var timeout: TimeInterval = 35

    static func installed() throws -> HostedSessionClient {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CHERRY_CLI_PATH"], !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw HostedSessionError.message("CHERRY_CLI_PATH does not point to an executable cherry client.")
            }
            return HostedSessionClient(executableURL: URL(fileURLWithPath: override))
        }

        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("cherry"))
        }
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for configuration in ["debug", "release"] {
            candidates.append(sourceRoot.appendingPathComponent("Host/target/\(configuration)/cherry"))
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("cherry"))
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw HostedSessionError.message("The cherry session client is missing. Build the Host workspace or set CHERRY_CLI_PATH to its cherry executable.")
        }
        return HostedSessionClient(executableURL: executable)
    }

    func list(on host: HostedSessionHost, expectedHostID: String? = nil) async throws -> HostedSessionList {
        let identityArguments = expectedHostID.map { ["--expected-host-id", $0] } ?? []
        return try JSONDecoder().decode(HostedSessionList.self, from: await run(host.arguments + identityArguments + ["list", "--json"]))
    }

    func create(on host: HostedSessionHost, expectedHostID: String, name: String, cwd: String) async throws -> HostedSessionInfo {
        let arguments = host.arguments + ["--expected-host-id", expectedHostID, "new", "--name", name, "--cwd", cwd.isEmpty ? "~" : cwd]
        return try JSONDecoder().decode(HostedSessionInfo.self, from: await run(arguments))
    }

    func terminate(_ sessionID: String, on host: HostedSessionHost, expectedHostID: String) async throws {
        _ = try await run(host.arguments + ["--expected-host-id", expectedHostID, "kill", sessionID])
    }

    func remove(_ sessionID: String, on host: HostedSessionHost, expectedHostID: String) async throws {
        _ = try await run(host.arguments + ["--expected-host-id", expectedHostID, "remove", sessionID])
    }

    private func run(_ arguments: [String]) async throws -> Data {
        let executableURL = executableURL
        let timeout = timeout
        return try await Task.detached(priority: .userInitiated) {
            try HostedSessionCommand.run(executableURL: executableURL, arguments: arguments, timeout: timeout)
        }.value
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

    static func run(executableURL: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
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

        let result = stdout.result
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(String(decoding: stderr.result.data, as: UTF8.self).prefix(2_000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostedSessionError.message(message.isEmpty ? "The session host could not be reached. Check the host installation and your SSH connection, then refresh the session list." : message)
        }
        guard !result.overflow else {
            throw HostedSessionError.message("The session host returned a response larger than the client limit.")
        }
        return result.data
    }
}
