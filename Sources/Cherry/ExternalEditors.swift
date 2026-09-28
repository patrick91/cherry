import AppKit
import CherryControl

struct KnownEditor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    /// Bundle identifiers in priority order; the first one that resolves wins,
    /// so preview/insider builds are found when the stable build isn't installed.
    let bundleIdentifiers: [String]
}

enum ExternalEditorCatalog {
    /// Catalog order doubles as the "Automatic" default-editor priority.
    static let all: [KnownEditor] = [
        KnownEditor(id: "zed", displayName: "Zed", bundleIdentifiers: ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        KnownEditor(id: "vscode", displayName: "Visual Studio Code", bundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        KnownEditor(id: "cursor", displayName: "Cursor", bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"]),
        KnownEditor(id: "windsurf", displayName: "Windsurf", bundleIdentifiers: ["com.exafunction.windsurf"]),
        KnownEditor(id: "sublime-text", displayName: "Sublime Text", bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3"]),
        KnownEditor(id: "intellij", displayName: "IntelliJ IDEA", bundleIdentifiers: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        KnownEditor(id: "pycharm", displayName: "PyCharm", bundleIdentifiers: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        KnownEditor(id: "webstorm", displayName: "WebStorm", bundleIdentifiers: ["com.jetbrains.WebStorm"]),
        KnownEditor(id: "goland", displayName: "GoLand", bundleIdentifiers: ["com.jetbrains.goland"]),
        KnownEditor(id: "rubymine", displayName: "RubyMine", bundleIdentifiers: ["com.jetbrains.rubymine"]),
        KnownEditor(id: "clion", displayName: "CLion", bundleIdentifiers: ["com.jetbrains.CLion"]),
        KnownEditor(id: "rider", displayName: "Rider", bundleIdentifiers: ["com.jetbrains.rider"]),
        KnownEditor(id: "phpstorm", displayName: "PhpStorm", bundleIdentifiers: ["com.jetbrains.PhpStorm"]),
        KnownEditor(id: "fleet", displayName: "Fleet", bundleIdentifiers: ["com.jetbrains.fleet"]),
        KnownEditor(id: "android-studio", displayName: "Android Studio", bundleIdentifiers: ["com.google.android.studio"]),
        KnownEditor(id: "xcode", displayName: "Xcode", bundleIdentifiers: ["com.apple.dt.Xcode"]),
        KnownEditor(id: "nova", displayName: "Nova", bundleIdentifiers: ["com.panic.Nova"]),
        KnownEditor(id: "bbedit", displayName: "BBEdit", bundleIdentifiers: ["com.barebones.bbedit"]),
        KnownEditor(id: "textmate", displayName: "TextMate", bundleIdentifiers: ["com.macromates.TextMate"]),
        KnownEditor(id: "macvim", displayName: "MacVim", bundleIdentifiers: ["org.vim.MacVim"]),
        KnownEditor(id: "emacs", displayName: "Emacs", bundleIdentifiers: ["org.gnu.Emacs"])
    ]
}

struct InstalledEditor: Identifiable, Equatable {
    let editor: KnownEditor
    let bundleIdentifier: String
    let appURL: URL

    var id: String { editor.id }
    var displayName: String { editor.displayName }
}

/// Resolves which known editors are installed, via Launch Services.
///
/// Discovery and icon loading only run inside `refresh()` — call it when a
/// surface appears (palette open, settings pane appear), never from a SwiftUI
/// body.
@MainActor
final class ExternalEditorDiscovery: ObservableObject {
    static let shared = ExternalEditorDiscovery()

    @Published private(set) var installedEditors: [InstalledEditor] = []

    private let appURLResolver: (String) -> URL?
    private let iconProvider: (URL) -> NSImage
    private var iconCache: [String: NSImage] = [:]

    init(
        appURLResolver: @escaping (String) -> URL? = { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        },
        iconProvider: @escaping (URL) -> NSImage = { appURL in
            NSWorkspace.shared.icon(forFile: appURL.path)
        }
    ) {
        self.appURLResolver = appURLResolver
        self.iconProvider = iconProvider
    }

    func refresh() {
        var editors: [InstalledEditor] = []
        for editor in ExternalEditorCatalog.all {
            for bundleID in editor.bundleIdentifiers {
                guard let appURL = appURLResolver(bundleID) else { continue }
                editors.append(InstalledEditor(editor: editor, bundleIdentifier: bundleID, appURL: appURL))
                break
            }
        }

        for installed in editors where iconCache[installed.appURL.path] == nil {
            iconCache[installed.appURL.path] = iconProvider(installed.appURL)
        }

        if editors != installedEditors {
            installedEditors = editors
        }
    }

    func icon(for editor: InstalledEditor) -> NSImage? {
        iconCache[editor.appURL.path]
    }

    nonisolated static func resolveDefault(
        editors: [InstalledEditor],
        preferredID: String
    ) -> InstalledEditor? {
        editors.first { $0.id == preferredID } ?? editors.first
    }
}

/// How an editor opens a folder on another Mac over SSH
/// (docs/specs/remote-devices.md, phase 3): VS Code and Cursor through their
/// Remote - SSH URL, Zed through its `zed://ssh/` hotlink. Other editors
/// cannot, and are not offered for a device's project.
enum RemoteEditorLink: Equatable {
    /// Opened with the editor's app.
    case url(URL)

    /// The URL scheme of a VS Code-family editor that opens
    /// `<scheme>://vscode-remote/ssh-remote+<destination><path>`.
    static func vscodeScheme(bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        case "com.microsoft.VSCode": "vscode"
        case "com.microsoft.VSCodeInsiders": "vscode-insiders"
        case "com.todesktop.230313mzl4w4u92": "cursor"
        default: nil
        }
    }

    /// Whether `editor` can open a folder on another Mac.
    static func supports(_ editor: InstalledEditor) -> Bool {
        editor.id == "zed" || vscodeScheme(bundleIdentifier: editor.bundleIdentifier) != nil
    }

    /// The link that opens `path` (absolute, on the device) on the SSH
    /// `destination` in `editor`; nil when it cannot.
    static func make(editor: InstalledEditor, destination: String, path: String) -> RemoteEditorLink? {
        guard path.hasPrefix("/"), !destination.isEmpty else { return nil }
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let encodedDestination = destination.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed.union(["@"])) ?? destination
        if let scheme = vscodeScheme(bundleIdentifier: editor.bundleIdentifier) {
            return URL(string: "\(scheme)://vscode-remote/ssh-remote+\(encodedDestination)\(encodedPath)").map { .url($0) }
        }
        if editor.id == "zed" {
            // Zed's documented hotlink, `zed://ssh/[user@]host/<path>`,
            // whose path Zed percent-decodes (a folder with spaces opens
            // as named). Not its CLI's `ssh://host/<path>`, whose decoding
            // Zed does not document; the host is left unencoded (Zed reads
            // `user@host:port` there).
            return URL(string: "zed://ssh/\(destination)\(encodedPath)").map { .url($0) }
        }
        return nil
    }
}

@MainActor
struct ExternalEditorLauncher {
    typealias RemoteOpener = @MainActor (RemoteEditorLink, InstalledEditor) -> Void

    private let openHandler: (URL, URL) -> Void
    private let remoteOpener: RemoteOpener
    /// The SSH destination of the device a project key names.
    private let destination: @MainActor (String) -> String?

    init(
        openHandler: @escaping (URL, URL) -> Void = { folderURL, appURL in
            NSWorkspace.shared.open(
                [folderURL],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    NSLog("[cherry] open-in-editor failed: %@", error.localizedDescription)
                }
            }
        },
        remoteOpener: @escaping RemoteOpener = ExternalEditorLauncher.openRemote,
        destination: @escaping @MainActor (String) -> String? = { key in
            RemoteDeviceStore.shared.device(forProjectKey: key)?.sshDestination
        }
    ) {
        self.openHandler = openHandler
        self.remoteOpener = remoteOpener
        self.destination = destination
    }

    /// Opens the project in `editor`. A project on another Mac (a
    /// `ProjectLocation` key) opens through the editor's remote support
    /// when it has one (`RemoteEditorLink`), else nothing happens.
    func open(projectRoot: String, with editor: InstalledEditor) {
        guard ProjectLocation.isRemoteKey(projectRoot) else {
            openHandler(URL(fileURLWithPath: projectRoot, isDirectory: true), editor.appURL)
            return
        }
        guard let destination = destination(projectRoot),
              let link = RemoteEditorLink.make(
                editor: editor, destination: destination, path: ProjectLocation.launchPath(forKey: projectRoot)
              )
        else { return }
        remoteOpener(link, editor)
    }

    /// The editors a project's Open in… offers: every installed one for
    /// This Mac's, those with remote support for a device's.
    static func editors(_ installed: [InstalledEditor], forProjectRoot projectRoot: String?) -> [InstalledEditor] {
        guard let projectRoot, ProjectLocation.isRemoteKey(projectRoot) else { return installed }
        return installed.filter(RemoteEditorLink.supports)
    }

    static let openRemote: RemoteOpener = { link, editor in
        switch link {
        case .url(let url):
            NSWorkspace.shared.open([url], withApplicationAt: editor.appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { NSLog("[cherry] open-in-editor failed: %@", error.localizedDescription) }
            }
        }
    }
}
