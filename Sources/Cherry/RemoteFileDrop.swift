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
    /// What a paste or drop on a device's tab carries that Cherry copies
    /// there: This Mac's files, or an image with no text (a screenshot).
    enum Content: Equatable {
        case files([URL])
        /// The image, as PNG.
        case image(Data)
    }

    /// Its files or image; nil when it is text (pasted as usual) or
    /// nothing Cherry copies. File URLs win over the text that comes with
    /// them (Finder puts their names on the pasteboard too); an image is
    /// copied only when there is no text.
    static func content(from pasteboard: NSPasteboard, preferringText: Bool) -> Content? {
        switch PastedContent(pasteboard: pasteboard) {
        case .files(let urls): return .files(urls)
        case .image(let png): return .image(png)
        case .text, .nothing: return nil
        }
    }

    /// This Mac's files a paste or drop carries: its file URLs, or its
    /// image written to a file (`PastedImageStore`) first. Nil when it is
    /// text or nothing Cherry copies.
    static func localFiles(
        from pasteboard: NSPasteboard,
        preferringText: Bool,
        imageDirectory: URL = TerminalPasteboardContent.defaultImageDirectory
    ) -> [URL]? {
        switch content(from: pasteboard, preferringText: preferringText) {
        case .files(let urls): return urls
        case .image(let png): return (try? PastedImageStore.save(png, in: imageDirectory)).map { [$0] }
        case nil: return nil
        }
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
/// when asked to, and inserts their paths there. An image pasted or dropped
/// (image data, not a file of the user's) is copied without asking.
@MainActor
enum RemoteFileDropCoordinator {
    /// Shows the question (on `window`, else app-modal) and reports whether
    /// the copy was confirmed.
    typealias Asker = @MainActor (RemoteFileDrop.Question, NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void

    /// Test seams: the question, the copier, where a pasted image is
    /// written, and how a failed copy is reported.
    static var ask: Asker = presentQuestion
    static var makeCopier: @MainActor (RemoteDevice) async -> RemoteFileCopier = { device in
        var shell = await RemoteDeviceShell.app()
        shell.controlPath = HostSSHMasterManager.shared.controlPathIfUp(for: device.sshDestination)
        return RemoteFileCopier(shell: shell, destination: device.sshDestination, machine: device.name)
    }
    static var device: @MainActor (HostedSessionHost) -> RemoteDevice? = { host in
        RemoteDeviceStore.shared.devices.first { $0.host == host }
    }
    static var imageDirectory: @MainActor () -> URL = { PastedImageStore.defaultDirectory }
    static var reportFailure: @MainActor (_ title: String, _ message: String, NSWindow?) -> Void = presentFailure
    /// The latest copy under way (tests wait for it).
    private(set) static var lastCopy: Task<Void, Never>?

    /// Whether `session`'s paste or drop of `pasteboard` is for this: a tab
    /// of another Mac, with files or an image. Then it asks (not for an
    /// image), and copies and inserts (`insert`) when confirmed; true
    /// either way (nothing is inserted meanwhile). A pasted image's path is
    /// inserted as a paste of This Mac's image is (the path alone); dropped
    /// files and images as a drop inserts paths (each followed by a space).
    @discardableResult
    static func handle(
        _ pasteboard: NSPasteboard,
        for session: TerminalSession,
        isPaste: Bool,
        window: NSWindow?,
        insert: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard let hosting = session.persistentHosting, !hosting.profile.isThisMac,
              let content = RemoteFileDrop.content(from: pasteboard, preferringText: isPaste)
        else { return false }
        let machine = hosting.profile.displayName
        let host = hosting.profile.host
        switch content {
        case .files(let files):
            ask(RemoteFileDrop.Question(files: files, machine: machine), window) { confirmed in
                guard confirmed else { return }
                copy(files, to: host, machine: machine, window: window, what: "The files were") { paths in
                    insert(RemoteFileDrop.insertionText(remotePaths: paths))
                }
            }
        case .image(let png):
            guard let file = try? PastedImageStore.save(png, in: imageDirectory()) else { return false }
            copy([file], to: host, machine: machine, window: window, what: "The image was") { paths in
                insert(isPaste ? PastedImage.quoted(paths[0]) : RemoteFileDrop.insertionText(remotePaths: paths))
            }
        }
        return true
    }

    private static func copy(
        _ files: [URL],
        to host: HostedSessionHost,
        machine: String,
        window: NSWindow?,
        what: String,
        then insert: @escaping @MainActor ([String]) -> Void
    ) {
        lastCopy = Task { @MainActor in
            guard let device = device(host) else {
                reportFailure("\(what) not copied to \(machine)", "Cherry no longer knows that Mac.", window)
                return
            }
            do {
                insert(try await makeCopier(device).copy(files))
            } catch {
                reportFailure("\(what) not copied to \(machine)", error.localizedDescription, window)
            }
        }
    }

    static let presentFailure: @MainActor (String, String, NSWindow?) -> Void = { title, message, window in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
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

// MARK: - Ctrl+V of an image in an agent tab of another Mac

/// Puts a PNG already copied to a device on that Mac's clipboard, over its
/// ssh: `osascript -e 'set the clipboard to (read (POSIX file "…") as
/// «class PNGf»)'`, then checks the clipboard holds a PNG. That works only
/// while the user has a GUI session there; otherwise osascript fails, and
/// the reason is reported.
struct RemoteClipboardSetter: Sendable {
    var shell: RemoteDeviceShell
    var destination: String
    var machine: String

    enum Outcome: Equatable, Sendable {
        case set
        case failed(String)
    }

    static let marker = "CHERRY-CLIPBOARD="

    /// AppleScript's string literal for `text`.
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The script (`sh -s` there). `osascript` is the one on that Mac's
    /// PATH (/usr/bin's on a Mac; a test's stand-in on the fake one).
    static func script(path: String) -> String {
        let set = "set the clipboard to (read (POSIX file \(appleScriptString(path))) as «class PNGf»)"
        let check = "clipboard info for «class PNGf»"
        return [
            "LC_ALL=en_US.UTF-8",
            "export LC_ALL",
            "if ! command -v osascript >/dev/null 2>&1; then printf '%s%s\\n' '\(marker)failed ' 'osascript was not found'; exit 0; fi",
            "if err=$(osascript -e \(RemoteDeviceProbe.singleQuoted(set)) 2>&1 >/dev/null); then",
            "  info=$(osascript -e \(RemoteDeviceProbe.singleQuoted(check)) 2>/dev/null)",
            "  case \"$info\" in",
            "    *PNGf*) printf '%s\\n' '\(marker)ok' ;;",
            "    *) printf '%s%s\\n' '\(marker)failed ' 'the clipboard there did not keep the image' ;;",
            "  esac",
            "else",
            "  err=$(printf '%s' \"$err\" | tr '\\n' ' ')",
            "  printf '%s%s\\n' '\(marker)failed ' \"${err:-osascript failed}\"",
            "fi",
        ].joined(separator: "\n") + "\n"
    }

    static func outcome(of output: RemoteDeviceShell.Output, machine: String) -> Outcome {
        guard let line = output.standardOutput.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else {
            if output.status == 255 || output.timedOut {
                return .failed("Could not reach \(machine): \(RemoteDeviceSSHFailure.classify(output.standardError, timedOut: output.timedOut).message)")
            }
            return .failed(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "exit \(output.status)")
        }
        let value = line.dropFirst(marker.count)
        if value == "ok" { return .set }
        let reason = value.hasPrefix("failed ") ? String(value.dropFirst("failed ".count)) : String(value)
        return .failed(reason.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "osascript failed")
    }

    func setClipboard(toPNGAt path: String) async -> Outcome {
        Self.outcome(of: await shell.run(Self.script(path: path), on: destination), machine: machine)
    }
}

/// Ctrl+V in an agent tab of another Mac when This Mac's pasteboard has an
/// image (and no text or files): Claude Code reads the clipboard of the Mac
/// it runs on, so Cherry copies the image there (`RemoteFileCopier`), puts
/// it on that Mac's clipboard (`RemoteClipboardSetter`) and then sends the
/// Ctrl+V. The key is never lost: when the copy fails or takes longer than
/// `deadline`, Ctrl+V goes on anyway with a toast saying why; when only the
/// clipboard there cannot be set (nobody logged in there, no osascript),
/// the copy's path is pasted instead, with a toast. Keys typed meanwhile
/// are held and sent after it, in order (`holdsKeys`, `hold`). It applies
/// only while the agent itself is in the foreground there (not an editor
/// it opened in its own terminal).
@MainActor
enum RemoteClipboardImagePaste {
    static var makeSetter: @MainActor (RemoteDevice) async -> RemoteClipboardSetter = { device in
        var shell = await RemoteDeviceShell.app()
        shell.controlPath = HostSSHMasterManager.shared.controlPathIfUp(for: device.sshDestination)
        return RemoteClipboardSetter(shell: shell, destination: device.sshDestination, machine: device.name)
    }
    static var showToast: @MainActor (ProjectWindowToast, NSWindow?) -> Void = { toast, window in
        guard let window, let chromeState = ProjectWindowRegistry.shared.chromeState(for: window) else { return }
        chromeState.toasts.show(toast)
    }
    /// How long the copy and the clipboard may take before Ctrl+V goes on
    /// without them.
    static var deadline: TimeInterval = 15
    /// The latest paste under way (tests wait for it).
    private(set) static var lastPaste: Task<Void, Never>?

    /// A paste under way in a tab: the keys typed meanwhile, and how to send
    /// the outcome and replay them.
    private struct InFlight {
        let token: UUID
        var held: [NSEvent] = []
        let sendControlV: @MainActor () -> Void
        let insert: @MainActor (String) -> Void
        let replay: @MainActor (NSEvent) -> Void
        let window: NSWindow?
    }
    private static var inFlight: [UUID: InFlight] = [:]

    /// Whether the program in front of the session there is the agent
    /// itself: its process group's leader is named after a known agent
    /// (`claude`, `codex`, …), or, in an agent tab, is the tab's own
    /// program (the agent it runs).
    static func foregroundIsAgent(_ info: HostedSessionInfo?, kind: TerminalSession.SessionKind) -> Bool {
        guard let info, info.isRunning, let foreground = info.foreground else { return false }
        if AgentToolBrand.detect(name: foreground.name) != nil { return true }
        return kind == .agent && info.pid == foreground.pid
    }

    /// Whether Ctrl+V in `session` is this: a tab of another Mac whose
    /// agent (an agent tab, or one whose agent Cherry recognised) is in the
    /// foreground there.
    static func applies(to session: TerminalSession) -> Bool {
        guard let hosting = session.persistentHosting, !hosting.profile.isThisMac,
              session.kind == .agent || session.agentName != nil || session.agentActivityState != .unknown
        else { return false }
        return foregroundIsAgent(session.hostReportedSession, kind: session.kind)
    }

    /// Whether keys typed into the tab are held now (a paste is under way).
    static func holdsKeys(for sessionID: UUID) -> Bool {
        inFlight[sessionID] != nil
    }

    /// Holds a key typed into the tab while its paste is under way; it is
    /// sent after the paste's Ctrl+V (or path).
    static func hold(_ event: NSEvent, for sessionID: UUID) {
        inFlight[sessionID]?.held.append(event)
    }

    /// The toast when the clipboard there could not be set.
    static func fallbackToast(machine: String, reason: String) -> ProjectWindowToast {
        ProjectWindowToast(
            title: "Pasted the image’s path on \(machine)",
            message: "The agent reads the clipboard of \(machine), and Cherry could not put the image there (\(reason)); it copied the image to \(machine) and pasted its path instead.",
            action: nil
        )
    }

    /// The toast when the image did not reach that Mac (Ctrl+V went on).
    static func notCopiedToast(machine: String, reason: String) -> ProjectWindowToast {
        ProjectWindowToast(
            title: "The image was not copied to \(machine)",
            message: "Ctrl+V went on as it is: \(reason)",
            action: nil
        )
    }

    private enum Outcome {
        case controlV
        case path(String)
    }

    /// Takes the Ctrl+V when it applies and the pasteboard holds an image
    /// alone; `sendControlV` then sends the key on, `insert` pastes the
    /// fallback's path, `replay` sends a key held meanwhile. False otherwise
    /// (the key goes on as it is).
    @discardableResult
    static func handle(
        _ pasteboard: NSPasteboard,
        for session: TerminalSession,
        window: NSWindow?,
        sendControlV: @escaping @MainActor () -> Void,
        insert: @escaping @MainActor (String) -> Void,
        replay: @escaping @MainActor (NSEvent) -> Void = { _ in }
    ) -> Bool {
        guard inFlight[session.id] == nil, applies(to: session), let hosting = session.persistentHosting,
              let png = PastedContent(pasteboard: pasteboard).image,
              let file = try? PastedImageStore.save(png, in: RemoteFileDropCoordinator.imageDirectory())
        else { return false }
        let machine = hosting.profile.displayName
        let host = hosting.profile.host
        let id = session.id
        let token = UUID()
        inFlight[id] = InFlight(token: token, sendControlV: sendControlV, insert: insert, replay: replay, window: window)
        let deadline = deadline
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(deadline))
            finish(id, token: token, .controlV, toast: notCopiedToast(machine: machine, reason: "it took longer than \(Int(deadline)) seconds."))
        }
        lastPaste = Task { @MainActor in
            guard let device = RemoteFileDropCoordinator.device(host) else {
                finish(id, token: token, .controlV, toast: notCopiedToast(machine: machine, reason: "Cherry no longer knows that Mac."))
                return
            }
            let path: String
            do {
                path = try await RemoteFileDropCoordinator.makeCopier(device).copy([file])[0]
            } catch {
                finish(id, token: token, .controlV, toast: notCopiedToast(machine: machine, reason: error.localizedDescription))
                return
            }
            switch await makeSetter(device).setClipboard(toPNGAt: path) {
            case .set:
                finish(id, token: token, .controlV, toast: nil)
            case .failed(let reason):
                finish(id, token: token, .path(PastedImage.quoted(path)), toast: fallbackToast(machine: machine, reason: reason))
            }
        }
        return true
    }

    /// Sends the outcome, then the keys held meanwhile, once per paste
    /// (the deadline and the paste race).
    private static func finish(_ id: UUID, token: UUID, _ outcome: Outcome, toast: ProjectWindowToast?) {
        guard let entry = inFlight[id], entry.token == token else { return }
        inFlight[id] = nil
        switch outcome {
        case .controlV: entry.sendControlV()
        case .path(let text): entry.insert(text)
        }
        for event in entry.held { entry.replay(event) }
        if let toast { showToast(toast, entry.window) }
    }
}
