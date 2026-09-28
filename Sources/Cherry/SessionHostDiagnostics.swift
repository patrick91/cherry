import AppKit
import Foundation

/// The local session host as `cherry status --json` describes it
/// (Settings › Sessions, "Session Host").
struct SessionHostStatus: Equatable, Sendable {
    var running: Bool
    var socket: String?
    var build: String?
    var protocolVersion: Int?
    var pid: Int?
    var uptime: TimeInterval?
    var sessions: Int?
    var runningSessions: Int?
    var maxSessions: Int?
    var connections: Int?
    var maxConnections: Int?
    var logPath: String?
    /// The bundled `cherry`'s build (`client.build`).
    var clientBuild: String?
    /// Sessions whose holder runs another build than the daemon (they keep
    /// the code they started with until they end).
    var otherHolderBuilds = 0

    /// Parses `cherry status --json` (running or not); nil for anything else.
    static func parse(_ data: Data) -> SessionHostStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let running = object["running"] as? Bool
        else { return nil }
        let host = object["host"] as? [String: Any] ?? [:]
        let client = object["client"] as? [String: Any] ?? [:]
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        let build = (object["build"] as? String) ?? (host["build"] as? String)
        let sessions = object["sessions"] as? [[String: Any]] ?? []
        return SessionHostStatus(
            running: running,
            socket: (host["socket"] as? String) ?? (object["socket"] as? String),
            build: build,
            protocolVersion: int(host["version"]) ?? int(object["protocol"]),
            pid: int(host["pid"]),
            uptime: int(host["uptime_ms"]).map { TimeInterval($0) / 1000 },
            sessions: int(host["sessions"]) ?? (running ? sessions.count : nil),
            runningSessions: int(host["running_sessions"]),
            maxSessions: int(host["max_sessions"]),
            connections: int(host["connections"]),
            maxConnections: int(host["max_connections"]),
            logPath: (host["log_path"] as? String) ?? (object["log_path"] as? String),
            clientBuild: client["build"] as? String,
            otherHolderBuilds: sessions.filter { session in
                guard let holder = session["holder_build"] as? String, let build else { return false }
                return holder != build
            }.count
        )
    }

    /// "Running · build 20260927101500.abc1234 · up 2h 5m", or "Not running".
    var headline: String {
        guard running else { return "Not running" }
        var parts = ["Running"]
        if let build { parts.append("build \(build)") }
        if let uptime { parts.append("up \(Self.duration(uptime))") }
        return parts.joined(separator: " · ")
    }

    /// "3 sessions (2 running) of 128 · 5 of 1024 connections · 1 holder of
    /// an older build", or where the host would run.
    var detail: String {
        guard running else {
            return "It starts with the first persistent tab. Socket: \(socket ?? "unknown")."
        }
        var parts: [String] = []
        if let sessions {
            var text = sessions == 1 ? "1 session" : "\(sessions) sessions"
            if let runningSessions { text += " (\(runningSessions) running)" }
            if let maxSessions { text += " of \(maxSessions)" }
            parts.append(text)
        }
        if let connections, let maxConnections {
            parts.append("\(connections) of \(maxConnections) connections")
        }
        if otherHolderBuilds > 0 {
            parts.append(otherHolderBuilds == 1
                ? "1 session runs in a holder of another build"
                : "\(otherHolderBuilds) sessions run in holders of another build")
        }
        if let pid { parts.append("pid \(pid)") }
        return parts.joined(separator: " · ")
    }

    /// `12s`, `4m 10s`, `2h 5m`, `3d 4h`, as `cherry status` prints it.
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let (days, hours, minutes) = (seconds / 86_400, seconds / 3_600 % 24, seconds / 60 % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}

/// What a `cherry` command printed, and how it ended.
struct HostCommandOutput: Equatable, Sendable {
    var status: Int32
    var output: String
    var errors: String
}

/// Runs the bundled `cherry` with the given arguments.
typealias HostCommandRunner = @Sendable ([String]) async throws -> HostCommandOutput

/// Settings › Sessions' "Session Host" card: the local host's status
/// (`cherry status --json`), Reveal Log, Copy Diagnostics (`cherry status`
/// and `cherry doctor`) and Restart Host (`cherry restart`, after the card
/// asked). It runs only commands that never start a host, except the
/// restart it was asked for.
@MainActor
final class SessionHostDiagnostics: ObservableObject {
    static let shared = SessionHostDiagnostics()

    @Published private(set) var status: SessionHostStatus?
    /// Why the status could not be read (no helper, a disk image copy).
    @Published private(set) var problem: String?
    @Published private(set) var isRestarting = false
    /// What the last restart said when it failed.
    @Published private(set) var restartFailure: String?

    private let runner: HostCommandRunner
    private let unavailableReason: @MainActor () -> String?
    private let revealInFinder: @MainActor (URL) -> Void
    private let copyToPasteboard: @MainActor (String) -> Void

    init(
        runner: @escaping HostCommandRunner = SessionHostDiagnostics.installedRunner(),
        unavailableReason: @escaping @MainActor () -> String? = { HostedSessionInstallation.localHostUnavailableReason() },
        revealInFinder: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        copyToPasteboard: @escaping @MainActor (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.runner = runner
        self.unavailableReason = unavailableReason
        self.revealInFinder = revealInFinder
        self.copyToPasteboard = copyToPasteboard
    }

    /// Reads the host's status again (`cherry status --json`).
    func refresh() async {
        if let reason = unavailableReason() {
            problem = reason
            status = nil
            return
        }
        do {
            let result = try await runner(["status", "--json"])
            if let parsed = SessionHostStatus.parse(Data(result.output.utf8)) {
                status = parsed
                problem = nil
            } else {
                status = nil
                problem = Self.failure(of: "cherry status", result)
            }
        } catch {
            status = nil
            problem = error.localizedDescription
        }
    }

    /// `cherry status` and `cherry doctor`, as a report to paste into an
    /// issue: the app's version first.
    func diagnostics() async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        var report = "Cherry \(version) (\(build))\n"
        if let reason = unavailableReason() {
            report += "Local sessions are unavailable: \(reason)\n"
        }
        for arguments in [["status"], ["doctor"]] {
            report += "\n$ cherry \(arguments.joined(separator: " "))\n"
            do {
                let result = try await runner(arguments)
                report += result.output
                if !result.errors.isEmpty { report += result.errors }
                if result.status != 0 { report += "(exit status \(result.status))\n" }
            } catch {
                report += "could not run it: \(error.localizedDescription)\n"
            }
        }
        return report
    }

    func copyDiagnostics() async {
        copyToPasteboard(await diagnostics())
    }

    /// Shows the host's log in the Finder: the daemon's `host.log`, or
    /// where it would be.
    func revealLog() {
        guard let path = status?.logPath else { return }
        revealInFinder(URL(fileURLWithPath: path))
    }

    /// Restarts the local host (`cherry restart`): its sessions carry on in
    /// their holders and tabs reconnect. The caller asked first.
    func restartHost() async {
        isRestarting = true
        restartFailure = nil
        defer { isRestarting = false }
        do {
            let result = try await runner(["restart"])
            if result.status != 0 {
                restartFailure = Self.failure(of: "cherry restart", result)
            }
        } catch {
            restartFailure = error.localizedDescription
        }
        await refresh()
    }

    private static func failure(of command: String, _ result: HostCommandOutput) -> String {
        let said = (result.errors.isEmpty ? result.output : result.errors)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "\(command) failed (exit status \(result.status))." : said
    }

    // MARK: Running cherry

    /// Runs `executable` with `environment` off the main actor.
    nonisolated static func processRunner(executable: URL, environment: [String: String]) -> HostCommandRunner {
        { arguments in
            try await Task.detached(priority: .userInitiated) {
                try runProcess(executable, arguments: arguments, environment: environment)
            }.value
        }
    }

    /// The app's own `cherry` (`HostedSessionClient.installed()`) with the
    /// helper environment its control connection uses.
    nonisolated static func installedRunner() -> HostCommandRunner {
        { arguments in
            let client = try HostedSessionClient.installed()
            let login = await client.resolvedLoginEnvironment()
            let environment = HostedSessionLoginEnvironment.helperEnvironment(
                base: ProcessInfo.processInfo.environment, login: login?.environment
            )
            return try await processRunner(executable: client.executableURL, environment: environment)(arguments)
        }
    }

    private final class Collected: @unchecked Sendable {
        var data = Data()
    }

    private nonisolated static func runProcess(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> HostCommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read both to the end before waiting, so neither pipe fills.
        let group = DispatchGroup()
        let errorData = Collected()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return HostCommandOutput(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            errors: String(decoding: errorData.data, as: UTF8.self)
        )
    }
}
