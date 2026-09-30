import CherryControl
import Foundation

// The Omni bar's folders, live: listing a folder (This Mac with
// FileManager off the main thread; another Mac with one `sh -s` script
// over its SSH master, only while it is connected), finding the git
// repositories under the usual places (`OmniRepositoryScanner`), and
// adding a folder on a device as a project (`RemoteDeviceProjectAdding`).
// Nothing here connects a Mac, starts an SSH master or a daemon: a Mac
// that is not connected is not asked.

// MARK: - This Mac

enum OmniLocalFolders {
    /// The folders at `path` (hidden ones too; the bar filters them), each
    /// marked when it has a `.git`, at most `OmniFolderListingLimits.entries`
    /// (visible ones first). Blocking: call it off the main thread.
    static func list(_ path: String, fileManager: FileManager = .default) -> OmniFolderListing {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: path)
        } catch {
            return .failed(error.localizedDescription)
        }
        let base = path == "/" ? "" : path
        let ordered = names.sorted { lhs, rhs in
            let lhsHidden = lhs.hasPrefix("."), rhsHidden = rhs.hasPrefix(".")
            if lhsHidden != rhsHidden { return !lhsHidden }
            return lhs < rhs
        }
        var entries: [OmniFolderEntry] = []
        var truncated = false
        for name in ordered {
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: base + "/" + name, isDirectory: &isFolder), isFolder.boolValue else { continue }
            guard entries.count < OmniFolderListingLimits.entries else {
                truncated = true
                break
            }
            entries.append(OmniFolderEntry(name: name, isRepository: fileManager.fileExists(atPath: base + "/" + name + "/.git")))
        }
        return .listed(OmniFolderContents(
            path: path,
            isRepository: fileManager.fileExists(atPath: base + "/.git"),
            entries: entries,
            truncated: truncated
        ))
    }

    /// Where repositories are looked for, under the home folder: each
    /// pattern's `*` is one level.
    static let scanPatterns = ["github/*/*", "github/*", "code/*", "src/*", "Developer/*", "projects/*"]

    /// The git repositories under `home` at `scanPatterns`, at most
    /// `OmniFolderListingLimits.repositories`. Blocking.
    static func scan(home: String, fileManager: FileManager = .default) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func folders(in path: String) -> [String] {
            let names = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
                var isFolder: ObjCBool = false
                let child = path + "/" + name
                return fileManager.fileExists(atPath: child, isDirectory: &isFolder) && isFolder.boolValue ? child : nil
            }
        }
        for pattern in scanPatterns {
            var level = [home]
            for part in pattern.split(separator: "/") {
                level = part == "*" ? level.flatMap(folders(in:)) : level.map { $0 + "/" + part }
            }
            for path in level where fileManager.fileExists(atPath: path + "/.git") && seen.insert(path).inserted {
                found.append(path)
                if found.count >= OmniFolderListingLimits.repositories { return found }
            }
        }
        return found
    }
}

// MARK: - Another Mac

/// The scripts that list a folder and find repositories on another Mac,
/// run with `sh -s` over its SSH master. The folder asked for is never in
/// the script as text a shell reads: it goes in as octal escapes that only
/// `printf` turns back into bytes (`octalBytes`), so no name, quote,
/// `$(…)`, backquote or newline in it runs anything. What the Mac prints is
/// NUL-separated, so a name with a newline stays one name.
enum OmniRemoteFolders {
    static let listMarker = "CHERRY-FOLDERS 1"
    static let scanMarker = "CHERRY-REPOS 1"
    /// How long a listing may take there.
    static let timeout: TimeInterval = 3

    /// `text`'s bytes as a `printf` format of octal escapes, in single
    /// quotes: only `'`, `\` and digits.
    static func octalBytes(_ text: String) -> String {
        "'" + text.utf8.map { byte in
            let digits = String(byte, radix: 8)
            return "\\" + String(repeating: "0", count: 3 - digits.count) + digits
        }.joined() + "'"
    }

    /// Lists the folder `directory` (absolute, or `~/…` expanded there):
    /// `P<path>` (its path there), `R` when it is a repository itself, then
    /// `G<name>` (a repository) or `D<name>` per folder, `T` when there
    /// were more than `limit`, and `E` at the end; `M` for no such folder.
    static func listScript(directory: String, limit: Int = OmniFolderListingLimits.entries) -> String {
        """
        dir=$(printf \(octalBytes(directory)); printf x)
        dir=${dir%x}
        case $dir in
          "~") dir=$HOME ;;
          "~/"*) dir=$HOME/${dir#"~/"} ;;
        esac
        printf '%s\\n' '\(listMarker)'
        if [ ! -d "$dir" ] || ! cd -- "$dir" 2>/dev/null; then printf 'M\\0'; exit 0; fi
        printf 'P%s\\0' "$PWD"
        if [ -e .git ]; then printf 'R\\0'; fi
        n=0
        for d in * .[!.]* ..?*; do
          [ -d "$d" ] || continue
          n=$((n + 1))
          if [ "$n" -gt \(limit) ]; then printf 'T\\0'; break; fi
          if [ -e "$d/.git" ]; then printf 'G%s\\0' "$d"; else printf 'D%s\\0' "$d"; fi
        done
        printf 'E\\0'

        """
    }

    /// Reads what `listScript` printed.
    static func parseListing(_ output: RemoteDeviceShell.DataOutput) -> OmniFolderListing {
        guard let records = records(output.standardOutput, after: listMarker) else {
            if output.status == 255 || output.timedOut {
                return .failed(RemoteDeviceSSHFailure.classify(output.standardError, timedOut: output.timedOut).message)
            }
            return .failed("the listing did not run (exit \(output.status))")
        }
        if records.first == "M" { return .missing }
        var path: String?
        var isRepository = false
        var entries: [OmniFolderEntry] = []
        var truncated = false
        var ended = false
        for record in records {
            guard let tag = record.first else { continue }
            let value = String(record.dropFirst())
            switch tag {
            case "P": path = value
            case "R": isRepository = true
            case "G", "D":
                guard !value.isEmpty, !value.contains("/"), value != ".", value != "..",
                      entries.count < OmniFolderListingLimits.entries
                else { continue }
                entries.append(OmniFolderEntry(name: value, isRepository: tag == "G"))
            case "T": truncated = true
            case "E": ended = true
            default: continue
            }
        }
        guard ended, let path, path.hasPrefix("/") else {
            return .failed(output.timedOut ? "it did not answer in time" : "the listing was cut short")
        }
        return .listed(OmniFolderContents(path: path, isRepository: isRepository, entries: entries, truncated: truncated))
    }

    /// Finds the repositories under the home folder there at
    /// `OmniLocalFolders.scanPatterns`: their absolute paths, NUL-separated.
    static func scanScript(limit: Int = OmniFolderListingLimits.repositories) -> String {
        let patterns = OmniLocalFolders.scanPatterns.joined(separator: " ")
        return """
        printf '%s\\n' '\(scanMarker)'
        cd -- "$HOME" 2>/dev/null || { printf 'E\\0'; exit 0; }
        n=0
        for d in \(patterns); do
          [ -d "$d" ] && [ -e "$d/.git" ] || continue
          n=$((n + 1))
          if [ "$n" -gt \(limit) ]; then break; fi
          printf 'G%s\\0' "$PWD/$d"
        done
        printf 'E\\0'

        """
    }

    /// Reads what `scanScript` printed; nil when it did not run to its end.
    static func parseScan(_ output: RemoteDeviceShell.DataOutput) -> [String]? {
        guard let records = records(output.standardOutput, after: scanMarker), records.last == "E" else { return nil }
        var seen = Set<String>()
        return records.compactMap { record -> String? in
            guard record.first == "G" else { return nil }
            let path = String(record.dropFirst())
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            return path
        }
        .prefix(OmniFolderListingLimits.repositories)
        .map { $0 }
    }

    /// The NUL-separated records after the marker line; nil without it.
    private static func records(_ data: Data, after marker: String) -> [String]? {
        guard let range = data.range(of: Data((marker + "\n").utf8)) else { return nil }
        return data[range.upperBound...]
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// The app's shell to `device`: through its SSH master while that is
    /// up, with a short timeout.
    static func shell(for device: RemoteDevice, masters: HostSSHMasterManager = .shared) async -> RemoteDeviceShell {
        var shell = await RemoteDeviceShell.app()
        shell.controlPath = masters.controlPathIfUp(for: device.sshDestination)
        shell.connectTimeout = Int(timeout)
        shell.timeout = timeout
        return shell
    }

    static func list(_ directory: String, on destination: String, shell: RemoteDeviceShell) async -> OmniFolderListing {
        let script = listScript(directory: directory)
        let output = await RemoteDeviceShell.onOwnThread { shell.runSynchronously(script, on: destination) }
        return parseListing(output)
    }

    static func scan(on destination: String, shell: RemoteDeviceShell) async -> [String]? {
        var shell = shell
        shell.timeout = max(shell.timeout, 10)
        let script = scanScript()
        let captured = shell
        let output = await RemoteDeviceShell.onOwnThread { captured.runSynchronously(script, on: destination) }
        return parseScan(output)
    }
}

/// Whether a device can be asked something now: its control is connected,
/// or its SSH master is up. Never connects either.
@MainActor
enum OmniDeviceConnections {
    static func isConnected(
        _ device: RemoteDevice,
        controls: HostControlRegistry = .shared,
        masters: HostSSHMasterManager = .shared
    ) -> Bool {
        guard let host = device.host else { return false }
        if controls.all.contains(where: { $0.host == host && $0.state == .connected }) { return true }
        return masters.controlPathIfUp(for: device.sshDestination) != nil
    }
}

// MARK: - Listing folders

/// Lists the folders the bar's path queries ask for, and keeps them a few
/// seconds (This Mac) or a minute (another Mac) per folder. Another Mac is
/// asked only while it is connected (`isConnected`); otherwise its listing
/// is `.notConnected` until it is, and asked again then (`retryDisconnected`).
@MainActor
final class OmniFolderBrowser {
    static let shared = OmniFolderBrowser()

    static let localLifetime: TimeInterval = 5
    static let remoteLifetime: TimeInterval = 60
    static let failureLifetime: TimeInterval = 3

    typealias LocalLister = @Sendable (_ path: String) async -> OmniFolderListing
    typealias RemoteLister = @MainActor (_ deviceID: UUID, _ directory: String) async -> OmniFolderListing

    private(set) var listings: [OmniFolderRequest: OmniFolderListing] = [:]
    private var listedAt: [OmniFolderRequest: Date] = [:]
    private var inFlight = Set<OmniFolderRequest>()
    /// Runs on the next main-loop turn after a listing changes (the bar
    /// gathers again).
    var onChange: @MainActor () -> Void = {}

    private let listLocal: LocalLister
    private let listRemote: RemoteLister
    private let isConnected: @MainActor (UUID) -> Bool
    private let localHome: () -> String
    private let now: () -> Date

    init(
        listLocal: @escaping LocalLister = { path in
            await RemoteDeviceShell.onOwnThread { OmniLocalFolders.list(path) }
        },
        listRemote: @escaping RemoteLister = OmniFolderBrowser.listOnDevice,
        isConnected: @escaping @MainActor (UUID) -> Bool = { id in
            RemoteDeviceStore.shared.device(id: id).map { OmniDeviceConnections.isConnected($0) } ?? false
        },
        localHome: @escaping () -> String = { NSHomeDirectory() },
        now: @escaping () -> Date = { Date() }
    ) {
        self.listLocal = listLocal
        self.listRemote = listRemote
        self.isConnected = isConnected
        self.localHome = localHome
        self.now = now
    }

    /// The app's: the device's `sh -s` over its master.
    static func listOnDevice(_ deviceID: UUID, _ directory: String) async -> OmniFolderListing {
        guard let device = RemoteDeviceStore.shared.device(id: deviceID) else { return .failed("that Mac is no longer known") }
        let shell = await OmniRemoteFolders.shell(for: device)
        return await OmniRemoteFolders.list(directory, on: device.sshDestination, shell: shell)
    }

    /// Lists `request`'s folder unless a fresh listing of it is kept or one
    /// is on its way.
    func request(_ request: OmniFolderRequest) {
        if let listing = listings[request], let at = listedAt[request],
           now().timeIntervalSince(at) < lifetime(of: listing, on: request.machine) {
            changed()
            return
        }
        guard !inFlight.contains(request) else { return }
        switch request.machine {
        case .thisMac:
            guard let path = OmniPathQuery.expand(request.directory, home: localHome()) else {
                store(.missing, for: request)
                return
            }
            start(request) { [listLocal] in await listLocal(path) }
        case .device(let id):
            guard isConnected(id) else {
                store(.notConnected, for: request)
                return
            }
            start(request) { [listRemote] in await listRemote(id, request.directory) }
        }
    }

    /// Lists again each folder of a device that was not connected and now is.
    func retryDisconnected() {
        for (request, listing) in listings where listing == .notConnected {
            guard case .device(let id) = request.machine, isConnected(id) else { continue }
            listedAt[request] = nil
            self.request(request)
        }
    }

    private func lifetime(of listing: OmniFolderListing, on machine: ProjectSwitcherModel.Machine) -> TimeInterval {
        switch listing {
        case .listed, .missing: machine == .thisMac ? Self.localLifetime : Self.remoteLifetime
        case .failed: Self.failureLifetime
        case .loading, .notConnected: 0
        }
    }

    private func start(_ request: OmniFolderRequest, _ list: @escaping @MainActor () async -> OmniFolderListing) {
        inFlight.insert(request)
        // A stale listing stays up while the new one comes.
        if listings[request] == nil || listings[request] == .notConnected {
            listings[request] = .loading
            changed()
        }
        Task { @MainActor [weak self] in
            let listing = await list()
            guard let self else { return }
            self.inFlight.remove(request)
            self.store(listing, for: request)
        }
    }

    /// The most folders kept (the oldest go first).
    static let capacity = 200

    private func store(_ listing: OmniFolderListing, for request: OmniFolderRequest) {
        listings[request] = listing
        listedAt[request] = now()
        if listings.count > Self.capacity {
            let oldest = listedAt.sorted { $0.value < $1.value }.prefix(listings.count - Self.capacity).map(\.key)
            for key in oldest where !inFlight.contains(key) && key != request {
                listings[key] = nil
                listedAt[key] = nil
            }
        }
        changed()
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
    }
}

// MARK: - Repositories not added yet

/// Finds the git repositories under the usual places on each Mac
/// (`OmniLocalFolders.scanPatterns`), for "Not added yet": This Mac's at
/// most every few minutes, each device's at most every ten minutes and
/// only while it is connected, when the bar opens (`scanIfDue`). What each
/// device had is also kept in a small file in the app's Application
/// Support folder (written only by the copy that holds the instance lock),
/// so it shows at once on the next launch.
@MainActor
final class OmniRepositoryScanner {
    static let shared = OmniRepositoryScanner(
        cacheURL: AppInstanceLock.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent(OmniRepositoryScanner.fileName, isDirectory: false),
        canWrite: { AppInstanceLock.shared.isHeld }
    )

    static let fileName = "omni-repositories.json"
    static let localInterval: TimeInterval = 180
    static let remoteInterval: TimeInterval = 600

    struct Cache: Codable, Equatable {
        struct Device: Codable, Equatable {
            var scannedAt: Date
            var paths: [String]
        }

        var version = 1
        var devices: [String: Device] = [:]
    }

    typealias LocalScanner = @Sendable () async -> [String]
    typealias RemoteScanner = @MainActor (RemoteDevice) async -> [String]?

    /// This Mac's, then each device's.
    private(set) var repositories: [OmniUnaddedRepository] = []
    var onChange: @MainActor () -> Void = {}

    private var local: [String] = []
    private var localScannedAt: Date?
    private var remote: [UUID: Cache.Device] = [:]
    private var scanning = Set<ProjectSwitcherModel.Machine>()
    private let cacheURL: URL?
    private let canWrite: @MainActor () -> Bool
    private let devices: @MainActor () -> [RemoteDevice]
    private let isConnected: @MainActor (RemoteDevice) -> Bool
    private let scanLocal: LocalScanner
    private let scanRemote: RemoteScanner
    private let now: () -> Date

    init(
        cacheURL: URL?,
        canWrite: @escaping @MainActor () -> Bool,
        devices: @escaping @MainActor () -> [RemoteDevice] = { RemoteDeviceStore.shared.devices },
        isConnected: @escaping @MainActor (RemoteDevice) -> Bool = { OmniDeviceConnections.isConnected($0) },
        scanLocal: @escaping LocalScanner = {
            let home = NSHomeDirectory()
            return await RemoteDeviceShell.onOwnThread { OmniLocalFolders.scan(home: home) }
        },
        scanRemote: @escaping RemoteScanner = { device in
            let shell = await OmniRemoteFolders.shell(for: device)
            return await OmniRemoteFolders.scan(on: device.sshDestination, shell: shell)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.cacheURL = cacheURL
        self.canWrite = canWrite
        self.devices = devices
        self.isConnected = isConnected
        self.scanLocal = scanLocal
        self.scanRemote = scanRemote
        self.now = now
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1 {
            for (key, entry) in cache.devices {
                guard let id = UUID(uuidString: key) else { continue }
                remote[id] = Cache.Device(
                    scannedAt: entry.scannedAt,
                    paths: Array(entry.paths.filter { $0.hasPrefix("/") }.prefix(OmniFolderListingLimits.repositories))
                )
            }
        }
        rebuild()
    }

    /// Scans This Mac when its last scan is older than `localInterval`, and
    /// each connected device whose last is older than `remoteInterval`.
    /// A device that is not connected is not asked (what it had stays).
    func scanIfDue() {
        let date = now()
        if !scanning.contains(.thisMac), localScannedAt.map({ date.timeIntervalSince($0) >= Self.localInterval }) ?? true {
            scanning.insert(.thisMac)
            let scanLocal = scanLocal
            Task { @MainActor [weak self] in
                let paths = await scanLocal()
                guard let self else { return }
                self.scanning.remove(.thisMac)
                self.local = paths
                self.localScannedAt = self.now()
                self.rebuild()
            }
        }
        for device in devices() {
            let machine = ProjectSwitcherModel.Machine.device(device.id)
            guard !scanning.contains(machine),
                  remote[device.id].map({ date.timeIntervalSince($0.scannedAt) >= Self.remoteInterval }) ?? true,
                  isConnected(device)
            else { continue }
            scanning.insert(machine)
            Task { @MainActor [weak self, scanRemote] in
                let paths = await scanRemote(device)
                guard let self else { return }
                self.scanning.remove(machine)
                // A failed scan keeps what was found before.
                guard let paths else { return }
                self.remote[device.id] = Cache.Device(scannedAt: self.now(), paths: paths)
                self.save()
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let known = Set(devices().map(\.id))
        var result = local.map { OmniUnaddedRepository(machine: .thisMac, path: $0) }
        for (id, entry) in remote.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where known.contains(id) {
            result += entry.paths.map { OmniUnaddedRepository(machine: .device(id), path: $0) }
        }
        guard result != repositories else { return }
        repositories = result
        onChange()
    }

    private func save() {
        guard let cacheURL, canWrite() else { return }
        var cache = Cache()
        for (id, entry) in remote { cache.devices[id.uuidString] = entry }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - Adding a device's folder

/// Add Project on <Mac>: the folder as that Mac resolves it (`pwd -P`),
/// added to the device's projects (`RemoteDeviceStore.addProject`), so its
/// key is `device:<uuid>:<path>`. The Omni bar's folders and the Add
/// Project on <Mac>… sheet both add through here.
@MainActor
enum RemoteDeviceProjectAdding {
    typealias Resolver = (_ path: String, _ device: RemoteDevice) async -> Result<String, RemoteDeviceProbe.RemoteDirectoryError>

    /// The app's: `RemoteDeviceProbe.resolveDirectory` over the device's
    /// master while it is up.
    static func resolveOverSSH(_ path: String, _ device: RemoteDevice) async -> Result<String, RemoteDeviceProbe.RemoteDirectoryError> {
        var shell = await RemoteDeviceShell.app()
        shell.controlPath = HostSSHMasterManager.shared.controlPathIfUp(for: device.sshDestination)
        return await RemoteDeviceProbe.resolveDirectory(path, on: device.sshDestination, shell: shell)
    }

    /// Adds `path` on the device: the project key, or why not.
    static func add(
        _ path: String,
        to deviceID: UUID,
        store: RemoteDeviceStore,
        resolve: Resolver = RemoteDeviceProjectAdding.resolveOverSSH
    ) async -> Result<String, RemoteDeviceProbe.RemoteDirectoryError> {
        guard let device = store.device(id: deviceID) else { return .failure(.message("That Mac is no longer one of your Macs.")) }
        guard store.canModify else { return .failure(.message(RemoteDeviceStore.readOnlyReason)) }
        switch await resolve(path, device) {
        case .success(let resolved):
            store.addProject(path: resolved, to: deviceID)
            return .success(device.projectKey(path: resolved))
        case .failure(let failure):
            return .failure(failure)
        }
    }
}
