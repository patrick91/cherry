import CryptoKit
import Foundation

public struct CherryDeepLink: Codable, Equatable, Sendable {
    public enum TargetKind: String, Codable, Equatable, Sendable {
        case note
        case todo
        case terminal
    }

    public static let scheme = "cherry"
    public static let host = "project"

    public let projectKey: String
    public let kind: TargetKind
    public let targetID: String

    public init(projectKey: String, kind: TargetKind, targetID: String) {
        self.projectKey = projectKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.kind = kind
        self.targetID = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(projectRoot: String, kind: TargetKind, targetID: String) {
        self.init(projectKey: Self.projectKey(forProjectRoot: projectRoot), kind: kind, targetID: targetID)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/\(projectKey)/\(kind.rawValue)/\(targetID)"
        return components.url ?? URL(string: "\(Self.scheme)://\(Self.host)/\(projectKey)/\(kind.rawValue)/\(targetID)")!
    }

    public var absoluteString: String {
        url.absoluteString
    }

    public static func noteURL(projectRoot: String, noteID: UUID) -> String {
        CherryDeepLink(projectRoot: projectRoot, kind: .note, targetID: noteID.uuidString).absoluteString
    }

    public static func todoURL(projectRoot: String, todoID: UUID) -> String {
        CherryDeepLink(projectRoot: projectRoot, kind: .todo, targetID: todoID.uuidString).absoluteString
    }

    public static func terminalURL(projectRoot: String, terminalID: UUID) -> String {
        CherryDeepLink(projectRoot: projectRoot, kind: .terminal, targetID: terminalID.uuidString).absoluteString
    }

    public static func projectKey(forProjectRoot projectRoot: String) -> String {
        let path = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func parse(_ value: String) throws -> CherryDeepLink {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host
        else {
            throw CherryControlError(code: "invalid_deep_link", message: "Cherry link must start with cherry://project/.")
        }

        let pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pathComponents.count == 3 else {
            throw CherryControlError(code: "invalid_deep_link", message: "Cherry link path must be /<project-key>/<kind>/<id>.")
        }

        let projectKey = pathComponents[0].lowercased()
        guard projectKey.count == 64,
              projectKey.allSatisfy({ $0.isHexDigit })
        else {
            throw CherryControlError(code: "invalid_project_key", message: "Cherry link project key is not a SHA-256 hex digest.")
        }

        guard let kind = TargetKind(rawValue: pathComponents[1].lowercased()) else {
            throw CherryControlError(code: "invalid_deep_link_kind", message: "Cherry link kind must be note, todo, or terminal.")
        }

        let targetID = pathComponents[2]
        guard !targetID.isEmpty else {
            throw CherryControlError(code: "invalid_deep_link_id", message: "Cherry link target id is empty.")
        }

        return CherryDeepLink(projectKey: projectKey, kind: kind, targetID: targetID)
    }
}
