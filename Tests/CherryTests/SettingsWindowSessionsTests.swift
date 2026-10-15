import Foundation
import SwiftUI
import Testing
@testable import Cherry

// Settings › Sessions (SessionsSettingsPage.swift): its banner, the Tabs
// note, the background sessions' title, Restart Host…'s question, what a
// launch argument does to its rows, its link to Notifications and its
// search rows. The session host's header is `SessionHostDiagnostics`
// (HostControlDiagnosticsTests.swift). Nothing here reaches the app's
// shared models, a host or the pasteboard.

@Test func settingsWindowSessionsBackgroundTitleCountsRunningThenEndedSessions() {
    #expect(SessionsSettingsPage.backgroundSessionsTitle(count: 0, running: 0) == "No sessions are running in the background")
    #expect(SessionsSettingsPage.backgroundSessionsTitle(count: 1, running: 1) == "1 session is running in the background")
    #expect(SessionsSettingsPage.backgroundSessionsTitle(count: 3, running: 3) == "3 sessions are running in the background")
    // Ended ones are named only when none runs.
    #expect(SessionsSettingsPage.backgroundSessionsTitle(count: 5, running: 2) == "2 sessions are running in the background")
    #expect(SessionsSettingsPage.backgroundSessionsTitle(count: 1, running: 0) == "1 ended session is in the background")
    #expect(SessionsSettingsPage.backgroundSessionsTitle(count: 2, running: 0) == "2 ended sessions are in the background")
}

@Test func settingsWindowSessionsBannerShowsOnlyWhenSomethingIsWrong() throws {
    #expect(SessionsSettingsPage.banner(unavailableReason: nil, lastLaunchFailure: nil) == nil)

    let unavailable = try #require(SessionsSettingsPage.banner(
        unavailableReason: "Cherry is running from a disk image.",
        lastLaunchFailure: nil
    ))
    #expect(unavailable.title == "Local sessions are unavailable")
    #expect(unavailable.message == "Cherry is running from a disk image. New tabs run as regular terminals until then.")

    let failure = try #require(SessionsSettingsPage.banner(
        unavailableReason: nil,
        lastLaunchFailure: "The session host did not answer in time."
    ))
    #expect(failure.title == "A tab is not a persistent session")
    #expect(failure.message == "The session host did not answer in time. It runs as a regular terminal; Retry on the tab, or restart it, to try again.")

    // Sessions that cannot run at all say so first.
    let both = try #require(SessionsSettingsPage.banner(
        unavailableReason: "Cherry is running from a disk image.",
        lastLaunchFailure: "The session host did not answer in time."
    ))
    #expect(both.title == "Local sessions are unavailable")
}

@Test func settingsWindowSessionsTabsNoteShowsWithoutPersistentSessions() {
    let note = "Without persistent sessions Cherry can't see a shell's exit status, so a terminal tab closes whenever its shell ends."
    #expect(SessionsSettingsPage.tabsNote(persistLocalSessions: true, unavailableReason: nil) == nil)
    #expect(SessionsSettingsPage.tabsNote(persistLocalSessions: false, unavailableReason: nil) == note)
    #expect(SessionsSettingsPage.tabsNote(persistLocalSessions: true, unavailableReason: "Cherry is running from a disk image.") == note)
}

@Test @MainActor func settingsWindowSessionsRestartAsksFirstWithADestructiveButton() {
    var restarts = 0
    let confirmation = SessionsSettingsPage.restartConfirmation { restarts += 1 }
    #expect(confirmation == SettingsConfirmation(
        title: "Restart the session host?",
        message: "The host that runs your persistent sessions stops and starts again. Your programs keep running, and their tabs reconnect in a moment.",
        choices: [
            SettingsConfirmation.Choice("Restart Host", role: .destructive),
            .cancel(),
        ]
    ))
    #expect(restarts == 0)
    confirmation.choices[0].perform()
    #expect(restarts == 1)
    confirmation.choices[1].perform()
    #expect(restarts == 1)
}

@Test @MainActor func settingsWindowSessionsLaunchArgumentsMakeTheirRowsReadOnly() throws {
    // `-sessions.persistLocal '<false/>' -sessions.onQuit keep`, as scripted
    // runs launch.
    let scripted = TerminalSettings(
        defaults: privateDefaults("SettingsWindowSessionsArguments"),
        launchArguments: ["sessions.persistLocal": false, "sessions.onQuit": "keep"]
    )
    for setting in [TerminalSettings.Setting.persistLocalSessions, .localSessionsOnQuit] {
        let state = SettingsSourceState.terminal(setting, in: scripted)
        #expect(state.source == .launchArgument(applied: true), Comment(rawValue: setting.rawValue))
        #expect(!state.source.isEditable, Comment(rawValue: setting.rawValue))
        #expect(state.badgeText == "This run only", Comment(rawValue: setting.rawValue))
        // No ↺ and no Reset to default: there is nothing here to reset.
        #expect(state.rowReset == nil, Comment(rawValue: setting.rawValue))
        #expect(state.buttons.isEmpty, Comment(rawValue: setting.rawValue))
        #expect(state.lines.first?.detail == "-\(setting.rawValue)", Comment(rawValue: setting.rawValue))
    }
    // A row no argument sets stays editable.
    #expect(SettingsSourceState.terminal(.closeTabsOnCleanExit, in: scripted).source.isEditable)

    // Changed here (or by "Don't ask again"): Set here, with ↺ to the default.
    let defaults = privateDefaults("SettingsWindowSessionsSetHere")
    let settings = TerminalSettings(defaults: defaults, launchArguments: [:])
    settings.localSessionsOnQuit = .keep
    let onQuit = SettingsSourceState.terminal(.localSessionsOnQuit, in: settings)
    #expect(onQuit.source == .setHere)
    #expect(onQuit.source.isEditable)
    let reset = try #require(onQuit.rowReset)
    #expect(reset.title == "Reset to default (Ask)")
    reset.perform()
    #expect(settings.localSessionsOnQuit == .ask)
    #expect(defaults.object(forKey: "sessions.onQuit") == nil)
    #expect(SettingsSourceState.terminal(.localSessionsOnQuit, in: settings).source == .cherryDefault)
}

@Test @MainActor func settingsWindowSessionsLinkOpensNotificationsAtBackgroundSessions() {
    let navigator = SettingsNavigator(initial: .page(.sessions))
    SessionsSettingsPage.showBackgroundNotifications(navigator)
    #expect(navigator.route == .page(.notifications))
    #expect(navigator.highlight.row == .notificationsBackground)
    #expect(navigator.backHistory == [.page(.sessions)])
}

@Test @MainActor func settingsWindowSessionsSearchFindsItsRows() throws {
    let defaults = privateDefaults("SettingsWindowSessionsSearch")
    let rows = SettingsSearchIndex.rows(in: SettingsSearchContext(
        terminal: TerminalSettings(defaults: defaults, launchArguments: [:]),
        agents: AgentSettings(defaults: defaults),
        defaults: defaults
    ))
    func sessionsResults(_ query: String) -> [SettingsRowID] {
        SettingsSearchIndex.groups(for: query, in: rows)
            .first { $0.kind == .page(.sessions) }?
            .results.map(\.id) ?? []
    }

    #expect(sessionsResults("quit").contains(.sessionsOnQuit))
    let daemon = sessionsResults("daemon")
    #expect(daemon.contains(.sessionsHost))
    #expect(daemon.contains(.sessionsPersistLocal))
    #expect(sessionsResults("host").contains(.sessionsHost))
    #expect(sessionsResults("diagnostics") == [.sessionsHost])
    #expect(sessionsResults("socket").first == .sessionsHost)
    #expect(sessionsResults("end all") == [.sessionsBackground])
    #expect(sessionsResults("exit status") == [.sessionsCloseTabOnExit])

    // Rows say their values.
    let onQuit = try #require(rows.first { $0.id == .sessionsOnQuit })
    #expect(onQuit.section == "Persistent sessions")
    #expect(onQuit.value == "Ask")
    let background = try #require(rows.first { $0.id == .sessionsBackground })
    #expect(background.section == "Background sessions")
    #expect(background.value == "No sessions are running in the background")
    // Every row opens the Sessions page.
    let ids: [SettingsRowID] = [.sessionsHost, .sessionsPersistLocal, .sessionsOnQuit, .sessionsCloseTabOnExit, .sessionsBackground]
    for id in ids {
        #expect(rows.first { $0.id == id }?.route == .page(.sessions), Comment(rawValue: id.rawValue))
    }
}
