import AppKit
import CherryControl
import Foundation

// MARK: - preview_files (`cherry preview PATH…`)
//
// An agent shows the user files of its own Mac in Quick View: This Mac's
// for a tab here, the device's for a tab of another Mac (its token's tab;
// it can name no file of This Mac). Each path is found as a ⌘-click finds
// one (`QuickViewLink`: relative paths from the caller's directory, then
// its tab's directory and project; `path:LINE`), and Cherry answers which
// were found. Then a toast in the caller's window ("Codex shared
// preview.png", View) opens them, or, with `open`, the panel opens at once.

/// Files an agent shared, as `CherryControlServer.previewPresenter` shows
/// them.
@MainActor
struct QuickViewShare {
    /// One per file found, in the order asked.
    let requests: [QuickViewRequest]
    let source: QuickViewFileSource
    /// The caller's tab's name ("Codex"), or "An agent".
    let sharer: String
    let message: String?
    let open: Bool
    /// The caller's window, else the active one.
    let window: NSWindow?

    /// "preview.png", or "3 files".
    var what: String {
        if requests.count == 1, let path = requests[0].candidates.first?.path {
            return (path as NSString).lastPathComponent
        }
        return "\(requests.count) files"
    }

    /// The toast that offers them: "Codex shared preview.png", View.
    func toast(view: @escaping @MainActor () -> Void) -> ProjectWindowToast {
        ProjectWindowToast(
            name: sharer,
            predicate: " shared \(what)",
            message: message,
            action: .init(title: "View", perform: view),
            pausesWhileUnattended: true,
            symbolName: "eye.circle.fill"
        )
    }

    /// The app's: the panel at once when asked or when there is no window
    /// to put a toast in (true; it comes forward without taking the
    /// keyboard from what the user is typing in), else the toast (false),
    /// whose View is the user's own click.
    static func present(_ share: QuickViewShare) -> Bool {
        let show: @MainActor (Bool) -> Void = { takesKeyboard in
            QuickViewPanelController.shared.show(
                share.requests, source: share.source, from: share.window, takesKeyboard: takesKeyboard
            )
        }
        guard !share.open, let window = share.window,
              let chromeState = ProjectWindowRegistry.shared.chromeState(for: window)
        else {
            show(false)
            return true
        }
        chromeState.toasts.show(share.toast { show(true) })
        return false
    }
}

extension CherryControlServer {
    /// The most paths one preview takes.
    static let maximumPreviewPaths = 10

    /// preview_files: finds each path on the caller's Mac, then shows the
    /// ones found (`previewPresenter`). `file_not_found` when none is;
    /// `files_unreachable` when the caller's Mac does not answer.
    @MainActor
    func previewFiles(_ request: PreviewFilesRequest, workspace fallback: TerminalWorkspace) async throws -> PreviewFilesResult {
        let paths = request.paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            throw CherryControlError(code: "invalid_argument", message: "Name at least one file: paths.")
        }
        guard paths.count <= Self.maximumPreviewPaths else {
            throw CherryControlError(code: "invalid_argument", message: "At most \(Self.maximumPreviewPaths) paths at a time.")
        }
        let caller = verifiedCallerSession()
        if Self.remoteDevice != nil, caller == nil {
            // A device's caller is always its token's tab.
            throw CherryControlError(code: "terminal_not_found", message: "Cherry could not find your tab.")
        }
        let context = caller.flatMap(QuickViewOpening.context(of:))
            ?? QuickViewContext(machine: .thisMac, workingDirectory: nil, projectRoot: nil, homeDirectory: NSHomeDirectory())
        let source: QuickViewFileSource = switch context.machine {
        case .thisMac: QuickViewLocalFiles()
        case let .remote(name, destination): QuickViewOpening.remoteSource(name, destination)
        }

        // Every path at once: on another Mac each look is a round trip.
        let asked = paths.map { QuickViewLink.request(text: $0, kind: .unknown, context: context) }
        let looks = await withTaskGroup(of: (Int, QuickViewLook).self) { group in
            for (index, request) in asked.enumerated() {
                guard let candidates = request?.candidates else { continue }
                group.addTask { (index, await source.look(at: candidates)) }
            }
            var looks: [Int: QuickViewLook] = [:]
            for await (index, look) in group {
                looks[index] = look
            }
            return looks
        }
        var files: [PreviewFilesResult.File] = []
        var found: [QuickViewRequest] = []
        for (index, path) in paths.enumerated() {
            switch looks[index] ?? .missing {
            case let .file(file, line):
                files.append(.init(path: path, foundPath: file.path, kind: "file"))
                found.append(QuickViewRequest(
                    machine: context.machine, linkText: path, candidates: [QuickViewCandidate(path: file.path, line: line)]
                ))
            case let .folder(folder):
                files.append(.init(path: path, foundPath: folder.path, kind: "folder"))
                found.append(.path(folder.path, on: context.machine))
            case .missing, .special:
                files.append(.init(path: path, foundPath: nil, kind: nil))
            case let .failed(message):
                throw CherryControlError(code: "files_unreachable", message: message)
            }
        }
        guard !found.isEmpty else {
            let place = context.machine.isRemote ? "on \(context.machine.name)" : "on this Mac"
            throw CherryControlError(
                code: "file_not_found",
                message: "No file \(place) at \(paths.joined(separator: ", "))."
            )
        }
        let message = request.message.flatMap { text in
            text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) }?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        }
        let workspace = caller.flatMap { session in openWorkspaces().first { $0.sessions.contains { $0 === session } } }
            ?? fallback
        let share = QuickViewShare(
            requests: found,
            source: source,
            sharer: caller?.title.nilIfEmpty ?? "An agent",
            message: message,
            open: request.open ?? false,
            window: ProjectWindowRegistry.shared.window(for: workspace)
        )
        let opened = previewPresenter(share)
        SessionLog.debug("[quick-view] \(share.sharer) shared \(found.count) file(s) on \(context.machine.name); opened: \(opened)")
        return PreviewFilesResult(files: files, machine: context.machine.name, opened: opened)
    }
}
