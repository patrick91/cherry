import Darwin
import Foundation

/// The phones paired with this Mac: the keys Cherry added to
/// `~/.ssh/authorized_keys`, each a line it wrote as
/// `restrict,pty,command="'<cherry>' host mobile-gateway" <type> <key>
/// cherry-mobile <phone's name>`: sshd runs Cherry's gateway for whatever
/// the phone asks, which runs only what Cherry for iOS sends (Host's
/// `cherry-cli/src/gateway.rs`), with no forwarding. Cherry reads, limits
/// and removes only those lines (and the unlimited ones it wrote before,
/// `<type> <key> cherry-mobile <name>`), keeps every other one as it is, and
/// never writes through a link (a file another tool manages, as
/// home-manager's): it says so with the line to add by hand.
struct AuthorizedPhoneKeys: Sendable {
    struct Phone: Identifiable, Equatable, Sendable {
        var name: String
        var key: SSHPublicKeyLine
        /// Its line runs Cherry's gateway; false for a line Cherry wrote
        /// before it limited keys, which logs in like the user's own.
        var isLimited: Bool = true

        var id: String { key.base64 }
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The file is a link: `line` is what to add to where it points.
        case linked(destination: String, line: String)
        case unwritable(String, line: String)
        /// No `cherry` for the line to run (`TabCLIDirectory`), or one at a
        /// path a forced command can't quote.
        case noGateway

        var errorDescription: String? {
            switch self {
            case .linked(let destination, _):
                "~/.ssh/authorized_keys is a link to \(destination), which another tool manages, so Cherry leaves it alone. Add this line there:"
            case .unwritable(let reason, _):
                "Cherry couldn't add the key to ~/.ssh/authorized_keys (\(reason)). Add this line yourself:"
            case .noGateway:
                "Cherry couldn't find its cherry command, which your iPhone's key runs on this Mac to reach only Cherry's sessions, so it added nothing. Quit Cherry, open it again and try again."
            }
        }

        /// The line to add by hand.
        var line: String? {
            switch self {
            case .linked(_, let line), .unwritable(_, let line): line
            case .noGateway: nil
            }
        }
    }

    static let marker = "cherry-mobile"

    let file: URL
    /// The `cherry` a phone's key runs: an absolute path, nil when there is
    /// none.
    let gateway: @Sendable () -> String?

    init(file: URL, gateway: @escaping @Sendable () -> String?) {
        self.file = file
        self.gateway = gateway
    }

    /// The user's file, and the `cherry` link Cherry keeps in its
    /// Application Support folder, which stays put when the app moves or
    /// updates (each launch points it at the app's own).
    static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        gateway: @escaping @Sendable () -> String? = { TabCLIDirectory.current.map { "\($0)/\(TabCLIDirectory.linkName)" } }
    ) -> AuthorizedPhoneKeys {
        AuthorizedPhoneKeys(file: home.appendingPathComponent(".ssh/authorized_keys"), gateway: gateway)
    }

    /// The line Cherry writes for `key`: limited to the gateway at
    /// `gateway`, the phone's name on one line, at most 64 characters. Nil
    /// for a gateway path that is not absolute or that has a quote, a
    /// backslash or a control character (the forced command quotes it).
    static func line(for key: SSHPublicKeyLine, name: String, gateway: String?) -> String? {
        guard let gateway, gateway.hasPrefix("/"),
              !gateway.unicodeScalars.contains(where: { "'\"\\".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return "restrict,pty,command=\"'\(gateway)' host mobile-gateway\" \(key.line) \(marker) \(cleanName(name))"
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
        (lines() ?? []).compactMap(Self.phone(in:))
    }

    /// Adds `key` for the phone `name`, limited to the gateway: replaces a
    /// line Cherry wrote for it (limiting one written before, renaming
    /// it), and leaves a line of the user's that has it alone.
    func add(_ key: SSHPublicKeyLine, name: String) throws {
        guard let line = Self.line(for: key, name: name, gateway: gateway()) else { throw Failure.noGateway }
        try rewrite(line: line) { lines in
            if let index = lines.firstIndex(where: { Self.phone(in: $0)?.key == key }) {
                var changed = lines
                changed[index] = line
                // Another line of Cherry's for the key (written by hand
                // twice, say) would let it in unlimited.
                changed = changed.enumerated().filter { $0.offset == index || Self.phone(in: $0.element)?.key != key }.map(\.element)
                return changed == lines ? nil : changed
            }
            guard !lines.contains(where: { Self.fields(of: $0).contains(key.base64) }) else { return nil }
            return lines + [line]
        }
    }

    /// Limits `phone`'s line, written before Cherry limited keys, to the
    /// gateway.
    func limit(_ phone: Phone) throws {
        try add(phone.key, name: phone.name)
    }

    /// Removes the lines Cherry wrote for `phone`'s key.
    func remove(_ phone: Phone) throws {
        let line = Self.line(for: phone.key, name: phone.name, gateway: gateway()) ?? "\(phone.key.line) \(Self.marker) \(phone.name)"
        try rewrite(line: line) { lines in
            let kept = lines.filter { Self.phone(in: $0)?.key != phone.key }
            return kept.count == lines.count ? nil : kept
        }
    }

    // MARK: The file

    /// The file's lines, blank and comment lines included; none for no
    /// file, nil for one that can't be read as UTF-8 text.
    private func lines() -> [String]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func fields(of line: Substring) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func fields(of line: String) -> [String] {
        fields(of: line[...])
    }

    /// A line's options (sshd's `restrict,command="…"` before the key's
    /// type; nil when it starts with the type) and the rest.
    static func options(of line: String) -> (options: String?, rest: Substring) {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") || trimmed.hasPrefix("sk-") {
            return (nil, trimmed)
        }
        var quoted = false
        var escaped = false
        var end = trimmed.endIndex
        for index in trimmed.indices {
            let character = trimmed[index]
            if escaped {
                escaped = false
            } else if quoted, character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == " " || character == "\t" {
                end = index
                break
            }
        }
        let rest = trimmed[end...].drop { $0 == " " || $0 == "\t" }
        return (String(trimmed[..<end]), rest)
    }

    /// Whether `options` are the ones Cherry writes for its gateway.
    private static func runsGateway(_ options: String) -> Bool {
        options.hasPrefix("restrict,pty,command=\"") && options.hasSuffix(" host mobile-gateway\"")
    }

    private static func phone(in line: String) -> Phone? {
        let (options, rest) = options(of: line)
        let fields = fields(of: rest)
        guard fields.count >= 3, fields[2] == marker, let key = SSHPublicKeyLine(String(rest)) else { return nil }
        return Phone(
            name: fields.dropFirst(3).joined(separator: " "),
            key: key,
            isLimited: options.map(runsGateway) ?? false
        )
    }

    /// Writes the lines `change` makes of the file's (nil: nothing to
    /// change) to a file beside it, then renames it over the file, with the
    /// file's mode (0600 for a new one, in a `~/.ssh` made 0700). A file
    /// that isn't UTF-8 text is left alone.
    private func rewrite(line: String, _ change: ([String]) -> [String]?) throws {
        let directory = file.deletingLastPathComponent()
        var status = stat()
        if lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK {
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) ?? "another file"
            throw Failure.linked(destination: destination, line: line)
        }
        let exists = FileManager.default.fileExists(atPath: file.path)
        let mode = exists ? mode_t(status.st_mode & 0o777) : 0o600
        guard let lines = lines() else { throw Failure.unwritable("it isn't UTF-8 text", line: line) }
        guard let changed = change(lines) else { return }
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
