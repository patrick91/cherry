import Foundation

enum TerminalAttentionStudy {
    static let enabledDefaultsKey = "attentionStudy.enabled"
    static let maximumManagedBytes: Int64 = 500 * 1_024 * 1_024

    private static let preparationState = DirectoryPreparationState()

    static func configuredDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL? {
        if let value = environment[TerminalAttentionObservationRecorder.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            let path = NSString(string: value).expandingTildeInPath
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        guard defaults.bool(forKey: enabledDefaultsKey) else { return nil }
        return recordingsDirectoryURL(fileManager: fileManager)
    }

    static func recordingsDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Cherry", isDirectory: true)
            .appendingPathComponent("Attention Study", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func correctionsDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Cherry", isDirectory: true)
            .appendingPathComponent("Attention Study", isDirectory: true)
            .appendingPathComponent("Corrections", isDirectory: true)
    }

    static func prepareDirectoryIfNeeded(
        _ directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directoryURL.path
        )

        let managedPath = recordingsDirectoryURL(fileManager: fileManager).standardizedFileURL.path
        let requestedPath = directoryURL.standardizedFileURL.path
        guard requestedPath == managedPath, preparationState.claim(requestedPath) else { return }
        _ = try pruneRecordings(
            in: directoryURL,
            maximumBytes: maximumManagedBytes,
            fileManager: fileManager
        )
    }

    @discardableResult
    static func pruneRecordings(
        in directoryURL: URL,
        maximumBytes: Int64,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let candidates = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (url: URL, bytes: Int64, modifiedAt: Date)? in
                guard let values = try? url.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true
                else {
                    return nil
                }
                return (
                    url,
                    Int64(values.fileSize ?? 0),
                    values.contentModificationDate ?? .distantPast
                )
            }
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt < rhs.modifiedAt
                }
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }

        var totalBytes = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        var removed: [URL] = []
        for candidate in candidates where totalBytes > max(0, maximumBytes) {
            try fileManager.removeItem(at: candidate.url)
            totalBytes -= candidate.bytes
            removed.append(candidate.url)
        }
        return removed
    }
}

private final class DirectoryPreparationState: @unchecked Sendable {
    private let lock = NSLock()
    private var preparedPaths: Set<String> = []

    func claim(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return preparedPaths.insert(path).inserted
    }
}
