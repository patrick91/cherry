import AppKit
import CherryControl
import GhosttyTerminal

/// A ⌘-click on a file's path in terminal output shows the file in Quick
/// View (`QuickViewPanelController`) instead of opening it, on whichever
/// Mac the tab runs: This Mac's file where it is, another Mac's copied here
/// over its SSH master (`QuickViewRemoteFiles`). Settings › Terminal ›
/// Quick View files on ⌘-click turns it off (`TerminalSettings.quickViewFiles`).
///
/// It takes a click (`GhosttySessionBridge.terminalShouldHandleOpenURL`,
/// before `TerminalLinkOpening`) only when the link names a file: a path
/// Ghostty matched, or an OSC 8 `file:` link. In a tab of This Mac only
/// when one of its paths is a file here: a folder still opens in Finder,
/// and a path that names nothing here is still refused by
/// `TerminalLinkOpening`, which says why. In a tab of another Mac every
/// path link: nothing here can open that Mac's files, and the panel says
/// what it found there.
@MainActor
enum QuickViewOpening {
    /// Whether a click previews files. Off until the app follows the
    /// setting (`CherryApp.init`), so tests' surfaces leave links to
    /// `TerminalLinkOpening` unless a test turns it on.
    static var isEnabled: @MainActor () -> Bool = { false }
    /// Shows a request (the panel, on the next main-loop turn: Ghostty
    /// calls `open_url` from its mouse handling with its renderer's lock
    /// held, and the panel's drawing must not run under it). Tests record.
    static var present: @MainActor (QuickViewRequest, QuickViewFileSource, NSWindow?) -> Void = { request, source, window in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                QuickViewPanelController.shared.show(request, source: source, from: window)
            }
        }
    }
    /// Another Mac's files, by its name and ssh destination.
    static var remoteSource: @MainActor (_ name: String, _ destination: String) -> QuickViewFileSource = { name, destination in
        QuickViewRemoteFiles.app(name: name, destination: destination)
    }

    /// The app's: follows Settings › Terminal.
    static func followSettings(_ settings: TerminalSettings = .shared) {
        isEnabled = { [weak settings] in settings?.quickViewFiles ?? false }
    }

    /// The Mac whose files `session`'s paths name, its directory and
    /// project folder there, and its home when Cherry knows it.
    static func context(of session: TerminalSession) -> QuickViewContext? {
        if let hosting = session.persistentHosting, !hosting.profile.isThisMac {
            guard let destination = hosting.profile.host.sshDestination else { return nil }
            return QuickViewContext(
                machine: .remote(name: hosting.profile.displayName, destination: destination),
                workingDirectory: session.workingDirectory,
                projectRoot: session.projectRoot.flatMap(remoteProjectPath),
                homeDirectory: hosting.profile.homeDirectory
            )
        }
        if let attachment = session.hostedAttachment, let destination = attachment.host.sshDestination {
            // A session of an SSH host: its directory as the host gave it.
            return QuickViewContext(
                machine: .remote(name: attachment.host.displayName, destination: destination),
                workingDirectory: attachment.remoteWorkingDirectory,
                projectRoot: nil,
                homeDirectory: nil
            )
        }
        let projectRoot = session.projectRoot.flatMap { ProjectLocation.isRemoteKey($0) ? nil : $0 }
        return QuickViewContext(
            machine: .thisMac,
            workingDirectory: session.workingDirectory,
            projectRoot: projectRoot,
            homeDirectory: NSHomeDirectory()
        )
    }

    /// A device project key's path there.
    private static func remoteProjectPath(_ key: String) -> String? {
        ProjectLocation.isRemoteKey(key) ? ProjectLocation.launchPath(forKey: key) : nil
    }

    /// Shows the file a click of `kind` on `text` in `session` names: true
    /// when Quick View took it, false to leave it to `TerminalLinkOpening`.
    @discardableResult
    static func open(_ text: String, kind: TerminalOpenURLKind, session: TerminalSession?, window: NSWindow?) -> Bool {
        guard isEnabled(), let session, let context = context(of: session),
              var request = QuickViewLink.request(text: text, kind: kind, context: context)
        else { return false }
        let source: QuickViewFileSource
        switch context.machine {
        case .thisMac:
            guard let (found, isFolder) = QuickViewLocalFiles.firstExisting(request.candidates), !isFolder else {
                return false
            }
            request = QuickViewRequest(machine: .thisMac, linkText: text, candidates: [found])
            source = QuickViewLocalFiles()
        case let .remote(name, destination):
            source = remoteSource(name, destination)
        }
        SessionLog.debug("[quick-view] \(request.machine.name): \(request.candidates.count) path(s) for a \(String(describing: kind)) link")
        present(request, source, window)
        return true
    }
}
