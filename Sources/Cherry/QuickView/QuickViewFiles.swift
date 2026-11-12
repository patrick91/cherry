import CryptoKit
import Foundation

// Quick View's files: This Mac's are read where they are; another Mac's
// are looked at with a `sh -s` script over its SSH master and copied into
// a cache here (`QuickViewCache`), so Quick Look can show them.

/// A file Quick View found.
struct QuickViewFoundFile: Equatable, Sendable {
    /// Its path on its Mac (absolute).
    let path: String
    /// Its size in bytes, when its Mac said.
    var size: Int64?
    /// When it last changed, in seconds since 1970, when its Mac said.
    var modified: Int64?
    var isReadable = true

    var name: String {
        (path as NSString).lastPathComponent
    }
}

/// A folder Quick View found: its entries, folders first, by name.
struct QuickViewFolder: Equatable, Sendable {
    struct Entry: Equatable, Hashable, Sendable, Identifiable {
        let name: String
        let isFolder: Bool
        var id: String { name }
    }

    let path: String
    var entries: [Entry]
    /// More entries than a listing shows (`QuickViewRemoteFiles.folderEntryLimit`).
    var isTruncated = false
    var isReadable = true

    var name: String {
        (path as NSString).lastPathComponent
    }

    /// Folders first, then files, each by name as Finder sorts them.
    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { left, right in
            if left.isFolder != right.isFolder { return left.isFolder }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

/// What is at the first path of a request that names something.
enum QuickViewLook: Equatable, Sendable {
    /// A file, and the line its link named.
    case file(QuickViewFoundFile, line: Int?)
    case folder(QuickViewFolder)
    /// Something that is neither (a device, a socket), at this path.
    case special(String)
    /// Nothing at any of the paths.
    case missing
    /// The Mac could not be asked, or did not answer.
    case failed(String)
}

/// A file Quick View can show: here, or copied here.
enum QuickViewCopy: Equatable, Sendable {
    case local(URL)
    /// Larger than Quick View copies from another Mac.
    case tooLarge(Int64)
    /// It went (or became unreadable) since it was looked at.
    case missing
    case failed(String)
}

/// Where Quick View reads a Mac's files.
protocol QuickViewFileSource: Sendable {
    var machine: QuickViewMachine { get }
    /// What is at the first of `candidates` that names something.
    func look(at candidates: [QuickViewCandidate]) async -> QuickViewLook
    /// The file, as a file here; `refresh` reads it again even when a copy
    /// of the same size and time is cached.
    func copy(_ file: QuickViewFoundFile, refresh: Bool) async -> QuickViewCopy
}

// MARK: - This Mac

/// This Mac's files, read where they are.
struct QuickViewLocalFiles: QuickViewFileSource {
    var machine: QuickViewMachine { .thisMac }

    /// The first candidate that exists, and whether it is a folder; read on
    /// the caller's thread (a click asks this before it decides).
    static func firstExisting(_ candidates: [QuickViewCandidate]) -> (QuickViewCandidate, isFolder: Bool)? {
        for candidate in candidates where candidate.path.hasPrefix("/") {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isFolder) {
                return (candidate, isFolder.boolValue)
            }
        }
        return nil
    }

    func look(at candidates: [QuickViewCandidate]) async -> QuickViewLook {
        await Task.detached(priority: .userInitiated) { Self.lookSynchronously(at: candidates) }.value
    }

    static func lookSynchronously(at candidates: [QuickViewCandidate]) -> QuickViewLook {
        guard let (candidate, isFolder) = firstExisting(candidates) else { return .missing }
        let path = candidate.path
        let manager = FileManager.default
        if isFolder {
            guard let names = try? manager.contentsOfDirectory(atPath: path) else {
                return .folder(QuickViewFolder(path: path, entries: [], isReadable: false))
            }
            let limit = QuickViewRemoteFiles.folderEntryLimit
            let entries = names.prefix(limit).map { name in
                var isFolder: ObjCBool = false
                manager.fileExists(atPath: path + "/" + name, isDirectory: &isFolder)
                return QuickViewFolder.Entry(name: name, isFolder: isFolder.boolValue)
            }
            return .folder(QuickViewFolder(path: path, entries: QuickViewFolder.sorted(entries), isTruncated: names.count > limit))
        }
        // What a link leads to (a link's own attributes are the link's).
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? manager.attributesOfItem(atPath: target) else { return .missing }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .special(path) }
        let size = (attributes[.size] as? NSNumber)?.int64Value
        let modified = (attributes[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
        let file = QuickViewFoundFile(path: path, size: size, modified: modified, isReadable: manager.isReadableFile(atPath: path))
        return .file(file, line: candidate.line)
    }

    func copy(_ file: QuickViewFoundFile, refresh: Bool) async -> QuickViewCopy {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        return .local(URL(fileURLWithPath: file.path))
    }
}

// MARK: - Another Mac

/// Another Mac's files, through `sh -s` over its SSH master
/// (`RemoteDeviceShell`, the same ssh as the device's other one-shot
/// scripts). A path is never in a script as text a shell reads: it goes in
/// as octal escapes only `printf` turns back into bytes
/// (`OmniRemoteFolders.octalBytes`), so no name, quote, `$(…)`, backquote
/// or newline in it runs anything there. What the Mac prints is
/// NUL-separated, so a name with a newline stays one name. Copies go into
/// `QuickViewCache`, at most `maximumCopyBytes` each.
struct QuickViewRemoteFiles: QuickViewFileSource {
    static let lookMarker = "CHERRY-QUICKVIEW 1"
    static let copyMarker = "CHERRY-QUICKVIEW-COPY 1"
    /// The largest file Quick View copies from another Mac.
    static let maximumCopyBytes: Int64 = 50 * 1024 * 1024
    /// The most entries a folder lists.
    static let folderEntryLimit = 2000
    /// How long a look may take there.
    static let lookTimeout: TimeInterval = 20
    /// How long a copy may take.
    static let copyTimeout: TimeInterval = 180

    let machine: QuickViewMachine
    let destination: String
    /// The shell its scripts run in (the app's resolves the login
    /// environment and the master's control path; tests pass their own).
    let shell: @Sendable (TimeInterval) async -> RemoteDeviceShell
    let cache: QuickViewCache

    /// The app's: `destination`'s SSH master while it is up, else its own
    /// BatchMode ssh.
    static func app(name: String, destination: String, cache: QuickViewCache = QuickViewCache()) -> QuickViewRemoteFiles {
        QuickViewRemoteFiles(
            machine: .remote(name: name, destination: destination),
            destination: destination,
            shell: { timeout in await RemoteDeviceShell.app(through: destination, timeout: timeout) },
            cache: cache
        )
    }

    // MARK: Scripts

    /// The shell function that prints a file's size and modification time
    /// (`<bytes> <seconds>`), following a link, with BSD's or GNU's stat.
    static let statFunction = """
    qv_stat() {
      case $(uname -s) in
        Linux) stat -L -c '%s %Y' -- "$1" 2>/dev/null ;;
        *) stat -L -f '%z %m' -- "$1" 2>/dev/null ;;
      esac
    }
    """

    /// Looks at each candidate in turn (`~` and `~/…` expanded there) and
    /// reports the first that exists: `P<path>`, then `Kf` and
    /// `S<bytes> <seconds>` (`U` when it cannot be read) for a file, `Kd`
    /// and its entries (`D<name>` a folder, `F<name>` anything else, `T`
    /// past `limit`, `X` when it cannot be read) for a folder, `Ko` for
    /// anything else; `N` when none exists; `E` at the end.
    static func lookScript(candidates: [String], limit: Int = folderEntryLimit) -> String {
        let tries = candidates.map { candidate in
            "[ -n \"$found\" ] || { c=$(printf \(OmniRemoteFolders.octalBytes(candidate)); printf x); qv_try \"${c%x}\"; }"
        }.joined(separator: "\n")
        return """
        \(statFunction)
        qv_try() {
          case $1 in
            "~") set -- "$HOME" ;;
            "~/"*) h=${1#"~/"}; set -- "$HOME/$h" ;;
          esac
          if [ -e "$1" ] || [ -L "$1" ]; then found=$1; fi
        }
        found=
        \(tries)
        printf '%s\\n' '\(lookMarker)'
        if [ -z "$found" ]; then printf 'N\\0E\\0'; exit 0; fi
        case $found in /*) ;; *) found=$PWD/$found ;; esac
        printf 'P%s\\0' "$found"
        if [ -d "$found" ]; then
          printf 'Kd\\0'
          if cd -- "$found" 2>/dev/null; then
            n=0
            for e in * .[!.]* ..?*; do
              [ -e "$e" ] || [ -L "$e" ] || continue
              n=$((n + 1))
              if [ "$n" -gt \(limit) ]; then printf 'T\\0'; break; fi
              if [ -d "$e" ]; then printf 'D%s\\0' "$e"; else printf 'F%s\\0' "$e"; fi
            done
          else
            printf 'X\\0'
          fi
        elif [ -f "$found" ]; then
          printf 'Kf\\0'
          printf 'S%s\\0' "$(qv_stat "$found")"
          [ -r "$found" ] || printf 'U\\0'
        else
          printf 'Ko\\0'
        fi
        printf 'E\\0'

        """
    }

    /// Prints the file's `S<bytes> <seconds>` and `C`, then at most
    /// `limit` + 1 of its bytes (so a file that grew past the limit is
    /// seen to); `N` when it is no readable file.
    static func copyScript(path: String, limit: Int64 = maximumCopyBytes) -> String {
        """
        \(statFunction)
        p=$(printf \(OmniRemoteFolders.octalBytes(path)); printf x)
        p=${p%x}
        printf '%s\\n' '\(copyMarker)'
        if [ -f "$p" ] && [ -r "$p" ]; then
          printf 'S%s\\0C\\0' "$(qv_stat "$p")"
          exec head -c \(limit + 1) -- "$p"
        fi
        printf 'N\\0'

        """
    }

    // MARK: Reading what the Mac printed

    /// The NUL-separated records after `marker`'s line, and the bytes after
    /// the record `stop` when it is one of them; nil without the marker.
    static func records(_ data: Data, after marker: String, stoppingAt stop: String? = nil) -> (records: [String], rest: Data?)? {
        let markerLine = Data((marker + "\n").utf8)
        guard let range = data.range(of: markerLine) else { return nil }
        var records: [String] = []
        var index = range.upperBound
        while index < data.endIndex {
            let end = data[index...].firstIndex(of: 0) ?? data.endIndex
            let record = String(decoding: data[index..<end], as: UTF8.self)
            index = end < data.endIndex ? data.index(after: end) : end
            if let stop, record == stop {
                return (records, Data(data[index...]))
            }
            records.append(record)
            if end == data.endIndex { break }
        }
        return (records, nil)
    }

    /// `<bytes> <seconds>` as `qv_stat` prints it.
    static func sizeAndTime(_ text: Substring) -> (size: Int64?, modified: Int64?) {
        let parts = text.split(separator: " ")
        return (parts.first.flatMap { Int64($0) }, parts.dropFirst().first.flatMap { Int64($0) })
    }

    /// Why the Mac did not answer, from ssh's exit and words.
    static func unreachable(_ output: RemoteDeviceShell.DataOutput, machine: String, what: String) -> String {
        if output.status == 255 || output.timedOut {
            return "Could not reach \(machine): \(RemoteDeviceSSHFailure.classify(output.standardError, timedOut: output.timedOut).message)"
        }
        let errors = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return errors.isEmpty ? "\(what) did not run on \(machine) (exit \(output.status))." : errors
    }

    /// Reads what `lookScript` printed.
    static func parseLook(_ output: RemoteDeviceShell.DataOutput, machine: String, lines: [String: Int] = [:]) -> QuickViewLook {
        guard let (records, _) = records(output.standardOutput, after: lookMarker) else {
            return .failed(unreachable(output, machine: machine, what: "The look"))
        }
        guard records.last == "E" else {
            return .failed(output.timedOut ? "\(machine) did not answer in time." : "The look at \(machine) was cut short.")
        }
        if records.first == "N" { return .missing }
        var path: String?
        var kind: Character?
        var size: Int64?
        var modified: Int64?
        var readable = true
        var truncated = false
        var entries: [QuickViewFolder.Entry] = []
        for record in records {
            guard let tag = record.first else { continue }
            let value = record.dropFirst()
            switch tag {
            case "P": path = String(value)
            case "K": kind = value.first
            case "S": (size, modified) = sizeAndTime(value)
            case "U", "X": readable = false
            case "T": truncated = true
            case "D", "F":
                guard !value.isEmpty, !value.contains("/"), value != ".", value != "..",
                      entries.count < folderEntryLimit
                else { continue }
                entries.append(QuickViewFolder.Entry(name: String(value), isFolder: tag == "D"))
            default: continue
            }
        }
        guard let path, path.hasPrefix("/") else { return .failed("The look at \(machine) was cut short.") }
        switch kind {
        case "f":
            // The line of the candidate it found; `~/…` was expanded there,
            // so a home-relative candidate's line is looked up by its end.
            let line = lines[path] ?? lines.first(where: { $0.key.hasPrefix("~/") && path.hasSuffix(String($0.key.dropFirst())) })?.value
            return .file(QuickViewFoundFile(path: path, size: size, modified: modified, isReadable: readable), line: line)
        case "d":
            return .folder(QuickViewFolder(path: path, entries: QuickViewFolder.sorted(entries), isTruncated: truncated, isReadable: readable))
        default:
            return .special(path)
        }
    }

    /// What `copyScript` printed: the file's size and time, and its bytes;
    /// nil bytes when it was no readable file.
    static func parseCopy(_ output: RemoteDeviceShell.DataOutput) -> (size: Int64?, modified: Int64?, bytes: Data?)? {
        guard let (records, rest) = records(output.standardOutput, after: copyMarker, stoppingAt: "C") else { return nil }
        guard let rest else {
            return records.contains("N") ? (nil, nil, nil) : nil
        }
        let stat = records.first(where: { $0.hasPrefix("S") }).map { sizeAndTime($0.dropFirst()) }
        return (stat?.size, stat?.modified, rest)
    }

    // MARK: Looking and copying

    func look(at candidates: [QuickViewCandidate]) async -> QuickViewLook {
        guard !candidates.isEmpty else { return .missing }
        let script = Self.lookScript(candidates: candidates.map(\.path))
        let output = await shell(Self.lookTimeout).runData(script, on: destination)
        var lines: [String: Int] = [:]
        for candidate in candidates {
            if let line = candidate.line, lines[candidate.path] == nil { lines[candidate.path] = line }
        }
        return Self.parseLook(output, machine: machine.name, lines: lines)
    }

    func copy(_ file: QuickViewFoundFile, refresh: Bool) async -> QuickViewCopy {
        if let size = file.size, size > Self.maximumCopyBytes { return .tooLarge(size) }
        if !refresh, let size = file.size, let cached = cache.cachedCopy(destination: destination, path: file.path, size: size, modified: file.modified) {
            return .local(cached)
        }
        let output = await shell(Self.copyTimeout).runData(Self.copyScript(path: file.path), on: destination)
        guard let copied = Self.parseCopy(output) else {
            return .failed(Self.unreachable(output, machine: machine.name, what: "The copy"))
        }
        guard let bytes = copied.bytes else { return .missing }
        if Int64(bytes.count) > Self.maximumCopyBytes {
            return .tooLarge(max(copied.size ?? 0, Int64(bytes.count)))
        }
        // Fewer bytes than its size with a failed head (the connection
        // dropped), not a file that shrank meanwhile.
        let isShort = copied.size.map { Int64(bytes.count) < $0 } ?? false
        if output.timedOut || (isShort && output.status != 0) {
            return .failed("The copy from \(machine.name) was cut short.")
        }
        do {
            let url = try cache.store(
                bytes, destination: destination, path: file.path,
                size: Int64(bytes.count), modified: copied.modified ?? file.modified
            )
            return .local(url)
        } catch {
            return .failed("Cherry could not keep the copy: \(error.localizedDescription)")
        }
    }
}

// MARK: - The cache of copies

/// Copies of other Macs' files: `~/Library/Caches/<app identity>/Quick
/// View/<digest of Mac and path>/<bytes>-<seconds>/<name>`, the folder and
/// files private to the user. A file's other copies go when a new one is
/// kept; copies not used for `retention` go whenever one is kept.
struct QuickViewCache: Sendable {
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    let directory: URL

    init(directory: URL = QuickViewCache.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        PastedImageStore.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("Quick View", isDirectory: true)
    }

    /// The folder of one file's copies.
    func fileDirectory(destination: String, path: String) -> URL {
        let digest = SHA256.hash(data: Data((destination + "\u{0}" + path).utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    /// Where the copy of `path` at `size` and `modified` is kept.
    func copyURL(destination: String, path: String, size: Int64, modified: Int64?) -> URL {
        var name = (path as NSString).lastPathComponent
        if name.isEmpty || name == "/" { name = "file" }
        return fileDirectory(destination: destination, path: path)
            .appendingPathComponent("\(size)-\(modified ?? 0)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    /// The copy kept of `path` at that size and time, when there is one.
    func cachedCopy(destination: String, path: String, size: Int64, modified: Int64?) -> URL? {
        guard modified != nil else { return nil }
        let url = copyURL(destination: destination, path: path, size: size, modified: modified)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == size
        else { return nil }
        // Used now: pruning goes by the file's folder's time.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileDirectory(destination: destination, path: path).path)
        return url
    }

    /// Keeps `bytes` as the copy of `path`, removing its other copies and
    /// copies unused for `retention`; returns the copy.
    func store(_ bytes: Data, destination: String, path: String, size: Int64, modified: Int64?, now: Date = Date()) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune(now: now)
        let fileDirectory = fileDirectory(destination: destination, path: path)
        try? manager.removeItem(at: fileDirectory)
        let url = copyURL(destination: destination, path: path, size: size, modified: modified)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url, options: [.atomic])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? manager.setAttributes([.modificationDate: now], ofItemAtPath: fileDirectory.path)
        return url
    }

    /// Removes the copies of files not used since `now - retention`;
    /// returns their folders.
    @discardableResult
    func prune(now: Date = Date(), retention: TimeInterval = QuickViewCache.retention) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-retention)
        var removed: [URL] = []
        for folder in folders {
            guard let values = try? folder.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                  let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed.append(folder) }
        }
        return removed
    }
}
