import CherryControl
import Foundation

// A device's project as a project window needs it (docs/specs/remote-devices.md,
// phase 3): what `cherry-host project-info` reports (the folder and its
// cherry.toml) in one round trip, through that Mac's SSH master.

/// `cherry-host project-info --json PATH…`.
struct RemoteProjectInfoReport: Decodable, Equatable, Sendable {
    static let supportedVersion = 1

    var version: Int
    var projects: [RemoteProjectInfo]

    /// The answer for `path`.
    func project(at path: String) -> RemoteProjectInfo? {
        projects.first { $0.path == path }
    }
}

struct RemoteProjectInfo: Decodable, Equatable, Sendable {
    struct CherryToml: Decodable, Equatable, Sendable {
        var size: UInt64
        var text: String?
        var error: String?
    }

    var path: String
    var exists: Bool
    var isDirectory: Bool
    var cherryToml: CherryToml?

    enum CodingKeys: String, CodingKey {
        case path, exists
        case isDirectory = "is_directory"
        case cherryToml = "cherry_toml"
    }

    init(path: String, exists: Bool, isDirectory: Bool, cherryToml: CherryToml? = nil) {
        self.path = path
        self.exists = exists
        self.isDirectory = isDirectory
        self.cherryToml = cherryToml
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        exists = try container.decode(Bool.self, forKey: .exists)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        cherryToml = try container.decodeIfPresent(CherryToml.self, forKey: .cherryToml)
    }

    /// Its cherry.toml text when it has one Cherry can use: at most
    /// `RemoteProjectAccess.cherryTomlLimit` bytes (the host sends no more,
    /// and a larger text is refused here too).
    var cherryTomlText: String? {
        guard let text = cherryToml?.text, UInt64(text.utf8.count) <= RemoteProjectAccess.cherryTomlLimit else { return nil }
        return text
    }

    /// Why its cherry.toml cannot be used, when it has one.
    var cherryTomlProblem: String? {
        guard let toml = cherryToml else { return nil }
        if let error = toml.error?.nilIfEmpty { return error }
        if cherryTomlText == nil { return "cherry.toml is larger than \(RemoteProjectAccess.cherryTomlLimit / 1024) KiB" }
        return nil
    }
}

enum RemoteProjectError: LocalizedError, Equatable {
    /// ssh could not reach the device.
    case unreachable(String)
    /// The device's cherry-host has no `project-info` (installed by an
    /// older Cherry): Update Session Host… installs one that has.
    case unsupported(String)
    /// It answered something this Cherry cannot read.
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let message), .invalid(let message): message
        case .unsupported(let machine):
            "The session host on \(machine) is too old to describe projects; update it (Update Session Host…) to see its cherry.toml here."
        }
    }
}

/// How a device's project window reaches that Mac for `project-info`: the
/// device's ssh (its SSH master while that is up, else
/// its own BatchMode ssh), with scripts on standard input to `sh -s`, so
/// any login shell runs them.
struct RemoteProjectAccess: Sendable {
    /// The most bytes of cherry.toml used (`project-info` sends no more).
    static let cherryTomlLimit: UInt64 = 256 * 1024
    /// The most bytes of a `project-info` answer read.
    static let reportLimit = 4 * 1024 * 1024

    let deviceID: UUID
    let deviceName: String
    let destination: String
    /// The device's cherry-host (`~/…` or absolute), else the one on its
    /// PATH.
    let remoteHostPath: String?
    /// The shell to reach it with, each time.
    let shell: @Sendable () async -> RemoteDeviceShell

    init(
        deviceID: UUID,
        deviceName: String,
        destination: String,
        remoteHostPath: String?,
        shell: @escaping @Sendable () async -> RemoteDeviceShell
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.destination = destination
        self.remoteHostPath = remoteHostPath
        self.shell = shell
    }

    /// The app's access to `device`: the login shell's ssh, through the
    /// device's SSH master while it is up.
    static func app(_ device: RemoteDevice, masters: HostSSHMasterManager = .shared) -> RemoteProjectAccess {
        let destination = device.sshDestination
        return RemoteProjectAccess(
            deviceID: device.id,
            deviceName: device.name,
            destination: destination,
            remoteHostPath: device.remoteHostPath,
            shell: {
                var shell = await RemoteDeviceShell.app()
                shell.controlPath = masters.controlPathIfUp(for: destination)
                shell.timeout = 120
                return shell
            }
        )
    }

    /// The key of the project at `path` on the device.
    func key(forPath path: String) -> String {
        ProjectLocation.remote(deviceID: deviceID, path: path).key
    }

    /// The path on the device a key (or a path) names.
    func path(forKey key: String) -> String {
        ProjectLocation.launchPath(forKey: key)
    }

    // MARK: project-info

    static let projectInfoBegin = "CHERRY-PROJECT-INFO 1"

    /// The script that runs `cherry-host project-info --json` there.
    /// `CHERRY_GIT` is unset, so project-info runs no git (Cherry reads no
    /// git state of a device's project).
    static func projectInfoScript(paths: [String], remoteHostPath: String?) -> String {
        var lines = ["unset CHERRY_GIT"]
        if let path = remoteHostPath?.nilIfEmpty {
            lines.append("host=\(RemoteDeviceProbe.shellWord(path))")
        } else {
            lines.append("host=cherry-host")
        }
        lines.append("printf '%s\\n' '\(projectInfoBegin)'")
        lines.append("exec \"$host\" project-info --json " + paths.map(RemoteDeviceProbe.singleQuoted).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parses what the script printed.
    static func parseProjectInfo(_ output: RemoteDeviceShell.DataOutput, machine: String) throws -> RemoteProjectInfoReport {
        let text = output.standardOutput.prefix(reportLimit + 64)
        guard let marker = text.range(of: Data((projectInfoBegin + "\n").utf8)) else {
            if output.status == 255 || output.timedOut {
                throw RemoteProjectError.unreachable(RemoteDeviceSSHFailure.classify(output.standardError, timedOut: output.timedOut).message)
            }
            throw RemoteProjectError.invalid("\(machine) did not run the project check (exit \(output.status)): \(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let body = text[marker.upperBound...]
        if output.status != 0 {
            let error = output.standardError.lowercased()
            if error.contains("unrecognized subcommand") || error.contains("unexpected argument") || error.contains("no such file") || error.contains("not found") {
                throw RemoteProjectError.unsupported(machine)
            }
            throw RemoteProjectError.invalid("cherry-host project-info on \(machine) failed (exit \(output.status)): \(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard body.count <= reportLimit else {
            throw RemoteProjectError.invalid("\(machine) described its project at more length than Cherry reads.")
        }
        let report: RemoteProjectInfoReport
        do {
            report = try JSONDecoder().decode(RemoteProjectInfoReport.self, from: Data(body))
        } catch {
            throw RemoteProjectError.invalid("\(machine) described its project in a way this Cherry cannot read.")
        }
        guard report.version == RemoteProjectInfoReport.supportedVersion else {
            throw RemoteProjectError.unsupported(machine)
        }
        return report
    }

    /// Asks the device about `paths` (its folders).
    func projectInfo(paths: [String]) async throws -> RemoteProjectInfoReport {
        let shell = await shell()
        let script = Self.projectInfoScript(paths: paths, remoteHostPath: remoteHostPath)
        let destination = destination
        let output = await Task.detached(priority: .userInitiated) {
            shell.runSynchronously(script, on: destination)
        }.value
        return try Self.parseProjectInfo(output, machine: deviceName)
    }
}

/// The cherry.toml of each device project a window read
/// (`RemoteProjectAccess.projectInfo`), by project key: `CherryProjectFile`
/// reads its commands, features and appearance from here, since the file is
/// on the other Mac. Read-only: Cherry never writes a device's cherry.toml.
@MainActor
final class RemoteProjectFiles: ObservableObject {
    static let shared = RemoteProjectFiles()

    struct Entry: Equatable {
        /// Its text; nil when the project has none (or it cannot be used).
        var text: String?
        /// Why it cannot be used (too large, not UTF-8).
        var problem: String?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    /// Bumped on each change: `CherryProjectFile`'s parse cache follows it.
    private(set) var generation = 0

    func entry(for key: String) -> Entry? {
        entries[ProjectLocation(key: key).key]
    }

    func text(for key: String) -> String? {
        entry(for: key)?.text
    }

    /// What `info` said of the project at `key`.
    func record(_ info: RemoteProjectInfo, for key: String) {
        set(Entry(text: info.cherryTomlText, problem: info.cherryTomlProblem), for: key)
    }

    func set(_ entry: Entry?, for key: String) {
        let key = ProjectLocation(key: key).key
        guard entries[key] != entry else { return }
        entries[key] = entry
        generation += 1
        CherryProjectFile.invalidate(projectRoot: key)
    }
}
