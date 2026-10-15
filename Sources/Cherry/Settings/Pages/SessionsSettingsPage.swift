import AppKit
import SwiftUI

/// Settings › Sessions, the sidebar's status item: the local session host
/// (its header: status, socket, log, diagnostics, Restart Host…),
/// persistent sessions, closing tabs and background sessions. A banner at
/// the top says when local sessions cannot run. It reads the host only
/// with `cherry status`, which never starts one. No page reset: its values
/// reset one row at a time.
struct SessionsSettingsPage: View, SettingsPageContent {
    @ObservedObject private var settings: TerminalSettings
    @ObservedObject private var status: PersistentSessionsStatus
    @ObservedObject private var backgroundSessions: BackgroundSessionsSummary
    @ObservedObject private var hostDiagnostics: SessionHostDiagnostics
    private let navigator: SettingsNavigator
    private let endBackgroundSessions: @MainActor () -> Void
    /// For paths shown with "~".
    private let homeDirectory: String

    @Environment(\.settingsActions) private var actions
    @State private var confirmation: SettingsConfirmation?
    @State private var isCopyingDiagnostics = false
    /// Whether a This Mac window is open for Open Persistent Sessions…
    /// (`tracksPersistentSessionsAvailability`).
    @State private var canShowPersistentSessions = false

    init(
        settings: TerminalSettings = .shared,
        status: PersistentSessionsStatus = .shared,
        backgroundSessions: BackgroundSessionsSummary = BackgroundSessionsModel.shared.summary,
        hostDiagnostics: SessionHostDiagnostics = .shared,
        navigator: SettingsNavigator = .shared,
        // On the Settings window, where it was asked (the window it was
        // clicked in is key).
        endBackgroundSessions: @escaping @MainActor () -> Void = {
            BackgroundSessionsModel.shared.confirmEndAll(from: NSApp.keyWindow)
        },
        homeDirectory: String = NSHomeDirectory()
    ) {
        _settings = ObservedObject(wrappedValue: settings)
        _status = ObservedObject(wrappedValue: status)
        _backgroundSessions = ObservedObject(wrappedValue: backgroundSessions)
        _hostDiagnostics = ObservedObject(wrappedValue: hostDiagnostics)
        self.navigator = navigator
        self.endBackgroundSessions = endBackgroundSessions
        self.homeDirectory = homeDirectory
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.sessions.title) {
            if let banner = Self.banner(
                unavailableReason: status.localSessionsUnavailableReason,
                lastLaunchFailure: status.lastLaunchFailure
            ) {
                SettingsBanner(.warning, title: banner.title, message: banner.message)
            }
            hostSection
            persistentSessionsSection
            tabsSection
            backgroundSessionsSection
            SettingsPageFooter(caption: Self.footerCaption) {
                VStack(alignment: .trailing, spacing: 3) {
                    SettingsLinkButton("Open Persistent Sessions…") {
                        if !actions.showPersistentSessions(nil) {
                            canShowPersistentSessions = false
                        }
                    }
                    .disabled(!canShowPersistentSessions)
                    if !canShowPersistentSessions {
                        Text(Self.persistentSessionsNeedAWindow)
                            .font(SettingsDesign.Fonts.help)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsConfirmation($confirmation)
        .onAppear {
            // Checks the installation (disk image, helper) now; cheap.
            PersistentLocalSessions.shared.refreshStatus()
        }
        .tracksPersistentSessionsAvailability($canShowPersistentSessions)
        .task {
            // `cherry status` never starts a host.
            await hostDiagnostics.refresh()
        }
    }

    // MARK: Session host

    private var hostSection: some View {
        let hero = hostDiagnostics.heroState
        let hostStatus = hostDiagnostics.status
        return SettingsSection(caption: Self.hostCaption, id: .sessionsHost) {
            SettingsHero(tile: SettingsTile(.cherry, size: .large), title: "Session host") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        SettingsStatusDot(hero.tone)
                        Text(hero.title)
                            .textSelection(.enabled)
                    }
                    if let detail = hero.detail {
                        Text(detail)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            } actions: {
                if hostDiagnostics.isRestarting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Restart Host…", role: .destructive) {
                    confirmation = Self.restartConfirmation {
                        Task { await hostDiagnostics.restartHost() }
                    }
                }
                .settingsButton(.danger)
                .disabled(hostDiagnostics.isRestarting || hostStatus?.running != true)
            }

            if let hostStatus {
                SettingsItem("Sessions") {
                    EmptyView()
                } detail: {
                    HostValue(hostStatus.sessionsSummary)
                }
            }

            if let socket = hostStatus?.socket {
                SettingsItem("Socket") {
                    SettingsCopyButton(label: "Copy socket path") { hostDiagnostics.copySocketPath() }
                } detail: {
                    HostValue(socket, mono: true)
                }
            }

            SettingsItem("Log") {
                Button("Reveal Log") {
                    hostDiagnostics.revealLog()
                }
                .settingsButton()
                .disabled(hostStatus?.logPath == nil)
            } detail: {
                if let logPath = hostStatus?.logPath {
                    HostValue(ProjectSwitcherModel.displayPath(logPath, home: homeDirectory), mono: true)
                }
            }

            SettingsItem("Diagnostics", help: Self.diagnosticsHelp) {
                Button("Copy Diagnostics") {
                    isCopyingDiagnostics = true
                    Task {
                        await hostDiagnostics.copyDiagnostics()
                        isCopyingDiagnostics = false
                    }
                }
                .settingsButton()
                .disabled(isCopyingDiagnostics)
            }
        }
    }

    // MARK: Persistent sessions

    /// Its rows, and Tabs', are read-only while a launch argument sets them
    /// (This run only: `-sessions.onQuit keep` in scripted runs), since what
    /// the control wrote would not be what the next run reads.
    private var persistentSessionsSection: some View {
        SettingsSection("Persistent sessions") {
            let persist = SettingsSourceState.terminal(.persistLocalSessions, in: settings)
            SettingsItem(
                id: .sessionsPersistLocal,
                TerminalSettings.Setting.persistLocalSessions.title,
                help: Self.persistLocalHelp,
                source: persist
            ) {
                Toggle(TerminalSettings.Setting.persistLocalSessions.title, isOn: $settings.persistLocalSessions)
                    .settingsSwitch()
                    .disabled(!persist.source.isEditable)
            }

            // Not tied to the switch above: tabs restored as persistent
            // sessions still ask while new tabs run natively.
            let onQuit = SettingsSourceState.terminal(.localSessionsOnQuit, in: settings)
            SettingsItem(
                id: .sessionsOnQuit,
                TerminalSettings.Setting.localSessionsOnQuit.title,
                help: Self.onQuitHelp,
                source: onQuit
            ) {
                Picker(TerminalSettings.Setting.localSessionsOnQuit.title, selection: $settings.localSessionsOnQuit) {
                    ForEach(LocalSessionsOnQuit.allCases) { choice in
                        Text(choice.label)
                            .tag(choice)
                    }
                }
                .settingsMenuPicker()
                .disabled(!onQuit.source.isEditable)
            }
        }
    }

    // MARK: Tabs

    private var tabsSection: some View {
        SettingsSection(
            "Tabs",
            caption: Self.tabsNote(
                persistLocalSessions: settings.persistLocalSessions,
                unavailableReason: status.localSessionsUnavailableReason
            )
        ) {
            let closeTab = SettingsSourceState.terminal(.closeTabsOnCleanExit, in: settings)
            SettingsItem(
                id: .sessionsCloseTabOnExit,
                TerminalSettings.Setting.closeTabsOnCleanExit.title,
                help: Self.closeTabHelp,
                source: closeTab
            ) {
                Toggle(TerminalSettings.Setting.closeTabsOnCleanExit.title, isOn: $settings.closeTabsOnCleanExit)
                    .settingsSwitch()
                    .disabled(!closeTab.source.isEditable)
            }
        }
    }

    // MARK: Background sessions

    private var backgroundSessionsSection: some View {
        SettingsSection("Background sessions", id: .sessionsBackground) {
            SettingsItem(
                Self.backgroundSessionsTitle(count: backgroundSessions.count, running: backgroundSessions.runningCount),
                help: Self.backgroundHelp
            ) {
                // The menu bar panel lists them only while there are some.
                if backgroundSessions.count > 0 {
                    HStack(spacing: 8) {
                        Button("Show List") {
                            _ = actions.showBackgroundSessionsList()
                        }
                        .settingsButton()
                        Button("End All…", role: .destructive, action: endBackgroundSessions)
                            .settingsButton(.danger)
                    }
                }
            }

            SettingsListItem(opens: { Self.showBackgroundNotifications(navigator) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications for background sessions")
                        .font(SettingsDesign.Fonts.rowTitle)
                    Text(Self.backgroundNotificationsHelp)
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The link row: Notifications at its background sessions, flashed.
    static func showBackgroundNotifications(_ navigator: SettingsNavigator) {
        navigator.open(.page(.notifications), row: .notificationsBackground)
    }

    // MARK: Models

    /// The banner at the top: local sessions cannot run, or the latest
    /// tab whose session could not start runs as a regular terminal; nil
    /// when nothing is wrong.
    nonisolated static func banner(unavailableReason: String?, lastLaunchFailure: String?) -> (title: String, message: String)? {
        if let unavailableReason {
            return ("Local sessions are unavailable", "\(unavailableReason) New tabs run as regular terminals until then.")
        }
        if let lastLaunchFailure {
            return (
                "A tab is not a persistent session",
                "\(lastLaunchFailure) It runs as a regular terminal; Retry on the tab, or restart it, to try again."
            )
        }
        return nil
    }

    /// The caption under Tabs while persistent sessions are off or cannot
    /// run: a native tab's shell has no exit status Cherry can see.
    nonisolated static func tabsNote(persistLocalSessions: Bool, unavailableReason: String?) -> String? {
        guard !persistLocalSessions || unavailableReason != nil else { return nil }
        return "Without persistent sessions Cherry can't see a shell's exit status, so a terminal tab closes whenever its shell ends."
    }

    /// "3 sessions are running in the background", or the ended ones when
    /// none runs.
    nonisolated static func backgroundSessionsTitle(count: Int, running: Int) -> String {
        let ended = count - running
        if running > 0 {
            return running == 1
                ? "1 session is running in the background"
                : "\(running) sessions are running in the background"
        }
        if ended > 0 {
            return ended == 1
                ? "1 ended session is in the background"
                : "\(ended) ended sessions are in the background"
        }
        return "No sessions are running in the background"
    }

    /// What Restart Host… asks first.
    static func restartConfirmation(restart: @escaping @MainActor () -> Void) -> SettingsConfirmation {
        SettingsConfirmation(
            title: "Restart the session host?",
            message: "The host that runs your persistent sessions stops and starts again. Your programs keep running, and their tabs reconnect in a moment.",
            choices: [
                SettingsConfirmation.Choice("Restart Host", role: .destructive, perform: restart),
                .cancel(),
            ]
        )
    }

    // MARK: Texts

    static let hostCaption = "Restarting the host keeps your programs running; tabs reconnect in a moment."
    static let diagnosticsHelp = "Copies what cherry status and cherry doctor report, for a bug report."
    static let persistLocalHelp = "Terminal, command and agent tabs keep running when Cherry quits, crashes or updates, and come back when it opens. Applies to new tabs."
    static let onQuitHelp = "What happens to running sessions when you quit or close a project window. “Don't ask again” in that question sets this too. A log out, restart or shut down never asks."
    static let closeTabHelp = "When a terminal's shell exits with status 0, its tab closes, and the window closes with its last tab. A failed exit keeps the tab open. Command and agent tabs stay open."
    static let backgroundHelp = "Sessions of tabs and windows you closed that keep running. Open or end them from Background Sessions in the menu bar."
    static let backgroundNotificationsHelp = "When a background program needs you or finishes, and the notice when Cherry opens."
    static let footerCaption = "Sessions on SSH hosts always keep running when you close a tab, close a window or quit."
    static let persistentSessionsNeedAWindow = "Open a project window on This Mac first."

    // MARK: Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let terminal = context.terminal
        let background = context.backgroundSessions
        return [
            SettingsSearchRow(
                id: .sessionsHost,
                route: .page(.sessions),
                section: "",
                title: "Session host",
                help: hostCaption,
                keywords: ["host", "daemon", "log", "diagnostics", "doctor", "restart", "cherry status", "socket"]
            ),
            SettingsSearchRow(
                id: .sessionsPersistLocal,
                route: .page(.sessions),
                section: "Persistent sessions",
                title: TerminalSettings.Setting.persistLocalSessions.title,
                help: persistLocalHelp,
                keywords: ["persist", "daemon", "tmux", "keep running"],
                value: terminal.valueText(.persistLocalSessions)
            ),
            SettingsSearchRow(
                id: .sessionsOnQuit,
                route: .page(.sessions),
                section: "Persistent sessions",
                title: TerminalSettings.Setting.localSessionsOnQuit.title,
                help: onQuitHelp,
                keywords: ["quit", "close window", "ask", "end sessions"],
                value: terminal.valueText(.localSessionsOnQuit)
            ),
            SettingsSearchRow(
                id: .sessionsCloseTabOnExit,
                route: .page(.sessions),
                section: "Tabs",
                title: TerminalSettings.Setting.closeTabsOnCleanExit.title,
                help: closeTabHelp,
                keywords: ["exit", "exit status", "close", "shell"],
                value: terminal.valueText(.closeTabsOnCleanExit)
            ),
            SettingsSearchRow(
                id: .sessionsBackground,
                route: .page(.sessions),
                section: "Background sessions",
                title: "Background sessions",
                help: backgroundHelp,
                keywords: ["detached", "end all", "show list"],
                value: backgroundSessionsTitle(count: background.count, running: background.runningCount)
            ),
        ]
    }
}

/// A value under a row's title that can be selected and copied by hand:
/// the sessions' summary, the socket's and the log's paths.
private struct HostValue: View {
    let text: String
    let mono: Bool

    init(_ text: String, mono: Bool = false) {
        self.text = text
        self.mono = mono
    }

    var body: some View {
        Text(text)
            .font(mono ? SettingsDesign.Fonts.mono : SettingsDesign.Fonts.help)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(mono ? 1 : nil)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: !mono)
    }
}

extension SettingsRowID {
    static let sessionsHost: Self = "sessions.host"
    static let sessionsPersistLocal: Self = "sessions.persistLocal"
    static let sessionsOnQuit: Self = "sessions.onQuit"
    static let sessionsCloseTabOnExit: Self = "sessions.closeTabOnExit"
}
