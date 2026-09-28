import Foundation

/// Where a project lives (docs/specs/remote-devices.md): on This Mac, or on
/// one of the user's other Macs (a device) that runs its tabs over SSH.
///
/// Its `key` identifies the project everywhere a project is keyed (window
/// registry, saved workspace state, notes, todos, deep links, settings):
/// a local project's key is its path, unchanged, and a remote one's is
/// `device:<lowercased device UUID>:<absolute path>`. A remote key is never
/// a local path: only launch and remote-command code uses its `path`.
public enum ProjectLocation: Hashable, Sendable {
    case local(path: String)
    case remote(deviceID: UUID, path: String)

    public static let remoteKeyPrefix = "device:"

    /// The location a key names: a remote key (`device:<uuid>:/path`), or
    /// else a local path (any other string, as local keys always were).
    public init(key: String) {
        self = Self.remote(fromKey: key) ?? .local(path: key)
    }

    /// Whether `key` names a project on another Mac.
    public static func isRemoteKey(_ key: String) -> Bool {
        remote(fromKey: key) != nil
    }

    /// The path a key's tabs start in on the machine that runs them: a
    /// remote key's path, or a local key as it is.
    public static func launchPath(forKey key: String) -> String {
        ProjectLocation(key: key).path
    }

    public var key: String {
        switch self {
        case .local(let path):
            path
        case .remote(let deviceID, let path):
            "\(Self.remoteKeyPrefix)\(deviceID.uuidString.lowercased()):\(Self.normalizedRemotePath(path))"
        }
    }

    /// The path on the machine that has the project.
    public var path: String {
        switch self {
        case .local(let path): path
        case .remote(_, let path): Self.normalizedRemotePath(path)
        }
    }

    public var deviceID: UUID? {
        if case .remote(let deviceID, _) = self { return deviceID }
        return nil
    }

    public var isRemote: Bool { deviceID != nil }

    /// `device:<uuid>:<absolute path>`, nil for anything else.
    private static func remote(fromKey key: String) -> ProjectLocation? {
        guard key.hasPrefix(remoteKeyPrefix) else { return nil }
        let rest = key.dropFirst(remoteKeyPrefix.count)
        guard let separator = rest.firstIndex(of: ":"),
              let deviceID = UUID(uuidString: String(rest[..<separator]))
        else { return nil }
        let path = String(rest[rest.index(after: separator)...])
        guard path.hasPrefix("/") else { return nil }
        return .remote(deviceID: deviceID, path: path)
    }

    /// An absolute remote path without a trailing slash (except `/`) or
    /// empty components; `.` and `..` are left alone (the remote machine
    /// resolves them, and symlinks may make `..` mean something else).
    private static func normalizedRemotePath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + components.joined(separator: "/")
    }
}
