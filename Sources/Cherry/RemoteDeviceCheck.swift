import CherryControl
import Darwin
import Foundation

// Add Mac… (docs/specs/remote-devices.md). One `ssh -T -o BatchMode=yes
// <host> sh -s` runs a POSIX script on the other Mac (whatever its login
// shell), which reports the system, the session host it finds (`cherry-host
// version --json` and `status --json`, never starting or replacing
// anything), this Cherry's installs there and any Cherry.app, and the
// permissions tabs there will have. Installing this Cherry's session host
// there is RemoteHostInstall.swift's (phase 2).

/// Runs a script on another Mac through the user's ssh, without a terminal:
/// BatchMode (no prompts), no forwarding, a connect timeout. The script goes
/// on standard input to `sh -s`, so any login shell (fish, csh) runs it.
struct RemoteDeviceShell: Sendable {
    /// The ssh the app runs (the login shell's `ssh` on PATH, else
    /// /usr/bin/ssh). Tests pass a fake one.
    var sshExecutable: String
    /// Cherry's environment with the login shell's variables (its
    /// SSH_AUTH_SOCK and PATH for ProxyCommand tools).
    var environment: [String: String]
    var connectTimeout: Int = 10
    var timeout: TimeInterval = 30
    /// The device's SSH master's control path while it is up
    /// (`HostSSHMasterManager.controlPathIfUp`): an install's commands go
    /// through it instead of logging in again.
    var controlPath: String?

    struct Output: Equatable, Sendable {
        var status: Int32
        var standardOutput: String
        var standardError: String
        var timedOut = false
    }

    /// The app's: resolves the login environment (off the main actor).
    static func app() async -> RemoteDeviceShell {
        await Task.detached(priority: .userInitiated) {
            // Its ssh (and the masters it starts) never take the last run's
            // agent socket (`LoginEnvironmentCache`).
            let environment = HostControl.sshMasterEnvironment(
                base: ProcessInfo.processInfo.environment, login: HostedSessionLoginEnvironment.shared.resolve()
            )
            return RemoteDeviceShell(sshExecutable: sshExecutable(environment: environment), environment: environment)
        }.value
    }

    /// `ssh` on the environment's PATH, else /usr/bin/ssh.
    static func sshExecutable(environment: [String: String]) -> String {
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/ssh"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/ssh"
    }

    /// The ssh arguments for running `sh -s` on `destination`.
    func arguments(destination: String) -> [String] {
        [
            "-T",
            "-o", "ControlMaster=no",
        ]
        + (controlPath.map { ["-o", HostSSHMasterManager.controlPathOption($0)] } ?? [])
        + [
            "-o", "RemoteCommand=none",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            // No agent or X11 forwarding.
            "-a", "-x",
            "--", destination, "sh -s",
        ]
    }

    /// Runs `script` on `destination`. Never on the main actor's time: the
    /// process is waited for on a thread of its own.
    func run(_ script: String, on destination: String) async -> Output {
        let shell = self
        return await Self.onOwnThread {
            shell.runSynchronously(script, on: destination).text
        }
    }

    /// Runs `body`, which blocks (waits for a process, reads its pipes), on
    /// a thread of its own. Neither Swift's cooperative pool (as wide as the
    /// Mac has cores, 3 on a CI runner) nor GCD's global queues (at most 5
    /// threads a core) may be held for as long as a copy can take: blocked
    /// there, their threads run nothing else, and blocks queued behind them
    /// (another install's pipe reads) wait until their timeout.
    static func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Reads `handle` to its end on a thread of its own, into `box`, then
    /// leaves `group` (see `onOwnThread`).
    static func readToEnd(_ handle: FileHandle, into box: PipeOutputBox, group: DispatchGroup) {
        group.enter()
        let thread = Thread {
            box.data = handle.readDataToEndOfFile()
            box.finished = true
            group.leave()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// What a script printed, as bytes (git's NUL-separated lists).
    struct DataOutput: Sendable {
        var status: Int32
        var standardOutput: Data
        var standardError: String
        var timedOut = false

        var text: Output {
            Output(
                status: status,
                standardOutput: String(decoding: standardOutput, as: UTF8.self),
                standardError: standardError,
                timedOut: timedOut
            )
        }
    }

    /// Runs `script` on `destination` and waits for it (blocking: call it
    /// off the main actor).
    func runSynchronously(_ script: String, on destination: String) -> DataOutput {
        let host: HostedSessionHost
        do {
            host = try HostedSessionHost.ssh(destination)
        } catch {
            return DataOutput(status: 255, standardOutput: Data(), standardError: error.localizedDescription)
        }
        let output = Self.runProcess(
            executable: sshExecutable,
            arguments: arguments(destination: host.sshDestination ?? destination),
            environment: environment,
            input: script,
            timeout: timeout
        )
        if controlPath != nil, output.status == 255, Self.isRefusedByMaster(output.standardError) {
            // The master has no session to spare (a server with a lower
            // MaxSessions): directly, as the CLI does.
            var direct = self
            direct.controlPath = nil
            return direct.runSynchronously(script, on: destination)
        }
        return output
    }

    /// ssh's words when the master connection refused a session.
    static func isRefusedByMaster(_ standardError: String) -> Bool {
        standardError.contains("Session open refused by peer")
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String],
        input: String,
        timeout: TimeInterval
    ) -> DataOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return DataOutput(status: 255, standardOutput: Data(), standardError: "Could not run ssh: \(error.localizedDescription)")
        }
        let group = DispatchGroup()
        let outData = PipeOutputBox()
        let errData = PipeOutputBox()
        readToEnd(stdout.fileHandleForReading, into: outData, group: group)
        readToEnd(stderr.fileHandleForReading, into: errData, group: group)
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if group.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 2)
            }
        }
        process.waitUntilExit()
        return DataOutput(
            status: timedOut ? 255 : process.terminationStatus,
            standardOutput: outData.data,
            standardError: String(decoding: errData.data, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

/// One reader's output: written by its reader before the group is left,
/// read after the wait (`finished` also for a wait that timed out).
final class PipeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()
    private var storedFinished = false

    var data: Data {
        get { lock.withLock { storedData } }
        set { lock.withLock { storedData = newValue } }
    }

    var finished: Bool {
        get { lock.withLock { storedFinished } }
        set { lock.withLock { storedFinished = newValue } }
    }
}

/// How ssh failed, as Add Mac… explains it.
enum RemoteDeviceSSHFailure: Equatable, Sendable {
    /// The host's key is unknown or changed: "Open in Terminal" runs
    /// `ssh <host>` in a local tab to check and accept it.
    case hostKey(String)
    /// The login was refused (keys or agent not set up).
    case permissionDenied(String)
    /// The name does not resolve.
    case unknownHost(String)
    /// No answer (offline, asleep, firewall, Remote Login off).
    case unreachable(String)
    case other(String)

    /// From ssh's standard error (and exit status 255).
    static func classify(_ standardError: String, timedOut: Bool = false) -> RemoteDeviceSSHFailure {
        let text = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = text.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
        if timedOut { return .unreachable("ssh did not finish within the time allowed.") }
        let lowered = text.lowercased()
        if lowered.contains("host key verification failed") || lowered.contains("remote host identification has changed")
            || lowered.contains("no ecdsa host key is known") || lowered.contains("no ed25519 host key is known")
            || lowered.contains("host key is known") || lowered.contains("host key for") {
            return .hostKey(last)
        }
        if lowered.contains("permission denied") || lowered.contains("too many authentication failures")
            || lowered.contains("no more authentication methods") {
            return .permissionDenied(last)
        }
        if lowered.contains("could not resolve hostname") || lowered.contains("nodename nor servname") {
            return .unknownHost(last)
        }
        if lowered.contains("timed out") || lowered.contains("connection refused") || lowered.contains("no route to host")
            || lowered.contains("network is unreachable") || lowered.contains("host is down")
            || lowered.contains("connection closed") || lowered.contains("connection reset") {
            return .unreachable(last)
        }
        return .other(last.isEmpty ? "ssh failed." : last)
    }

    var message: String {
        switch self {
        case .hostKey(let detail): "SSH does not trust this Mac's host key yet (\(detail))."
        case .permissionDenied(let detail): "SSH could not log in (\(detail))."
        case .unknownHost(let detail): "SSH could not find this host (\(detail))."
        case .unreachable(let detail): "The Mac did not answer (\(detail))."
        case .other(let detail): detail
        }
    }

    /// What to do about it.
    var help: String {
        switch self {
        case .hostKey:
            "Open a terminal to it once, check the fingerprint and accept the key; then check again."
        case .permissionDenied:
            "Set up key-based login: add your public key to ~/.ssh/authorized_keys on the other Mac (ssh-copy-id), and make sure your SSH agent has the key (ssh-add -l). Cherry never types passwords."
        case .unknownHost:
            "Use an alias from ~/.ssh/config, or user@hostname (a .local name works on the same network)."
        case .unreachable:
            "Make sure the Mac is awake and on the network, and that Remote Login is on in System Settings › General › Sharing."
        case .other:
            "Try `ssh <host>` in a terminal to see what it needs."
        }
    }
}

/// `cherry-host version --json`.
struct RemoteHostVersionReport: Codable, Equatable, Sendable {
    var `protocol`: UInt32
    var build: String?
    var version: String?
    var os: String?
    var arch: String?
    var min_macos: String?
}

/// `cherry-host status --json`.
struct RemoteHostStatusReport: Codable, Equatable, Sendable {
    var running: Bool
    var state: String
    var `protocol`: UInt32?
    var build: String?
    var host_id: String?
    var error: String?
}

/// What the check found on the other Mac.
struct RemoteDeviceProbeResult: Equatable, Sendable {
    var sshFailure: RemoteDeviceSSHFailure?
    /// `uname -sm`, e.g. "Darwin arm64".
    var uname: String?
    /// `sw_vers -productVersion`; nil on anything but macOS.
    var macOSVersion: String?
    var computerName: String?
    var hostName: String?
    var localHostName: String?
    var homeDirectory: String?
    /// `getconf DARWIN_USER_TEMP_DIR` there (phase 4b).
    var userTemporaryDirectory: String?
    var shell: String?
    /// The cherry-host it ran (the given path, or the one it found).
    var hostPath: String?
    var hostVersion: RemoteHostVersionReport?
    var hostStatus: RemoteHostStatusReport?
    /// Whether a folder only Full Disk Access opens could be read.
    var fullDiskAccess: Bool?
    /// Whether the login keychain could be read in an SSH session.
    var keychainUnlocked: Bool?
    /// Build directories of ours (~/Library/Application Support/
    /// cherry-host/bin/<build>), with their files' hashes.
    var installedBuilds: [RemoteInstalledBuild] = []
    /// Cherry.app copies there (/Applications, ~/Applications).
    var cherryApps: [RemoteCherryApp] = []

    var architecture: String? {
        uname?.split(separator: " ").last.map(String.init)
    }

    var isMac: Bool {
        uname?.hasPrefix("Darwin") == true
    }

    /// The names its programs may give it in OSC 7 reports.
    var machineNames: [String] {
        var names: [String] = []
        for name in [hostName, localHostName, localHostName.map { "\($0).local" }] {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }
}

/// Runs the check.
enum RemoteDeviceProbe {
    static let beginMarker = "CHERRY-PROBE 1"
    static let endMarker = "CHERRY-PROBE-END"

    /// The POSIX script run on the other Mac. `remoteHostPath`: the
    /// cherry-host to check (else PATH, then the known install places).
    /// `marker`: a build directory of ours this installation uses, marked
    /// as used now (`.used-by/<installation id>`).
    static func script(remoteHostPath: String?, marker: (directoryName: String, installationID: UUID)? = nil) -> String {
        var lines = [
            "printf '%s\\n' '\(beginMarker)'",
            "printf 'uname=%s\\n' \"$(uname -sm 2>/dev/null)\"",
            "printf 'macos=%s\\n' \"$(sw_vers -productVersion 2>/dev/null)\"",
            "printf 'computer=%s\\n' \"$(scutil --get ComputerName 2>/dev/null)\"",
            "printf 'localhost=%s\\n' \"$(scutil --get LocalHostName 2>/dev/null)\"",
            "printf 'hostname=%s\\n' \"$(hostname 2>/dev/null)\"",
            "printf 'home=%s\\n' \"$HOME\"",
            "printf 'shell=%s\\n' \"$SHELL\"",
            "printf 'usertmp=%s\\n' \"$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)\"",
        ]
        // This Cherry's installs (phase 2): each build's directory with its
        // files' hashes, and any Cherry.app with what its cherry-host is.
        lines += RemoteHostResources.hashFunction
        lines += [
            "root=\"$HOME\"/" + singleQuoted(RemoteHostInstall.rootRelativePath),
            "newest=",
            // Every build directory, incomplete ones too (a missing file
            // is `-`), so the install repairs them.
            "for d in \"$root\"/*; do",
            "  [ -d \"$d\" ] || continue",
            "  case \"$d\" in *.partial-*|*.broken-*) continue ;; esac",
            "  hashes=",
            "  for f in cherry cherry-host; do",
            "    h=",
            "    [ -f \"$d/$f\" ] && h=$(\(RemoteHostInstaller.Tool.shasum) -a 256 \"$d/$f\" 2>/dev/null | \(RemoteHostInstaller.Tool.awk) '{ print $1 }')",
            "    hashes=\"$hashes ${h:--}\"",
            "  done",
            "  printf 'installed=%s%s\\n' \"${d##*/}\" \"$hashes\"",
            // Ghostty's terminfo and shell integration there (phase 3).
            "  printf 'resources=%s %s\\n' \"${d##*/}\" \"$(resources_hash \"$d\")\"",
            "  [ -x \"$d/cherry-host\" ] || continue",
            "  [ -n \"$newest\" ] && [ \"$newest\" -nt \"$d\" ] || newest=$d",
            "done",
            "for app in /Applications/Cherry.app \"$HOME/Applications/Cherry.app\"; do",
            "  if [ -x \"$app/Contents/MacOS/cherry-host\" ]; then",
            "    printf 'app=%s\\t%s\\n' \"$app\" \"$(\"$app/Contents/MacOS/cherry-host\" version --json 2>/dev/null | tr -d '\\n')\"",
            "  fi",
            "done",
        ]
        if let marker {
            lines.append("used=\"$root\"/" + singleQuoted(marker.directoryName))
            lines += RemoteHostInstaller.markerLines(directoryVariable: "used", installationID: marker.installationID)
        }
        if let remoteHostPath = remoteHostPath?.nilIfEmpty {
            lines.append("host=\(shellWord(remoteHostPath))")
        } else {
            lines += [
                "host=$(command -v cherry-host 2>/dev/null)",
                "for candidate in \"$HOME/Library/Application Support/Cherry/bin/cherry-host\" \"${newest:+$newest/cherry-host}\" /Applications/Cherry.app/Contents/MacOS/cherry-host \"$HOME/Applications/Cherry.app/Contents/MacOS/cherry-host\"; do",
                "  [ -n \"$host\" ] && break",
                "  [ -n \"$candidate\" ] && [ -x \"$candidate\" ] && host=$candidate",
                "done",
            ]
        }
        lines += [
            "printf 'hostpath=%s\\n' \"$host\"",
            "if [ -n \"$host\" ] && [ -x \"$host\" ]; then",
            "  printf 'version=%s\\n' \"$(\"$host\" version --json 2>/dev/null | tr -d '\\n')\"",
            "  printf 'status=%s\\n' \"$(\"$host\" status --json 2>/dev/null | tr -d '\\n')\"",
            "fi",
            "if /bin/ls \"$HOME/Library/Safari\" >/dev/null 2>&1; then echo fda=yes; else echo fda=no; fi",
            "if security show-keychain-info >/dev/null 2>&1; then echo keychain=unlocked; else echo keychain=locked; fi",
            "printf '%s\\n' '\(endMarker)'",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `~/…` as `"$HOME"/'…'`, anything else single-quoted, for sh.
    static func shellWord(_ path: String) -> String {
        if let rest = path.nilIfEmpty.flatMap({ $0.hasPrefix("~/") ? String($0.dropFirst(2)) : nil }) {
            return "\"$HOME\"/" + singleQuoted(rest)
        }
        if path == "~" { return "\"$HOME\"" }
        return singleQuoted(path)
    }

    nonisolated static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Parses what the script printed (and how ssh ended).
    static func parse(_ output: RemoteDeviceShell.Output) -> RemoteDeviceProbeResult {
        var result = RemoteDeviceProbeResult()
        let lines = output.standardOutput.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker) else {
            result.sshFailure = output.status == 255 || output.timedOut
                ? RemoteDeviceSSHFailure.classify(output.standardError, timedOut: output.timedOut)
                : .other(output.standardError.nilIfEmpty?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "The other Mac's shell did not run the check (exit \(output.status)).")
            return result
        }
        let decoder = JSONDecoder()
        for line in lines[lines.index(after: begin)...] {
            if line == endMarker { break }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "uname": result.uname = value.nilIfEmpty
            case "macos": result.macOSVersion = value.nilIfEmpty
            case "computer": result.computerName = value.nilIfEmpty
            case "localhost": result.localHostName = value.nilIfEmpty
            case "hostname": result.hostName = value.nilIfEmpty
            case "home": result.homeDirectory = value.nilIfEmpty
            case "usertmp": result.userTemporaryDirectory = RemoteMCPPaths.validTemporaryDirectory(value, source: "the check")
            case "shell": result.shell = value.nilIfEmpty
            case "hostpath": result.hostPath = value.nilIfEmpty
            case "version": result.hostVersion = try? decoder.decode(RemoteHostVersionReport.self, from: Data(value.utf8))
            case "status": result.hostStatus = try? decoder.decode(RemoteHostStatusReport.self, from: Data(value.utf8))
            case "installed":
                let parts = value.split(separator: " ").map(String.init)
                if let name = parts.first {
                    result.installedBuilds.append(RemoteInstalledBuild(name: name, hashes: Array(parts.dropFirst())))
                }
            case "resources":
                let parts = value.split(separator: " ").map(String.init)
                if parts.count == 2, let index = result.installedBuilds.lastIndex(where: { $0.name == parts[0] }) {
                    result.installedBuilds[index].resourcesHash = parts[1]
                }
            case "app":
                let parts = value.split(separator: "\t", maxSplits: 1).map(String.init)
                if let path = parts.first {
                    let version = parts.count > 1
                        ? try? decoder.decode(RemoteHostVersionReport.self, from: Data(parts[1].utf8)) : nil
                    result.cherryApps.append(RemoteCherryApp(path: path, version: version))
                }
            case "fda": result.fullDiskAccess = value == "yes"
            case "keychain": result.keychainUnlocked = value == "unlocked"
            default: break
            }
        }
        return result
    }

    static func run(
        destination: String,
        remoteHostPath: String?,
        marker: (directoryName: String, installationID: UUID)? = nil,
        shell: RemoteDeviceShell
    ) async -> RemoteDeviceProbeResult {
        parse(await shell.run(script(remoteHostPath: remoteHostPath, marker: marker), on: destination))
    }

    /// Checks a folder on the device for Add Project on <Mac>…: its
    /// physical path (`pwd -P`), or why not.
    static func resolveDirectory(_ path: String, on destination: String, shell: RemoteDeviceShell) async -> Result<String, RemoteDirectoryError> {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") else {
            return .failure(.message("Enter an absolute path (or one starting with ~/)."))
        }
        let script = """
        printf '%s\\n' '\(beginMarker)'
        dir=\(shellWord(trimmed))
        if [ -d "$dir" ] && cd "$dir" 2>/dev/null; then printf 'dir=%s\\n' "$(pwd -P)"; else echo missing=1; fi
        printf '%s\\n' '\(endMarker)'

        """
        let output = await shell.run(script, on: destination)
        let lines = output.standardOutput.components(separatedBy: "\n")
        guard lines.contains(beginMarker) else {
            return .failure(.ssh(RemoteDeviceSSHFailure.classify(output.standardError, timedOut: output.timedOut)))
        }
        if let line = lines.first(where: { $0.hasPrefix("dir=") }), line.count > 4, line.dropFirst(4).hasPrefix("/") {
            return .success(String(line.dropFirst(4)))
        }
        return .failure(.message("There is no folder at \(trimmed) on that Mac."))
    }

    enum RemoteDirectoryError: Error, Equatable {
        case ssh(RemoteDeviceSSHFailure)
        case message(String)

        var message: String {
            switch self {
            case .ssh(let failure): failure.message
            case .message(let message): message
            }
        }
    }
}

/// Add Mac…'s checklist: each line, and whether the Mac can be added.
struct RemoteDeviceChecklist: Equatable {
    enum Status: Equatable {
        case ok, warning, failure
    }

    enum Action: Equatable {
        /// Run `ssh <host>` in a local terminal tab (a host key to accept).
        case openInTerminal
    }

    struct Item: Equatable, Identifiable {
        let id: String
        let status: Status
        let title: String
        var detail: String?
        var action: Action?
    }

    let items: [Item]
    /// Whether Add is offered: SSH works, it is a Mac, and, when this
    /// Cherry can install its session host there (`installation`), the
    /// install is not refused, or the cherry-host already there can be used.
    let canAdd: Bool
    /// The name field's default (its ComputerName).
    let suggestedName: String?
    /// Whether the device's cherry-host speaks this Cherry's protocol.
    let hostIsCompatible: Bool

    /// How to put a session host there by hand, when this Cherry cannot
    /// install one (it has no helpers of its own).
    static func manualInstallInstructions(destination: String) -> String {
        """
        Install the same version of Cherry on that Mac, or copy this Cherry's helpers there by hand:
          ssh \(destination) 'mkdir -p "$HOME/Library/Application Support/Cherry/bin"'
          scp /Applications/Cherry.app/Contents/MacOS/cherry /Applications/Cherry.app/Contents/MacOS/cherry-host \(destination):'Library/Application Support/Cherry/bin/'
        then check again.
        """
    }

    /// `installation`: what installing this Cherry's session host there
    /// would do (`RemoteHostInstall.decide`); nil when no install is
    /// offered (a cherry-host path was given), as in phase 1.
    init(
        result: RemoteDeviceProbeResult,
        destination: String,
        localProtocol: UInt32 = HostProtocol.version,
        installation: RemoteHostInstallDecision? = nil
    ) {
        var items: [Item] = []
        if let failure = result.sshFailure {
            items.append(Item(
                id: "ssh", status: .failure, title: "SSH", detail: failure.message + " " + failure.help,
                action: { if case .hostKey = failure { return .openInTerminal } else { return nil } }()
            ))
            self.items = items
            canAdd = false
            suggestedName = nil
            hostIsCompatible = false
            return
        }
        items.append(Item(id: "ssh", status: .ok, title: "SSH", detail: "Logged in to \(destination) without a password."))
        if result.isMac {
            let version = result.macOSVersion.map { "macOS \($0)" } ?? "macOS"
            let parts = [result.computerName, version, result.architecture].compactMap { $0 }
            items.append(Item(id: "system", status: .ok, title: "Mac", detail: parts.joined(separator: " · ")))
        } else {
            items.append(Item(
                id: "system", status: .failure, title: "Mac",
                detail: "\(result.uname ?? "This machine") is not a Mac. Other systems are not supported in the picker yet; use Persistent Sessions for its sessions."
            ))
        }
        // What is there now.
        var compatible = false
        let installs = installation?.plan != nil
        if let version = result.hostVersion {
            let path = result.hostPath.map { " (\($0))" } ?? ""
            if version.protocol == localProtocol {
                compatible = true
                let running = result.hostStatus.map { status in
                    status.running ? "; its session host runs" : "; its session host starts with the first tab"
                } ?? ""
                items.append(Item(
                    id: "host", status: .ok, title: "Session host",
                    detail: "cherry-host \(version.version ?? version.build ?? "") speaks protocol \(version.protocol), as this Cherry does\(path)\(running)."
                ))
            } else if installs {
                // The installer puts this Cherry's own next to it.
                items.append(Item(
                    id: "host", status: .ok, title: "Session host",
                    detail: "The cherry-host there\(path) speaks protocol \(version.protocol); this Cherry speaks \(localProtocol) and uses its own."
                ))
            } else {
                items.append(Item(
                    id: "host", status: .failure, title: "Session host",
                    detail: "cherry-host there speaks protocol \(version.protocol), this Cherry speaks \(localProtocol)\(path). Update Cherry on the Mac with the older one. "
                        + Self.manualInstallInstructions(destination: destination)
                ))
            }
            if installation == nil, let status = result.hostStatus, status.running, let running = status.protocol, running != localProtocol {
                compatible = false
                items.append(Item(
                    id: "daemon", status: .failure, title: "Running host",
                    detail: "Its running session host speaks protocol \(running) (another Cherry there runs it). Update Cherry on that Mac or here so both speak the same protocol."
                ))
            }
        } else {
            let found = "No cherry-host was found\(result.hostPath.map { " at \($0)" } ?? " on its PATH")."
            items.append(Item(
                id: "host", status: installs ? .ok : .warning, title: "Session host",
                detail: installs ? found : found + " " + Self.manualInstallInstructions(destination: destination)
            ))
        }
        if let status = result.hostStatus, status.running, let running = status.protocol, running != localProtocol {
            compatible = false
        }
        // What Install & Add does, or why it cannot.
        var blocked = false
        switch installation {
        case .install(let plan)?:
            let what = plan.copyNeeded
                ? "\(plan.addTitle.replacingOccurrences(of: " & Add", with: "")) copies this Cherry's cherry and cherry-host to ~/\(RemoteHostInstall.rootRelativePath)/\(plan.directoryName) there"
                : "This Cherry's cherry and cherry-host are already there (~/\(RemoteHostInstall.rootRelativePath)/\(plan.directoryName))"
            let daemon: String
            switch plan.daemon {
            case .absent: daemon = "; the first tab starts its session host."
            case .sameProtocol: daemon = "; it relays to the session host that runs there, whose sessions carry on."
            case .olderProtocol: daemon = "; the first connection replaces the older session host there, whose sessions carry on."
            case .unknown: daemon = "."
            }
            items.append(Item(
                id: "install", status: plan.warnings.isEmpty ? .ok : .warning,
                title: plan.copyNeeded ? (plan.isUpdate ? "Update" : "Install") : "Installed",
                detail: ([what + daemon] + plan.warnings).joined(separator: " ")
            ))
        case .blocked(let reason, let allowsPlainAdd)?:
            blocked = !allowsPlainAdd
            items.append(Item(
                id: "install", status: blocked ? .failure : .warning, title: "Session host",
                detail: allowsPlainAdd && compatible
                    ? reason + " The cherry-host already there is used instead."
                    : reason
            ))
        case nil:
            break
        }
        if result.fullDiskAccess == false {
            items.append(Item(
                id: "fda", status: .warning, title: "Full Disk Access",
                detail: "Programs started over SSH cannot open protected folders (Desktop, Documents, Downloads, Mail…). To allow it, turn on \"Allow full disk access for remote users\" in System Settings › General › Sharing › Remote Login on that Mac."
            ))
        }
        if result.keychainUnlocked == false {
            items.append(Item(
                id: "keychain", status: .warning, title: "Keychain",
                detail: "Its login keychain is locked in SSH sessions: tools that keep credentials there (git, gh, agents) may ask again or fail. Unlock it with `security unlock-keychain` in a tab if needed."
            ))
        }
        self.items = items
        canAdd = result.isMac && !blocked
        suggestedName = result.computerName ?? result.localHostName ?? result.hostName
        hostIsCompatible = compatible
    }
}
