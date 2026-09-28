import GhosttyTerminal
import GhosttyTheme
import SwiftUI

enum CherryAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func toggled(
        from appearance: CherryAppearancePreference,
        currentColorScheme: ColorScheme
    ) -> CherryAppearancePreference {
        switch appearance {
        case .system:
            currentColorScheme == .dark ? .light : .dark
        case .light:
            .dark
        case .dark:
            .light
        }
    }
}

enum SidebarTerminalPathDisplayMode: String, CaseIterable, Identifiable {
    case repoFocused
    case smartInitials
    case fullPath

    var id: String { rawValue }

    var label: String {
        switch self {
        case .repoFocused: "Repo focused"
        case .smartInitials: "Smart initials"
        case .fullPath: "Full path"
        }
    }
}

enum ProjectColorDisplayMode: String, CaseIterable, Identifiable {
    case off
    case accent
    case tinted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .accent: "Accent"
        case .tinted: "Tinted"
        }
    }
}

extension Notification.Name {
    static let terminalSettingsDidChange = Notification.Name("Cherry.terminalSettingsDidChange")
}

/// What quitting Cherry or closing a project window does with the local
/// sessions still running there (Settings › Sessions). "Don't ask again" in
/// that question stores the answer here.
enum LocalSessionsOnQuit: String, CaseIterable, Identifiable, Sendable {
    /// Ask (`SessionTeardownQuestion`).
    case ask
    /// Keep them running with no question: their tabs come back.
    case keep
    /// End them with no question.
    case end

    var id: String { rawValue }

    /// The words of the question's buttons.
    var label: String {
        switch self {
        case .ask: "Ask"
        case .keep: "Keep Running"
        case .end: "End Sessions"
        }
    }
}

/// Settings → Sessions, as one value for close and backend decisions.
struct SessionPersistenceSettings: Equatable, Sendable {
    /// Run new local terminal, command and agent tabs as persistent sessions.
    var persistLocalSessions: Bool
    /// Whether quitting or closing a window asks about the local sessions
    /// running there, keeps them or ends them. The answer travels with the
    /// close intent (`SessionTeardown`), so no close action reads this.
    var localSessionsOnQuit: LocalSessionsOnQuit
    /// A terminal tab closes when its shell exits with status 0
    /// (`TerminalWorkspace.tabProgramDidExit`), native tabs too.
    var closeTabsOnCleanExit: Bool = true

    static let defaults = SessionPersistenceSettings(
        persistLocalSessions: true,
        localSessionsOnQuit: .ask,
        closeTabsOnCleanExit: true
    )

    /// Everything native, and exited tabs stay, as tests expect unless they
    /// opt in. With no persistent tab, nothing asks about sessions.
    static let native = SessionPersistenceSettings(
        persistLocalSessions: false,
        localSessionsOnQuit: .ask,
        closeTabsOnCleanExit: false
    )
}

/// How a workspace picks the backend for new tabs and what closing a tab
/// does. Workspaces take it at construction: the app passes `.userSettings`,
/// tests get `.native` and never read `TerminalSettings.shared` or start a
/// session host.
@MainActor
struct SessionBackendPolicy {
    /// Read at every decision, so a settings change applies to the next one.
    var settings: @MainActor () -> SessionPersistenceSettings
    /// Whether closing a local persistent tab follows its intent; see
    /// `SessionClosePolicy.hostedLocalTabsFollowSettings`.
    var hostedLocalTabsFollowSettings = SessionClosePolicy.hostedLocalTabsFollowSettings
    /// Ends a local persistent tab's session on its host after a
    /// `.terminate` close action detached the tab: Kill, then Remove once the
    /// host reports the exit (bounded). For a user's close in a window that
    /// stays open, only once the close can no longer be undone
    /// (`PersistentLocalSessions.deferEnd`). Tests replace it to record calls.
    var terminateHostedSession: @MainActor (TerminalSession, SessionCloseIntent) -> Void = { session, _ in
        session.endPersistentSession()
    }
    /// Runs new local tabs as persistent sessions when the settings prefer
    /// them and the local host can run them. Nil keeps every new tab native.
    var localSessions: PersistentLocalSessions?
    /// A terminal whose shell exits within this long of starting keeps its
    /// tab: a shell that ends at once (a broken startup file, or a native
    /// tab's login(1), which always reports 0) must not close a window as it
    /// opens, and what it printed stays readable. Tests shorten it.
    var cleanExitMinimumRunTime: TimeInterval = 1
    /// Stores the answer of a sessions question whose "Don't ask again" was
    /// ticked (`localSessionsOnQuit`). Tests record it; only the app's
    /// policy writes the setting.
    var rememberLocalSessionsOnQuit: @MainActor (LocalSessionsOnQuit) -> Void = { _ in }
    /// The user detached a tab (⌘D, Detach) keeping its persistent session
    /// running: they know it runs in the background, so the launch notice
    /// does not name it (`BackgroundSessionsNotice.noteTold`). Given its
    /// host session id. Tests record it; only the app's policy tells the
    /// app's notice.
    var sessionDetached: @MainActor (String) -> Void = { _ in }
    /// Brings back tabs attached to an SSH host's sessions once their
    /// adapter gave up and the host answers again. Nil keeps such a tab
    /// disconnected until Reconnect.
    var hostReconnects: HostedReconnects?

    static let native = SessionBackendPolicy(settings: { .native })

    static let userSettings = SessionBackendPolicy(
        settings: { TerminalSettings.shared.sessionPersistenceSettings },
        localSessions: .shared,
        rememberLocalSessionsOnQuit: { TerminalSettings.shared.localSessionsOnQuit = $0 },
        sessionDetached: { ProjectWindowRegistry.shared.backgroundSessionsNotice?.noteTold([$0]) },
        hostReconnects: .shared
    )

    /// Whether new local tabs should be persistent sessions (the setting;
    /// `persistentHostingForNewTab()` also checks the host can run them).
    /// A device's window (its host allows no native fallback) always runs
    /// its tabs as persistent sessions there.
    var prefersPersistentLocalSessions: Bool {
        localSessions?.profile.allowsNativeFallback == false || settings().persistLocalSessions
    }

    /// A device's window (docs/specs/remote-devices.md): its tabs run on
    /// another Mac's host, `localSessions`.
    static func remote(
        _ hosting: PersistentHostSessions,
        settings: @escaping @MainActor () -> SessionPersistenceSettings = { TerminalSettings.shared.sessionPersistenceSettings },
        hostReconnects: HostedReconnects? = .shared
    ) -> SessionBackendPolicy {
        precondition(!hosting.profile.allowsNativeFallback, "a device's hosting never falls back to native tabs")
        return SessionBackendPolicy(
            settings: settings,
            localSessions: hosting,
            rememberLocalSessionsOnQuit: { TerminalSettings.shared.localSessionsOnQuit = $0 },
            hostReconnects: hostReconnects
        )
    }

    /// Where a new local tab runs its program: the local host, when the
    /// settings prefer persistent sessions and it can run them now; nil for
    /// a native tab. When the host cannot, `PersistentSessionsStatus` says why.
    ///
    /// Another Mac's host (a device's window, docs/specs/remote-devices.md)
    /// is always it, whatever the setting and whether or not it can host
    /// now: its tabs never run natively on This Mac, a tab that cannot
    /// start there says so.
    func persistentHostingForNewTab() -> PersistentLocalSessions? {
        guard let localSessions else { return nil }
        guard localSessions.profile.allowsNativeFallback else { return localSessions }
        guard prefersPersistentLocalSessions else { return nil }
        return localSessions.canHostNewTabs() ? localSessions : nil
    }

    func closeAction(for session: TerminalSession, intent: SessionCloseIntent) -> SessionCloseAction {
        SessionClosePolicy.closeAction(
            for: session,
            intent: intent,
            hostedLocalTabsFollowSettings: hostedLocalTabsFollowSettings
        )
    }
}

/// Runtime state of local persistent sessions, shown on Settings → Sessions.
@MainActor
final class PersistentSessionsStatus: ObservableObject {
    static let shared = PersistentSessionsStatus()

    /// Why new local tabs fall back to the native backend (disk image, App
    /// Translocation, missing helper, the daemon failing to start), as full
    /// sentences like `HostedSessionInstallation.localHostUnavailableReason()`.
    /// Nil while local sessions can run. `PersistentLocalSessions` sets it.
    @Published var localSessionsUnavailableReason: String?
    /// Why the latest tab whose session could not start runs natively (the
    /// host's rejection, such as its session limit, or no answer in time),
    /// until a session starts again. Also set for a rejection that leaves
    /// new tabs persistent. `PersistentLocalSessions.noteLaunchFailure` sets it.
    @Published var lastLaunchFailure: String?

    init(localSessionsUnavailableReason: String? = nil, lastLaunchFailure: String? = nil) {
        self.localSessionsUnavailableReason = localSessionsUnavailableReason
        self.lastLaunchFailure = lastLaunchFailure
    }
}

struct TerminalThemeColors: Equatable {
    let background: String
    let foreground: String
    let selectionBackground: String?
    let palette: [Int: String]
}

@MainActor
final class TerminalSettings: ObservableObject {
    static let shared = TerminalSettings()

    /// Changes only when a setting that affects the Ghostty surface changes.
    /// AppKit containers use this to avoid rebuilding theme colors on unrelated
    /// SwiftUI updates while still reacting immediately to real terminal-setting
    /// changes.
    private(set) var terminalAppearanceRevision: UInt64 = 0

    @Published var fontSize: Double {
        didSet { save(fontSize, forKey: Keys.fontSize) }
    }

    @Published var cursorBlink: Bool {
        didSet { save(cursorBlink, forKey: Keys.cursorBlink) }
    }

    @Published var minimumContrast: Double {
        didSet { save(minimumContrast, forKey: Keys.minimumContrast) }
    }

    @Published var sidebarBackgroundDepth: Double {
        didSet {
            save(sidebarBackgroundDepth, forKey: Keys.sidebarBackgroundDepth, notifyTerminal: false)
        }
    }

    @Published var sidebarTerminalPathDisplayMode: SidebarTerminalPathDisplayMode {
        didSet {
            save(sidebarTerminalPathDisplayMode.rawValue, forKey: Keys.sidebarTerminalPathDisplayMode, notifyTerminal: false)
        }
    }

    @Published var projectColorDisplayMode: ProjectColorDisplayMode {
        didSet {
            save(projectColorDisplayMode.rawValue, forKey: Keys.projectColorDisplayMode, notifyTerminal: false)
        }
    }

    @Published var worktreeSpacesEnabled: Bool {
        didSet {
            save(worktreeSpacesEnabled, forKey: Keys.worktreeSpacesEnabled, notifyTerminal: false)
        }
    }

    @Published var attentionStudyEnabled: Bool {
        didSet {
            save(attentionStudyEnabled, forKey: Keys.attentionStudyEnabled, notifyTerminal: false)
        }
    }

    @Published var appearance: CherryAppearancePreference {
        didSet { save(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var lightTerminalThemeName: String {
        didSet { save(lightTerminalThemeName, forKey: Keys.lightTerminalThemeName) }
    }

    @Published var darkTerminalThemeName: String {
        didSet { save(darkTerminalThemeName, forKey: Keys.darkTerminalThemeName) }
    }

    /// Empty string means "Automatic": the first installed editor in catalog order.
    @Published var defaultEditorID: String {
        didSet { save(defaultEditorID, forKey: Keys.defaultEditorID, notifyTerminal: false) }
    }

    // Session settings apply to the next tab or close; they never touch the
    // Ghostty configuration.

    @Published var persistLocalSessions: Bool {
        didSet { save(persistLocalSessions, forKey: Keys.persistLocalSessions, notifyTerminal: false) }
    }

    @Published var localSessionsOnQuit: LocalSessionsOnQuit {
        didSet { save(localSessionsOnQuit.rawValue, forKey: Keys.localSessionsOnQuit, notifyTerminal: false) }
    }

    @Published var closeTabsOnCleanExit: Bool {
        didSet { save(closeTabsOnCleanExit, forKey: Keys.closeTabsOnCleanExit, notifyTerminal: false) }
    }

    /// When Cherry opens, say once which sessions of closed windows or tabs
    /// are still at work in the background, other than those the user kept
    /// running on purpose (`BackgroundSessionsNotice`).
    @Published var noticeBackgroundSessionsAtLaunch: Bool {
        didSet {
            save(noticeBackgroundSessionsAtLaunch, forKey: Keys.noticeBackgroundSessionsAtLaunch, notifyTerminal: false)
        }
    }

    var sessionPersistenceSettings: SessionPersistenceSettings {
        SessionPersistenceSettings(
            persistLocalSessions: persistLocalSessions,
            localSessionsOnQuit: localSessionsOnQuit,
            closeTabsOnCleanExit: closeTabsOnCleanExit
        )
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? Defaults.fontSize
        cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? Defaults.cursorBlink
        minimumContrast = defaults.object(forKey: Keys.minimumContrast) as? Double ?? Defaults.minimumContrast
        sidebarBackgroundDepth = defaults.object(forKey: Keys.sidebarBackgroundDepth) as? Double
            ?? Defaults.sidebarBackgroundDepth
        sidebarTerminalPathDisplayMode = (defaults.object(forKey: Keys.sidebarTerminalPathDisplayMode) as? String)
            .flatMap(SidebarTerminalPathDisplayMode.init(rawValue:)) ?? Defaults.sidebarTerminalPathDisplayMode
        projectColorDisplayMode = (defaults.object(forKey: Keys.projectColorDisplayMode) as? String)
            .flatMap(ProjectColorDisplayMode.init(rawValue:)) ?? Defaults.projectColorDisplayMode
        worktreeSpacesEnabled = defaults.object(forKey: Keys.worktreeSpacesEnabled) as? Bool
            ?? Defaults.worktreeSpacesEnabled
        attentionStudyEnabled = defaults.object(forKey: Keys.attentionStudyEnabled) as? Bool
            ?? Defaults.attentionStudyEnabled
        appearance = (defaults.object(forKey: Keys.appearance) as? String)
            .flatMap(CherryAppearancePreference.init(rawValue:)) ?? Defaults.appearance
        lightTerminalThemeName = defaults.object(forKey: Keys.lightTerminalThemeName) as? String
            ?? Defaults.lightTerminalThemeName
        darkTerminalThemeName = defaults.object(forKey: Keys.darkTerminalThemeName) as? String
            ?? Defaults.darkTerminalThemeName
        defaultEditorID = defaults.object(forKey: Keys.defaultEditorID) as? String ?? Defaults.defaultEditorID
        persistLocalSessions = defaults.object(forKey: Keys.persistLocalSessions) as? Bool
            ?? Defaults.sessions.persistLocalSessions
        // A string, so `-sessions.onQuit keep` works as a launch argument.
        localSessionsOnQuit = (defaults.object(forKey: Keys.localSessionsOnQuit) as? String)
            .flatMap(LocalSessionsOnQuit.init(rawValue:)) ?? Defaults.sessions.localSessionsOnQuit
        closeTabsOnCleanExit = defaults.object(forKey: Keys.closeTabsOnCleanExit) as? Bool
            ?? Defaults.sessions.closeTabsOnCleanExit
        noticeBackgroundSessionsAtLaunch = defaults.object(forKey: Keys.noticeBackgroundSessionsAtLaunch) as? Bool
            ?? Defaults.noticeBackgroundSessionsAtLaunch
    }

    func resetTerminalAppearance() {
        fontSize = Defaults.fontSize
        cursorBlink = Defaults.cursorBlink
        minimumContrast = Defaults.minimumContrast
        sidebarBackgroundDepth = Defaults.sidebarBackgroundDepth
        sidebarTerminalPathDisplayMode = Defaults.sidebarTerminalPathDisplayMode
        projectColorDisplayMode = Defaults.projectColorDisplayMode
        lightTerminalThemeName = Defaults.lightTerminalThemeName
        darkTerminalThemeName = Defaults.darkTerminalThemeName
    }

    func toggleLightDarkAppearance(currentColorScheme: ColorScheme) {
        appearance = CherryAppearancePreference.toggled(
            from: appearance,
            currentColorScheme: currentColorScheme
        )
    }

    /// Keyboard-related lines lifted from the user's own ghostty config so native
    /// panes match standalone ghostty (their `shift+enter`, `macos-option-as-alt`,
    /// etc.). Read once. Defaults `macos-option-as-alt = true` if unset so the
    /// Alt/Meta family works out of the box. Only input-producing keybinds are
    /// forwarded — app-action keybinds (tabs/splits) are Cherry's job.
    static let nativeUserKeyboardConfig: [(String, String)] = loadUserGhosttyKeyboardConfig()

    private static func loadUserGhosttyKeyboardConfig() -> [(String, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".config/ghostty/config"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"),
        ]
        let contents = candidates
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return parseUserGhosttyKeyboardConfig(contents ?? "")
    }

    /// Pure parser: keep `macos-option-as-alt` and input-producing `keybind` lines,
    /// defaulting option-as-alt to `true` when the user didn't set it.
    nonisolated static func parseUserGhosttyKeyboardConfig(_ contents: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var sawOptionAsAlt = false
        var userKeybindTriggers: Set<String> = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "macos-option-as-alt":
                result.append((key, value))
                sawOptionAsAlt = true
            case "keybind" where isInputProducingKeybind(value):
                result.append((key, value))
                if let eq = value.firstIndex(of: "=") {
                    userKeybindTriggers.insert(value[..<eq].trimmingCharacters(in: .whitespaces).lowercased())
                }
            default:
                continue
            }
        }
        // Default keybinds for agent special keys the wrapper's native key handling
        // encodes wrong (it sends modifiers as modify-other-keys). Force the standard
        // sequence via ghostty; a user's own binding for the same trigger wins.
        for (trigger, action) in [("shift+tab", "csi:Z")] where !userKeybindTriggers.contains(trigger) {
            result.append(("keybind", "\(trigger)=\(action)"))
        }
        if !sawOptionAsAlt {
            result.append(("macos-option-as-alt", "true"))
        }
        return result
    }

    /// A ghostty keybind value is `trigger=action`. Keep only actions that produce
    /// terminal input (so we don't hijack tab/split/window actions Cherry owns).
    nonisolated private static func isInputProducingKeybind(_ value: String) -> Bool {
        guard let eq = value.firstIndex(of: "=") else { return false }
        let action = value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return action.hasPrefix("text:") || action.hasPrefix("csi:")
            || action.hasPrefix("esc:") || action == "ignore"
    }

    func ghosttyConfiguration() -> TerminalConfiguration {
        Self.ghosttyConfiguration(
            fontSize: fontSize,
            cursorBlink: cursorBlink,
            minimumContrast: minimumContrast
        )
    }

    static func ghosttyConfiguration(
        fontSize: Double,
        cursorBlink: Bool,
        minimumContrast: Double
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily("Menlo")
            builder.withFontSize(Float(fontSize))
            builder.withCursorStyle(.bar)
            builder.withCursorStyleBlink(cursorBlink)
            builder.withMinimumContrast(minimumContrast)
            builder.withWindowPaddingX(8)
            builder.withWindowPaddingY(14)
            builder.withCustom("scrollback-limit", "\(Defaults.ghosttyScrollbackLimitBytes)")
            // The Ghostty surface owns the keyboard for every running session, so
            // honor the same input-producing bindings as standalone Ghostty.
            // App-action bindings (new tabs, splits, and windows) remain Cherry's
            // responsibility and are intentionally skipped.
            for (key, value) in Self.nativeUserKeyboardConfig {
                builder.withCustom(key, value)
            }
        }
    }

    func ghosttyTheme() -> TerminalTheme {
        TerminalTheme(
            light: terminalTheme(named: lightTerminalThemeName, fallback: Defaults.lightTerminalThemeName)
                .toTerminalConfiguration(),
            dark: terminalTheme(named: darkTerminalThemeName, fallback: Defaults.darkTerminalThemeName)
                .toTerminalConfiguration()
        )
    }

    func ghosttyThemeColors(for colorScheme: ColorScheme) -> TerminalThemeColors {
        let theme = switch colorScheme {
        case .light:
            terminalTheme(named: lightTerminalThemeName, fallback: Defaults.lightTerminalThemeName)
        case .dark:
            terminalTheme(named: darkTerminalThemeName, fallback: Defaults.darkTerminalThemeName)
        @unknown default:
            terminalTheme(named: darkTerminalThemeName, fallback: Defaults.darkTerminalThemeName)
        }

        return TerminalThemeColors(
            background: theme.background,
            foreground: theme.foreground,
            selectionBackground: theme.selectionBackground,
            palette: theme.palette
        )
    }

    /// What a persistent session's terminal reports to its program of its
    /// colours (OSC 10, 11 and 12) and appearance (`CSI ? 996 n`): the
    /// terminal theme for `colorScheme`, as the tab's surface shows it.
    /// Nil when the theme's colours are not `#rrggbb` (the host then
    /// reports its defaults).
    func hostTerminalColors(for colorScheme: ColorScheme) -> HostTerminalColors? {
        let theme = switch colorScheme {
        case .light:
            terminalTheme(named: lightTerminalThemeName, fallback: Defaults.lightTerminalThemeName)
        default:
            terminalTheme(named: darkTerminalThemeName, fallback: Defaults.darkTerminalThemeName)
        }
        return HostTerminalColors(
            foreground: theme.foreground,
            background: theme.background,
            cursor: theme.cursorColor.flatMap(HostTerminalColors.normalized),
            dark: colorScheme != .light
        )
    }

    func isKnownGhosttyTheme(_ name: String) -> Bool {
        GhosttyThemeCatalog.theme(named: name.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private func save(_ value: Double, forKey key: String, notifyTerminal: Bool = true) {
        defaults.set(value, forKey: key)
        if notifyTerminal {
            notifyChanged()
        }
    }

    private func save(_ value: Bool, forKey key: String, notifyTerminal: Bool = true) {
        defaults.set(value, forKey: key)
        if notifyTerminal {
            notifyChanged()
        }
    }

    private func save(_ value: String, forKey key: String, notifyTerminal: Bool = true) {
        defaults.set(value, forKey: key)
        if notifyTerminal {
            notifyChanged()
        }
    }

    private func notifyChanged() {
        terminalAppearanceRevision &+= 1
        NotificationCenter.default.post(name: .terminalSettingsDidChange, object: self)
    }

    private enum Defaults {
        static let fontSize = 14.0
        static let cursorBlink = true
        static let minimumContrast = 1.15
        static let ghosttyScrollbackLimitBytes = 4_000_000
        static let sidebarBackgroundDepth = 0.08
        static let sidebarTerminalPathDisplayMode = SidebarTerminalPathDisplayMode.repoFocused
        static let projectColorDisplayMode = ProjectColorDisplayMode.accent
        static let worktreeSpacesEnabled = false
        static let attentionStudyEnabled = false
        static let appearance = CherryAppearancePreference.system
        static let lightTerminalThemeName = "Alabaster"
        static let darkTerminalThemeName = "Afterglow"
        static let defaultEditorID = ""
        static let sessions = SessionPersistenceSettings.defaults
        static let noticeBackgroundSessionsAtLaunch = true
    }

    private enum Keys {
        static let fontSize = "terminal.fontSize"
        static let cursorBlink = "terminal.cursorBlink"
        static let minimumContrast = "terminal.minimumContrast"
        static let sidebarBackgroundDepth = "sidebar.backgroundDepth"
        static let sidebarTerminalPathDisplayMode = "sidebar.terminalPathDisplayMode"
        static let projectColorDisplayMode = "sidebar.projectColorDisplayMode"
        static let worktreeSpacesEnabled = "features.worktreeSpaces"
        static let attentionStudyEnabled = TerminalAttentionStudy.enabledDefaultsKey
        static let appearance = "appearance.theme"
        static let lightTerminalThemeName = "terminal.theme.light"
        static let darkTerminalThemeName = "terminal.theme.dark"
        static let defaultEditorID = "editor.default"
        static let persistLocalSessions = "sessions.persistLocal"
        static let localSessionsOnQuit = "sessions.onQuit"
        static let closeTabsOnCleanExit = "sessions.closeTabOnExit"
        static let noticeBackgroundSessionsAtLaunch = "sessions.backgroundNoticeAtLaunch"
    }

    private func terminalTheme(named name: String, fallback: String) -> GhosttyThemeDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return GhosttyThemeCatalog.theme(named: trimmedName)
            ?? GhosttyThemeCatalog.theme(named: fallback)
            ?? .afterglow
    }
}
