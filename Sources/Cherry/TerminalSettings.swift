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
        case .system: "Auto"
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

/// What a program's bell (BEL) does in a tab (Settings › Notifications ›
/// Terminal bell).
enum TerminalBell: String, CaseIterable, Identifiable {
    /// The system beep.
    case beep
    /// Nothing.
    case silent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beep: "Beep"
        case .silent: "Silent"
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
    /// How long a new persistent tab's Create waits for the terminal grid of
    /// the window that shows it to settle (`TerminalWindowGridWait`), so its
    /// program starts at that window's size. The app's windows wait; nil (a
    /// test's workspace, which no window shows) takes the grid the tab has
    /// at once.
    var windowGridWait: TerminalWindowGridWait?

    static let native = SessionBackendPolicy(settings: { .native })

    static let userSettings = SessionBackendPolicy(
        settings: { TerminalSettings.shared.sessionPersistenceSettings },
        localSessions: .shared,
        rememberLocalSessionsOnQuit: { TerminalSettings.shared.localSessionsOnQuit = $0 },
        sessionDetached: { ProjectWindowRegistry.shared.backgroundSessionsNotice?.noteTold([$0]) },
        hostReconnects: .shared,
        windowGridWait: .standard
    )

    /// Whether new local tabs should be persistent sessions (the setting;
    /// `persistentHostingForNewTab()` also checks the host can run them).
    /// A device's window (its host allows no native fallback) always runs
    /// its tabs as persistent sessions there.
    var prefersPersistentLocalSessions: Bool {
        localSessions?.profile.allowsNativeFallback == false || settings().persistLocalSessions
    }

    /// A device's window (docs/specs/remote-devices.md): its tabs run on
    /// another Mac's host, `localSessions`. `windowGridWait`: the app's
    /// device windows wait as This Mac's do (`.standard`).
    static func remote(
        _ hosting: PersistentHostSessions,
        settings: @escaping @MainActor () -> SessionPersistenceSettings = { TerminalSettings.shared.sessionPersistenceSettings },
        hostReconnects: HostedReconnects? = .shared,
        windowGridWait: TerminalWindowGridWait? = nil
    ) -> SessionBackendPolicy {
        precondition(!hosting.profile.allowsNativeFallback, "a device's hosting never falls back to native tabs")
        return SessionBackendPolicy(
            settings: settings,
            localSessions: hosting,
            rememberLocalSessionsOnQuit: { TerminalSettings.shared.localSessionsOnQuit = $0 },
            hostReconnects: hostReconnects,
            windowGridWait: windowGridWait
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
        SessionClosePolicy.closeAction(for: SessionCloseBackend(session), intent: intent)
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

/// The keyboard lines of the user's Ghostty configuration, as native tabs
/// read them (`TerminalSettings.ghosttyKeyboardConfig`), with where each
/// line is and what Cherry does with it: Settings › Terminal and Shortcuts
/// show them, and so does the Keyboard Diagnostics window.
struct UserGhosttyKeyboardConfig {
    /// A `keybind` or `macos-option-as-alt` line of a file read.
    struct Line: Equatable {
        var file: URL
        /// Its number in `file`, from 1: blank lines and comments count.
        var line: Int
        var key: String
        var value: String
        /// The embedded Ghostty's diagnostic for a line it rejects, which is
        /// left out.
        var rejection: String?
        /// Whether native surfaces take it (`parseUserGhosttyKeyboardConfig`).
        var isApplied = false
        /// Why native surfaces leave out a line Ghostty accepts; nil for a
        /// line they take, one Ghostty rejects, and the lines that bind
        /// nothing themselves (`keybind = clear`, an empty value).
        var notAppliedReason: NotAppliedReason?
    }

    /// Why a line Ghostty accepts does not reach Cherry's terminals, as
    /// Ghostty's binding set would drop it (`parseUserGhosttyKeyboardConfig`).
    /// A line is named by its index in `lines`.
    enum NotAppliedReason: Equatable, Sendable {
        /// An app action (`new_tab`, `unbind`): such keys stay Cherry's.
        case appAction
        /// A later binding of its trigger, of a sequence it starts or of the
        /// first steps of its own sequence replaced it (or the binding it
        /// chains to): the line at that index.
        case replaced(byLine: Int)
        /// `keybind = clear`, an empty `keybind =` or an empty
        /// `macos-option-as-alt =` after it dropped it: the line at that
        /// index.
        case cleared(byLine: Int)
        /// A `chain=` line whose binding is not taken.
        case chainOfDropped

        /// The same reason, its line's index in another list.
        fileprivate func renumbered(_ index: (Int) -> Int) -> NotAppliedReason {
            switch self {
            case .appAction, .chainOfDropped: self
            case .replaced(let line): .replaced(byLine: index(line))
            case .cleared(let line): .cleared(byLine: index(line))
            }
        }
    }

    /// Where a `config-file` line named a file.
    struct Inclusion: Equatable, Sendable {
        var file: URL
        /// From 1.
        var line: Int
    }

    /// Every file read, keyboard lines or not, in Ghostty's order
    /// (`ghosttyConfigFileContents`).
    var files: [URL] = []
    /// The `config-file` line that named each of `files` that Ghostty does
    /// not look for itself, by its path.
    var includedBy: [String: Inclusion] = [:]
    /// Their keyboard lines, in order.
    var lines: [Line] = []
    /// What native surfaces take: the lines applied, then the ones Cherry
    /// adds.
    var surfaceLines: [(String, String)] = []
    /// The lines Cherry adds after the applied ones: `keybind =
    /// shift+tab=csi:Z` while no line binds Shift+Tab, and
    /// `macos-option-as-alt = true` while none sets it.
    var added: [(String, String)] = []
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
        didSet { save(fontSize, for: .fontSize) }
    }

    @Published var cursorBlink: Bool {
        didSet { save(cursorBlink, for: .cursorBlink) }
    }

    @Published var minimumContrast: Double {
        didSet { save(minimumContrast, for: .minimumContrast) }
    }

    @Published var sidebarBackgroundDepth: Double {
        didSet { save(sidebarBackgroundDepth, for: .sidebarBackgroundDepth) }
    }

    @Published var sidebarTerminalPathDisplayMode: SidebarTerminalPathDisplayMode {
        didSet { save(sidebarTerminalPathDisplayMode.rawValue, for: .sidebarTerminalPathDisplayMode) }
    }

    @Published var projectColorDisplayMode: ProjectColorDisplayMode {
        didSet { save(projectColorDisplayMode.rawValue, for: .projectColorDisplayMode) }
    }

    @Published var appearance: CherryAppearancePreference {
        didSet { save(appearance.rawValue, for: .appearance) }
    }

    @Published var lightTerminalThemeName: String {
        didSet { save(lightTerminalThemeName, for: .lightTerminalThemeName) }
    }

    @Published var darkTerminalThemeName: String {
        didSet { save(darkTerminalThemeName, for: .darkTerminalThemeName) }
    }

    /// Empty string means "Automatic": the first installed editor in catalog order.
    @Published var defaultEditorID: String {
        didSet { save(defaultEditorID, for: .defaultEditorID) }
    }

    // Session settings apply to the next tab or close; they never touch the
    // Ghostty configuration.

    @Published var persistLocalSessions: Bool {
        didSet { save(persistLocalSessions, for: .persistLocalSessions) }
    }

    @Published var localSessionsOnQuit: LocalSessionsOnQuit {
        didSet { save(localSessionsOnQuit.rawValue, for: .localSessionsOnQuit) }
    }

    @Published var closeTabsOnCleanExit: Bool {
        didSet { save(closeTabsOnCleanExit, for: .closeTabsOnCleanExit) }
    }

    /// When Cherry opens, say once which sessions of closed windows or tabs
    /// are still at work in the background, other than those the user kept
    /// running on purpose (`BackgroundSessionsNotice`).
    @Published var noticeBackgroundSessionsAtLaunch: Bool {
        didSet { save(noticeBackgroundSessionsAtLaunch, for: .noticeBackgroundSessionsAtLaunch) }
    }

    /// A background session's program that waits for the user (program
    /// status `blocked`, OSC 7501) posts a notification
    /// (`BackgroundSessionsModel`); either way its row is marked.
    @Published var notifyWhenBackgroundProgramNeedsInput: Bool {
        didSet { save(notifyWhenBackgroundProgramNeedsInput, for: .notifyWhenBackgroundProgramNeedsInput) }
    }

    /// A background session's program that finishes or fails (`done`,
    /// `error`) posts a notification; either way its row is marked.
    @Published var notifyWhenBackgroundProgramFinishes: Bool {
        didSet { save(notifyWhenBackgroundProgramFinishes, for: .notifyWhenBackgroundProgramFinishes) }
    }

    /// What a program's bell does in a tab. Background sessions' bells post
    /// their notifications whatever it says.
    @Published var terminalBell: TerminalBell {
        didSet { save(terminalBell.rawValue, for: .terminalBell) }
    }

    var sessionPersistenceSettings: SessionPersistenceSettings {
        SessionPersistenceSettings(
            persistLocalSessions: persistLocalSessions,
            localSessionsOnQuit: localSessionsOnQuit,
            closeTabsOnCleanExit: closeTabsOnCleanExit
        )
    }

    private let defaults: UserDefaults
    /// The values this run's launch arguments give settings (`-key value`,
    /// `UserDefaults.argumentDomain`), by key: they win over the stored
    /// ones until Cherry quits (`source(of:)`).
    private let launchArguments: [String: Any]
    /// Set while `reset(_:)` assigns defaults, so it posts one change for
    /// all of them.
    private var isResetting = false

    /// `launchArguments`: nil reads this run's for `.standard` and none for
    /// another store (`SettingSource.launchArguments(for:)`); tests pass
    /// their own.
    init(defaults: UserDefaults = .standard, launchArguments: [String: Any]? = nil) {
        self.defaults = defaults
        let launchArguments = launchArguments ?? SettingSource.launchArguments(for: defaults)
        self.launchArguments = launchArguments
        // A launch argument's value, else the stored one: for `.standard`
        // the defaults search the argument domain first anyway.
        func stored(_ setting: Setting) -> Any? {
            launchArguments[setting.rawValue] ?? defaults.object(forKey: setting.rawValue)
        }
        fontSize = stored(.fontSize) as? Double ?? Defaults.fontSize
        cursorBlink = stored(.cursorBlink) as? Bool ?? Defaults.cursorBlink
        minimumContrast = stored(.minimumContrast) as? Double ?? Defaults.minimumContrast
        sidebarBackgroundDepth = stored(.sidebarBackgroundDepth) as? Double ?? Defaults.sidebarBackgroundDepth
        sidebarTerminalPathDisplayMode = (stored(.sidebarTerminalPathDisplayMode) as? String)
            .flatMap(SidebarTerminalPathDisplayMode.init(rawValue:)) ?? Defaults.sidebarTerminalPathDisplayMode
        projectColorDisplayMode = (stored(.projectColorDisplayMode) as? String)
            .flatMap(ProjectColorDisplayMode.init(rawValue:)) ?? Defaults.projectColorDisplayMode
        appearance = (stored(.appearance) as? String)
            .flatMap(CherryAppearancePreference.init(rawValue:)) ?? Defaults.appearance
        lightTerminalThemeName = stored(.lightTerminalThemeName) as? String ?? Defaults.lightTerminalThemeName
        darkTerminalThemeName = stored(.darkTerminalThemeName) as? String ?? Defaults.darkTerminalThemeName
        defaultEditorID = stored(.defaultEditorID) as? String ?? Defaults.defaultEditorID
        persistLocalSessions = stored(.persistLocalSessions) as? Bool ?? Defaults.sessions.persistLocalSessions
        // A string, so `-sessions.onQuit keep` works as a launch argument.
        localSessionsOnQuit = (stored(.localSessionsOnQuit) as? String)
            .flatMap(LocalSessionsOnQuit.init(rawValue:)) ?? Defaults.sessions.localSessionsOnQuit
        closeTabsOnCleanExit = stored(.closeTabsOnCleanExit) as? Bool ?? Defaults.sessions.closeTabsOnCleanExit
        noticeBackgroundSessionsAtLaunch = stored(.noticeBackgroundSessionsAtLaunch) as? Bool
            ?? Defaults.noticeBackgroundSessionsAtLaunch
        notifyWhenBackgroundProgramNeedsInput = stored(.notifyWhenBackgroundProgramNeedsInput) as? Bool
            ?? Defaults.notifyWhenBackgroundProgramNeedsInput
        notifyWhenBackgroundProgramFinishes = stored(.notifyWhenBackgroundProgramFinishes) as? Bool
            ?? Defaults.notifyWhenBackgroundProgramFinishes
        terminalBell = (stored(.terminalBell) as? String).flatMap(TerminalBell.init(rawValue:)) ?? Defaults.terminalBell
    }

    func toggleLightDarkAppearance(currentColorScheme: ColorScheme) {
        appearance = CherryAppearancePreference.toggled(
            from: appearance,
            currentColorScheme: currentColorScheme
        )
    }

    /// Keyboard-related lines lifted from the user's own Ghostty configuration
    /// so native panes match standalone Ghostty (their `shift+enter`,
    /// `macos-option-as-alt`, etc.): from every file Ghostty loads
    /// (`ghosttyKeyboardConfig`), read once, the first time a surface needs
    /// them after the app allowed it (`readsUserGhosttyConfiguration`);
    /// before that, and in tests, Cherry's own lines alone. Defaults
    /// `macos-option-as-alt = true` if unset so the Alt/Meta family works out
    /// of the box. Only input-producing keybinds are forwarded — app-action
    /// keybinds (tabs/splits) are Cherry's job. Tests set it before they
    /// create a surface.
    static var nativeUserKeyboardConfig: [(String, String)] {
        get {
            nativeKeyboardConfigOverride
                ?? (readsUserGhosttyConfiguration ? userGhosttyKeyboardConfig.surfaceLines : parseUserGhosttyKeyboardConfig(""))
        }
        set { nativeKeyboardConfigOverride = newValue }
    }

    /// What `nativeUserKeyboardConfig` read of the user's Ghostty files, file
    /// by file and line by line, for Settings and the Keyboard Diagnostics
    /// window (which read them if no surface has yet); nil when it reads
    /// none, as in tests.
    static var nativeUserKeyboardConfigReading: UserGhosttyKeyboardConfig? {
        readsUserGhosttyConfiguration ? userGhosttyKeyboardConfig : nil
    }

    /// Whether `nativeUserKeyboardConfig` reads the user's Ghostty files:
    /// the app sets it (`CherryApp.init`); tests never read them.
    static var readsUserGhosttyConfiguration = false

    private static var nativeKeyboardConfigOverride: [(String, String)]?
    private static let userGhosttyKeyboardConfig = ghosttyKeyboardConfig(
        home: FileManager.default.homeDirectoryForCurrentUser,
        environment: ProcessInfo.processInfo.environment
    )

    /// The keys of the lines `parseUserGhosttyKeyboardConfig` keeps.
    nonisolated private static let keyboardConfigKeys: Set<String> = ["keybind", "macos-option-as-alt"]

    /// The keyboard lines of the Ghostty configuration of `home`
    /// (`ghosttyConfigFileContents`), and those native surfaces take
    /// (`parseUserGhosttyKeyboardConfig`). A line the embedded Ghostty
    /// rejects would fail the configuration of every surface, which would
    /// then run with none at all (`TerminalController.rejectedLines`): it is
    /// left out and logged, as standalone Ghostty reports and ignores it.
    static func ghosttyKeyboardConfig(home: URL, environment: [String: String]) -> UserGhosttyKeyboardConfig {
        let files = ghosttyConfigFiles(home: home, environment: environment)
        var lines = files.flatMap { file in
            ghosttyConfigNumberedLines(file.contents)
                .filter { keyboardConfigKeys.contains($0.key) }
                .map { UserGhosttyKeyboardConfig.Line(file: file.url, line: $0.line, key: $0.key, value: $0.value) }
        }
        let rejected = TerminalController.rejectedLines(of: TerminalConfiguration { builder in
            for line in lines {
                builder.withCustom(line.key, line.value)
            }
        })
        for (index, issue) in rejected.sorted(by: { $0.key < $1.key }) {
            lines[index].rejection = issue
            SessionLog.notice(
                "Native tabs leave out a line of the Ghostty configuration that Ghostty rejects: "
                    + "\(lines[index].key) = \(lines[index].value) (\(issue))"
            )
        }
        let taken = lines.indices.filter { lines[$0].rejection == nil }
        let parsed = userGhosttyKeyboardLines(taken.map { (lines[$0].key, lines[$0].value) })
        for index in parsed.kept {
            lines[taken[index]].isApplied = true
        }
        for (index, reason) in parsed.dropped {
            lines[taken[index]].notAppliedReason = reason.renumbered { taken[$0] }
        }
        var includedBy: [String: UserGhosttyKeyboardConfig.Inclusion] = [:]
        for file in files {
            if let inclusion = file.includedBy { includedBy[file.url.path] = inclusion }
        }
        return UserGhosttyKeyboardConfig(
            files: files.map(\.url),
            includedBy: includedBy,
            lines: lines,
            surfaceLines: lines.filter(\.isApplied).map { ($0.key, $0.value) } + parsed.added,
            added: parsed.added
        )
    }

    /// The configuration files Ghostty loads by default, in its order
    /// (`Config.loadDefaultFiles`, Ghostty 1.3): `config`, then
    /// `config.ghostty`, in `$XDG_CONFIG_HOME/ghostty` (`~/.config/ghostty`
    /// when that is unset, empty or not an absolute path), then the same two
    /// in `~/Library/Application Support/com.mitchellh.ghostty`. Ghostty
    /// loads every one that exists; a later line overrides an earlier one.
    nonisolated static func ghosttyDefaultConfigPaths(home: URL, environment: [String: String]) -> [URL] {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".config")
        return [
            configHome.appendingPathComponent("ghostty"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty"),
        ].flatMap { [$0.appendingPathComponent("config"), $0.appendingPathComponent("config.ghostty")] }
    }

    /// Every configuration file Ghostty loads and its text, in its order: the
    /// default files that exist (`ghosttyDefaultConfigPaths`), then the files
    /// their `config-file` lines name, in the order named and each file once
    /// (`Config.loadRecursiveFiles`; a symbolic link is its target); a file
    /// one of those names comes after the files named so far. A path is
    /// relative to the directory of the file that names it, `~/` is `home`,
    /// a leading `?` only makes it optional, and an empty `config-file`
    /// empties the list. Ghostty reads a file line by line: a line that is
    /// not UTF-8 is left out, not the file.
    nonisolated static func ghosttyConfigFileContents(
        home: URL,
        environment: [String: String]
    ) -> [(url: URL, contents: String)] {
        ghosttyConfigFiles(home: home, environment: environment).map { ($0.url, $0.contents) }
    }

    /// `ghosttyConfigFileContents`, with the `config-file` line that named
    /// each file Ghostty does not look for itself (nil for those it does).
    nonisolated static func ghosttyConfigFiles(
        home: URL,
        environment: [String: String]
    ) -> [(url: URL, contents: String, includedBy: UserGhosttyKeyboardConfig.Inclusion?)] {
        var contents: [(url: URL, contents: String, includedBy: UserGhosttyKeyboardConfig.Inclusion?)] = []
        var includes: [(url: URL, by: UserGhosttyKeyboardConfig.Inclusion)] = []
        func load(_ file: URL, includedBy: UserGhosttyKeyboardConfig.Inclusion?) {
            // A regular file, or a link to one, as Ghostty reads a
            // `config-file`: reading a FIFO would wait for a writer.
            var info = stat()
            guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let data = try? Data(contentsOf: file)
            else { return }
            var text = data.split(separator: 0x0A, omittingEmptySubsequences: false)
                .map { String(bytes: $0, encoding: .utf8) ?? "" }
                .joined(separator: "\n")
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            contents.append((file, text, includedBy))
            for (line, key, value) in ghosttyConfigNumberedLines(text) where key == "config-file" {
                guard !value.isEmpty else {
                    includes.removeAll()
                    continue
                }
                var path = value.hasPrefix("?") ? String(value.dropFirst()) : value
                if path.utf8.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
                    path = String(path.dropFirst().dropLast())
                }
                if path.isEmpty { continue }
                let by = UserGhosttyKeyboardConfig.Inclusion(file: file, line: line)
                if path.hasPrefix("/") {
                    includes.append((URL(fileURLWithPath: path), by))
                } else if path.hasPrefix("~/") {
                    includes.append((home.appendingPathComponent(String(path.dropFirst(2))), by))
                } else {
                    includes.append((file.deletingLastPathComponent().appendingPathComponent(path), by))
                }
            }
        }
        for file in ghosttyDefaultConfigPaths(home: home, environment: environment) {
            load(file, includedBy: nil)
        }
        var loaded: Set<String> = []
        var index = 0
        while index < includes.count {
            let include = includes[index]
            index += 1
            if loaded.insert(include.url.resolvingSymlinksInPath().path).inserted {
                load(include.url, includedBy: include.by)
            }
        }
        return contents
    }

    /// The `key = value` lines of a Ghostty configuration file, as Ghostty
    /// reads them (`cli.args.LineIterator`): lines end at LF and are trimmed
    /// of spaces, tabs and CR, blank lines and `#` comments are skipped, and
    /// a value's surrounding double quotes are removed.
    nonisolated static func ghosttyConfigLines(_ contents: String) -> [(key: String, value: String)] {
        ghosttyConfigNumberedLines(contents).map { ($0.key, $0.value) }
    }

    /// `ghosttyConfigLines`, each with its number in the file, from 1: blank
    /// lines and comments count, as in Ghostty's diagnostics.
    nonisolated static func ghosttyConfigNumberedLines(_ contents: String) -> [(line: Int, key: String, value: String)] {
        let blanks = CharacterSet(charactersIn: " \t")
        // "\r\n" is one Character.
        let rawLines = contents.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        return rawLines.enumerated().compactMap { offset, rawLine in
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: blanks)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: blanks)
            if value.utf8.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return (offset + 1, key, value)
        }
    }

    /// `parseUserGhosttyKeyboardConfig(lines:)` of a configuration file's
    /// text.
    nonisolated static func parseUserGhosttyKeyboardConfig(_ contents: String) -> [(String, String)] {
        parseUserGhosttyKeyboardConfig(lines: ghosttyConfigLines(contents))
    }

    /// Pure parser: keep `macos-option-as-alt` and input-producing `keybind`
    /// lines in order, a keybind only while Ghostty's binding set would keep
    /// it (`Binding.Set.parseAndPutRecurse`): a later binding of its trigger,
    /// whatever its action, replaces it, and so does one of a sequence it
    /// starts or of the first steps of its own sequence (except `unbind`),
    /// and `keybind = clear` or an empty `keybind =` drops every earlier
    /// one. A `chain=` line goes with the binding before it. An empty
    /// `macos-option-as-alt =` drops the earlier ones. Adds `shift+tab=csi:Z`
    /// when no line binds Shift+Tab, or a sequence that starts with it, and
    /// option-as-alt `true` when no line sets it.
    nonisolated static func parseUserGhosttyKeyboardConfig(
        lines: [(key: String, value: String)]
    ) -> [(String, String)] {
        let parsed = userGhosttyKeyboardLines(lines)
        return parsed.kept.map { (lines[$0].key, lines[$0].value) } + parsed.added
    }

    /// The `lines` `parseUserGhosttyKeyboardConfig(lines:)` keeps, by index
    /// in order, why it drops the others it reads (by index, with the index
    /// of the line that dropped them), and the lines it adds after them.
    nonisolated private static func userGhosttyKeyboardLines(
        _ lines: [(key: String, value: String)]
    ) -> (kept: [Int], dropped: [Int: UserGhosttyKeyboardConfig.NotAppliedReason], added: [(String, String)]) {
        // Each kept line, and the trigger of the keybind it is or chains to
        // (`keybindSteps`).
        var kept: [(index: Int, steps: [String]?)] = []
        var dropped: [Int: UserGhosttyKeyboardConfig.NotAppliedReason] = [:]
        var sawOptionAsAlt = false
        var bindsShiftTab = false
        // The trigger the latest keybind line bound, and whether it is kept.
        var latestBinding: (steps: [String], isKept: Bool)?
        for (index, (key, value)) in lines.enumerated() {
            switch key {
            case "macos-option-as-alt" where value.isEmpty:
                // Back to the default.
                kept.removeAll { line in
                    guard lines[line.index].key == key else { return false }
                    dropped[line.index] = .cleared(byLine: index)
                    return true
                }
                sawOptionAsAlt = false
            case "macos-option-as-alt":
                kept.append((index, nil))
                sawOptionAsAlt = true
            case "keybind" where value.isEmpty || value == "clear":
                // No binding of the user's is left: `clear` drops them all,
                // and an empty value restores Ghostty's defaults.
                kept.removeAll { line in
                    guard line.steps != nil else { return false }
                    dropped[line.index] = .cleared(byLine: index)
                    return true
                }
                bindsShiftTab = false
                latestBinding = nil
            case "keybind":
                guard let parts = keybindParts(value) else { continue }
                if parts.trigger == "chain" {
                    if let latestBinding, latestBinding.isKept, isInputProducingKeybindAction(parts.action) {
                        kept.append((index, latestBinding.steps))
                    } else {
                        dropped[index] = latestBinding?.isKept == true ? .appAction : .chainOfDropped
                    }
                    continue
                }
                let steps = keybindSteps(parts.trigger)
                let unbinds = parts.action == "unbind"
                kept.removeAll { line in
                    guard let other = line.steps,
                          other.starts(with: steps) || (!unbinds && steps.starts(with: other))
                    else { return false }
                    dropped[line.index] = .replaced(byLine: index)
                    return true
                }
                if steps.first == "shift+tab" { bindsShiftTab = true }
                let isKept = isInputProducingKeybindAction(parts.action)
                if isKept {
                    kept.append((index, steps))
                } else {
                    dropped[index] = .appAction
                }
                latestBinding = (steps, isKept)
            default:
                continue
            }
        }
        var added: [(String, String)] = []
        // Shift+Tab types `CSI Z` (back tab) in every keyboard mode, where
        // Ghostty's encoder types `CSI 27;2;9~` under modifyOtherKeys 2 and
        // `CSI 9;2u` under the kitty keyboard protocol; a user's own binding
        // for the same trigger, whatever its action, wins.
        if !bindsShiftTab {
            added.append(("keybind", "shift+tab=csi:Z"))
        }
        if !sawOptionAsAlt {
            added.append(("macos-option-as-alt", "true"))
        }
        return (kept.map(\.index), dropped, added)
    }

    /// A keybind value's trigger and action, split at the `=` Ghostty splits
    /// it at: an `=` followed by `+` or `=` is the trigger's `=` key.
    nonisolated static func keybindParts(_ value: String) -> (trigger: String, action: String)? {
        var start = value.startIndex
        while let eq = value[start...].firstIndex(of: "=") {
            let next = value.index(after: eq)
            if next < value.endIndex, value[next] == "+" || value[next] == "=" {
                start = next
                continue
            }
            return (
                value[..<eq].trimmingCharacters(in: .whitespaces),
                value[next...].trimmingCharacters(in: .whitespaces)
            )
        }
        return nil
    }

    /// A trigger's steps (`a>b` is two) as Ghostty tells triggers apart
    /// (`Binding.Trigger.parse` and `hash`), for a trigger Ghostty accepts:
    /// without the `all:`, `global:`, `unconsumed:` and `performable:`
    /// flags, each step's modifiers by their Ghostty names in one order
    /// (`cmd+shift+a` and `shift+super+a` are one), and its key by one name
    /// (`keybindKeyName`).
    nonisolated static func keybindSteps(_ trigger: String) -> [String] {
        var rest = Substring(trigger)
        while let colon = rest.firstIndex(of: ":"),
              ["all", "global", "unconsumed", "performable"].contains(String(rest[..<colon])) {
            rest = rest[rest.index(after: colon)...]
        }
        let modifierNames = [
            "shift": "shift", "ctrl": "ctrl", "control": "ctrl", "alt": "alt", "opt": "alt", "option": "alt",
            "super": "super", "cmd": "super", "command": "super", "caps_lock": "caps_lock", "num_lock": "num_lock",
        ]
        return rest.split(separator: ">", omittingEmptySubsequences: false).map { step in
            var modifiers: Set<String> = []
            var key = ""
            // Parts end at `+`; an empty one is the `+` key (`ctrl++`).
            var parts = step
            while !parts.isEmpty {
                let end = parts.firstIndex(of: "+") ?? parts.endIndex
                let part = String(parts[..<end])
                parts = end == parts.endIndex ? "" : parts[parts.index(after: end)...]
                if let modifier = modifierNames[part] {
                    modifiers.insert(modifier)
                } else {
                    key = keybindKeyName(part)
                }
            }
            return (modifiers.sorted() + [key]).joined(separator: "+")
        }
    }

    /// The name of a trigger's key, one for each key Ghostty tells apart: a
    /// character in lower case (`A` is `a`), the `+` key for an empty part,
    /// and a physical key by its snake_case name, which Ghostty 1.1's names
    /// (`left`, `kp_enter`, `one`) and W3C codes (`ArrowLeft`, `Digit1`,
    /// `F1`) are spelled differently (`Key.fromW3C`,
    /// `Trigger.backwards_compatible_keys`).
    nonisolated static func keybindKeyName(_ part: String) -> String {
        if part.isEmpty { return "+" }
        if part.unicodeScalars.count == 1 { return part.lowercased() }
        // Ghostty 1.1's names.
        let isPhysical = part.hasPrefix("physical:")
        let old = isPhysical ? String(part.dropFirst("physical:".count)) : part
        let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        if let digit = digits.firstIndex(of: old) { return isPhysical ? "digit_\(digit)" : "\(digit)" }
        if old.hasPrefix("kp_") { return "numpad_" + old.dropFirst(3) }
        for side in ["left", "right"] where old.hasPrefix(side + "_") {
            let modifier = old.dropFirst(side.count + 1)
            if ["shift", "control", "alt", "super"].contains(modifier) {
                return "\(modifier == "super" ? "meta" : modifier)_\(side)"
            }
        }
        switch old {
        case "plus": return "+"
        case "apostrophe": return isPhysical ? "quote" : "'"
        case "grave_accent": return "backquote"
        case "left_bracket": return "bracket_left"
        case "right_bracket": return "bracket_right"
        case "up", "down", "left", "right": return "arrow_" + old
        default: break
        }
        // A key's own name, or its W3C code in any case.
        let lower = part.lowercased()
        let oneWordNames: Set<String> = [
            "backquote", "backslash", "comma", "equal", "minus", "period", "quote", "semicolon", "slash",
            "backspace", "enter", "space", "tab", "convert", "delete", "end", "help", "home", "insert",
            "escape", "fn", "pause", "eject", "power", "sleep", "copy", "cut", "paste",
        ]
        let isFunctionKey = lower.count > 1 && lower.first == "f" && lower.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
        if lower.contains("_") || oneWordNames.contains(lower) || isFunctionKey {
            return lower
        }
        // `ArrowLeft` is `arrow_left`, `Digit1` `digit_1`.
        var name = ""
        for (index, character) in part.enumerated() {
            if index > 0, character.isUppercase || character.isNumber { name += "_" }
            name += character.lowercased()
        }
        return name
    }

    /// Keep only actions that produce terminal input (so we don't hijack
    /// tab/split/window actions Cherry owns).
    nonisolated static func isInputProducingKeybindAction(_ action: String) -> Bool {
        action.hasPrefix("text:") || action.hasPrefix("csi:") || action.hasPrefix("esc:") || action == "ignore"
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
            builder.withCustom("scrollback-limit", "\(Self.shownTabScrollbackBytes)")
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
            light: terminalTheme(for: .light).toTerminalConfiguration(),
            dark: terminalTheme(for: .dark).toTerminalConfiguration()
        )
    }

    func ghosttyThemeColors(for colorScheme: ColorScheme) -> TerminalThemeColors {
        let theme = terminalTheme(for: colorScheme)
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
        let theme = terminalTheme(for: colorScheme)
        return HostTerminalColors(
            foreground: theme.foreground,
            background: theme.background,
            cursor: theme.cursorColor.flatMap(HostTerminalColors.normalized),
            dark: colorScheme != .light
        )
    }

    /// Writes a setting's value (a Double, Bool or String) to the defaults,
    /// and tells live surfaces of a change that affects them
    /// (`Setting.affectsTerminal`), unless `reset(_:)` tells them once.
    private func save(_ value: Any, for setting: Setting) {
        defaults.set(value, forKey: setting.rawValue)
        if setting.affectsTerminal, !isResetting {
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
        static let sidebarBackgroundDepth = 0.08
        static let sidebarTerminalPathDisplayMode = SidebarTerminalPathDisplayMode.repoFocused
        static let projectColorDisplayMode = ProjectColorDisplayMode.accent
        static let appearance = CherryAppearancePreference.system
        static let lightTerminalThemeName = "Alabaster"
        static let darkTerminalThemeName = "Afterglow"
        static let defaultEditorID = ""
        static let sessions = SessionPersistenceSettings.defaults
        static let noticeBackgroundSessionsAtLaunch = true
        static let notifyWhenBackgroundProgramNeedsInput = true
        static let notifyWhenBackgroundProgramFinishes = false
        static let terminalBell = TerminalBell.beep
    }

    /// The terminal theme `colorScheme` shows: the light one in light mode,
    /// else the dark one.
    private func terminalTheme(for colorScheme: ColorScheme) -> GhosttyThemeDefinition {
        colorScheme == .light
            ? terminalTheme(named: lightTerminalThemeName, fallback: Defaults.lightTerminalThemeName)
            : terminalTheme(named: darkTerminalThemeName, fallback: Defaults.darkTerminalThemeName)
    }

    private func terminalTheme(named name: String, fallback: String) -> GhosttyThemeDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return GhosttyThemeCatalog.theme(named: trimmedName)
            ?? GhosttyThemeCatalog.theme(named: fallback)
            ?? .afterglow
    }
}

// MARK: - Where values come from, and resets

/// Settings' rows read where each value comes from here (`source(of:)`):
/// nothing about it is published, so it is computed from the
/// values and the stored keys, which change together.
extension TerminalSettings {
    /// One stored setting. Its raw value is its defaults key.
    enum Setting: String, CaseIterable, Sendable {
        case appearance = "appearance.theme"
        case sidebarTerminalPathDisplayMode = "sidebar.terminalPathDisplayMode"
        case projectColorDisplayMode = "sidebar.projectColorDisplayMode"
        case sidebarBackgroundDepth = "sidebar.backgroundDepth"
        case lightTerminalThemeName = "terminal.theme.light"
        case darkTerminalThemeName = "terminal.theme.dark"
        case minimumContrast = "terminal.minimumContrast"
        case fontSize = "terminal.fontSize"
        case cursorBlink = "terminal.cursorBlink"
        case notifyWhenBackgroundProgramNeedsInput = "sessions.background.notifyNeedsInput"
        case notifyWhenBackgroundProgramFinishes = "sessions.background.notifyFinished"
        case noticeBackgroundSessionsAtLaunch = "sessions.backgroundNoticeAtLaunch"
        case terminalBell = "terminal.bell"
        case persistLocalSessions = "sessions.persistLocal"
        case localSessionsOnQuit = "sessions.onQuit"
        case closeTabsOnCleanExit = "sessions.closeTabOnExit"
        case defaultEditorID = "editor.default"

        /// Its row's title, as a page's Reset… lists it.
        var title: String {
            switch self {
            case .appearance: "Color scheme"
            case .sidebarTerminalPathDisplayMode: "Paths in the sidebar"
            case .projectColorDisplayMode: "Project colors"
            case .sidebarBackgroundDepth: "Sidebar contrast"
            case .lightTerminalThemeName: "Light Mode theme"
            case .darkTerminalThemeName: "Dark Mode theme"
            case .minimumContrast: "Minimum contrast"
            case .fontSize: "Font size"
            case .cursorBlink: "Blink cursor"
            case .notifyWhenBackgroundProgramNeedsInput: "Notify me when a background program needs me"
            case .notifyWhenBackgroundProgramFinishes: "Notify me when a background program finishes"
            case .noticeBackgroundSessionsAtLaunch: "Tell me about background sessions when Cherry opens"
            case .terminalBell: "Bell"
            case .persistLocalSessions: "Run local terminals as persistent sessions"
            case .localSessionsOnQuit: "When quitting or closing a window"
            case .closeTabsOnCleanExit: "Close a tab when its shell exits"
            case .defaultEditorID: "Default editor"
            }
        }

        /// Whether a change reaches the Ghostty surfaces, which then apply
        /// the settings again (`.terminalSettingsDidChange`). The others
        /// apply to the sidebar, the next tab or the next close.
        var affectsTerminal: Bool {
            switch self {
            case .appearance, .lightTerminalThemeName, .darkTerminalThemeName, .minimumContrast, .fontSize,
                 .cursorBlink:
                true
            case .sidebarTerminalPathDisplayMode, .projectColorDisplayMode, .sidebarBackgroundDepth,
                 .notifyWhenBackgroundProgramNeedsInput, .notifyWhenBackgroundProgramFinishes,
                 .noticeBackgroundSessionsAtLaunch, .terminalBell, .persistLocalSessions, .localSessionsOnQuit,
                 .closeTabsOnCleanExit, .defaultEditorID:
                false
            }
        }

        /// What Reset Interface… resets, in the page's order.
        static let interfacePage: [Setting] = [
            .appearance, .sidebarTerminalPathDisplayMode, .projectColorDisplayMode, .sidebarBackgroundDepth,
        ]
        /// What Reset Themes… resets.
        static let themesPage: [Setting] = [.lightTerminalThemeName, .darkTerminalThemeName, .minimumContrast]
        /// What Reset Terminal… resets. Values from the user's Ghostty
        /// config are not settings: they stay.
        static let terminalPage: [Setting] = [.fontSize, .cursorBlink]
        /// What Reset Notifications… resets.
        static let notificationsPage: [Setting] = [
            .notifyWhenBackgroundProgramNeedsInput, .notifyWhenBackgroundProgramFinishes,
            .noticeBackgroundSessionsAtLaunch, .terminalBell,
        ]
        /// The Sessions page's settings, for their badges: it has no page
        /// reset.
        static let sessionsPage: [Setting] = [.persistLocalSessions, .localSessionsOnQuit, .closeTabsOnCleanExit]

        /// Whether `object`, as the defaults or a launch argument hold it,
        /// reads as one of this setting's values (`init` reads it so): a
        /// launch argument is a property list, so `-terminal.fontSize 20` is
        /// the string "20", which is no Double, and the default is used.
        fileprivate func reads(_ object: Any) -> Bool {
            switch self {
            case .fontSize, .minimumContrast, .sidebarBackgroundDepth:
                object is Double
            case .cursorBlink, .notifyWhenBackgroundProgramNeedsInput, .notifyWhenBackgroundProgramFinishes,
                 .noticeBackgroundSessionsAtLaunch, .persistLocalSessions, .closeTabsOnCleanExit:
                object is Bool
            case .lightTerminalThemeName, .darkTerminalThemeName, .defaultEditorID:
                object is String
            case .appearance:
                (object as? String).flatMap(CherryAppearancePreference.init(rawValue:)) != nil
            case .sidebarTerminalPathDisplayMode:
                (object as? String).flatMap(SidebarTerminalPathDisplayMode.init(rawValue:)) != nil
            case .projectColorDisplayMode:
                (object as? String).flatMap(ProjectColorDisplayMode.init(rawValue:)) != nil
            case .localSessionsOnQuit:
                (object as? String).flatMap(LocalSessionsOnQuit.init(rawValue:)) != nil
            case .terminalBell:
                (object as? String).flatMap(TerminalBell.init(rawValue:)) != nil
            }
        }
    }

    /// How much scrollback a tab's surface keeps while it is shown, in bytes
    /// (Ghostty's `scrollback-limit`). Fixed: not a setting.
    nonisolated static let shownTabScrollbackBytes = 4_000_000

    /// Where `setting`'s value comes from: a launch argument (This run only,
    /// read-only until Cherry quits), else a stored value that is not the
    /// default (Set here), else Cherry's default. A stored value that does
    /// not read as one of its values is the default's.
    func source(of setting: Setting) -> SettingSource {
        // Without a launch argument the value in use is the stored one.
        SettingSource.stored(
            key: setting.rawValue,
            defaults: defaults,
            launchArguments: launchArguments,
            parses: setting.reads,
            isDefault: { _ in isDefault(setting) }
        )
    }

    /// Whether `setting` has its default value. A stepped slider can store
    /// a value a hair off its step (1.1500000000000001 for 1.15), so numbers
    /// count as their default within half a step.
    func isDefault(_ setting: Setting) -> Bool {
        switch setting {
        case .appearance: appearance == Defaults.appearance
        case .sidebarTerminalPathDisplayMode: sidebarTerminalPathDisplayMode == Defaults.sidebarTerminalPathDisplayMode
        case .projectColorDisplayMode: projectColorDisplayMode == Defaults.projectColorDisplayMode
        case .sidebarBackgroundDepth: abs(sidebarBackgroundDepth - Defaults.sidebarBackgroundDepth) < 0.005
        case .lightTerminalThemeName: lightTerminalThemeName == Defaults.lightTerminalThemeName
        case .darkTerminalThemeName: darkTerminalThemeName == Defaults.darkTerminalThemeName
        case .minimumContrast: abs(minimumContrast - Defaults.minimumContrast) < 0.025
        case .fontSize: abs(fontSize - Defaults.fontSize) < 0.5
        case .cursorBlink: cursorBlink == Defaults.cursorBlink
        case .notifyWhenBackgroundProgramNeedsInput:
            notifyWhenBackgroundProgramNeedsInput == Defaults.notifyWhenBackgroundProgramNeedsInput
        case .notifyWhenBackgroundProgramFinishes:
            notifyWhenBackgroundProgramFinishes == Defaults.notifyWhenBackgroundProgramFinishes
        case .noticeBackgroundSessionsAtLaunch:
            noticeBackgroundSessionsAtLaunch == Defaults.noticeBackgroundSessionsAtLaunch
        case .terminalBell: terminalBell == Defaults.terminalBell
        case .persistLocalSessions: persistLocalSessions == Defaults.sessions.persistLocalSessions
        case .localSessionsOnQuit: localSessionsOnQuit == Defaults.sessions.localSessionsOnQuit
        case .closeTabsOnCleanExit: closeTabsOnCleanExit == Defaults.sessions.closeTabsOnCleanExit
        case .defaultEditorID: defaultEditorID == Defaults.defaultEditorID
        }
    }

    /// `setting`'s value as its row and search show it: "14 pt", "1.15×",
    /// "8 %", "Afterglow", "Ask", "Auto", "On".
    func valueText(_ setting: Setting) -> String {
        texts(setting).value
    }

    /// `setting`'s default as `valueText` shows it, for "Reset to default
    /// (14 pt)".
    func defaultValueText(_ setting: Setting) -> String {
        texts(setting).defaultValue
    }

    /// Those of `settings` that are Set here, with their value and default,
    /// as a page's Reset… lists them (`SettingsPageReset`). Empty turns the
    /// page's Reset… off.
    func changes(in settings: [Setting]) -> [SettingsChange] {
        settings.filter { source(of: $0) == .setHere }.map { setting in
            SettingsChange(title: setting.title, from: valueText(setting), to: defaultValueText(setting))
        }
    }

    /// Puts `settings` back to their defaults: assigns each default, which
    /// publishes, so views and live surfaces follow, then removes its key, so
    /// a later change of the default reaches the user. Posts
    /// `.terminalSettingsDidChange` at most once, when a value that affects
    /// the terminal changed. A setting a launch argument sets keeps it.
    func reset(_ settings: some Sequence<Setting>) {
        var changedTerminal = false
        isResetting = true
        for setting in settings where launchArguments[setting.rawValue] == nil {
            if assignDefault(setting), setting.affectsTerminal {
                changedTerminal = true
            }
            defaults.removeObject(forKey: setting.rawValue)
        }
        isResetting = false
        if changedTerminal {
            notifyChanged()
        }
    }

    /// Assigns `setting`'s default, unless it has it; whether it changed.
    private func assignDefault(_ setting: Setting) -> Bool {
        switch setting {
        case .appearance: assign(\.appearance, Defaults.appearance)
        case .sidebarTerminalPathDisplayMode:
            assign(\.sidebarTerminalPathDisplayMode, Defaults.sidebarTerminalPathDisplayMode)
        case .projectColorDisplayMode: assign(\.projectColorDisplayMode, Defaults.projectColorDisplayMode)
        case .sidebarBackgroundDepth: assign(\.sidebarBackgroundDepth, Defaults.sidebarBackgroundDepth)
        case .lightTerminalThemeName: assign(\.lightTerminalThemeName, Defaults.lightTerminalThemeName)
        case .darkTerminalThemeName: assign(\.darkTerminalThemeName, Defaults.darkTerminalThemeName)
        case .minimumContrast: assign(\.minimumContrast, Defaults.minimumContrast)
        case .fontSize: assign(\.fontSize, Defaults.fontSize)
        case .cursorBlink: assign(\.cursorBlink, Defaults.cursorBlink)
        case .notifyWhenBackgroundProgramNeedsInput:
            assign(\.notifyWhenBackgroundProgramNeedsInput, Defaults.notifyWhenBackgroundProgramNeedsInput)
        case .notifyWhenBackgroundProgramFinishes:
            assign(\.notifyWhenBackgroundProgramFinishes, Defaults.notifyWhenBackgroundProgramFinishes)
        case .noticeBackgroundSessionsAtLaunch:
            assign(\.noticeBackgroundSessionsAtLaunch, Defaults.noticeBackgroundSessionsAtLaunch)
        case .terminalBell: assign(\.terminalBell, Defaults.terminalBell)
        case .persistLocalSessions: assign(\.persistLocalSessions, Defaults.sessions.persistLocalSessions)
        case .localSessionsOnQuit: assign(\.localSessionsOnQuit, Defaults.sessions.localSessionsOnQuit)
        case .closeTabsOnCleanExit: assign(\.closeTabsOnCleanExit, Defaults.sessions.closeTabsOnCleanExit)
        case .defaultEditorID: assign(\.defaultEditorID, Defaults.defaultEditorID)
        }
    }

    private func assign<Value: Equatable>(
        _ property: ReferenceWritableKeyPath<TerminalSettings, Value>,
        _ value: Value
    ) -> Bool {
        guard self[keyPath: property] != value else { return false }
        self[keyPath: property] = value
        return true
    }

    private func texts(_ setting: Setting) -> (value: String, defaultValue: String) {
        switch setting {
        case .appearance: (appearance.label, Defaults.appearance.label)
        case .sidebarTerminalPathDisplayMode:
            (sidebarTerminalPathDisplayMode.label, Defaults.sidebarTerminalPathDisplayMode.label)
        case .projectColorDisplayMode: (projectColorDisplayMode.label, Defaults.projectColorDisplayMode.label)
        case .sidebarBackgroundDepth:
            (Self.percentText(sidebarBackgroundDepth), Self.percentText(Defaults.sidebarBackgroundDepth))
        case .lightTerminalThemeName: (lightTerminalThemeName, Defaults.lightTerminalThemeName)
        case .darkTerminalThemeName: (darkTerminalThemeName, Defaults.darkTerminalThemeName)
        case .minimumContrast: (Self.ratioText(minimumContrast), Self.ratioText(Defaults.minimumContrast))
        case .fontSize: (Self.pointText(fontSize), Self.pointText(Defaults.fontSize))
        case .cursorBlink: (SettingSource.onOff(cursorBlink), SettingSource.onOff(Defaults.cursorBlink))
        case .notifyWhenBackgroundProgramNeedsInput:
            (
                SettingSource.onOff(notifyWhenBackgroundProgramNeedsInput),
                SettingSource.onOff(Defaults.notifyWhenBackgroundProgramNeedsInput)
            )
        case .notifyWhenBackgroundProgramFinishes:
            (
                SettingSource.onOff(notifyWhenBackgroundProgramFinishes),
                SettingSource.onOff(Defaults.notifyWhenBackgroundProgramFinishes)
            )
        case .noticeBackgroundSessionsAtLaunch:
            (
                SettingSource.onOff(noticeBackgroundSessionsAtLaunch),
                SettingSource.onOff(Defaults.noticeBackgroundSessionsAtLaunch)
            )
        case .terminalBell: (terminalBell.label, Defaults.terminalBell.label)
        case .persistLocalSessions:
            (SettingSource.onOff(persistLocalSessions), SettingSource.onOff(Defaults.sessions.persistLocalSessions))
        case .localSessionsOnQuit: (localSessionsOnQuit.label, Defaults.sessions.localSessionsOnQuit.label)
        case .closeTabsOnCleanExit:
            (SettingSource.onOff(closeTabsOnCleanExit), SettingSource.onOff(Defaults.sessions.closeTabsOnCleanExit))
        case .defaultEditorID: (Self.editorText(defaultEditorID), Self.editorText(Defaults.defaultEditorID))
        }
    }

    /// A font size, as its slider shows it: "14 pt".
    private static func pointText(_ size: Double) -> String {
        "\(Int(size.rounded())) pt"
    }

    /// A contrast ratio, as its slider shows it: "1.15×".
    private static func ratioText(_ ratio: Double) -> String {
        "\(ratio.formatted(.number.precision(.fractionLength(2))))×"
    }

    /// The sidebar's depth, as its slider shows it: "8 %".
    private static func percentText(_ depth: Double) -> String {
        "\(Int((depth * 100).rounded())) %"
    }


    /// An editor's name, "Automatic" for none (the first installed one).
    private static func editorText(_ editorID: String) -> String {
        guard !editorID.isEmpty else { return "Automatic" }
        return ExternalEditorCatalog.all.first { $0.id == editorID }?.displayName ?? editorID
    }
}
