import AppKit
import CherryControl
import Foundation

// Files pasted or dropped on a tab whose program runs on another Mac
// (docs/specs/remote-devices.md, phase 3). This Mac's paths mean nothing
// there, so instead of inserting them Cherry asks, copies the files to that
// Mac (scp over the device's SSH master, into a new temporary folder there)
// and inserts the paths they have there.

/// The files of a paste or drop, and what is inserted for them.
enum RemoteFileDrop {
    /// This Mac's files a paste or drop carries: its file URLs, or an image
    /// with no text (a screenshot), written to a file first. Nil when it is
    /// text (pasted as usual) or nothing Cherry copies.
    static func localFiles(
        from pasteboard: NSPasteboard,
        preferringText: Bool,
        imageDirectory: URL = TerminalPasteboardContent.defaultImageDirectory
    ) -> [URL]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map(\.standardizedFileURL)
        }
        if preferringText, let text = pasteboard.string(forType: .string), !text.isEmpty { return nil }
        if pasteboard.string(forType: .string)?.isEmpty == false { return nil }
        return TerminalPasteboardContent.pastedImageFileURL(from: pasteboard, imageDirectory: imageDirectory).map { [$0] }
    }

    /// The paths inserted: each escaped for a shell (and the agents' input
    /// parsing), separated and followed by a space, as a drop inserts them.
    static func insertionText(remotePaths: [String]) -> String {
        remotePaths.map(escaped).joined(separator: " ") + " "
    }

    /// A simple path as it is; anything else single-quoted.
    static func escaped(_ path: String) -> String {
        let isSimple = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-~+,@".contains($0) }
        return isSimple ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What the question says, and its button.
    struct Question: Equatable {
        let title: String
        let message: String
        let confirmTitle: String

        init(files: [URL], machine: String) {
            let what = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) files"
            title = "Copy \(what) to \(machine)?"
            message = "This tab runs on \(machine), which cannot open files on this Mac, so Cherry does not insert their paths here. It can copy \(files.count == 1 ? "it" : "them") to a new temporary folder on \(machine) and insert the \(files.count == 1 ? "path it has" : "paths they have") there."
            confirmTitle = "Copy to \(machine)"
        }
    }
}

/// Copies files to a device: a new temporary folder there (`mktemp -d`),
/// then `scp -O` (the scp protocol, which any sshd serves) over its SSH
/// master while that is up, else its own BatchMode ssh.
struct RemoteFileCopier: Sendable {
    var shell: RemoteDeviceShell
    var destination: String
    var machine: String
    var scpExecutable = "/usr/bin/scp"
    var timeout: TimeInterval = 600

    static let folderMarker = "CHERRY-DROP-DIR="

    /// The script that makes the folder there and prints it.
    static let folderScript = """
    dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cherry-drop.XXXXXX") || exit 1
    printf '\(folderMarker)%s\\n' "$dir"

    """

    /// scp's arguments: legacy protocol, recursive, quiet, batch, through
    /// `ssh` (with the master's control path when up), the files, then
    /// `destination:'folder/'`.
    /// The ssh options are those of the CLI and `RemoteDeviceShell`: no
    /// master of its own, no remote or local command, no forwarding,
    /// BatchMode, and the device's master's control path while it is up.
    static func scpArguments(files: [URL], folder: String, destination: String, ssh: String, controlPath: String?) -> [String] {
        var arguments = ["-O", "-r", "-q", "-B", "-S", ssh, "-o", "ControlMaster=no"]
        if let controlPath { arguments += ["-o", HostSSHMasterManager.controlPathOption(controlPath)] }
        arguments += [
            "-o", "RemoteCommand=none",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "--",
        ]
        arguments += files.map(\.path)
        // The scp protocol hands the target to the remote shell.
        arguments.append("\(destination):" + RemoteDeviceProbe.singleQuoted(folder + "/"))
        return arguments
    }

    /// Copies `files` there; returns the path each has there.
    func copy(_ files: [URL]) async throws -> [String] {
        let made = await shell.run(Self.folderScript, on: destination)
        guard let line = made.standardOutput.split(separator: "\n").first(where: { $0.hasPrefix(Self.folderMarker) }),
              case let folder = String(line.dropFirst(Self.folderMarker.count)), folder.hasPrefix("/")
        else {
            if made.status == 255 {
                throw HostedSessionError.message("Could not reach \(machine): \(RemoteDeviceSSHFailure.classify(made.standardError, timedOut: made.timedOut).message)")
            }
            throw HostedSessionError.message("Could not make a folder on \(machine) for the files: \(made.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let scp = scpExecutable
        let environment = shell.environment
        let timeout = timeout
        let run: @Sendable (String?) async -> (status: Int32, errors: String) = { [files, destination, ssh = shell.sshExecutable] controlPath in
            let arguments = Self.scpArguments(files: files, folder: folder, destination: destination, ssh: ssh, controlPath: controlPath)
            return await Task.detached(priority: .userInitiated) {
                Self.run(scp, arguments, environment: environment, timeout: timeout)
            }.value
        }
        var result = await run(shell.controlPath)
        if shell.controlPath != nil, result.status != 0, RemoteDeviceShell.isRefusedByMaster(result.errors) {
            // The master has no session to spare: directly, as the CLI does.
            result = await run(nil)
        }
        guard result.status == 0 else {
            throw HostedSessionError.message("Could not copy the files to \(machine): \(result.errors.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return files.map { "\(folder)/\($0.lastPathComponent)" }
    }

    private static func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> (status: Int32, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return (127, "Could not run scp: \(error.localizedDescription)")
        }
        let box = DropOutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: box.data, as: UTF8.self))
    }
}

private final class DropOutputBox: @unchecked Sendable {
    var data = Data()
}

/// Asks about files pasted or dropped on a device's tab, copies them there
/// when asked to, and inserts their paths there.
@MainActor
enum RemoteFileDropCoordinator {
    /// Shows the question (on `window`, else app-modal) and reports whether
    /// the copy was confirmed.
    typealias Asker = @MainActor (RemoteFileDrop.Question, NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void

    /// Test seams: the question, the copier.
    static var ask: Asker = presentQuestion
    static var makeCopier: @MainActor (RemoteDevice) async -> RemoteFileCopier = { device in
        var shell = await RemoteDeviceShell.app()
        shell.controlPath = HostSSHMasterManager.shared.controlPathIfUp(for: device.sshDestination)
        return RemoteFileCopier(shell: shell, destination: device.sshDestination, machine: device.name)
    }
    static var device: @MainActor (HostedSessionHost) -> RemoteDevice? = { host in
        RemoteDeviceStore.shared.devices.first { $0.host == host }
    }

    /// Whether `session`'s paste or drop of `pasteboard` is for this: a tab
    /// of another Mac, with files. Then it asks, and copies and inserts
    /// (`insert`) when confirmed; true either way (nothing is inserted
    /// meanwhile).
    @discardableResult
    static func handle(
        _ pasteboard: NSPasteboard,
        for session: TerminalSession,
        isPaste: Bool,
        window: NSWindow?,
        insert: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard let hosting = session.persistentHosting, !hosting.profile.isThisMac,
              let files = RemoteFileDrop.localFiles(from: pasteboard, preferringText: isPaste)
        else { return false }
        let machine = hosting.profile.displayName
        let host = hosting.profile.host
        ask(RemoteFileDrop.Question(files: files, machine: machine), window) { confirmed in
            guard confirmed else { return }
            Task { @MainActor in
                guard let device = device(host) else { return }
                do {
                    let paths = try await makeCopier(device).copy(files)
                    insert(RemoteFileDrop.insertionText(remotePaths: paths))
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "The files were not copied to \(machine)"
                    alert.informativeText = error.localizedDescription
                    if let window {
                        alert.beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
        return true
    }

    static let presentQuestion: Asker = { question, window, answer in
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: question.confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if let window {
            RemoteViewCrashGuard.installIfNeeded()
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(response == .alertFirstButtonReturn) }
            }
        } else {
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
