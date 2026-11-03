import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What Settings asks of the rest of the app: opening a project's window,
/// Finder, a text file, the pasteboard, the Persistent Sessions sheet, the
/// menu bar's background sessions list. Pages read it from the environment
/// (`@Environment(\.settingsActions)`) and never reach `NSWorkspace`,
/// `NSPasteboard.general` or the windows themselves, so their models stay
/// testable. The window's shell gives it `live(openWindow:)`; the
/// environment's default does nothing (each closure is a no-op returning
/// false), and tests build their own with recording closures. Not
/// `SettingsAction`, which is one button a row offers. The closures run on
/// the main actor.
struct SettingsActions {
    /// Brings the project's window forward, else opens it (its root).
    var openProjectWindow: @MainActor (String) -> Void
    var revealInFinder: @MainActor ([URL]) -> Void
    /// Opens a text file (Edit in Ghostty Config, cherry.toml's Open) in
    /// Projects › Default editor, else in the app macOS opens plain text
    /// with. A missing file is never created: nothing opens.
    var openTextFile: @MainActor (URL) -> Void
    var copy: @MainActor (String) -> Void
    /// Shows the Persistent Sessions sheet of the frontmost This Mac
    /// window at `host` (nil: This Mac) and brings that window forward;
    /// false when no such window is open.
    var showPersistentSessions: @MainActor (HostedSessionHost?) -> Bool
    /// Whether a This Mac window is open to show it.
    var canShowPersistentSessions: @MainActor () -> Bool
    /// Opens the menu bar panel's background sessions list; false when
    /// the menu bar item is not installed.
    var showBackgroundSessionsList: @MainActor () -> Bool

    init(
        openProjectWindow: @escaping @MainActor (String) -> Void = { _ in },
        revealInFinder: @escaping @MainActor ([URL]) -> Void = { _ in },
        openTextFile: @escaping @MainActor (URL) -> Void = { _ in },
        copy: @escaping @MainActor (String) -> Void = { _ in },
        showPersistentSessions: @escaping @MainActor (HostedSessionHost?) -> Bool = { _ in false },
        canShowPersistentSessions: @escaping @MainActor () -> Bool = { false },
        showBackgroundSessionsList: @escaping @MainActor () -> Bool = { false }
    ) {
        self.openProjectWindow = openProjectWindow
        self.revealInFinder = revealInFinder
        self.openTextFile = openTextFile
        self.copy = copy
        self.showPersistentSessions = showPersistentSessions
        self.canShowPersistentSessions = canShowPersistentSessions
        self.showBackgroundSessionsList = showBackgroundSessionsList
    }

    /// Does nothing: the environment's default, so a view built without
    /// the shell never reaches the app.
    static var inert: SettingsActions {
        SettingsActions()
    }

    /// The app's: the Settings window's shell builds it with its
    /// `openWindow`. Only the app runs it; tests never do.
    @MainActor
    static func live(openWindow: OpenWindowAction) -> SettingsActions {
        SettingsActions(
            openProjectWindow: { root in
                AgentSettings.shared.markProjectOpened(root)
                guard !ProjectWindowRegistry.shared.focus(projectRoot: root) else { return }
                openWindow(value: ProjectWindowValue.primary(root))
            },
            revealInFinder: { urls in
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            },
            openTextFile: { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                let discovery = ExternalEditorDiscovery.shared
                discovery.refresh()
                let application = SettingsTextFileOpening.application(
                    editors: discovery.installedEditors,
                    preferredEditorID: TerminalSettings.shared.defaultEditorID,
                    plainTextApplication: NSWorkspace.shared.urlForApplication(toOpen: .plainText)
                )
                guard let application else {
                    NSWorkspace.shared.open(url)
                    return
                }
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error {
                        NSLog("[cherry] opening %@ failed: %@", url.path, error.localizedDescription)
                    }
                }
            },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            showPersistentSessions: { host in
                let registry = ProjectWindowRegistry.shared
                guard let workspace = registry.frontmostLocalWorkspace(),
                      let chromeState = registry.chromeState(for: workspace)
                else { return false }
                chromeState.hostedSessionsInitialHost = host
                chromeState.isHostedSessionsPresented = true
                // Settings is in front of it.
                registry.window(for: workspace)?.makeKeyAndOrderFront(nil)
                return true
            },
            canShowPersistentSessions: {
                ProjectWindowRegistry.shared.frontmostLocalWorkspace() != nil
            },
            showBackgroundSessionsList: {
                guard MenuBarStatusItem.shared.statusItem != nil else { return false }
                // On the next turn, so the click's own window does not take
                // key back from the panel.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { _ = MenuBarStatusItem.shared.openPanel() }
                }
                return true
            }
        )
    }
}

extension EnvironmentValues {
    /// What Settings' pages ask of the app. The shell sets
    /// `SettingsActions.live(openWindow:)`; elsewhere it does nothing.
    var settingsActions: SettingsActions {
        get { self[SettingsActionsKey.self] }
        set { self[SettingsActionsKey.self] = newValue }
    }
}

/// Spelled out rather than `@Entry` (see `RemoteDeviceStoreKey`).
private struct SettingsActionsKey: EnvironmentKey {
    static var defaultValue: SettingsActions {
        .inert
    }
}

extension View {
    /// Keeps `canShow` to whether Open Persistent Sessions… can be offered
    /// (`SettingsActions.canShowPersistentSessions`: a This Mac window is
    /// open), read on appear and as windows come and go, never from a
    /// body. A page also sets it false when the sheet could not be shown.
    func tracksPersistentSessionsAvailability(_ canShow: Binding<Bool>) -> some View {
        modifier(PersistentSessionsAvailability(canShow: canShow))
    }
}

private struct PersistentSessionsAvailability: ViewModifier {
    @Binding var canShow: Bool

    @Environment(\.settingsActions) private var actions

    func body(content: Content) -> some View {
        content
            .onAppear {
                canShow = actions.canShowPersistentSessions()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                canShow = actions.canShowPersistentSessions()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
                // Once the window is gone.
                Task { @MainActor in
                    canShow = actions.canShowPersistentSessions()
                }
            }
    }
}

/// Which app Settings opens a text file with.
enum SettingsTextFileOpening {
    /// Projects › Default editor (its "Automatic" is the first installed
    /// editor), else the app macOS opens plain text with; nil for neither.
    static func application(
        editors: [InstalledEditor],
        preferredEditorID: String,
        plainTextApplication: URL?
    ) -> URL? {
        ExternalEditorDiscovery.resolveDefault(editors: editors, preferredID: preferredEditorID)?.appURL
            ?? plainTextApplication
    }
}
