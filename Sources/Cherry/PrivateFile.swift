import Darwin
import Foundation

/// A small state file only this user may read: written whole (a private
/// temporary file beside it, renamed over it) and read only as this user's
/// own private regular file, never through a link. Callers keep their own
/// encoding.
enum PrivateFile {
    /// Replaces `fileURL` with `data`: the directory is made (0700) if
    /// needed, then a temporary file beside it (0600), renamed over it, so
    /// readers see the old file or the new one, never part of one. The
    /// rename replaces whatever is there (a link included), never what a
    /// link points to. `durable` syncs the data to disk before the rename;
    /// `excludedFromBackup` leaves the file out of backups.
    static func write(_ data: Data, to fileURL: URL, durable: Bool = true, excludedFromBackup: Bool = false) throws {
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            if durable { try handle.synchronize() }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        if excludedFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? temporary.setResourceValues(values)
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? manager.removeItem(at: temporary)
            throw POSIXError(code)
        }
    }

    /// The contents of `fileURL` when it is this user's own private regular
    /// file (no access for group or others), opened without following a
    /// link; nil when there is none or it cannot be read. `refused` runs
    /// when a file is there but is not such a file.
    static func contents(of fileURL: URL, refused: () -> Void = {}) -> Data? {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            refused()
            return nil
        }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return try? handle.readToEnd()
    }

    /// Moves a file this version cannot use out of the way of the next
    /// save, beside it: `<name>.<label>-<UTC time>.bak`, with a few random
    /// characters added when that name is taken
    /// (`WorkspaceStateStore.pruneSetAsideFiles` removes old ones). Returns
    /// where it went; throws the rename's error.
    @discardableResult
    static func setAside(_ fileURL: URL, label: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())
        let directory = fileURL.deletingLastPathComponent()
        var destination = directory.appendingPathComponent("\(fileURL.lastPathComponent).\(label)-\(stamp).bak")
        var status = stat()
        if lstat(destination.path, &status) == 0 {
            destination = directory.appendingPathComponent(
                "\(fileURL.lastPathComponent).\(label)-\(stamp)-\(UUID().uuidString.prefix(8)).bak"
            )
        }
        guard rename(fileURL.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        fputs("Cherry: \(fileURL.lastPathComponent) cannot be used by this version (\(label)); moved it to \(destination.lastPathComponent)\n", stderr)
        return destination
    }
}
