import Darwin
import Foundation
import os

/// A CLI's version: the first `<major>.<minor>.<patch>` its `--version`
/// prints ("2.1.299 (Claude Code)", "codex-cli 0.162.1").
struct AgentCLIVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(versionOutput: String) {
        guard let range = versionOutput.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else {
            return nil
        }
        let parts = versionOutput[range].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(major: parts[0], minor: parts[1], patch: parts[2])
    }

    static func < (lhs: AgentCLIVersion, rhs: AgentCLIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// The versions of the agent CLIs on This Mac (`claude`, `codex`, `pi`),
/// which decide whether a launch gets Cherry MCP on its command line
/// (`AgentMCPLaunch`, `AgentMCPLaunchContext`) and whether Settings may
/// run Pi's `pi mcp` (`PiMCPRegistration`). A version is what
/// `<executable> --version` prints on its standard output, run off the
/// main thread in the login environment, as the tab's shell finds the
/// executable, for at most `timeout`; it is kept for this run by the file
/// that ran (its path, inode, size and modification time), so an updated
/// CLI is asked again. A version only its standard error names is kept
/// apart (`VersionAnswer.versionOnErrorOutput`), never as its version.
///
/// A launch only reads what is known (`version(of:)`) and never waits: a
/// CLI not asked yet launches without the flags while it is asked in the
/// background. The app's windows warm it as the first one opens
/// (`warmUp(agents:)`). Settings waits for its answer (`answer(_:environment:)`,
/// with what it printed). Tests build their own (`seed`, `answer`,
/// `probe`); none touches `.shared`, which runs the user's CLIs.
final class AgentCLIVersions: @unchecked Sendable {
    /// The app's: the login environment (`HostedSessionLoginEnvironment`),
    /// and a launch's miss asks the CLI. Never Cherry's own environment:
    /// its PATH is not the one a tab's login shell finds the CLI on, so a
    /// CLI is not found until the login environment is known.
    static let shared = AgentCLIVersions(
        environment: { HostedSessionLoginEnvironment.shared.availableNow()?.environment ?? [:] },
        resolvedEnvironment: { HostedSessionLoginEnvironment.shared.resolve()?.environment ?? [:] },
        probesOnMiss: true
    )

    /// The file a version was read from: an executable regular file, its
    /// path as found (a link's target's inode, size and modification time).
    struct ExecutableFile: Hashable, Sendable {
        var path: String
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
    }

    /// What a CLI's `--version` gave. Only its standard output gives its
    /// version.
    enum VersionAnswer: Equatable, Sendable {
        /// It printed this version.
        case version(AgentCLIVersion)
        /// It exited 0 and printed no version on its standard output (what
        /// it printed there: `output`), but this one on its standard error,
        /// as Pi 0.62.0 does without a terminal. Never the CLI's version:
        /// only to name a CLI older than a minimum (Pi's "Update Pi"). It
        /// gives no `pi mcp` and no launch flags; launches take it as
        /// unknown (`version(of:)`).
        case versionOnErrorOutput(AgentCLIVersion, output: String)
        /// It exited 0 but printed no version: what it printed
        /// (`shownOutput`).
        case noVersion(output: String)
        /// It did not run, did not exit 0, or did not finish within the
        /// timeout.
        case noAnswer
    }

    /// What one asked file printed: its version (from its standard output),
    /// nil when it printed none there; the version its standard error named
    /// then (`VersionAnswer.versionOnErrorOutput`); and the start of what it
    /// printed on its standard output (`shownOutput`).
    private struct Answer {
        var version: AgentCLIVersion?
        var versionOnErrorOutput: AgentCLIVersion?
        var output: String

        var reply: VersionAnswer {
            if let version { return .version(version) }
            if let versionOnErrorOutput { return .versionOnErrorOutput(versionOnErrorOutput, output: output) }
            return .noVersion(output: output)
        }
    }

    private struct State {
        var answers: [ExecutableFile: Answer] = [:]
        /// Files a launch's miss is asking now.
        var asking: Set<ExecutableFile> = []
    }

    /// The environment a launch resolves a CLI in, and its miss asks it
    /// with: what is known now, never waited for.
    private let environment: @Sendable () -> [String: String]
    /// The environment the warm-up waits for (it may run the login shell).
    private let resolvedEnvironment: @Sendable () -> [String: String]
    private let probesOnMiss: Bool
    private let timeout: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `probesOnMiss`: whether `version(of:)` asks a CLI it does not know
    /// yet, in the background. Off unless given: a test's instance runs
    /// nothing it was not asked to.
    init(
        environment: @escaping @Sendable () -> [String: String],
        resolvedEnvironment: (@Sendable () -> [String: String])? = nil,
        probesOnMiss: Bool = false,
        timeout: TimeInterval = 5
    ) {
        self.environment = environment
        self.resolvedEnvironment = resolvedEnvironment ?? environment
        self.probesOnMiss = probesOnMiss
        self.timeout = timeout
    }

    /// The version of the CLI `word` runs in this instance's environment, if
    /// it is known; never runs it. A CLI not known yet is asked in the
    /// background when the instance `probesOnMiss`, for a later launch.
    func version(of word: String) -> AgentCLIVersion? {
        let environment = environment()
        guard let file = Self.executableFile(for: word, environment: environment) else { return nil }
        let (answer, asks): (Answer?, Bool) = state.withLock { state in
            if let answer = state.answers[file] { return (answer, false) }
            guard probesOnMiss, !state.asking.contains(file) else { return (nil, false) }
            state.asking.insert(file)
            return (nil, true)
        }
        if asks {
            DispatchQueue.global(qos: .utility).async { [self] in
                ask(file, environment: environment)
                state.withLock { _ = $0.asking.remove(file) }
            }
        }
        return answer?.version
    }

    /// The version of the CLI `word` runs in `environment`, if it is known;
    /// never runs it. For tests, which name their environment; launches use
    /// `version(of:)`.
    func version(of word: String, environment: [String: String]) -> AgentCLIVersion? {
        guard let file = Self.executableFile(for: word, environment: environment) else { return nil }
        return state.withLock { $0.answers[file]?.version }
    }

    /// What `--version` of the CLI `word` runs in `environment` gives: the
    /// known answer, else what it prints now (off the caller's thread),
    /// kept as `version(of:)` keeps it. `.noAnswer` when `word` names no
    /// executable, or it does not exit 0 within `timeout` (it is killed,
    /// with what it started). Settings waits for it before it runs a CLI's
    /// `mcp` (`PiMCPRegistration.register`); launches never wait for a
    /// version (`version(of:)`, `warmUp(agents:)`).
    ///
    /// `asksAgain`: runs it even when its answer is known, and forgets that
    /// one first. A file can stay the same while what it runs changes (a
    /// version manager's shim: Volta, mise, asdf), so Settings asks again
    /// right before it runs `pi mcp`, and on Check Again.
    func answer(_ word: String, environment: [String: String], asksAgain: Bool = false) async -> VersionAnswer {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let answer = Self.executableFile(for: word, environment: environment).map {
                    ask($0, environment: environment, asksAgain: asksAgain)
                } ?? .noAnswer
                continuation.resume(returning: answer)
            }
        }
    }

    /// The version `answer(_:environment:)` gives, if it gives one.
    func probe(_ word: String, environment: [String: String]) async -> AgentCLIVersion? {
        guard case .version(let version) = await answer(word, environment: environment) else { return nil }
        return version
    }

    /// Fixed versions for the executables at these paths, as they are now
    /// (a test's known versions). A path that names no executable is left
    /// out.
    func seed(_ versions: [String: AgentCLIVersion]) {
        let files = versions.compactMap { path, version in
            Self.executableFile(atPath: path).map { ($0, version) }
        }
        state.withLock { state in
            for (file, version) in files {
                state.answers[file] = Answer(version: version, output: version.description)
            }
        }
    }

    /// Asks the CLIs that `agents`' launches would give Cherry MCP to, once
    /// the login environment is known (off the main thread), so the agents
    /// of this run find their versions.
    func warmUp(agents: [AgentToolDefinition]) {
        let words = Set(agents.filter(\.isLaunchable).compactMap {
            AgentMCPLaunch.detect(commandLine: $0.commandLine)?.executableWord
        })
        guard !words.isEmpty else { return }
        let resolvedEnvironment = resolvedEnvironment
        DispatchQueue.global(qos: .utility).async { [self] in
            let environment = resolvedEnvironment()
            for word in words.sorted() {
                guard let file = Self.executableFile(for: word, environment: environment) else { continue }
                ask(file, environment: environment)
            }
        }
    }

    /// The known answer of `file` (unless it `asksAgain`, which forgets
    /// it), else what it prints now. Kept unless it could not be run or did
    /// not finish (asked again by the next launch), and only while the file
    /// is the one that ran. Blocks.
    @discardableResult
    private func ask(_ file: ExecutableFile, environment: [String: String], asksAgain: Bool = false) -> VersionAnswer {
        if asksAgain {
            state.withLock { _ = $0.answers.removeValue(forKey: file) }
        } else if let answer = state.withLock({ $0.answers[file] }) {
            return answer.reply
        }
        guard let printed = Self.versionOutput(of: file.path, environment: environment, timeout: timeout) else {
            SessionLog.debug("[mcp] \(file.path) --version gave no answer")
            return .noAnswer
        }
        let version = AgentCLIVersion(versionOutput: printed.output)
        let answer = Answer(
            version: version,
            versionOnErrorOutput: version == nil ? AgentCLIVersion(versionOutput: printed.errors) : nil,
            output: Self.shownOutput(printed.output)
        )
        let shown = answer.version.map(String.init(describing:))
            ?? answer.versionOnErrorOutput.map { "no version (\($0) on standard error)" }
            ?? "no version"
        SessionLog.debug("[mcp] \(file.path) --version: \(shown)")
        if Self.executableFile(atPath: file.path) == file {
            state.withLock { $0.answers[file] = answer }
        }
        return answer.reply
    }

    /// The start of what `--version` printed, as Settings quotes it: its
    /// lines joined with spaces, at most 200 characters.
    static func shownOutput(_ output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(line.prefix(200))
    }

    /// The executable `word` runs: itself when it has a `/` (a leading `~`
    /// expanded), else the first `word` on `environment`'s PATH that is an
    /// executable regular file, as a shell looks for it.
    static func executableFile(for word: String, environment: [String: String]) -> ExecutableFile? {
        guard !word.isEmpty else { return nil }
        if word.contains("/") {
            let path = word.hasPrefix("~") ? NSString(string: word).expandingTildeInPath : word
            return path.hasPrefix("/") ? executableFile(atPath: path) : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let path = directory.hasSuffix("/") ? "\(directory)\(word)" : "\(directory)/\(word)"
            if let file = executableFile(atPath: path) { return file }
        }
        return nil
    }

    /// `path` as an `ExecutableFile` when it names an executable regular
    /// file (a link is followed).
    static func executableFile(atPath path: String) -> ExecutableFile? {
        var status = stat()
        guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 else { return nil }
        return ExecutableFile(
            path: path,
            inode: UInt64(status.st_ino),
            size: Int64(status.st_size),
            modifiedSeconds: Int(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(status.st_mtimespec.tv_nsec)
        )
    }

    /// The most of `--version`'s output, and of its errors, that is read.
    private static let outputLimit = 64 * 1_024
    /// How long the pipes are read for once `--version` exited.
    private static let exitDrainTime: TimeInterval = 0.25

    /// What `<executable> --version` prints on its standard output and on
    /// its standard error, when it exits 0 within `timeout`; both pipes are
    /// read as it writes them, so neither fills up and blocks it, and for
    /// at most `exitDrainTime` once it exited (a process it started can
    /// keep them open). It runs
    /// in a session of its own, without a terminal (`HostSpawnedProcess`;
    /// standard input /dev/null). One that does not exit in time is sent
    /// SIGTERM, then SIGKILL, with its process group. Blocks.
    static func versionOutput(
        of executable: String, environment: [String: String], timeout: TimeInterval
    ) -> (output: String, errors: String)? {
        guard let process = try? HostSpawnedProcess.spawn(
            executable: executable, arguments: ["--version"], environment: environment, output: true, errors: true
        ) else { return nil }
        var deadline = Date().addingTimeInterval(timeout)
        // Standard output, then standard error: each pipe until its end
        // (-1 then), and what was read of it.
        var pipes = [process.output, process.errors]
        var printed = [Data(), Data()]
        var status: Int32 = 0
        var exited = false
        func noteExit() {
            guard !exited else { return }
            let result = waitpid(process.pid, &status, WNOHANG)
            if result == process.pid {
                exited = true
            } else if result == -1, errno != EINTR {
                exited = true
                status = -1
            }
            // What it left in the pipes is read at once; a process it
            // started that keeps writing to them is not waited for.
            if exited { deadline = min(deadline, Date().addingTimeInterval(exitDrainTime)) }
        }
        func finish(_ index: Int) {
            close(pipes[index])
            pipes[index] = -1
        }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            noteExit()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let open = pipes.indices.filter { pipes[$0] >= 0 }
            guard !open.isEmpty else { break }
            var descriptors = open.map { pollfd(fd: pipes[$0], events: Int16(POLLIN), revents: 0) }
            // Once it exited, only what it left in the pipes is read: a
            // process it started can keep them open.
            let ready = poll(&descriptors, nfds_t(descriptors.count), exited ? 0 : Int32(min(remaining, 0.05) * 1_000) + 1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if exited { break }
                continue
            }
            for (index, descriptor) in zip(open, descriptors) where descriptor.revents != 0 {
                let count = read(descriptor.fd, &buffer, buffer.count)
                if count < 0 {
                    if errno != EINTR && errno != EAGAIN { finish(index) }
                    continue
                }
                if count == 0 {
                    finish(index)
                    continue
                }
                if printed[index].count < outputLimit { printed[index].append(contentsOf: buffer[..<count]) }
            }
        }
        for index in pipes.indices where pipes[index] >= 0 { finish(index) }
        while !exited, deadline.timeIntervalSinceNow > 0 {
            noteExit()
            if !exited { usleep(10_000) }
        }
        guard exited else {
            _ = kill(-process.pid, SIGTERM)
            let killAt = Date().addingTimeInterval(0.5)
            while !exited, Date() < killAt {
                noteExit()
                if !exited { usleep(10_000) }
            }
            if !exited {
                _ = kill(-process.pid, SIGKILL)
                _ = HostSpawnedProcess.waitForExit(process.pid)
            }
            return nil
        }
        guard HostSpawnedProcess.exitCode(fromWaitStatus: status) == 0 else { return nil }
        return (String(decoding: printed[0], as: UTF8.self), String(decoding: printed[1], as: UTF8.self))
    }
}
