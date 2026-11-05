import Darwin
import Foundation

/// The phones paired with this Mac: the keys Cherry added to
/// `~/.ssh/authorized_keys`, each a line it wrote as
/// `<type> <key> cherry-mobile <phone's name>`. Cherry reads and removes
/// only those lines, keeps every other one as it is, and never writes
/// through a link (a file another tool manages, as home-manager's): it says
/// so with the line to add by hand.
struct AuthorizedPhoneKeys: Sendable {
    struct Phone: Identifiable, Equatable, Sendable {
        var name: String
        var key: SSHPublicKeyLine

        var id: String { key.base64 }
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The file is a link: `line` is what to add to where it points.
        case linked(destination: String, line: String)
        case unwritable(String, line: String)

        var errorDescription: String? {
            switch self {
            case .linked(let destination, _):
                "~/.ssh/authorized_keys is a link to \(destination), which another tool manages, so Cherry leaves it alone. Add this line there:"
            case .unwritable(let reason, _):
                "Cherry couldn't add the key to ~/.ssh/authorized_keys (\(reason)). Add this line yourself:"
            }
        }

        /// The line to add by hand.
        var line: String {
            switch self {
            case .linked(_, let line), .unwritable(_, let line): line
            }
        }
    }

    static let marker = "cherry-mobile"

    let file: URL

    init(file: URL) {
        self.file = file
    }

    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AuthorizedPhoneKeys {
        AuthorizedPhoneKeys(file: home.appendingPathComponent(".ssh/authorized_keys"))
    }

    /// The line Cherry writes for `key`: the phone's name on one line, at
    /// most 64 characters.
    static func line(for key: SSHPublicKeyLine, name: String) -> String {
        "\(key.line) \(marker) \(cleanName(name))"
    }

    static func cleanName(_ name: String) -> String {
        let single = name.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return single.isEmpty ? "iPhone" : String(single.prefix(64))
    }

    /// The phones Cherry added, in the file's order.
    func phones() -> [Phone] {
        lines().compactMap(Self.phone(in:))
    }

    /// Adds `key` for the phone `name`, unless the file has the key already
    /// (on any line).
    func add(_ key: SSHPublicKeyLine, name: String) throws {
        let line = Self.line(for: key, name: name)
        try rewrite(line: line) { lines in
            guard !lines.contains(where: { Self.fields(of: $0).contains(key.base64) }) else { return nil }
            return lines + [line]
        }
    }

    /// Removes the lines Cherry wrote for `phone`'s key.
    func remove(_ phone: Phone) throws {
        try rewrite(line: Self.line(for: phone.key, name: phone.name)) { lines in
            let kept = lines.filter { Self.phone(in: $0)?.key != phone.key }
            return kept.count == lines.count ? nil : kept
        }
    }

    // MARK: The file

    private func lines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private static func fields(of line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func phone(in line: String) -> Phone? {
        let fields = fields(of: line)
        guard fields.count >= 3, fields[2] == marker, let key = SSHPublicKeyLine(line) else { return nil }
        return Phone(name: fields.dropFirst(3).joined(separator: " "), key: key)
    }

    /// Writes the lines `change` makes of the file's (nil: nothing to
    /// change) to a file beside it, then renames it over the file, with the
    /// file's mode (0600 for a new one, in a `~/.ssh` made 0700).
    private func rewrite(line: String, _ change: ([String]) -> [String]?) throws {
        let directory = file.deletingLastPathComponent()
        var status = stat()
        if lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK {
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) ?? "another file"
            throw Failure.linked(destination: destination, line: line)
        }
        let exists = FileManager.default.fileExists(atPath: file.path)
        let mode = exists ? mode_t(status.st_mode & 0o777) : 0o600
        guard let changed = change(lines()) else { return }
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let temporary = directory.appendingPathComponent(".authorized_keys.cherry-\(UUID().uuidString)")
            let text = changed.joined(separator: "\n") + "\n"
            guard FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            guard rename(temporary.path, file.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: temporary)
                throw Failure.unwritable(reason, line: line)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unwritable(error.localizedDescription, line: line)
        }
    }
}
