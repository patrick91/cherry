import AppKit

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

@MainActor
struct ExternalEditorLauncher {
    private let openHandler: (URL, URL) -> Void

    init(openHandler: @escaping (URL, URL) -> Void = { folderURL, appURL in
        NSWorkspace.shared.open(
            [folderURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                NSLog("[cherry] open-in-editor failed: %@", error.localizedDescription)
            }
        }
    }) {
        self.openHandler = openHandler
    }

    func open(projectRoot: String, with editor: InstalledEditor) {
        openHandler(URL(fileURLWithPath: projectRoot, isDirectory: true), editor.appURL)
    }
}
