import CherryControl
import CryptoKit
import Darwin
import Foundation

// Installing this Cherry's `cherry` and `cherry-host` on another Mac
// (docs/specs/remote-devices.md, phase 2): Add Mac… (Install & Add, Update &
// Add) and a device's Update Session Host….
//
// Layout on the other Mac: ~/Library/Application Support/cherry-host/bin/
// <build>/{cherry,cherry-host}, one directory per build, never changed once
// in place (macOS kills a running signed executable whose pages change, and
// daemons and holders of older builds keep running from theirs). A copy goes
// over the device's ssh (its master when up) as a tar stream into
// `<build>.partial-<uuid>`, is checked there (`xattr -c`, `codesign --verify
// --strict`, `cherry-host version --json` and the SHA-256 of both files) and
// only then renamed into place. The current build and the two installed
// before it are kept; older directories go unless a running process (the
// daemon, a holder, a gateway) or the daemon's sessions use them.
//
// Which daemon runs there decides what happens (`RemoteHostInstallDecision`):
// none, or one of this protocol: install ours (it relays to that daemon);
// an older protocol (4 or later): install ours, and the gateway's Replace
// moves the daemon to it (its sessions carry on); a newer protocol, or one
// older than 4: refuse. A daemon of this protocol is never replaced by a
// build that is not newer, nor ever when it is the other Mac's own Cherry's:
// only a daemon started from one of our own install directories is handed
// over (`cherry restart`, run by the new build), and only during an install
// or update the user asked for, so two Cherrys never take turns.

// MARK: - Builds

/// Build order, as `cherry_protocol::build_is_newer`: only builds that
/// start with a 14-digit time (`20260927101500.abc1234`, what
/// Scripts/install-local-app stamps) are ordered; development builds are
/// neither newer nor older than anything.
enum HostBuildOrder {
    static func stamp(_ build: String) -> UInt64? {
        let first = build.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard first.count == 14, first.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt64(first)
    }

    /// Whether `build` was made after `other`.
    static func isNewer(_ build: String?, than other: String?) -> Bool {
        guard let build, let other, let lhs = stamp(build), let rhs = stamp(other) else { return false }
        return lhs > rhs
    }
}

// MARK: - Architectures

/// The architectures of a Mach-O file, as `lipo -archs` names them, read
/// from its header (no Xcode tools needed).
enum MachOArchitectures {
    static func read(_ url: URL) -> Set<String>? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Set<String>? {
        let bytes = [UInt8](data)
        func big32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func little32(_ offset: Int) -> UInt32? {
            big32(offset).map { $0.byteSwapped }
        }
        guard let magic = big32(0) else { return nil }
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let entrySize = magic == 0xCAFE_BABE ? 20 : 32
            guard let count = big32(4), count > 0, count < 64 else { return nil }
            var names = Set<String>()
            for index in 0..<Int(count) {
                let offset = 8 + index * entrySize
                guard let type = big32(offset), let subtype = big32(offset + 4) else { return nil }
                names.insert(name(cpuType: type, subtype: subtype))
            }
            return names
        case 0xCFFA_EDFE, 0xCEFA_EDFE:
            // A thin file, little-endian (every Mac architecture).
            guard let type = little32(4), let subtype = little32(8) else { return nil }
            return [name(cpuType: type, subtype: subtype)]
        default:
            return nil
        }
    }

    static func name(cpuType: UInt32, subtype: UInt32) -> String {
        let capability: UInt32 = 0xFF00_0000
        switch cpuType {
        case 0x0100_000C: return subtype & ~capability == 2 ? "arm64e" : "arm64"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        case 0x0000_000C: return "arm"
        default: return "cpu\(cpuType)"
        }
    }
}

// MARK: - This Cherry's helpers

/// The `cherry` and `cherry-host` this Cherry installs on other Macs: the
/// ones it runs itself (`HostedSessionClient.installed()`, in the app's
/// Contents/MacOS), what they report, their architectures and hashes.
struct RemoteHostHelpers: Equatable, Sendable {
    static let names = ["cherry", "cherry-host"]

    var directory: URL
    var version: RemoteHostVersionReport
    /// The architectures both executables carry (`lipo -archs` names).
    var architectures: Set<String>
    /// SHA-256 (hex) of `cherry`, then `cherry-host`.
    var hashes: [String]
    /// Ghostty's resources this Cherry bundles (the xterm-ghostty terminfo
    /// and shell integration), installed next to the helpers as `Ghostty/`
    /// and `terminfo/` (docs/specs/remote-devices.md, phase 3); nil when it
    /// has none (then nothing is installed with them).
    var resources: GhosttyResourceStaging.Source? = nil
    /// Their digest (`RemoteHostResources.digest`), as the other Mac's
    /// scripts compute it (`resources_hash`), CherryMCP included when there
    /// is one.
    var resourcesHash: String? = nil
    /// CherryMCP (docs/specs/remote-devices.md, phase 4b), installed with
    /// the resources as `<build>/CherryMCP` for agents in tabs there; nil
    /// when this Cherry has none next to its helpers or its own executable.
    var mcpHelper: URL? = nil

    var build: String { version.build ?? "unknown" }

    /// The install directory's name on the other Mac: the build.
    var directoryName: String { Self.directoryName(forBuild: build) }

    /// A build as a directory name: letters, digits, `.`, `_` and `-`
    /// only, never starting with a dot.
    static func directoryName(forBuild build: String) -> String {
        var name = String(build.map { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character)) ? character : "_"
        })
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "unknown" : String(name.prefix(96))
    }

    /// Reads the helpers in `directory` (runs `cherry-host version --json`),
    /// with the Ghostty resources (`resources`: the app's bundled ones by
    /// default) installed next to them.
    static func load(
        directory: URL,
        resources: GhosttyResourceStaging.Source? = GhosttyResourceStaging.bundledSource(),
        mcpHelper: URL?? = nil
    ) throws -> RemoteHostHelpers {
        let mcpHelper = mcpHelper ?? defaultMCPHelper(near: directory)
        let files = names.map { directory.appendingPathComponent($0) }
        for file in files where !FileManager.default.isExecutableFile(atPath: file.path) {
            throw HostedSessionError.message("This Cherry has no \(file.lastPathComponent) to install (looked in \(directory.path)).")
        }
        let output = try runHelper(files[1], arguments: ["version", "--json"])
        guard let version = try? JSONDecoder().decode(RemoteHostVersionReport.self, from: Data(output.utf8)) else {
            throw HostedSessionError.message("This Cherry's cherry-host did not say what it is (\(output.prefix(200))).")
        }
        var architectures: Set<String>?
        for file in files {
            guard let found = MachOArchitectures.read(file) else {
                throw HostedSessionError.message("\(file.path) is not a Mac executable.")
            }
            architectures = architectures.map { $0.intersection(found) } ?? found
        }
        let installable = resources.flatMap(RemoteHostResources.installable)
        return RemoteHostHelpers(
            directory: directory,
            version: version,
            architectures: architectures ?? [],
            hashes: try files.map(sha256),
            resources: installable,
            resourcesHash: installable.flatMap { try? RemoteHostResources.digest(of: $0, mcpHelper: mcpHelper) },
            mcpHelper: installable == nil ? nil : mcpHelper
        )
    }

    /// The CherryMCP installed with the helpers: next to them (the app's
    /// Contents/MacOS), else next to the running executable (a SwiftPM
    /// build's products).
    static func defaultMCPHelper(near directory: URL) -> URL? {
        let candidates = [directory, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        return candidates.map { $0.appendingPathComponent(RemoteMCPPaths.helperName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runHelper(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HostedSessionError.message("\(executable.path) \(arguments.joined(separator: " ")) exited \(process.terminationStatus).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether a Mac of `architecture` (`uname -m`) can run them.
    func runs(on architecture: String?) -> Bool {
        guard let architecture else { return false }
        if architectures.contains(architecture) { return true }
        // An arm64e Mac runs arm64 code.
        return architecture == "arm64e" && architectures.contains("arm64")
    }

    var architectureList: String {
        architectures.sorted().joined(separator: " and ")
    }

    // MARK: The app's

    private static let cache = AppHelpersCache()

    /// This app's helpers, read once (again when the files change: an
    /// update of the app on disk), off the main actor.
    static func app() async -> Result<RemoteHostHelpers, HostedSessionError> {
        await Task.detached(priority: .userInitiated) { cache.load() }.value
    }

    /// The app's helpers' build once read (nil before), for the device
    /// menu's Update Session Host….
    static var cachedAppBuild: String? { cache.cachedBuild }

    /// Reads the app's helpers in the background, for `cachedAppBuild`.
    static func preloadApp() {
        guard cache.cachedBuild == nil else { return }
        Task.detached(priority: .utility) { _ = cache.load() }
    }
}

private final class AppHelpersCache: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: (stamp: [String], result: Result<RemoteHostHelpers, HostedSessionError>)?

    var cachedBuild: String? {
        lock.withLock {
            if case .success(let helpers)? = loaded?.result { return helpers.build }
            return nil
        }
    }

    func load() -> Result<RemoteHostHelpers, HostedSessionError> {
        let directory: URL
        do {
            directory = try HostedSessionClient.installed().executableURL.deletingLastPathComponent()
        } catch {
            return .failure(.message(error.localizedDescription))
        }
        let stamp = RemoteHostHelpers.names.map { name -> String in
            let path = directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            return "\(path)|\(modified)|\(size)"
        }
        if let loaded = lock.withLock({ loaded }), loaded.stamp == stamp { return loaded.result }
        let result: Result<RemoteHostHelpers, HostedSessionError>
        do {
            result = .success(try RemoteHostHelpers.load(directory: directory))
        } catch let error as HostedSessionError {
            result = .failure(error)
        } catch {
            result = .failure(.message(error.localizedDescription))
        }
        lock.withLock { loaded = (stamp, result) }
        return result
    }
}

// MARK: - Ghostty's resources

/// Ghostty's terminfo (`xterm-ghostty`) and shell integration, installed
/// next to cherry-host on another Mac (`<build>/Ghostty`, `<build>/terminfo`)
/// so its tabs get Cherry's terminal type and OSC 7, titles and prompt marks
/// (docs/specs/remote-devices.md, phase 3). Like the helpers, one copy per
/// build, never changed once in place, checked by digest.
enum RemoteHostResources {
    /// The names the two trees have there (and in the archive).
    static let treeNames = [GhosttyResourceStaging.resourcesName, GhosttyResourceStaging.terminfoName]

    /// `source` when both of its directories are there and named as they
    /// are installed (`Ghostty`, `terminfo`).
    static func installable(_ source: GhosttyResourceStaging.Source) -> GhosttyResourceStaging.Source? {
        let resources = source.resourcesDirectory.resolvingSymlinksInPath()
        let terminfo = source.terminfoDirectory.resolvingSymlinksInPath()
        guard resources.lastPathComponent == treeNames[0], terminfo.lastPathComponent == treeNames[1] else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("shell-integration").path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(atPath: terminfo.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return GhosttyResourceStaging.Source(resourcesDirectory: resources, terminfoDirectory: terminfo)
    }

    /// The digest the other Mac's `resources_hash` computes: the SHA-256 of
    /// `shasum -a 256` lines ("<hex>  <path>") of every regular file under
    /// `Ghostty/` and `terminfo/`, by path in byte order.
    static func digest(of source: GhosttyResourceStaging.Source, mcpHelper: URL? = nil) throws -> String {
        var files: [(path: String, url: URL)] = []
        for (name, root) in zip(treeNames, [source.resourcesDirectory, source.terminfoDirectory]) {
            try collectFiles(in: root, relativePath: name, into: &files)
        }
        if let mcpHelper { files.append((RemoteMCPPaths.helperName, mcpHelper)) }
        files.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var listing = ""
        for file in files {
            listing += "\(try RemoteHostHelpers.sha256(file.url))  \(file.path)\n"
        }
        return SHA256.hash(data: Data(listing.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func collectFiles(in directory: URL, relativePath: String, into files: inout [(path: String, url: URL)]) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            var status = stat()
            guard lstat(url.path, &status) == 0 else { continue }
            switch status.st_mode & S_IFMT {
            case S_IFDIR: try collectFiles(in: url, relativePath: "\(relativePath)/\(name)", into: &files)
            case S_IFREG: files.append(("\(relativePath)/\(name)", url))
            default: break
            }
        }
    }

    /// `resources_hash D`: the digest of D's trees and its CherryMCP (when
    /// it has one), or `-` when either tree is missing.
    static let hashFunction: [String] = [
        "resources_hash() {",
        "  if [ -d \"$1/Ghostty/shell-integration\" ] && [ -d \"$1/terminfo\" ]; then",
        "    (cd \"$1\" && { /usr/bin/find Ghostty terminfo -type f -print 2>/dev/null; if [ -f CherryMCP ]; then echo CherryMCP; fi; } | LC_ALL=C /usr/bin/sort | while IFS= read -r f; do \(RemoteHostInstaller.Tool.shasum) -a 256 \"$f\"; done) | \(RemoteHostInstaller.Tool.shasum) -a 256 | \(RemoteHostInstaller.Tool.awk) '{ print $1 }'",
        "  else",
        "    echo -",
        "  fi",
        "}",
    ]
}

// MARK: - What the other Mac has

/// A build directory of ours on the other Mac, as the check found it.
struct RemoteInstalledBuild: Equatable, Sendable {
    var name: String
    /// SHA-256 of its `cherry` and `cherry-host`, in that order.
    var hashes: [String]
    /// The digest of its Ghostty resources (`RemoteHostResources`), `-`
    /// when it has none; nil when the check did not say (an older Cherry's).
    var resourcesHash: String? = nil

    /// It has `helpers` (and their resources, when they have any).
    func matches(_ helpers: RemoteHostHelpers) -> Bool {
        hashes == helpers.hashes && (helpers.resourcesHash == nil || resourcesHash == helpers.resourcesHash)
    }
}

/// A Cherry.app on the other Mac (/Applications, ~/Applications).
struct RemoteCherryApp: Equatable, Sendable {
    var path: String
    var version: RemoteHostVersionReport?
}

/// `cherry status --json` as the new build reports it on the other Mac.
struct RemoteCLIStatusReport: Decodable, Equatable, Sendable {
    struct Host: Decodable, Equatable, Sendable {
        var version: UInt32?
        var build: String?
        var pid: UInt32?
        var executable: String?
    }

    struct Session: Decodable, Equatable, Sendable {
        var id: String?
        var state: String?
        var holder_build: String?
    }

    var running: Bool
    var build: String?
    var host: Host?
    var sessions: [Session]?
}

// MARK: - The decision

/// What installing on a device would do, before anything is copied.
enum RemoteHostInstallDecision: Equatable, Sendable {
    case install(RemoteHostInstallPlan)
    /// Nothing is installed. `allowsPlainAdd`: the Mac can still be added
    /// without an install (with the cherry-host it already has, if any),
    /// because what is in the way is only this Cherry's own helpers (none,
    /// another protocol, another architecture, a newer macOS), not the Mac.
    case blocked(reason: String, allowsPlainAdd: Bool)

    var plan: RemoteHostInstallPlan? {
        if case .install(let plan) = self { return plan }
        return nil
    }
}

struct RemoteHostInstallPlan: Equatable, Sendable {
    /// The daemon on the device's default socket.
    enum Daemon: Equatable, Sendable {
        /// None runs: the first tab's gateway starts ours.
        case absent
        /// This protocol: ours relays to it. `newerBuild`: its build is
        /// newer than ours, and it keeps running.
        case sameProtocol(build: String?, newerBuild: Bool)
        /// An older protocol (4 or later): the gateway's Replace moves it to
        /// ours, and its sessions carry on.
        case olderProtocol(UInt32)
        /// It did not answer, or its socket could not be checked.
        case unknown(String)
    }

    var daemon: Daemon
    /// The Mac's architecture (`uname -m`), as the check saw it.
    var architecture: String? = nil
    /// Where ours goes: `<root>/<directoryName>`.
    var directoryName: String
    /// False when that directory is there with the same files.
    var copyNeeded: Bool
    /// Something of an older Cherry is there (an install of ours of another
    /// build, an older daemon or cherry-host): "Update".
    var isUpdate: Bool
    var warnings: [String]

    /// Add Mac…'s button.
    var addTitle: String {
        guard copyNeeded else { return "Add" }
        return isUpdate ? "Update & Add" : "Install & Add"
    }

    /// Update Session Host…'s button.
    var updateTitle: String {
        guard copyNeeded else { return "Use It" }
        return isUpdate ? "Update" : "Install"
    }
}

enum RemoteHostInstall {
    /// Under the remote home.
    static let rootRelativePath = "Library/Application Support/cherry-host/bin"
    /// Where Cherry's manual instructions put cherry-host before phase 2.
    static let legacyRelativePath = "Library/Application Support/Cherry/bin"
    /// The oldest protocol whose daemon can make way (`Replace`).
    static let oldestReplaceableProtocol: UInt32 = 4
    /// Build directories kept besides those in use: the current one and
    /// the two before it.
    static let keptBuilds = 3

    /// The device's `remoteHostPath` for a build directory.
    static func remoteHostPath(directoryName: String) -> String {
        "~/\(rootRelativePath)/\(directoryName)/cherry-host"
    }

    /// The build directory a `remoteHostPath` of ours names, if it is one.
    static func directoryName(ofRemoteHostPath path: String?) -> String? {
        guard let path else { return nil }
        let prefix = "~/\(rootRelativePath)/"
        guard path.hasPrefix(prefix), path.hasSuffix("/cherry-host") else { return nil }
        let name = path.dropFirst(prefix.count).dropLast("/cherry-host".count)
        return name.isEmpty || name.contains("/") ? nil : String(name)
    }

    static func shutdownInstructions(protocol version: UInt32) -> String {
        "It speaks protocol \(version), which cannot make way for a newer session host: finish its sessions and stop it there (`cherry shutdown` from the Cherry of that version, or `pkill -u \"$USER\" -f 'cherry-host serve'`, which ends its sessions), then check again."
    }

    /// Decides from the check (`RemoteDeviceProbe`) and this Cherry's
    /// helpers (or why there are none) what installing would do.
    static func decide(
        probe: RemoteDeviceProbeResult,
        helpers: Result<RemoteHostHelpers, HostedSessionError>,
        machine: String,
        localProtocol: UInt32 = HostProtocol.version
    ) -> RemoteHostInstallDecision {
        if let failure = probe.sshFailure {
            return .blocked(reason: failure.message, allowsPlainAdd: false)
        }
        guard probe.isMac else {
            return .blocked(reason: "\(probe.uname ?? "This machine") is not a Mac.", allowsPlainAdd: false)
        }
        let olderApps = probe.cherryApps.filter { ($0.version?.protocol ?? localProtocol) < localProtocol }
        let newerApps = probe.cherryApps.filter { ($0.version?.protocol ?? 0) > localProtocol }
        var warnings: [String] = []

        // The daemon on the default socket.
        let daemon: RemoteHostInstallPlan.Daemon
        let status = probe.hostStatus
        if let status, status.running, let running = status.protocol {
            if running > localProtocol {
                return .blocked(
                    reason: "\(machine)'s session host speaks protocol \(running), newer than this Cherry (protocol \(localProtocol)). Update Cherry on this Mac, then check again.",
                    allowsPlainAdd: false
                )
            }
            if running < oldestReplaceableProtocol {
                return .blocked(
                    reason: "\(machine) runs a session host too old to update. " + shutdownInstructions(protocol: running),
                    allowsPlainAdd: false
                )
            }
            if running < localProtocol {
                daemon = .olderProtocol(running)
                warnings.append(olderApps.isEmpty
                    ? "\(machine)'s session host speaks an older protocol (\(running)): connecting replaces it with this one, and its sessions carry on."
                    : "Cherry on \(machine) is older; connecting updates its session host; its sessions carry on; update Cherry there too.")
            } else {
                let newer = HostBuildOrder.isNewer(status.build, than: helpersBuild(helpers))
                daemon = .sameProtocol(build: status.build, newerBuild: newer)
                if newer {
                    warnings.append("\(machine)'s session host is a newer build (\(status.build ?? "")); it keeps running, and this Cherry's cherry-host relays to it.")
                }
            }
        } else if let status, status.running || status.state == "error" {
            if status.state == "other" {
                // Another version that did not say which.
                return .blocked(
                    reason: "\(machine) runs a session host of a version this Cherry cannot use or replace. Update Cherry on both Macs, then check again.",
                    allowsPlainAdd: false
                )
            }
            daemon = .unknown(status.error ?? status.state)
            warnings.append("\(machine)'s session host did not answer (\(status.error ?? status.state)); tabs there say so until it does.")
        } else {
            daemon = .absent
        }
        // An older daemon's warning already asks to update Cherry there.
        let olderDaemon: Bool = { if case .olderProtocol = daemon { return true } else { return false } }()
        for app in olderApps where !olderDaemon {
            let version = app.version.map { " (protocol \($0.protocol))" } ?? ""
            warnings.append("Cherry on \(machine) (\(app.path))\(version) is older than this one: while it runs it cannot use the session host this Cherry installs. Update Cherry there too.")
        }
        for app in newerApps {
            warnings.append("Cherry on \(machine) (\(app.path)) is newer (protocol \(app.version?.protocol ?? 0)): once it runs there, its session host replaces this one, and tabs from here wait until you update Cherry on this Mac.")
        }

        // This Cherry's helpers.
        // From here on only this Cherry's helpers are in the way: the Mac
        // can still be added as in phase 1, with the cherry-host there if it
        // has one (its tabs say what is missing otherwise).
        let found: RemoteHostHelpers
        switch helpers {
        case .success(let loaded): found = loaded
        case .failure(let error):
            return .blocked(reason: error.errorDescription ?? "This Cherry has no session host to install.", allowsPlainAdd: true)
        }
        let helpers = found
        guard helpers.version.protocol == localProtocol else {
            return .blocked(
                reason: "This Cherry's cherry-host speaks protocol \(helpers.version.protocol), not \(localProtocol); reinstall Cherry.",
                allowsPlainAdd: true
            )
        }
        guard helpers.runs(on: probe.architecture) else {
            let kind = probe.architecture == "x86_64" ? "an Intel Mac (x86_64)" : "a Mac of \(probe.architecture ?? "another architecture")"
            return .blocked(
                reason: "This Cherry's cherry and cherry-host are built for \(helpers.architectureList.isEmpty ? "another architecture" : helpers.architectureList) only, and \(machine) is \(kind). Install a universal build of Cherry on this Mac (Scripts/build-host builds arm64 and x86_64).",
                allowsPlainAdd: true
            )
        }
        if let minimum = minimumMacOS(helpers.version, architecture: probe.architecture),
           let running = probe.macOSVersion, compareVersions(running, minimum) == .orderedAscending {
            return .blocked(
                reason: "This Cherry's session host needs macOS \(minimum) or later; \(machine) runs macOS \(running).",
                allowsPlainAdd: true
            )
        }

        // Where ours goes: its build's directory. Nothing is copied when
        // that (or the one named by hash, used when the build's holds other
        // files something runs from) has the same files; otherwise the copy
        // goes there, and the finish repairs a damaged one or, when it is in
        // use, falls back to the one named by hash.
        var directoryName = helpers.directoryName
        var copyNeeded = true
        let alternate = RemoteHostInstaller.alternateName(directoryName, hashes: helpers.hashes)
        for candidate in [directoryName, alternate]
        where probe.installedBuilds.contains(where: { $0.name == candidate && $0.matches(helpers) }) {
            directoryName = candidate
            copyNeeded = false
            break
        }
        let otherBuildsThere = probe.installedBuilds.contains { $0.name != directoryName && $0.name != alternate }
        let olderHostThere = probe.hostVersion.map {
            $0.protocol < localProtocol || HostBuildOrder.isNewer(helpers.build, than: $0.build)
        } ?? false
        let isUpdate: Bool
        switch daemon {
        case .olderProtocol: isUpdate = true
        default: isUpdate = otherBuildsThere || olderHostThere
        }
        return .install(RemoteHostInstallPlan(
            daemon: daemon,
            architecture: probe.architecture,
            directoryName: directoryName,
            copyNeeded: copyNeeded,
            isUpdate: isUpdate,
            warnings: warnings
        ))
    }

    private static func helpersBuild(_ helpers: Result<RemoteHostHelpers, HostedSessionError>) -> String? {
        if case .success(let helpers) = helpers { return helpers.build }
        return nil
    }

    /// The oldest macOS the slice for `architecture` runs on. The version
    /// report is the running slice's (this Mac's); an x86_64 slice built
    /// by Rust's defaults needs 10.12, an arm64 one 11.0.
    static func minimumMacOS(_ version: RemoteHostVersionReport, architecture: String?) -> String? {
        guard let reported = version.min_macos else { return nil }
        let thisArchitecture = version.arch == "aarch64" ? "arm64" : version.arch
        if thisArchitecture == architecture || architecture == nil { return reported }
        // Another slice: never ask for more than the report, never less
        // than that architecture's first macOS.
        return architecture == "arm64" ? maxVersion(reported, "11.0") : reported
    }

    private static func maxVersion(_ lhs: String, _ rhs: String) -> String {
        compareVersions(lhs, rhs) == .orderedAscending ? rhs : lhs
    }

    /// Compares dotted version numbers (26.0 vs 15.5.1).
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Garbage collection

    /// A build directory there, as the install's report lists it.
    struct BuildDirectory: Equatable, Sendable {
        var name: String
        /// When it was put in place (its `.installed` stamp, else the
        /// directory's own time).
        var installed: Date
        /// The newest `.used-by/<installation id>` marker: when an
        /// installation of Cherry (on any Mac) last connected through it or
        /// checked it.
        var lastUsed: Date?
    }

    /// A build nothing else vouches for is kept this long after it was
    /// installed.
    static let minimumAge: TimeInterval = 7 * 86_400
    /// A build some installation of Cherry used within this long is kept:
    /// another Mac's device record may point at it.
    static let markerLifetime: TimeInterval = 30 * 86_400
    /// A partial copy (`*.partial-*`) or a directory moved aside
    /// (`*.broken-*`) is left this long (an install may be running).
    static let partialLifetime: TimeInterval = 3_600

    static func isScratch(_ name: String) -> Bool {
        name.contains(".partial-") || name.contains(".broken-")
    }

    /// The build directories to remove. A build stays when it is
    /// `current`, one of the `keptBuilds - 1` most recently installed
    /// others, in use (`inUse`), used by any installation within
    /// `markerLifetime`, or installed within `minimumAge`. Partial copies
    /// and directories moved aside go when not in use and older than
    /// `partialLifetime`.
    static func garbage(
        directories: [BuildDirectory],
        current: String,
        inUse: Set<String>,
        now: Date = Date()
    ) -> [String] {
        var removable: [String] = []
        for scratch in directories where isScratch(scratch.name) {
            if !inUse.contains(scratch.name), now.timeIntervalSince(scratch.installed) > partialLifetime {
                removable.append(scratch.name)
            }
        }
        let builds = directories
            .filter { !isScratch($0.name) && $0.name != current }
            .sorted { $0.installed == $1.installed ? $0.name > $1.name : $0.installed > $1.installed }
        for (index, build) in builds.enumerated() where index >= keptBuilds - 1 {
            if inUse.contains(build.name) { continue }
            if now.timeIntervalSince(build.installed) < minimumAge { continue }
            if let used = build.lastUsed, now.timeIntervalSince(used) < markerLifetime { continue }
            removable.append(build.name)
        }
        return removable
    }

    /// Why a build directory is in use.
    enum BuildUse: String, Equatable, Hashable, Sendable {
        /// A running process's command line names a file in it (the
        /// daemon, a holder, a gateway, an attachment).
        case process
        /// The daemon's executable is there.
        case daemonExecutable
        /// The daemon reports that build.
        case daemonBuild
        /// A running session's holder reports that build.
        case holderBuild
    }

    /// The build directories a process or the daemon uses, and why.
    static func directoriesInUse(
        root: String,
        directories: [String],
        processes: [String],
        status: RemoteCLIStatusReport?
    ) -> [String: Set<BuildUse>] {
        var used: [String: Set<BuildUse>] = [:]
        for name in directories {
            let path = "\(root)/\(name)/"
            if processes.contains(where: { $0.contains(path) }) { used[name, default: []].insert(.process) }
            if let executable = status?.host?.executable, executable.hasPrefix(path) {
                used[name, default: []].insert(.daemonExecutable)
            }
        }
        func mark(build: String, _ use: BuildUse) {
            let name = RemoteHostHelpers.directoryName(forBuild: build)
            for directory in directories where directory == name || directory.hasPrefix(name + "-") && !isScratch(directory) {
                used[directory, default: []].insert(use)
            }
        }
        if status?.running == true, let build = status?.host?.build ?? status?.build { mark(build: build, .daemonBuild) }
        for session in status?.sessions ?? [] where session.state != "exited" {
            if let build = session.holder_build { mark(build: build, .holderBuild) }
        }
        return used
    }

    /// Whether the new build should take over the daemon (`cherry
    /// restart`): it runs this protocol from one of our own install
    /// directories (never the other Mac's Cherry.app, nor another client's
    /// cherry-host), of another build that is not newer than ours. The
    /// restart itself names that daemon (`--if-pid`, `--if-executable`,
    /// `--if-build`), so one that changed meanwhile is left alone.
    static func shouldHandOver(
        status: RemoteCLIStatusReport?,
        homeDirectory: String,
        current: String,
        ourBuild: String,
        localProtocol: UInt32 = HostProtocol.version
    ) -> Bool {
        guard let status, status.running, let host = status.host, host.version == localProtocol,
              let executable = host.executable, let daemonBuild = host.build ?? status.build
        else { return false }
        let root = "\(homeDirectory)/\(rootRelativePath)/"
        let legacy = "\(homeDirectory)/\(legacyRelativePath)/"
        let ours = (executable.hasPrefix(root) && !executable.hasPrefix(root + current + "/")) || executable.hasPrefix(legacy)
        return ours && daemonBuild != ourBuild && !HostBuildOrder.isNewer(daemonBuild, than: ourBuild)
    }

    /// Checks the daemon again once the new build is in place, from its
    /// `cherry-host status --json` (the check may not have found any
    /// cherry-host to ask): warnings to show, or why the install must not be
    /// used (a newer protocol, or one too old to make way).
    static func recheck(
        status: RemoteHostStatusReport?,
        plan: RemoteHostInstallPlan,
        machine: String,
        localProtocol: UInt32 = HostProtocol.version
    ) -> Result<[String], HostedSessionError> {
        guard let status, status.running, let running = status.protocol else { return .success([]) }
        if running > localProtocol {
            return .failure(.message(
                "\(machine)'s session host speaks protocol \(running), newer than this Cherry (protocol \(localProtocol)). Update Cherry on this Mac, then check again."
            ))
        }
        if running < oldestReplaceableProtocol {
            return .failure(.message("\(machine) runs a session host too old to update. " + shutdownInstructions(protocol: running)))
        }
        switch plan.daemon {
        case .absent, .unknown:
            if running < localProtocol {
                return .success(["\(machine)'s session host speaks an older protocol (\(running)): connecting replaces it with this one, and its sessions carry on."])
            }
            return .success(["A session host already runs on \(machine); this Cherry's cherry-host relays to it."])
        case .sameProtocol, .olderProtocol:
            return .success([])
        }
    }
}

// MARK: - Running the install

/// Copies, checks and records this Cherry's helpers on a device.
struct RemoteHostInstaller: Sendable {
    enum Stage: Equatable, Sendable {
        case copying, verifying, finishing, handingOver, cleaningUp

        var text: String {
            switch self {
            case .copying: "Copying cherry and cherry-host…"
            case .verifying: "Checking the copy there…"
            case .finishing: "Putting it in place…"
            case .handingOver: "Moving the session host to this build (its sessions carry on)…"
            case .cleaningUp: "Removing builds nothing uses…"
            }
        }
    }

    struct Outcome: Equatable, Sendable {
        /// The device's new `remoteHostPath` (`~/…`).
        var remoteHostPath: String
        var directoryName: String
        var build: String
        /// The architecture the copy runs as there (its `version --json`).
        var architecture: String?
        var copied: Bool
        var handedOver: Bool
        var removed: [String]
        /// What the placement found: `moved` (the copy went in place),
        /// `existing` (the same build was there, checked), `replaced` (a
        /// broken one nothing ran from was replaced).
        var placement: String = "moved"
        /// A broken directory of this build that stays (in use), whose
        /// copy went to `<build>-<hash>` instead.
        var brokenKept: String?
        /// Build directories kept although old, and why.
        var kept: [String: Set<RemoteHostInstall.BuildUse>] = [:]
        /// Found once the build ran there (`RemoteHostInstall.recheck`).
        var warnings: [String] = []
        /// Ghostty's resources are there with it (`RemoteHostResources`).
        var resourcesInstalled = false
    }

    var shell: RemoteDeviceShell
    var helpers: RemoteHostHelpers
    /// This installation's id: the build it installs is marked as used by
    /// it (`.used-by/<id>`), so another Mac's install never collects it.
    var installationID: UUID?
    /// How long the copy may take.
    var copyTimeout: TimeInterval = 900

    static let copiedMarker = "CHERRY-INSTALL-COPIED"

    /// The system tools the scripts run, by absolute path: a PATH with GNU
    /// coreutils first (`stat -f` means something else there) or a stand-in
    /// must not change what they do.
    enum Tool {
        static let stat = "/usr/bin/stat"
        static let tar = "/usr/bin/tar"
        static let shasum = "/usr/bin/shasum"
        static let xattr = "/usr/bin/xattr"
        static let codesign = "/usr/bin/codesign"
        static let ps = "/bin/ps"
        static let perl = "/usr/bin/perl"
        static let awk = "/usr/bin/awk"
        static let touch = "/usr/bin/touch"
    }

    /// The one-line command the copy runs there (its standard input is the
    /// tar stream): `/bin/sh -c '…'`, quoted for any login shell (sh, bash,
    /// zsh, fish, csh, tcsh): one line, no `!` and no backslash inside the
    /// quotes.
    static func copyCommand(partialName: String) -> String {
        let directory = "\"$HOME\"/" + RemoteDeviceProbe.singleQuoted("\(RemoteHostInstall.rootRelativePath)/\(partialName)")
        let script = "umask 077 && mkdir -p \(directory) && \(Tool.tar) -xf - -C \(directory) && echo \(copiedMarker)"
        return "/bin/sh -c " + RemoteDeviceProbe.singleQuoted(script)
    }

    /// The name a copy of `directoryName` goes to when that directory holds
    /// other files that something runs from: `<build>-<first 12 of the
    /// hashes>`.
    static func alternateName(_ directoryName: String, hashes: [String]) -> String {
        "\(directoryName)-\(hashes.joined().prefix(12))"
    }

    /// A marker file of `installationID` in a build directory.
    static func markerLines(directoryVariable: String, installationID: UUID?) -> [String] {
        guard let installationID else { return [] }
        let id = installationID.uuidString.lowercased()
        return [
            "if [ -d \"$\(directoryVariable)\" ]; then mkdir -p \"$\(directoryVariable)/.used-by\" 2>/dev/null && \(Tool.touch) \"$\(directoryVariable)/.used-by/\(id)\" 2>/dev/null; fi",
        ]
    }

    /// The sh prelude of every script: the install root and the directory.
    private static func prelude(directoryName: String) -> [String] {
        [
            "printf '%s\\n' '\(RemoteDeviceProbe.beginMarker)'",
            "umask 077",
            "root=\"$HOME\"/" + RemoteDeviceProbe.singleQuoted(RemoteHostInstall.rootRelativePath),
            "dir=\"$root\"/" + RemoteDeviceProbe.singleQuoted(directoryName),
            "printf 'root=%s\\n' \"$root\"",
        ]
    }

    /// `verify_dir D`: both executables are there, their hashes are
    /// `$expected`, the Ghostty resources' digest is `$expected_resources`
    /// (when set), both signatures verify and cherry-host runs; else `$why`
    /// says what is wrong.
    private static func verifyFunction(expectedHashes: [String], expectedResources: String? = nil) -> [String] {
        RemoteHostResources.hashFunction + [
            "expected='\(expectedHashes.joined(separator: " ")) '",
            "expected_resources=\(expectedResources.map(RemoteDeviceProbe.singleQuoted) ?? "")",
            "verify_dir() {",
            "  why=",
            "  if [ ! -f \"$1/cherry\" ] || [ ! -x \"$1/cherry\" ] || [ ! -f \"$1/cherry-host\" ] || [ ! -x \"$1/cherry-host\" ]; then why=incomplete; return 1; fi",
            "  found=$(\(Tool.shasum) -a 256 \"$1/cherry\" \"$1/cherry-host\" 2>/dev/null | \(Tool.awk) '{ printf \"%s \", $1 }')",
            "  if [ \"$found\" != \"$expected\" ]; then why=hashes; return 1; fi",
            "  if [ -n \"$expected_resources\" ] && [ \"$(resources_hash \"$1\")\" != \"$expected_resources\" ]; then why=resources; return 1; fi",
            "  if \(Tool.codesign) --verify --strict \"$1/cherry-host\" >/dev/null 2>&1 && \(Tool.codesign) --verify --strict \"$1/cherry\" >/dev/null 2>&1; then :; else why=codesign; return 1; fi",
            "  if \"$1/cherry-host\" version --json >/dev/null 2>&1; then return 0; fi",
            "  why=version",
            "  return 1",
            "}",
        ]
    }

    /// Checks the copy at `source` (a partial directory or the build's):
    /// clears extended attributes, verifies both signatures, runs
    /// `cherry-host version --json` and hashes both files.
    static func verifyScript(directoryName: String, sourceName: String) -> String {
        var lines = prelude(directoryName: directoryName)
        lines += RemoteHostResources.hashFunction
        lines += [
            "src=\"$root\"/" + RemoteDeviceProbe.singleQuoted(sourceName),
            "if [ -f \"$src/cherry\" ] && [ -x \"$src/cherry\" ] && [ -f \"$src/cherry-host\" ] && [ -x \"$src/cherry-host\" ]; then",
            "  \(Tool.xattr) -c \"$src/cherry\" \"$src/cherry-host\" 2>/dev/null",
            "  for tree in Ghostty terminfo; do [ -d \"$src/$tree\" ] && \(Tool.xattr) -cr \"$src/$tree\" 2>/dev/null; done",
            "  [ -f \"$src/CherryMCP\" ] && \(Tool.xattr) -c \"$src/CherryMCP\" 2>/dev/null",
            "  printf 'resources_hash=%s\\n' \"$(resources_hash \"$src\")\"",
            "  printf 'xattrs=%s\\n' \"$(\(Tool.xattr) \"$src/cherry\" \"$src/cherry-host\" 2>/dev/null | tr '\\n' ' ')\"",
            "  if signature=$(\(Tool.codesign) --verify --strict \"$src/cherry-host\" 2>&1) && signature=$(\(Tool.codesign) --verify --strict \"$src/cherry\" 2>&1); then",
            "    echo codesign=ok",
            "  else",
            "    echo codesign=failed",
            "    printf 'codesign_error=%s\\n' \"$(printf '%s' \"$signature\" | tr '\\n' ' ')\"",
            "  fi",
            "  version=$(\"$src/cherry-host\" version --json 2>/dev/null)",
            "  printf 'verify_status=%s\\n' \"$?\"",
            "  printf 'verify=%s\\n' \"$(printf '%s' \"$version\" | tr -d '\\n')\"",
            "  printf 'hashes=%s\\n' \"$(\(Tool.shasum) -a 256 \"$src/cherry\" \"$src/cherry-host\" 2>/dev/null | \(Tool.awk) '{ printf \"%s \", $1 }')\"",
            "else",
            "  echo missing=1",
            "fi",
            "printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Removes a partial copy (after a failed check).
    static func discardScript(sourceName: String) -> String {
        var lines = prelude(directoryName: sourceName)
        lines += [
            "case \"$dir\" in *.partial-*) rm -rf \"$dir\" ;; esac",
            "printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Puts the checked copy (`sourceName`, a partial directory; nil when
    /// nothing was copied) in place as `directoryName`, then reports.
    ///
    /// The copy is renamed with rename(2) (`perl -e rename`), which fails
    /// when the target exists and is not empty, so a concurrent install of
    /// the same build never nests its copy inside another's. A target that
    /// is there already is used only when `verify_dir` passes (both
    /// executables, the expected hashes, signatures, it runs); a broken one
    /// that no process runs from is moved aside and replaced, one in use is
    /// left and the copy goes to `alternateName` (checked the same way).
    /// Partial copies nested inside a target by an older installer are
    /// removed. Without a copy, the target must pass `verify_dir`
    /// (`final=failed` otherwise, and the caller copies again). The report:
    /// `placed=`, `final=`, `broken=` (a broken target and why), and
    /// `reportLines`.
    static func finishScript(
        directoryName: String,
        sourceName: String?,
        expectedHashes: [String],
        expectedResources: String? = nil,
        installationID: UUID? = nil
    ) -> String {
        var lines = prelude(directoryName: directoryName)
        lines += verifyFunction(expectedHashes: expectedHashes, expectedResources: expectedResources)
        lines += [
            "processes=$(\(Tool.ps) -axww -o command= 2>/dev/null)",
            "in_use() { case \"$processes\" in *\"$1/\"*) return 0 ;; esac; return 1; }",
            "rename_dir() { \(Tool.perl) -e 'rename($ARGV[0], $ARGV[1]) or exit 1' \"$1\" \"$2\" 2>/dev/null; }",
            "placed=",
            "final=",
            "clean_nested() { for nested in \"$1\"/*.partial-*; do [ -d \"$nested\" ] && rm -rf \"$nested\" && printf 'nested=%s\\n' \"${nested##*/}\"; done; }",
        ]
        if let sourceName {
            lines += [
                "src=\"$root\"/" + RemoteDeviceProbe.singleQuoted(sourceName),
                "place() {",
                "  t=\"$root/$1\"",
                "  if rename_dir \"$src\" \"$t\"; then placed=$1; final=moved; return 0; fi",
                "  [ -d \"$t\" ] && clean_nested \"$t\"",
                "  if verify_dir \"$t\"; then rm -rf \"$src\"; placed=$1; final=existing; return 0; fi",
                "  printf 'broken=%s %s\\n' \"$1\" \"$why\"",
                "  if in_use \"$t\"; then printf 'broken_in_use=%s\\n' \"$1\"; return 1; fi",
                "  aside=\"$t.broken-$$\"",
                "  rename_dir \"$t\" \"$aside\" || return 1",
                "  if rename_dir \"$src\" \"$t\"; then rm -rf \"$aside\"; placed=$1; final=replaced; return 0; fi",
                // Another install put one there meanwhile.
                "  rm -rf \"$aside\"",
                "  if verify_dir \"$t\"; then rm -rf \"$src\"; placed=$1; final=existing; return 0; fi",
                "  return 1",
                "}",
                "if place \(RemoteDeviceProbe.singleQuoted(directoryName)) || place \(RemoteDeviceProbe.singleQuoted(alternateName(directoryName, hashes: expectedHashes))); then",
                "  [ \"$final\" = existing ] || \(Tool.touch) \"$root/$placed/.installed\"",
                "else",
                "  rm -rf \"$src\"",
                "  final=failed",
                "fi",
            ]
        } else {
            lines += [
                "for name in \(RemoteDeviceProbe.singleQuoted(directoryName)) \(RemoteDeviceProbe.singleQuoted(alternateName(directoryName, hashes: expectedHashes))); do",
                "  [ -d \"$root/$name\" ] || continue",
                "  clean_nested \"$root/$name\"",
                "  if verify_dir \"$root/$name\"; then placed=$name; final=existing; break; fi",
                "  printf 'broken=%s %s\\n' \"$name\" \"$why\"",
                "done",
                "[ -n \"$placed\" ] || final=failed",
            ]
        }
        lines += [
            "printf 'final=%s\\n' \"$final\"",
            "if [ -n \"$placed\" ]; then",
            "  dir=\"$root/$placed\"",
            "  printf 'placed=%s\\n' \"$placed\"",
            "  echo installed=1",
        ]
        lines += markerLines(directoryVariable: "dir", installationID: installationID).map { "  " + $0 }
        lines += ["fi"]
        lines += reportLines()
        lines.append("printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The daemon (`cherry status --json`, which never starts one, and
    /// `cherry-host status --json`, which says its protocol even when
    /// `cherry` cannot talk to it), each build directory (when installed,
    /// its newest `.used-by` marker) and the processes running from the
    /// install root. The process list is read once, before anything
    /// searches it, so no `grep` finds itself.
    private static func reportLines() -> [String] {
        [
            "if [ -x \"$dir/cherry\" ]; then",
            "  printf 'status=%s\\n' \"$(\"$dir/cherry\" status --json 2>/dev/null | tr -d '\\n')\"",
            "  printf 'hoststatus=%s\\n' \"$(\"$dir/cherry-host\" status --json 2>/dev/null | tr -d '\\n')\"",
            "fi",
            "for d in \"$root\"/*; do",
            "  [ -d \"$d\" ] || continue",
            "  if [ -e \"$d/.installed\" ]; then t=$(\(Tool.stat) -f %m \"$d/.installed\" 2>/dev/null); else t=$(\(Tool.stat) -f %m \"$d\" 2>/dev/null); fi",
            "  m=0",
            "  for f in \"$d\"/.used-by/*; do",
            "    [ -f \"$f\" ] || continue",
            "    x=$(\(Tool.stat) -f %m \"$f\" 2>/dev/null)",
            "    [ \"${x:-0}\" -gt \"$m\" ] && m=$x",
            "  done",
            "  printf 'directory=%s %s %s\\n' \"${t:-0}\" \"$m\" \"${d##*/}\"",
            "done",
            "processes=$(\(Tool.ps) -axww -o command= 2>/dev/null)",
            "printf '%s\\n' \"$processes\" | grep -F -- \"$root/\" | sed 's/^/process=/'",
        ]
    }

    /// Hands the daemon over to the new build: `cherry restart`, only if
    /// the daemon is still the one the report named (its pid, executable
    /// and build, checked on the connection that asks it to restart); the
    /// old daemon makes way, and its sessions' holders keep running and
    /// register with the new one. Then the report again.
    static func handOverScript(directoryName: String, pid: UInt32, executable: String, build: String) -> String {
        var lines = prelude(directoryName: directoryName)
        lines += [
            "if restart=$(\"$dir/cherry\" restart --if-pid \(pid) --if-executable \(RemoteDeviceProbe.singleQuoted(executable)) --if-build \(RemoteDeviceProbe.singleQuoted(build)) 2>&1); then",
            "  echo restart=ok",
            "else",
            "  code=$?",
            "  if [ \"$code\" = 4 ]; then echo restart=changed; else echo restart=failed; fi",
            "fi",
            "printf 'restart_output=%s\\n' \"$(printf '%s' \"$restart\" | tr '\\n' ' ')\"",
        ]
        lines += reportLines()
        lines.append("printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Removes each named directory unless a process runs from it now.
    static func cleanUpScript(names: [String]) -> String {
        var lines = prelude(directoryName: ".")
        lines.append("processes=$(\(Tool.ps) -axww -o command= 2>/dev/null)")
        for name in names {
            let quoted = RemoteDeviceProbe.singleQuoted(name)
            lines.append("d=\"$root\"/\(quoted)")
            lines.append("case \"$processes\" in *\"$d/\"*) printf 'kept=%s\\n' \(quoted) ;; *) rm -rf \"$d\" && printf 'removed=%s\\n' \(quoted) ;; esac")
        }
        lines.append("printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Marks the build directory of a device's `remoteHostPath` as used by
    /// this installation now (on each connection and check), so no other
    /// Mac's install collects it while this one points at it.
    static func markScript(directoryName: String, installationID: UUID) -> String {
        var lines = prelude(directoryName: directoryName)
        lines += markerLines(directoryVariable: "dir", installationID: installationID)
        lines.append("[ -f \"$dir/.used-by/\(installationID.uuidString.lowercased())\" ] && echo marked=1")
        lines.append("printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `key=value` lines between the markers; nil when the script did not
    /// run (ssh failed).
    static func fields(_ output: RemoteDeviceShell.Output) -> [(key: String, value: String)]? {
        let lines = output.standardOutput.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: RemoteDeviceProbe.beginMarker) else { return nil }
        var fields: [(String, String)] = []
        for line in lines[lines.index(after: begin)...] {
            if line == RemoteDeviceProbe.endMarker { break }
            guard let equals = line.firstIndex(of: "=") else { continue }
            fields.append((String(line[..<equals]), String(line[line.index(after: equals)...])))
        }
        return fields
    }

    /// What the check of a copy found, and why it cannot be used.
    struct Verification: Equatable {
        var codesignOK = false
        var codesignError: String?
        var status: Int32?
        var version: RemoteHostVersionReport?
        var hashes: [String] = []
        var missing = false
        /// Extended attributes still on the files after `xattr -c`.
        var remainingAttributes: String?
        /// The copy's Ghostty resources digest (`-`: none).
        var resourcesHash: String?

        init(fields: [(key: String, value: String)]) {
            for (key, value) in fields {
                switch key {
                case "resources_hash": resourcesHash = value.trimmingCharacters(in: .whitespaces).nilIfEmpty
                case "codesign": codesignOK = value == "ok"
                case "codesign_error": codesignError = value.trimmingCharacters(in: .whitespaces).nilIfEmpty
                case "verify_status": status = Int32(value)
                case "verify": version = try? JSONDecoder().decode(RemoteHostVersionReport.self, from: Data(value.utf8))
                case "hashes": hashes = value.split(separator: " ").map(String.init)
                case "missing": missing = true
                case "xattrs": remainingAttributes = value.trimmingCharacters(in: .whitespaces).nilIfEmpty
                default: break
                }
            }
        }

        /// Nil when the copy is this Cherry's helpers and runs there.
        func problem(expected helpers: RemoteHostHelpers, machine: String) -> String? {
            if missing { return "The copy on \(machine) is incomplete." }
            if !codesignOK {
                return "macOS on \(machine) does not accept the copy's signature (codesign: \(codesignError ?? "failed"))."
            }
            if status == 137 || status == 9 {
                return "macOS on \(machine) refused to run cherry-host (killed at launch, exit 137): its code signature is not valid there."
            }
            if status != 0 {
                return "cherry-host did not run on \(machine) (exit \(status.map(String.init) ?? "unknown"))."
            }
            guard let version else { return "cherry-host on \(machine) did not say what it is." }
            if version.protocol != helpers.version.protocol || version.build != helpers.version.build {
                return "The copy on \(machine) reports protocol \(version.protocol), build \(version.build ?? "?"), not this Cherry's \(helpers.version.protocol), \(helpers.build)."
            }
            if hashes != helpers.hashes {
                return "The copy on \(machine) differs from this Cherry's helpers (their SHA-256 do not match)."
            }
            if let expected = helpers.resourcesHash, resourcesHash != expected {
                return "The copy of Ghostty's terminfo and shell integration on \(machine) differs from this Cherry's."
            }
            return nil
        }
    }

    /// What `finishScript` and `handOverScript` report.
    struct Report: Equatable {
        var root: String?
        var installed = false
        var placed: String?
        var final: String?
        var broken: [String] = []
        var brokenInUse: String?
        var nested: [String] = []
        var status: RemoteCLIStatusReport?
        var hostStatus: RemoteHostStatusReport?
        var directories: [RemoteHostInstall.BuildDirectory] = []
        var processes: [String] = []
        var restart: String?
        var restartOutput: String?

        init(fields: [(key: String, value: String)]) {
            for (key, value) in fields {
                switch key {
                case "root": root = value
                case "installed": installed = true
                case "placed": placed = value
                case "final": final = value
                case "broken": broken.append(value)
                case "broken_in_use": brokenInUse = value
                case "nested": nested.append(value)
                case "status": status = try? JSONDecoder().decode(RemoteCLIStatusReport.self, from: Data(value.utf8))
                case "hoststatus": hostStatus = try? JSONDecoder().decode(RemoteHostStatusReport.self, from: Data(value.utf8))
                case "directory":
                    let parts = value.split(separator: " ", maxSplits: 2)
                    if parts.count == 3 {
                        let used = TimeInterval(parts[1]) ?? 0
                        directories.append(RemoteHostInstall.BuildDirectory(
                            name: String(parts[2]),
                            installed: Date(timeIntervalSince1970: TimeInterval(parts[0]) ?? 0),
                            lastUsed: used > 0 ? Date(timeIntervalSince1970: used) : nil
                        ))
                    }
                case "process": processes.append(value)
                case "restart": restart = value
                case "restart_output": restartOutput = value.trimmingCharacters(in: .whitespaces).nilIfEmpty
                default: break
                }
            }
        }

        /// The remote home (the root without its relative path).
        var homeDirectory: String? {
            guard let root, root.hasSuffix("/" + RemoteHostInstall.rootRelativePath) else { return nil }
            return String(root.dropLast(RemoteHostInstall.rootRelativePath.count + 1))
        }
    }

    /// Runs the install the plan describes on `destination` (called
    /// `machine` in messages). Throws with what went wrong; a failed copy
    /// leaves nothing in place.
    func install(
        _ plan: RemoteHostInstallPlan,
        on destination: String,
        machine: String,
        progress: @escaping @MainActor @Sendable (Stage) -> Void = { _ in }
    ) async throws -> Outcome {
        let directory = plan.directoryName
        var sourceName: String?
        var verification: Verification?
        if plan.copyNeeded {
            await progress(.copying)
            let partial = "\(directory).partial-\(UUID().uuidString.lowercased())"
            let copy = await copy(to: partial, on: destination)
            guard copy.status == 0, copy.standardOutput.contains(Self.copiedMarker) else {
                _ = await shell.run(Self.discardScript(sourceName: partial), on: destination)
                throw HostedSessionError.message(Self.failure("Could not copy cherry and cherry-host to \(machine)", copy))
            }
            sourceName = partial

            await progress(.verifying)
            let verifyOutput = await shell.run(Self.verifyScript(directoryName: directory, sourceName: partial), on: destination)
            guard let verifyFields = Self.fields(verifyOutput) else {
                _ = await shell.run(Self.discardScript(sourceName: partial), on: destination)
                throw HostedSessionError.message(Self.failure("Could not check the copy on \(machine)", verifyOutput))
            }
            let checked = Verification(fields: verifyFields)
            if let problem = checked.problem(expected: helpers, machine: machine) {
                _ = await shell.run(Self.discardScript(sourceName: partial), on: destination)
                throw HostedSessionError.message(problem)
            }
            verification = checked
        }

        await progress(.finishing)
        let finishOutput = await shell.run(
            Self.finishScript(
                directoryName: directory, sourceName: sourceName,
                expectedHashes: helpers.hashes, expectedResources: helpers.resourcesHash,
                installationID: installationID
            ),
            on: destination
        )
        guard let finishFields = Self.fields(finishOutput) else {
            if let sourceName { _ = await shell.run(Self.discardScript(sourceName: sourceName), on: destination) }
            throw HostedSessionError.message(Self.failure("Could not put the copy in place on \(machine)", finishOutput))
        }
        var report = Report(fields: finishFields)
        guard report.installed, let placed = report.placed else {
            if !plan.copyNeeded {
                // What the check saw there is not a good copy now: copy it.
                var again = plan
                again.copyNeeded = true
                return try await install(again, on: destination, machine: machine, progress: progress)
            }
            let broken = report.brokenInUse.map { " \($0) there is damaged and in use." } ?? ""
            throw HostedSessionError.message("The copy on \(machine) could not be put in place.\(broken)")
        }

        // The daemon, asked by the build now in place.
        let warnings: [String]
        switch RemoteHostInstall.recheck(status: report.hostStatus, plan: plan, machine: machine) {
        case .success(let found): warnings = found
        case .failure(let error): throw error
        }

        var handedOver = false
        if let home = report.homeDirectory,
           RemoteHostInstall.shouldHandOver(status: report.status, homeDirectory: home, current: placed, ourBuild: helpers.build),
           let host = report.status?.host, let pid = host.pid, let executable = host.executable,
           let daemonBuild = host.build ?? report.status?.build {
            await progress(.handingOver)
            let output = await shell.run(
                Self.handOverScript(directoryName: placed, pid: pid, executable: executable, build: daemonBuild),
                on: destination
            )
            if let fields = Self.fields(output) {
                let after = Report(fields: fields)
                handedOver = after.restart == "ok"
                if !handedOver {
                    SessionLog.error("cherry restart on \(machine): \(after.restart ?? "no answer"): \(after.restartOutput ?? "")")
                }
                report.status = after.status
                report.hostStatus = after.hostStatus
                report.directories = after.directories
                report.processes = after.processes
            }
        }

        var removed: [String] = []
        var kept: [String: Set<RemoteHostInstall.BuildUse>] = [:]
        if let root = report.root {
            let inUse = RemoteHostInstall.directoriesInUse(
                root: root, directories: report.directories.map(\.name), processes: report.processes, status: report.status
            )
            kept = inUse.filter { $0.key != placed }
            let garbage = RemoteHostInstall.garbage(directories: report.directories, current: placed, inUse: Set(inUse.keys))
            if !garbage.isEmpty {
                await progress(.cleaningUp)
                let output = await shell.run(Self.cleanUpScript(names: garbage), on: destination)
                removed = (Self.fields(output) ?? []).filter { $0.key == "removed" }.map(\.value)
            }
        }
        return Outcome(
            remoteHostPath: RemoteHostInstall.remoteHostPath(directoryName: placed),
            directoryName: placed,
            build: helpers.build,
            architecture: verification?.version?.arch.map { $0 == "aarch64" ? "arm64" : $0 } ?? plan.architecture,
            copied: plan.copyNeeded,
            handedOver: handedOver,
            removed: removed,
            placement: report.final ?? "moved",
            brokenKept: report.brokenInUse,
            kept: kept,
            warnings: warnings,
            resourcesInstalled: helpers.resourcesHash != nil
        )
    }

    private static func failure(_ what: String, _ output: RemoteDeviceShell.Output) -> String {
        if output.timedOut { return "\(what): it did not finish in time." }
        if output.status == 255 {
            return "\(what): \(RemoteDeviceSSHFailure.classify(output.standardError).message)"
        }
        let detail = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).last { !$0.isEmpty }
        return "\(what)" + (detail.map { ": \($0)" } ?? " (exit \(output.status)).")
    }

    /// `tar -cf - cherry cherry-host | ssh … '/bin/sh -c "…"'`.
    private func copy(to partialName: String, on destination: String) async -> RemoteDeviceShell.Output {
        let command = Self.copyCommand(partialName: partialName)
        let host: HostedSessionHost
        do {
            host = try HostedSessionHost.ssh(destination)
        } catch {
            return .init(status: 255, standardOutput: "", standardError: error.localizedDescription)
        }
        var arguments = shell.arguments(destination: host.sshDestination ?? destination)
        // Not `sh -s`: standard input is the archive.
        arguments.removeLast()
        arguments.append(command)
        let ssh = shell.sshExecutable
        let environment = shell.environment
        let tarArguments = Self.archiveArguments(helpers)
        let timeout = copyTimeout
        let output = await Task.detached(priority: .userInitiated) {
            Self.runPipeline(ssh: ssh, arguments: arguments, environment: environment, tarArguments: tarArguments, timeout: timeout)
        }.value
        if shell.controlPath != nil, output.status == 255, RemoteDeviceShell.isRefusedByMaster(output.standardError) {
            // The master has no session to spare: directly, as the CLI does.
            var direct = self
            direct.shell.controlPath = nil
            return await direct.copy(to: partialName, on: destination)
        }
        return output
    }

    /// What `tar -cf -` archives: the helpers, then Ghostty's two trees
    /// when there are any, each from its own directory.
    static func archiveArguments(_ helpers: RemoteHostHelpers) -> [String] {
        var arguments = ["-cf", "-", "-C", helpers.directory.path] + RemoteHostHelpers.names
        if let resources = helpers.resources, helpers.resourcesHash != nil {
            arguments += [
                "-C", resources.resourcesDirectory.deletingLastPathComponent().path, RemoteHostResources.treeNames[0],
                "-C", resources.terminfoDirectory.deletingLastPathComponent().path, RemoteHostResources.treeNames[1],
            ]
            if let mcpHelper = helpers.mcpHelper {
                arguments += ["-C", mcpHelper.deletingLastPathComponent().path, mcpHelper.lastPathComponent]
            }
        }
        return arguments
    }

    private static func runPipeline(
        ssh: String,
        arguments: [String],
        environment: [String: String],
        tarArguments: [String],
        timeout: TimeInterval
    ) -> RemoteDeviceShell.Output {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = tarArguments
        // Extended attributes travel with the files (macOS tar merges them
        // back on extraction); the check there clears them (`xattr -c`).
        tar.environment = ["PATH": "/usr/bin:/bin"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = arguments
        process.environment = environment
        let archive = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let tarErrors = Pipe()
        tar.standardOutput = archive
        tar.standardError = tarErrors
        tar.standardInput = FileHandle.nullDevice
        process.standardInput = archive
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .init(status: 255, standardOutput: "", standardError: "Could not run ssh: \(error.localizedDescription)")
        }
        do {
            try tar.run()
        } catch {
            process.terminate()
            process.waitUntilExit()
            return .init(status: 1, standardOutput: "", standardError: "Could not run tar: \(error.localizedDescription)")
        }
        // Only the children hold the pipe's ends now.
        try? archive.fileHandleForReading.close()
        try? archive.fileHandleForWriting.close()
        let group = DispatchGroup()
        let out = InstallOutputBox()
        let err = InstallOutputBox()
        let tarErr = InstallOutputBox()
        for (pipe, box) in [(stdout, out), (stderr, err), (tarErrors, tarErr)] {
            group.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            tar.terminate()
            process.terminate()
            if group.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                kill(tar.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 2)
            }
        }
        tar.waitUntilExit()
        process.waitUntilExit()
        var errors = String(decoding: err.data, as: UTF8.self)
        if tar.terminationStatus != 0 {
            errors += "\ntar: " + String(decoding: tarErr.data, as: UTF8.self)
        }
        return .init(
            status: timedOut ? 255 : (tar.terminationStatus != 0 && process.terminationStatus == 0 ? 1 : process.terminationStatus),
            standardOutput: String(decoding: out.data, as: UTF8.self),
            standardError: errors,
            timedOut: timedOut
        )
    }
}

private final class InstallOutputBox: @unchecked Sendable {
    var data = Data()
}
