import AppKit
import SwiftUI

/// Settings › Notifications: whether macOS lets Cherry post notifications,
/// what Cherry tells you about background sessions, and what a program's
/// bell does in a tab.
struct NotificationsSettingsPage: View, SettingsPageContent {
    /// What Reset Notifications… resets: this page only.
    static let resetSettings = TerminalSettings.Setting.notificationsPage

    @ObservedObject private var settings: TerminalSettings
    @StateObject private var permission: NotificationsPageModel
    private let navigator: SettingsNavigator

    init(settings: TerminalSettings = .shared, navigator: SettingsNavigator = .shared) {
        _settings = ObservedObject(wrappedValue: settings)
        _permission = StateObject(wrappedValue: NotificationsPageModel.app())
        self.navigator = navigator
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.notifications.title) {
            if let banner = permission.banner {
                permissionBanner(banner)
            }
            backgroundSessionsSection
            terminalBellSection
            SettingsPageFooter(caption: "Resets this page only.") {
                SettingsPageResetButton("Reset Notifications…", settings: Self.resetSettings, in: settings)
            }
        }
        .task { permission.start() }
    }

    // MARK: Permission

    private func permissionBanner(_ banner: NotificationPermissionBanner) -> some View {
        SettingsBanner(banner.isWarning ? .warning : .info, title: banner.title, message: banner.message) {
            Button(banner.action.title) {
                permission.perform(banner.action)
            }
            .settingsButton()
            .disabled(permission.isRequesting)
        }
        .accessibilityLabel("Notification permission")
    }

    // MARK: Background sessions

    private var backgroundSessionsSection: some View {
        SettingsSection("Background sessions") {
            backgroundSwitch(
                .notifyWhenBackgroundProgramNeedsInput,
                id: .notificationsBackground,
                help: Self.needsInputHelp,
                isOn: $settings.notifyWhenBackgroundProgramNeedsInput
            )
            backgroundSwitch(
                .notifyWhenBackgroundProgramFinishes,
                id: .notificationsBackgroundFinished,
                help: Self.finishesHelp,
                isOn: $settings.notifyWhenBackgroundProgramFinishes
            )
            backgroundSwitch(
                .noticeBackgroundSessionsAtLaunch,
                id: .notificationsLaunchNotice,
                help: Self.launchNoticeHelp,
                isOn: $settings.noticeBackgroundSessionsAtLaunch
            )
            SettingsListItem(opens: { Self.showBackgroundSessions(navigator: navigator) }) {
                SettingsListLabel(Self.backgroundSessionsLinkTitle)
            }
        }
    }

    private func backgroundSwitch(
        _ setting: TerminalSettings.Setting,
        id: SettingsRowID,
        help: String,
        isOn: Binding<Bool>
    ) -> some View {
        let source = SettingsSourceState.terminal(setting, in: settings)
        return SettingsItem(id: id, setting.title, help: help, source: source) {
            Toggle(setting.title, isOn: isOn)
                .settingsSwitch()
                .disabled(!source.source.isEditable)
        }
    }

    /// The link row's title: the sessions themselves are on Sessions.
    static let backgroundSessionsLinkTitle = "Background sessions are listed in Sessions"

    /// The link row: Sessions, at its Background sessions.
    static func showBackgroundSessions(navigator: SettingsNavigator) {
        navigator.open(.page(.sessions), row: .sessionsBackground)
    }

    // MARK: Terminal bell

    private var terminalBellSection: some View {
        SettingsSection("Terminal bell") {
            let bell = SettingsSourceState.terminal(.terminalBell, in: settings)
            SettingsItem(
                id: .notificationsBell,
                TerminalSettings.Setting.terminalBell.title,
                help: Self.bellHelp,
                source: bell
            ) {
                Picker(TerminalSettings.Setting.terminalBell.title, selection: $settings.terminalBell) {
                    ForEach(TerminalBell.allCases) { bell in
                        Text(bell.label)
                            .tag(bell)
                    }
                }
                .settingsMenuPicker()
                .disabled(!bell.source.isEditable)
            }
        }
    }

    private static let needsInputHelp = "When a program in a background session waits for your permission, "
        + "an answer or a sign-in, Cherry posts a notification with what it asks."
    private static let finishesHelp = "Also when it fails. Either way, Background Sessions marks it until you open it."
    private static let launchNoticeHelp = "When Cherry opens and agents, commands or busy terminals from closed tabs "
        + "still run, a notice says so once. Sessions you kept running on purpose aren't mentioned."
    private static let bellHelp = "What a program's bell does in a tab."

    // MARK: Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let terminal = context.terminal
        return [
            SettingsSearchRow(
                id: .notificationsBackground,
                route: .page(.notifications),
                section: "Background sessions",
                title: TerminalSettings.Setting.notifyWhenBackgroundProgramNeedsInput.title,
                help: needsInputHelp,
                keywords: ["permission", "needs input"],
                value: terminal.valueText(.notifyWhenBackgroundProgramNeedsInput)
            ),
            SettingsSearchRow(
                id: .notificationsBackgroundFinished,
                route: .page(.notifications),
                section: "Background sessions",
                title: TerminalSettings.Setting.notifyWhenBackgroundProgramFinishes.title,
                help: finishesHelp,
                keywords: ["done", "finished", "error", "failed"],
                value: terminal.valueText(.notifyWhenBackgroundProgramFinishes)
            ),
            SettingsSearchRow(
                id: .notificationsLaunchNotice,
                route: .page(.notifications),
                section: "Background sessions",
                title: TerminalSettings.Setting.noticeBackgroundSessionsAtLaunch.title,
                help: launchNoticeHelp,
                keywords: ["notice", "launch", "startup"],
                value: terminal.valueText(.noticeBackgroundSessionsAtLaunch)
            ),
            SettingsSearchRow(
                id: .notificationsBell,
                route: .page(.notifications),
                section: "Terminal bell",
                title: TerminalSettings.Setting.terminalBell.title,
                help: bellHelp,
                keywords: ["bell", "beep"],
                value: terminal.valueText(.terminalBell)
            ),
        ]
    }
}

extension SettingsRowID {
    static let notificationsBackgroundFinished: Self = "notifications.backgroundFinished"
    static let notificationsLaunchNotice: Self = "notifications.launchNotice"
    static let notificationsBell: Self = "notifications.bell"
}

// MARK: - Permission

/// The banner at the top of Settings › Notifications: when
/// macOS has notifications off for Cherry, and when Cherry has not asked
/// yet. None when they are allowed, or when this copy cannot post any.
struct NotificationPermissionBanner: Equatable {
    /// What the banner's one button does.
    enum Action: Equatable {
        /// System Settings › Notifications, at Cherry.
        case openSystemSettings
        /// Asks macOS now.
        case allowNotifications

        var title: String {
            switch self {
            case .openSystemSettings: "Open System Settings…"
            case .allowNotifications: "Allow Notifications…"
            }
        }
    }

    /// Orange, for notifications that are off; else information.
    var isWarning: Bool
    var title: String
    var message: String?
    var action: Action

    init?(_ permission: NotificationPermission) {
        switch permission {
        case .denied:
            isWarning = true
            title = "Notifications are off for Cherry in System Settings."
            message = "Cherry can still mark tabs in the sidebar and play sounds."
            action = .openSystemSettings
        case .notDetermined:
            isWarning = false
            title = "Cherry asks to post notifications the first time it has one."
            message = nil
            action = .allowNotifications
        case .allowed, .unavailable:
            return nil
        }
    }
}

/// Settings › Notifications' view of macOS's permission: read when the page
/// shows (`start`, from its `.task`) and again whenever Cherry comes to the
/// front, since the user changes it in System Settings. Its effects are
/// injected, so tests never reach `UNUserNotificationCenter` or System
/// Settings.
@MainActor
final class NotificationsPageModel: ObservableObject {
    /// nil until the first read: no banner meanwhile.
    @Published private(set) var permission: NotificationPermission?
    /// While Allow Notifications… waits for macOS.
    @Published private(set) var isRequesting = false

    private let readPermission: @MainActor () async -> NotificationPermission
    private let requestPermission: @MainActor () async -> NotificationPermission
    private let openSystemSettings: @MainActor () -> Void
    private let notificationCenter: NotificationCenter
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?
    /// Bumped by each read, so an older read that answers late changes
    /// nothing.
    private var generation = 0
    /// The read under way; tests wait on it.
    private(set) var reading: Task<Void, Never>?

    /// `notificationCenter` posts `NSApplication.didBecomeActiveNotification`
    /// (the app's default center; tests post to their own).
    init(
        readPermission: @escaping @MainActor () async -> NotificationPermission,
        requestPermission: @escaping @MainActor () async -> NotificationPermission,
        openSystemSettings: @escaping @MainActor () -> Void,
        notificationCenter: NotificationCenter
    ) {
        self.readPermission = readPermission
        self.requestPermission = requestPermission
        self.openSystemSettings = openSystemSettings
        self.notificationCenter = notificationCenter
    }

    /// The app's: `TerminalNotificationCenter`, and System Settings through
    /// `NSWorkspace`. Only the app's Settings window makes it.
    static func app() -> NotificationsPageModel {
        NotificationsPageModel(
            readPermission: { await TerminalNotificationCenter.shared.permission() },
            requestPermission: { await TerminalNotificationCenter.shared.requestAuthorizationNow() },
            openSystemSettings: {
                NSWorkspace.shared.open(systemSettingsURL(bundleIdentifier: Bundle.main.bundleIdentifier))
            },
            notificationCenter: .default
        )
    }

    deinit {
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
        }
    }

    /// System Settings › Notifications, at the app with this bundle id.
    nonisolated static func systemSettingsURL(bundleIdentifier: String?) -> URL {
        var text = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let bundleIdentifier = bundleIdentifier?.nilIfEmpty,
           let id = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            text += "?id=\(id)"
        }
        return URL(string: text)!
    }

    var banner: NotificationPermissionBanner? {
        permission.flatMap(NotificationPermissionBanner.init)
    }

    /// Reads the permission now, and again each time Cherry comes to the
    /// front.
    func start() {
        if activationObserver == nil {
            activationObserver = notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        update(with: readPermission)
    }

    /// The banner's button: System Settings, or macOS's question.
    func perform(_ action: NotificationPermissionBanner.Action) {
        switch action {
        case .openSystemSettings:
            openSystemSettings()
        case .allowNotifications:
            guard !isRequesting else { return }
            isRequesting = true
            update(with: requestPermission) { [weak self] isLatest in
                self?.isRequesting = false
                // A read that began while macOS asked (Cherry came to the
                // front meanwhile) may predate the answer: read again.
                if !isLatest {
                    self?.refresh()
                }
            }
        }
    }

    /// Publishes what `read` says, unless a later read began meanwhile;
    /// `finish` learns which.
    private func update(
        with read: @escaping @MainActor () async -> NotificationPermission,
        then finish: @escaping @MainActor (_ isLatest: Bool) -> Void = { _ in }
    ) {
        generation += 1
        let generation = generation
        reading = Task { [weak self] in
            let permission = await read()
            guard let self else { return }
            let isLatest = generation == self.generation
            if isLatest, permission != self.permission {
                self.permission = permission
            }
            finish(isLatest)
        }
    }
}
