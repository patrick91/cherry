import SwiftUI

/// Settings › Updates: this build's version in the page header (Copy
/// Version), what the updater does now (`UpdatesHero`), and automatic
/// updates: Sparkle's checks and downloads, which live in the app's own
/// defaults (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`), and
/// Cherry's `updates.prereleases`. While the updater isn't running (a build
/// that doesn't update itself, or before it starts) there is no status
/// card: the reason is Automatic updates' caption, and its card is dimmed
/// and shows the stored values (`AppUpdateStoredPreferences`). Every change
/// goes through the updater, never by writing a Sparkle key behind it. No
/// page reset: its values reset one row at a time.
struct UpdatesSettingsPage: View, SettingsPageContent {
    /// What the page asks of the updater: `AppUpdater.shared`'s, which only
    /// the app's Settings window reaches (`live`); tests record their own.
    struct Updater {
        var checkForUpdates: @MainActor () -> Void
        var restartToUpdate: @MainActor () -> Void
        var discardDownloadedUpdate: @MainActor () -> Void
        /// Sparkle's switches: they do nothing while the updater isn't
        /// running.
        var setAutomaticallyChecks: @MainActor (Bool) -> Void
        var setAutomaticallyDownloads: @MainActor (Bool) -> Void
        var setPrereleases: @MainActor (Bool) -> Void

        @MainActor
        static var live: Updater {
            let updater = AppUpdater.shared
            return Updater(
                checkForUpdates: { updater.checkForUpdates() },
                restartToUpdate: { updater.restartToUpdate() },
                discardDownloadedUpdate: { updater.discardDownloadedUpdate() },
                setAutomaticallyChecks: { updater.setAutomaticallyChecks($0) },
                setAutomaticallyDownloads: { updater.setAutomaticallyDownloads($0) },
                setPrereleases: { updater.setPrereleases($0) }
            )
        }
    }

    @ObservedObject private var status: AppUpdateStatus
    private let updater: Updater
    /// Where Sparkle's switches and `updates.prereleases` are stored.
    private let defaults: UserDefaults
    private let launchArguments: [String: Any]
    /// The app's Info.plist: the version, the build and Sparkle's defaults.
    private let info: [String: Any]

    @Environment(\.settingsActions) private var actions

    init(
        status: AppUpdateStatus = AppUpdater.shared.status,
        updater: Updater = .live,
        defaults: UserDefaults = .standard,
        launchArguments: [String: Any]? = nil,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        _status = ObservedObject(wrappedValue: status)
        self.updater = updater
        self.defaults = defaults
        self.launchArguments = launchArguments ?? SettingSource.launchArguments(for: defaults)
        self.info = info
    }

    var body: some View {
        // Read from the app's defaults on each update: Sparkle writes its
        // keys as its switches change, and `status` publishes then.
        let stored = AppUpdateStoredPreferences(defaults: defaults, info: info, launchArguments: launchArguments)
        SettingsPageScroll(SettingsPage.updates.title) {
            header
            if status.isEnabled {
                statusSection
            }
            automaticUpdatesSection(stored)
        }
    }

    // MARK: Header

    private var header: some View {
        let version = Self.version(info: info)
        return SettingsPageHeader(
            tile: SettingsTile(.cherry, size: .extraLarge),
            title: "Cherry",
            styledSubtitle: Self.versionText(version: version.version, build: version.build)
        ) {
            Button("Copy Version") {
                actions.copy(Self.copiedVersion(version: version.version, build: version.build))
            }
            .settingsButton(.standard, size: .small)
        }
        .settingsRow(.updatesVersion)
    }

    // MARK: Status

    /// "Up to date · checked 5 minutes ago" stays true while the page is open.
    /// The timeline only redraws it: its date is the start of the minute,
    /// before a check that just finished, so the hero measures from now.
    private var statusSection: some View {
        TimelineView(.everyMinute) { _ in
            if let hero = UpdatesHero(status: status, now: Date()) {
                SettingsSection(id: .updatesStatus) {
                    SettingsHero(tile: Self.tile(for: hero.tone), title: hero.title) {
                        if let subtitle = hero.subtitle {
                            Text(subtitle)
                        }
                    } actions: {
                        ForEach(hero.actions, id: \.kind) { action in
                            heroButton(action)
                        }
                    }

                    if let error = status.lastError {
                        SettingsSubItem {
                            SettingsNote(error, style: .error)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func heroButton(_ action: UpdatesHero.Action) -> some View {
        let button = Button(action.title) {
            perform(action.kind)
        }
        .settingsButton(action.isPrimary ? .primary : .standard)
        .disabled(!action.isEnabled)
        if let label = action.label {
            button
                .help(label)
                .accessibilityLabel(label)
        } else {
            button
        }
    }

    private func perform(_ kind: UpdatesHero.Action.Kind) {
        switch kind {
        case .discard: updater.discardDownloadedUpdate()
        case .restartToUpdate: updater.restartToUpdate()
        // Install… is Check for Updates…: Sparkle's window offers it.
        case .install, .checkNow: updater.checkForUpdates()
        }
    }

    /// The status card's tile: green when an update is ready, blue when one
    /// was found, the accent while Cherry restarts, else gray.
    private static func tile(for tone: UpdatesHero.Tone) -> SettingsTile {
        let color: Color = switch tone {
        case .ready: SettingsDesign.Colors.hex(SettingsDesign.TileColors.updates)
        case .available: SettingsDesign.Colors.hex("#0A84FF")
        case .restarting: .accentColor
        case .idle: SettingsDesign.Colors.hex("#8E8E93")
        }
        return SettingsTile(.symbol(tone.symbol), color: color, size: .large)
    }

    // MARK: Automatic updates

    private func automaticUpdatesSection(_ stored: AppUpdateStoredPreferences) -> some View {
        let runs = status.isEnabled
        let shown = Self.shownValues(status: status, stored: stored)
        let checks = Self.sparkleSwitchSource(
            stored.automaticChecks,
            isOn: shown.checks,
            updaterRuns: runs,
            set: updater.setAutomaticallyChecks
        )
        let downloads = Self.sparkleSwitchSource(
            stored.automaticDownloads,
            isOn: shown.downloads,
            updaterRuns: runs,
            set: updater.setAutomaticallyDownloads
        )
        let prereleases = Self.prereleasesSource(
            stored,
            isOn: shown.prereleases,
            updaterRuns: runs,
            defaults: defaults,
            set: updater.setPrereleases
        )
        // The card at 60 % while the updater isn't running.
        let opacity = runs ? 1 : 0.6
        return SettingsSection("Automatic updates", intro: status.enablement.reason?.explanation) {
            SettingsItem(id: .updatesAutomaticChecks, Self.checksTitle, help: Self.checksHelp, source: checks) {
                Toggle(Self.checksTitle, isOn: Binding(
                    get: { shown.checks },
                    set: { updater.setAutomaticallyChecks($0) }
                ))
                .settingsSwitch()
                .disabled(!checks.source.isEditable)
            }
            .opacity(opacity)

            SettingsItem(id: .updatesAutomaticDownloads, Self.downloadsTitle, help: Self.downloadsHelp, source: downloads) {
                Toggle(Self.downloadsTitle, isOn: Binding(
                    get: { shown.downloads },
                    set: { updater.setAutomaticallyDownloads($0) }
                ))
                .settingsSwitch()
                .disabled(!downloads.source.isEditable || !shown.checks)
            }
            .opacity(opacity)

            SettingsItem(id: .updatesPrereleases, Self.prereleasesTitle, help: Self.prereleasesHelp, source: prereleases) {
                Toggle(Self.prereleasesTitle, isOn: Binding(
                    get: { shown.prereleases },
                    set: { updater.setPrereleases($0) }
                ))
                .settingsSwitch()
                .disabled(!prereleases.source.isEditable)
            }
            .opacity(opacity)

            if let version = Self.downloadedPrereleaseWhileOff(status: status) {
                SettingsItem(Self.downloadedPrereleaseTitle(version)) {
                    Button("Discard It") {
                        updater.discardDownloadedUpdate()
                    }
                    .settingsButton()
                    .disabled(status.isRestarting)
                }
            }
        }
        .disabled(!runs)
    }

    // MARK: Models

    /// What the three switches show: Sparkle's values while the updater
    /// runs, else the stored ones (Sparkle's read off until it starts).
    /// Get pre-release builds shows the model's, which it read from the
    /// stored value.
    static func shownValues(
        status: AppUpdateStatus,
        stored: AppUpdateStoredPreferences
    ) -> (checks: Bool, downloads: Bool, prereleases: Bool) {
        guard status.isEnabled else {
            return (stored.automaticChecks.value, stored.automaticDownloads.value, status.prereleases)
        }
        return (status.automaticallyChecks, status.automaticallyDownloads, status.prereleases)
    }

    /// A Sparkle switch's badge and ↺. ↺ is offered only while the updater
    /// runs, and sets the Info.plist's default through it (`set`), which
    /// leaves the key equal to the default, so no badge shows: removing an
    /// `SU*` key would itself be a write behind the running updater.
    static func sparkleSwitchSource(
        _ item: AppUpdateStoredPreferences.Switch,
        isOn: Bool,
        updaterRuns: Bool,
        set: @escaping @MainActor (Bool) -> Void
    ) -> SettingsSourceState {
        let defaultValue = item.defaultValue
        var reset: (@MainActor () -> Void)?
        if updaterRuns {
            reset = { set(defaultValue) }
        }
        return .app(
            source: item.source,
            value: SettingSource.onOff(isOn),
            defaultValue: SettingSource.onOff(defaultValue),
            launchArgument: "-\(item.key)",
            reset: reset
        )
    }

    /// Get pre-release builds' badge and ↺. ↺ turns it off through the
    /// updater (`set`, which also resets Sparkle's cycle), then removes
    /// Cherry's own key, so a later default reaches the user; only while
    /// the updater runs, as the card is off otherwise.
    static func prereleasesSource(
        _ stored: AppUpdateStoredPreferences,
        isOn: Bool,
        updaterRuns: Bool,
        defaults: UserDefaults,
        set: @escaping @MainActor (Bool) -> Void
    ) -> SettingsSourceState {
        let key = AppUpdateModel.prereleasesKey
        var reset: (@MainActor () -> Void)?
        if updaterRuns {
            reset = {
                set(false)
                defaults.removeObject(forKey: key)
            }
        }
        return .app(
            source: stored.prereleasesSource,
            value: SettingSource.onOff(isOn),
            defaultValue: SettingSource.onOff(false),
            launchArgument: "-\(key)",
            reset: reset
        )
    }

    /// The pre-release Cherry staged, while Get pre-release builds is off.
    static func downloadedPrereleaseWhileOff(status: AppUpdateStatus) -> String? {
        guard !status.prereleases, status.offersDiscard, case .ready(let version, "prerelease", _) = status.phase else { return nil }
        return version
    }

    /// The Discard It row's text.
    nonisolated static func downloadedPrereleaseTitle(_ version: String) -> String {
        "Cherry \(version) (pre-release) is downloaded and installs when Cherry quits."
    }

    /// This build's version (`CFBundleShortVersionString`) and build
    /// (`CFBundleVersion`), "Unknown" where the Info.plist has none.
    nonisolated static func version(info: [String: Any]) -> (version: String, build: String) {
        (
            info["CFBundleShortVersionString"] as? String ?? "Unknown",
            info["CFBundleVersion"] as? String ?? "Unknown"
        )
    }

    /// The header's line: "Version 2026.10.14.5 · Build 20261014120000.cdb92d6".
    nonisolated static func versionLine(version: String, build: String) -> String {
        "Version \(version) · Build \(build)"
    }

    /// The header shows `versionLine` with the two values in mono.
    static func versionText(version: String, build: String) -> Text {
        let mono = SettingsDesign.Fonts.pageHeaderMono
        return Text("Version \(Text(version).font(mono)) · Build \(Text(build).font(mono))")
    }

    /// What Copy Version copies: "2026.10.14.5 (20261014120000.cdb92d6)".
    nonisolated static func copiedVersion(version: String, build: String) -> String {
        "\(version) (\(build))"
    }

    // MARK: Texts

    static let checksTitle = "Check for updates automatically"
    static let checksHelp = "Checks every hour."
    static let downloadsTitle = "Download and install updates automatically"
    static let downloadsHelp = "Downloads in the background. The update installs when Cherry quits, or at once with Restart to Update; persistent sessions keep running."
    static let prereleasesTitle = "Get pre-release builds"
    static let prereleasesHelp = "Every change to Cherry's main branch, once its tests pass. Turning this off never goes back to an older build: this Mac stays on its pre-release until a newer stable release ships."

    // MARK: Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        searchRows(in: context, info: Bundle.main.infoDictionary ?? [:])
    }

    /// `info`: the app's Info.plist (tests pass their own).
    static func searchRows(in context: SettingsSearchContext, info: [String: Any]) -> [SettingsSearchRow] {
        let stored = AppUpdateStoredPreferences(defaults: context.defaults, info: info, launchArguments: context.launchArguments)
        let shown = shownValues(status: context.updates, stored: stored)
        let version = version(info: info)
        return [
            SettingsSearchRow(
                id: .updatesVersion,
                route: .page(.updates),
                section: "",
                title: "Version",
                keywords: ["build", "copy version"],
                value: "\(version.version) · Build \(version.build)"
            ),
            SettingsSearchRow(
                id: .updatesAutomaticChecks,
                route: .page(.updates),
                section: "Automatic updates",
                title: checksTitle,
                help: checksHelp,
                keywords: ["sparkle", "upgrade"],
                value: SettingSource.onOff(shown.checks)
            ),
            SettingsSearchRow(
                id: .updatesAutomaticDownloads,
                route: .page(.updates),
                section: "Automatic updates",
                title: downloadsTitle,
                help: downloadsHelp,
                keywords: ["sparkle", "upgrade"],
                value: SettingSource.onOff(shown.downloads)
            ),
            SettingsSearchRow(
                id: .updatesPrereleases,
                route: .page(.updates),
                section: "Automatic updates",
                title: prereleasesTitle,
                help: prereleasesHelp,
                keywords: ["prerelease", "beta"],
                value: SettingSource.onOff(shown.prereleases)
            ),
        ]
    }
}

/// The update status card at the top of Settings › Updates:
/// its tile, title, status line and buttons for what the updater does now.
/// Nil while updates are off: Automatic updates' caption gives the reason
/// then.
struct UpdatesHero: Equatable {
    /// The tile's color and glyph.
    enum Tone: Equatable {
        /// Downloaded: green.
        case ready
        /// Found, not downloaded: blue.
        case available
        /// Sparkle armed its relaunch: the accent color.
        case restarting
        /// Nothing found yet, or a check failed: gray.
        case idle

        var symbol: String {
            switch self {
            case .ready, .available, .idle: "arrow.down"
            case .restarting: "arrow.clockwise"
            }
        }
    }

    /// One of the card's buttons.
    struct Action: Equatable {
        enum Kind: Hashable {
            /// Discard Downloaded Update.
            case discard
            case restartToUpdate
            /// Install…: Sparkle's window, as Check for Updates….
            case install
            case checkNow
        }

        var kind: Kind
        var title: String
        /// Its tooltip and what VoiceOver reads where the title is shorter:
        /// Discard's "Discard Downloaded Update".
        var label: String?
        /// The page's prominent button.
        var isPrimary: Bool
        var isEnabled: Bool
    }

    var tone: Tone
    /// "Cherry 2026.10.15.1 is ready", "Up to date · checked 5 minutes ago".
    var title: String
    var subtitle: String?
    var actions: [Action]

    /// `now`: what "checked 5 minutes ago" is measured from.
    @MainActor
    init?(status: AppUpdateStatus, now: Date = Date()) {
        guard status.isEnabled else { return nil }
        tone = Self.tone(status)
        title = Self.title(status, now: now)
        subtitle = Self.subtitle(status)
        actions = Self.actions(status)
    }

    @MainActor
    private static func tone(_ status: AppUpdateStatus) -> Tone {
        if status.isRestarting { return .restarting }
        switch status.phase {
        case .ready: return .ready
        case .available: return .available
        case .idle: return .idle
        }
    }

    @MainActor
    private static func title(_ status: AppUpdateStatus, now: Date) -> String {
        if status.isRestarting { return "Restarting…" }
        switch status.phase {
        case .ready(let version, let channel, _):
            return "Cherry \(version)\(channel == "prerelease" ? " (pre-release)" : "") is ready"
        case .available(let version, _):
            return "Cherry \(version) is available"
        case .idle:
            if status.isReplacedOnDisk { return "Another build of Cherry was installed" }
            if status.lastError != nil { return "Last check failed" }
            guard let lastCheck = status.lastCheck else { return "Not checked yet" }
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            // Never "checked in 5 seconds": a check is never after now.
            return "Up to date · checked \(formatter.localizedString(for: lastCheck, relativeTo: max(now, lastCheck)))"
        }
    }

    @MainActor
    private static func subtitle(_ status: AppUpdateStatus) -> String? {
        guard !status.isRestarting else { return nil }
        switch status.phase {
        case .ready(_, _, throughSparkle: false):
            return "Restart to install it now; otherwise it installs when Cherry quits. Persistent sessions keep running."
        case .ready(_, _, throughSparkle: true):
            return "Restart to Update shows it, to install it now or skip it; otherwise it installs when Cherry quits. Persistent sessions keep running."
        case .idle where status.isReplacedOnDisk:
            return "Quit and reopen Cherry to use it. Until then this copy installs no update."
        default:
            return nil
        }
    }

    @MainActor
    private static func actions(_ status: AppUpdateStatus) -> [Action] {
        let checkNow = Action(
            kind: .checkNow,
            title: "Check Now",
            isPrimary: false,
            isEnabled: status.canCheckForUpdates && !status.isReplacedOnDisk
        )
        switch status.phase {
        case .ready:
            var actions: [Action] = []
            if status.offersDiscard {
                actions.append(Action(
                    kind: .discard,
                    title: "Discard",
                    label: "Discard Downloaded Update",
                    isPrimary: false,
                    isEnabled: !status.isRestarting
                ))
            }
            actions.append(Action(kind: .restartToUpdate, title: "Restart to Update", isPrimary: true, isEnabled: !status.isRestarting))
            return actions
        case .available:
            return [
                Action(kind: .install, title: "Install…", isPrimary: true, isEnabled: status.canCheckForUpdates),
                checkNow,
            ]
        case .idle:
            return [checkNow]
        }
    }
}

extension SettingsRowID {
    static let updatesVersion: Self = "updates.version"
    static let updatesStatus: Self = "updates.status"
    static let updatesAutomaticChecks: Self = "updates.automaticChecks"
    static let updatesAutomaticDownloads: Self = "updates.automaticDownloads"
    static let updatesPrereleases: Self = "updates.prereleases"
}
