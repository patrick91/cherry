import CherryControl
import Foundation
import os

/// The directory at the front of every This Mac tab's PATH that holds only
/// `cherry`, a link to the app's own (`ShellProcessController.appCLIPath`):
/// `<identity's Application Support>/bin` (docs/specs/agent-cli.md, PATH).
///
/// Agents type `cherry`, never `"$CHERRY_CLI"`: Codex's command rules and
/// Claude Code's `Bash(cherry …)` rules match a command's first word, which
/// an absolute path is not. The app's `Contents/MacOS`, which Ghostty puts
/// on PATH too, comes last and holds the app itself (`Cherry`, the same name
/// as `cherry` on a case-insensitive volume), so it cannot be the one.
///
/// Tabs get it as `CHERRY_BIN_DIR`, prepended to their PATH; Cherry's zsh
/// bootstrap prepends it again after the user's startup files, which may
/// set PATH from scratch (path_helper, nix-darwin). A device's commands and
/// agents get their install's directory instead (`RemoteLaunchSpec`).
enum TabCLIDirectory {
    static let environmentKey = "CHERRY_BIN_DIR"
    static let linkName = "cherry"

    private static let storage = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The directory tabs get, once the app prepared it (`prepare`). Nil in
    /// tests and when this copy has no `cherry` (none is set up then).
    static var current: String? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// `<identity's Application Support>/bin`.
    static func directory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        CherryAppIdentity.applicationSupportDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// Makes `directory/cherry` a link to `cliPath` (only when `canWrite`:
    /// the instance-lock holder), and says whether tabs can use the
    /// directory: its `cherry` runs. Another copy of the app uses what the
    /// holder made. Only a link is ever replaced: a file of another kind
    /// named `cherry` there is left alone, and the directory is not used.
    static func prepare(
        cliPath: String?,
        directory: URL,
        canWrite: Bool,
        fileManager: FileManager = .default
    ) -> String? {
        let link = directory.appendingPathComponent(linkName, isDirectory: false)
        if canWrite, let cliPath, !cliPath.isEmpty {
            let existing = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
            if existing != cliPath {
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    if existing != nil {
                        try fileManager.removeItem(at: link)
                    }
                    try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: cliPath)
                } catch {
                    // A regular file named cherry, or no permission: the
                    // check below decides.
                }
            }
        }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil,
              fileManager.isExecutableFile(atPath: link.path)
        else { return nil }
        return directory.path
    }

    /// `path` with `directory` first, once.
    static func prepending(_ directory: String, to path: String?) -> String {
        let rest = (path ?? "").split(separator: ":", omittingEmptySubsequences: false)
            .filter { $0 != Substring(directory) && !$0.isEmpty }
        return ([directory] + rest.map(String.init)).joined(separator: ":")
    }
}
