import AppKit
import Foundation
import Testing
import UserNotifications
@testable import Cherry

// Settings › Notifications (Pages/NotificationsSettingsPage.swift): the
// permission banner and its model, the background-session switches, the
// terminal bell (TerminalBellSound.swift), Reset Notifications… and the
// page's search rows. Private defaults and a private notification center
// only: nothing here reads the app's defaults, asks macOS or opens System
// Settings.

@MainActor
private func notificationsSettings(
    _ defaults: UserDefaults = privateDefaults("SettingsWindowNotifications"),
    launchArguments: [String: Any] = [:]
) -> TerminalSettings {
    TerminalSettings(defaults: defaults, launchArguments: launchArguments)
}

/// A permission reader that answers from a list, the last answer again
/// once the list is used up, and counts its reads.
@MainActor
private final class PermissionAnswers {
    private var answers: [NotificationPermission]
    private(set) var reads = 0

    init(_ answers: [NotificationPermission]) {
        self.answers = answers
    }

    func next() -> NotificationPermission {
        reads += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

/// Reads that wait until the test answers them.
@MainActor
private final class PendingReads {
    private(set) var waiting: [CheckedContinuation<NotificationPermission, Never>] = []

    func read() async -> NotificationPermission {
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// How many times something happened, from a closure the test hands out.
@MainActor
private final class Count {
    private(set) var value = 0

    func add() {
        value += 1
    }
}

/// The `.terminalSettingsDidChange` posts of one settings object.
private final class TerminalChangeCount: @unchecked Sendable {
    var value = 0
}

@MainActor
private func permissionModel(
    reading answers: PermissionAnswers,
    requesting request: PermissionAnswers = PermissionAnswers([.allowed]),
    opened: @escaping @MainActor () -> Void = {},
    center: NotificationCenter = NotificationCenter()
) -> NotificationsPageModel {
    NotificationsPageModel(
        readPermission: { answers.next() },
        requestPermission: { request.next() },
        openSystemSettings: opened,
        notificationCenter: center
    )
}

// MARK: - Permission

@Test func settingsWindowNotificationsPermissionFollowsMacOSStatus() {
    #expect(NotificationPermission(.notDetermined) == .notDetermined)
    #expect(NotificationPermission(.denied) == .denied)
    #expect(NotificationPermission(.authorized) == .allowed)
    // Quiet delivery is delivery.
    #expect(NotificationPermission(.provisional) == .allowed)
}

@Test func settingsWindowNotificationsBannerSaysWhatEachPermissionNeeds() throws {
    let denied = try #require(NotificationPermissionBanner(.denied))
    #expect(denied.isWarning)
    #expect(denied.title == "Notifications are off for Cherry in System Settings.")
    #expect(denied.message == "Cherry can still mark tabs in the sidebar and play sounds.")
    #expect(denied.action == .openSystemSettings)
    #expect(denied.action.title == "Open System Settings…")

    let notAsked = try #require(NotificationPermissionBanner(.notDetermined))
    #expect(!notAsked.isWarning)
    #expect(notAsked.title == "Cherry asks to post notifications the first time it has one.")
    #expect(notAsked.message == nil)
    #expect(notAsked.action == .allowNotifications)
    #expect(notAsked.action.title == "Allow Notifications…")

    // Nothing to say when Cherry may post, or when this copy cannot post.
    #expect(NotificationPermissionBanner(.allowed) == nil)
    #expect(NotificationPermissionBanner(.unavailable) == nil)
}

@Test @MainActor func settingsWindowNotificationsModelReadsOnStartAndWhenCherryComesToTheFront() async throws {
    let center = NotificationCenter()
    let answers = PermissionAnswers([.denied, .allowed])
    let model = permissionModel(reading: answers, center: center)

    // Nothing is read before the page shows: no banner meanwhile.
    #expect(model.permission == nil)
    #expect(model.banner == nil)
    #expect(answers.reads == 0)

    model.start()
    await model.reading?.value
    #expect(answers.reads == 1)
    #expect(model.permission == .denied)
    #expect(model.banner?.action == .openSystemSettings)

    // The user turns them on in System Settings and comes back.
    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(await eventually { answers.reads == 2 })
    await model.reading?.value
    #expect(model.permission == .allowed)
    #expect(model.banner == nil)

    // Another notification reads nothing.
    center.post(name: NSApplication.didResignActiveNotification, object: nil)
    await Task.yield()
    #expect(answers.reads == 2)
}

@Test @MainActor func settingsWindowNotificationsAStartedModelObservesOnlyItsOwnCenterOnce() async {
    let center = NotificationCenter()
    let answers = PermissionAnswers([.notDetermined])
    let model = permissionModel(reading: answers, center: center)
    model.start()
    model.start()
    await model.reading?.value
    #expect(answers.reads == 2)

    // One activation, one read, though the page started twice.
    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(await eventually { answers.reads == 3 })
    try? await Task.sleep(for: .milliseconds(50))
    #expect(answers.reads == 3)
}

@Test @MainActor func settingsWindowNotificationsAReadThatAnswersLateChangesNothing() async {
    let pending = PendingReads()
    let model = NotificationsPageModel(
        readPermission: { await pending.read() },
        requestPermission: { .allowed },
        openSystemSettings: {},
        notificationCenter: NotificationCenter()
    )
    model.refresh()
    #expect(await eventually { pending.waiting.count == 1 })
    model.refresh()
    #expect(await eventually { pending.waiting.count == 2 })
    let newer = model.reading

    // The newer read answers first; the older one's answer is stale.
    pending.waiting[1].resume(returning: .allowed)
    await newer?.value
    #expect(model.permission == .allowed)
    pending.waiting[0].resume(returning: .denied)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(model.permission == .allowed)
}

@Test @MainActor func settingsWindowNotificationsBannerButtonsAskMacOSOrOpenSystemSettings() async {
    let request = PermissionAnswers([.allowed])
    let opened = Count()
    let model = permissionModel(
        reading: PermissionAnswers([.notDetermined]),
        requesting: request,
        opened: { opened.add() }
    )
    model.start()
    await model.reading?.value
    #expect(model.banner?.action == .allowNotifications)

    model.perform(.allowNotifications)
    #expect(model.isRequesting)
    // A second click while macOS asks does not ask again.
    model.perform(.allowNotifications)
    await model.reading?.value
    #expect(request.reads == 1)
    #expect(!model.isRequesting)
    #expect(model.permission == .allowed)
    #expect(model.banner == nil)
    #expect(opened.value == 0)

    model.perform(.openSystemSettings)
    #expect(opened.value == 1)
    #expect(request.reads == 1)
}

@Test @MainActor func settingsWindowNotificationsAnAnswerThatComesAfterAnotherReadIsReadAgain() async {
    let answers = PermissionAnswers([.notDetermined, .notDetermined, .allowed])
    let request = PendingReads()
    let center = NotificationCenter()
    let model = NotificationsPageModel(
        readPermission: { answers.next() },
        requestPermission: { await request.read() },
        openSystemSettings: {},
        notificationCenter: center
    )
    model.start()
    await model.reading?.value
    #expect(model.permission == .notDetermined)

    model.perform(.allowNotifications)
    #expect(await eventually { request.waiting.count == 1 })
    // Cherry comes to the front while macOS asks: that read answers
    // before the user does.
    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(await eventually { answers.reads == 2 })
    await model.reading?.value
    #expect(model.permission == .notDetermined)
    #expect(model.isRequesting)

    // The user allows. The newer read already answered, so the page
    // reads once more and shows the answer.
    request.waiting[0].resume(returning: .allowed)
    #expect(await eventually { answers.reads == 3 })
    await model.reading?.value
    #expect(model.permission == .allowed)
    #expect(!model.isRequesting)
    #expect(model.banner == nil)
}

@Test func settingsWindowNotificationsSystemSettingsOpensAtCherry() {
    #expect(NotificationsPageModel.systemSettingsURL(bundleIdentifier: "dev.patrick.cherry").absoluteString
        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.patrick.cherry")
    #expect(NotificationsPageModel.systemSettingsURL(bundleIdentifier: nil).absoluteString
        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    #expect(NotificationsPageModel.systemSettingsURL(bundleIdentifier: "").absoluteString
        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
}

@Test @MainActor func settingsWindowNotificationsPermissionIsUnavailableOutsideAnAppBundle() async {
    // The test runner is no app bundle: neither call reaches
    // UNUserNotificationCenter, which raises there.
    #expect(Bundle.main.bundleURL.pathExtension != "app")
    #expect(await TerminalNotificationCenter.shared.permission() == .unavailable)
    #expect(await TerminalNotificationCenter.shared.requestAuthorizationNow() == .unavailable)
}

// MARK: - Terminal bell

@Test @MainActor func settingsWindowNotificationsBellBeepsOnlyWhenSetToBeep() {
    var beeps = 0
    TerminalBell.ring(.beep) { beeps += 1 }
    #expect(beeps == 1)
    TerminalBell.ring(.silent) { beeps += 1 }
    #expect(beeps == 1)
}

@Test @MainActor func settingsWindowNotificationsBellIsStoredAndReadBack() {
    let defaults = privateDefaults("SettingsWindowNotifications")
    let settings = notificationsSettings(defaults)
    #expect(settings.terminalBell == .beep)
    #expect(settings.source(of: .terminalBell) == .cherryDefault)

    settings.terminalBell = .silent
    #expect(defaults.string(forKey: TerminalSettings.Setting.terminalBell.rawValue) == "silent")
    #expect(settings.source(of: .terminalBell) == .setHere)
    #expect(settings.valueText(.terminalBell) == "Silent")

    let reloaded = notificationsSettings(defaults)
    #expect(reloaded.terminalBell == .silent)
    #expect(reloaded.source(of: .terminalBell) == .setHere)
    let state = SettingsSourceState.terminal(.terminalBell, in: reloaded)
    #expect(state.badgeText == "Set here")
    #expect(state.rowReset?.title == "Reset to default (Beep)")

    // Beep again is the default: no badge.
    reloaded.terminalBell = .beep
    #expect(reloaded.source(of: .terminalBell) == .cherryDefault)
    #expect(notificationsSettings(defaults).terminalBell == .beep)
}

// MARK: - Background sessions

@Test @MainActor func settingsWindowNotificationsBackgroundSwitchesKeepTheirKeys() {
    let defaults = privateDefaults("SettingsWindowNotifications")
    let settings = notificationsSettings(defaults)
    #expect(settings.notifyWhenBackgroundProgramNeedsInput)
    #expect(!settings.notifyWhenBackgroundProgramFinishes)
    #expect(settings.noticeBackgroundSessionsAtLaunch)

    settings.notifyWhenBackgroundProgramNeedsInput = false
    settings.notifyWhenBackgroundProgramFinishes = true
    settings.noticeBackgroundSessionsAtLaunch = false
    // The keys Background Sessions and its launch notice read.
    #expect(defaults.object(forKey: "sessions.background.notifyNeedsInput") as? Bool == false)
    #expect(defaults.object(forKey: "sessions.background.notifyFinished") as? Bool == true)
    #expect(defaults.object(forKey: "sessions.backgroundNoticeAtLaunch") as? Bool == false)
    for setting in NotificationsSettingsPage.resetSettings where setting != .terminalBell {
        #expect(settings.source(of: setting) == .setHere, Comment(rawValue: setting.rawValue))
    }
}

@Test @MainActor func settingsWindowNotificationsALaunchArgumentMakesTheLaunchNoticeThisRunOnly() {
    let defaults = privateDefaults("SettingsWindowNotifications")
    let settings = notificationsSettings(defaults, launchArguments: [
        TerminalSettings.Setting.noticeBackgroundSessionsAtLaunch.rawValue: false,
    ])
    #expect(!settings.noticeBackgroundSessionsAtLaunch)
    #expect(settings.source(of: .noticeBackgroundSessionsAtLaunch) == .launchArgument(applied: true))
    // Read-only: the page disables its switch.
    let state = SettingsSourceState.terminal(.noticeBackgroundSessionsAtLaunch, in: settings)
    #expect(state.badgeText == "This run only")
    #expect(!state.source.isEditable)
    #expect(state.rowReset == nil)
    #expect(state.lines.first?.detail == "-sessions.backgroundNoticeAtLaunch")
    // The other rows stay editable.
    #expect(settings.source(of: .notifyWhenBackgroundProgramNeedsInput).isEditable)

    // Reset Notifications… neither lists nor resets it.
    settings.terminalBell = .silent
    #expect(settings.changes(in: NotificationsSettingsPage.resetSettings).map(\.title) == ["Bell"])
    settings.reset(NotificationsSettingsPage.resetSettings)
    #expect(!settings.noticeBackgroundSessionsAtLaunch)
    #expect(settings.terminalBell == .beep)
}

@Test @MainActor func settingsWindowNotificationsLinkOpensSessionsAtItsBackgroundSessions() {
    let navigator = SettingsNavigator(initial: .page(.notifications))
    #expect(NotificationsSettingsPage.backgroundSessionsLinkTitle == "Background sessions are listed in Sessions")
    NotificationsSettingsPage.showBackgroundSessions(navigator: navigator)
    #expect(navigator.route == .page(.sessions))
    #expect(navigator.highlight.row == .sessionsBackground)
    #expect(navigator.canGoBack)
}

// MARK: - Reset Notifications…

@Test @MainActor func settingsWindowNotificationsResetListsAndResetsOnlyItsFourSettings() throws {
    let defaults = privateDefaults("SettingsWindowNotifications")
    let settings = notificationsSettings(defaults)
    settings.notifyWhenBackgroundProgramNeedsInput = false
    settings.notifyWhenBackgroundProgramFinishes = true
    settings.noticeBackgroundSessionsAtLaunch = false
    settings.terminalBell = .silent
    settings.closeTabsOnCleanExit = false
    settings.fontSize = 16
    settings.projectColorDisplayMode = .tinted

    #expect(NotificationsSettingsPage.resetSettings == [
        .notifyWhenBackgroundProgramNeedsInput, .notifyWhenBackgroundProgramFinishes,
        .noticeBackgroundSessionsAtLaunch, .terminalBell,
    ])
    let changes = settings.changes(in: NotificationsSettingsPage.resetSettings)
    #expect(changes.map(\.title) == [
        "Notify me when a background program needs me",
        "Notify me when a background program finishes",
        "Tell me about background sessions when Cherry opens",
        "Bell",
    ])

    let terminalChanges = TerminalChangeCount()
    let observer = NotificationCenter.default.addObserver(
        forName: .terminalSettingsDidChange,
        object: settings,
        queue: nil
    ) { _ in terminalChanges.value += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    let confirmation = SettingsConfirmation.pageReset(changes: changes, mentionsGhosttyConfig: false) {
        settings.reset(NotificationsSettingsPage.resetSettings)
    }
    #expect(confirmation.title == "Reset 4 settings?")
    #expect(confirmation.message == "Notify me when a background program needs me Off → On · "
        + "Notify me when a background program finishes On → Off · "
        + "Tell me about background sessions when Cherry opens Off → On · Bell Silent → Beep.")
    #expect(confirmation.choices.map(\.title) == ["Reset", "Cancel"])
    try #require(confirmation.choices.first).perform()

    #expect(settings.notifyWhenBackgroundProgramNeedsInput)
    #expect(!settings.notifyWhenBackgroundProgramFinishes)
    #expect(settings.noticeBackgroundSessionsAtLaunch)
    #expect(settings.terminalBell == .beep)
    for setting in NotificationsSettingsPage.resetSettings {
        #expect(defaults.object(forKey: setting.rawValue) == nil, Comment(rawValue: setting.rawValue))
    }
    // None of them changes a terminal: no live surface is rebuilt.
    #expect(terminalChanges.value == 0)
    // Nothing left to reset: Reset Notifications… is off.
    #expect(settings.changes(in: NotificationsSettingsPage.resetSettings).isEmpty)
    // The other pages' settings stay.
    #expect(!settings.closeTabsOnCleanExit)
    #expect(settings.fontSize == 16)
    #expect(settings.projectColorDisplayMode == .tinted)
}

// MARK: - Search

@MainActor
private func notificationsSearchContext(_ settings: TerminalSettings, defaults: UserDefaults) -> SettingsSearchContext {
    SettingsSearchContext(
        terminal: settings,
        agents: AgentSettings(defaults: defaults),
        defaults: defaults,
        homeDirectory: "/Users/someone"
    )
}

@Test @MainActor func settingsWindowNotificationsSearchRowsShowTheValuesInUse() {
    let defaults = privateDefaults("SettingsWindowNotifications")
    let settings = notificationsSettings(defaults)
    let context = notificationsSearchContext(settings, defaults: defaults)

    let rows = NotificationsSettingsPage.searchRows(in: context)
    #expect(rows.map(\.id) == [
        .notificationsBackground, .notificationsBackgroundFinished, .notificationsLaunchNotice, .notificationsBell,
    ])
    #expect(rows.map(\.section) == ["Background sessions", "Background sessions", "Background sessions", "Terminal bell"])
    #expect(rows.map(\.value) == ["On", "Off", "On", "Beep"])
    #expect(rows.allSatisfy { $0.route == .page(.notifications) })
    #expect(rows.last?.help == "What a program's bell does in a tab.")

    settings.terminalBell = .silent
    settings.notifyWhenBackgroundProgramFinishes = true
    let changed = NotificationsSettingsPage.searchRows(in: context)
    #expect(changed.map(\.value) == ["On", "On", "On", "Silent"])
}

@Test @MainActor func settingsWindowNotificationsSearchFindsTheBellAndTheNotifySwitches() throws {
    let defaults = privateDefaults("SettingsWindowNotifications")
    let settings = notificationsSettings(defaults)
    let rows = SettingsSearchIndex.rows(in: notificationsSearchContext(settings, defaults: defaults))
    func results(_ query: String) -> [SettingsRowID] {
        SettingsSearchIndex.groups(for: query, in: rows)
            .first { $0.kind == .page(.notifications) }?
            .results.map(\.id) ?? []
    }

    // "bell": the page, by its words, then Terminal bell › Bell.
    let bell = try #require(
        SettingsSearchIndex.groups(for: "bell", in: rows).first { $0.kind == .page(.notifications) }
    )
    #expect(bell.results.first?.row.opensPage == true)
    #expect(bell.results.first?.row.route == .page(.notifications))
    let bellRow = try #require(bell.results.first { $0.id == .notificationsBell })
    #expect(bellRow.row.detail == "Terminal bell · Beep")

    // "beep": the bell, by its value.
    #expect(results("beep").contains(.notificationsBell))
    // "notify": both notify switches, by their titles.
    let notify = results("notify")
    #expect(notify.contains(.notificationsBackground))
    #expect(notify.contains(.notificationsBackgroundFinished))
    // "startup": the launch notice, by its words.
    #expect(results("startup") == [.notificationsLaunchNotice])
}
