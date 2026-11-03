import AppKit
import Foundation
import os
import Testing
@testable import Cherry

// The Settings window's navigation (SettingsNavigation.swift,
// SettingsSidebar.swift): pages and routes, the navigator's history, the
// window's keys, opening Settings at a row, the status item and the
// sidebar's rows. Each test makes its own navigator, never `.shared`, and
// private defaults: nothing here opens a window or runs `cherry`.

/// What the closures a test hands the navigation code were called with.
@MainActor
private final class NavigationCallLog {
    var calls: [String] = []
}

private func keyDown(_ characters: String, modifiers: NSEvent.ModifierFlags = [.command]) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    ))
}

// MARK: - Pages

@Test func settingsWindowPagesAreInTheSidebarsOrderAndGroups() {
    #expect(SettingsPage.allCases == [
        .sessions, .interface, .themes, .terminal, .shortcuts, .notifications, .macs, .agents, .projects, .updates,
    ])
    #expect(SettingsPage.allCases.map(\.title) == [
        "Sessions", "Interface", "Themes", "Terminal", "Shortcuts", "Notifications", "Macs", "Agents",
        "Projects", "Updates",
    ])
    #expect(SettingsPage.allCases.map(\.sidebarGroup) == [0, 1, 1, 2, 2, 2, 3, 3, 3, 4])
    #expect(SettingsSidebarItems.pages(inGroup: 2).map(\.route) == [
        .page(.terminal), .page(.shortcuts), .page(.notifications),
    ])
    #expect(SettingsSidebarItems.pages(inGroup: 0).map(\.route) == [.page(.sessions)])
}

@Test func settingsWindowPageTilesAreTheBoardsColorsAndGlyphs() {
    #expect(SettingsPage.sessions.tile == .cherry)
    #expect(SettingsPage.interface.tile == SettingsTileStyle(.symbol("sidebar.left"), background: "#6366F1"))
    #expect(SettingsPage.themes.tile == SettingsTileStyle(.symbol("paintpalette.fill"), background: "#EC4899"))
    #expect(SettingsPage.terminal.tile == SettingsTileStyle(
        .symbol("apple.terminal"),
        background: "#232326",
        foreground: "#4ADE80"
    ))
    #expect(SettingsPage.shortcuts.tile == SettingsTileStyle(.symbol("command"), background: "#8E8E93"))
    #expect(SettingsPage.notifications.tile == SettingsTileStyle(.symbol("bell.fill"), background: "#F97316"))
    #expect(SettingsPage.macs.tile == SettingsTileStyle(.symbol("desktopcomputer"), background: "#0A84FF"))
    #expect(SettingsPage.agents.tile == SettingsTileStyle(.symbol("sparkles"), background: "#A855F7"))
    #expect(SettingsPage.projects.tile == SettingsTileStyle(.symbol("folder.fill"), background: "#D98E04"))
    #expect(SettingsPage.updates.tile == SettingsTileStyle(.symbol("arrow.down.circle"), background: "#22A55B"))
}

@Test func settingsWindowRowIDsThatCrossPagesKeepTheirNames() {
    #expect(SettingsRowID.agentsList.rawValue == "agents.list")
    #expect(SettingsRowID.agentsCherryCommand.rawValue == "agents.mcpServer")
    #expect(SettingsRowID.notificationsBackground.rawValue == "notifications.background")
    #expect(SettingsRowID.sessionsBackground.rawValue == "sessions.background")
    #expect(SettingsRowID.terminalKeyBindings.rawValue == "terminal.keyBindings")
    #expect(SettingsRowID.terminalGhosttyConfig.rawValue == "terminal.ghosttyConfig")
    #expect(SettingsRowID.shortcutsTerminalKeyBindings.rawValue == "shortcuts.terminalKeyBindings")
    #expect(SettingsRowID.macsList.rawValue == "macs.list")
}

// MARK: - Navigator

@Test @MainActor func settingsWindowNavigatorStartsOnInterfaceWithNoHistory() {
    let navigator = SettingsNavigator()

    #expect(navigator.route == .page(.interface))
    #expect(!navigator.canGoBack)
    #expect(!navigator.canGoForward)
    #expect(navigator.highlight.row == nil)
}

@Test @MainActor func settingsWindowOpeningAPagePushesHistoryAndEndsForward() {
    let navigator = SettingsNavigator()
    navigator.open(.page(.terminal))
    navigator.open(.agent("claude"))

    #expect(navigator.route == .agent("claude"))
    #expect(navigator.backHistory == [.page(.interface), .page(.terminal)])
    #expect(navigator.canGoBack)
    #expect(!navigator.canGoForward)

    navigator.goBack()
    #expect(navigator.route == .page(.terminal))
    #expect(navigator.canGoForward)

    // A page opened from there ends what Forward had.
    navigator.open(.page(.updates))
    #expect(navigator.route == .page(.updates))
    #expect(navigator.forwardHistory.isEmpty)
    #expect(!navigator.canGoForward)
    #expect(navigator.backHistory == [.page(.interface), .page(.terminal)])
}

@Test @MainActor func settingsWindowBackAndForwardWalkTheHistory() {
    let navigator = SettingsNavigator()
    navigator.open(.page(.themes))
    navigator.open(.project("/work/cherry"))

    navigator.goBack()
    navigator.goBack()
    #expect(navigator.route == .page(.interface))
    #expect(!navigator.canGoBack)
    #expect(navigator.forwardHistory == [.project("/work/cherry"), .page(.themes)])

    // Nothing further back.
    navigator.goBack()
    #expect(navigator.route == .page(.interface))

    navigator.goForward()
    #expect(navigator.route == .page(.themes))
    navigator.goForward()
    #expect(navigator.route == .project("/work/cherry"))
    #expect(!navigator.canGoForward)
    navigator.goForward()
    #expect(navigator.route == .project("/work/cherry"))
    #expect(navigator.backHistory == [.page(.interface), .page(.themes)])
}

@Test @MainActor func settingsWindowOpeningThePageShownPushesNothing() {
    let navigator = SettingsNavigator()
    navigator.open(.page(.macs))
    navigator.open(.page(.macs))
    navigator.open(.page(.macs), row: .macsList)

    #expect(navigator.backHistory == [.page(.interface)])
    #expect(navigator.route == .page(.macs))
}

@Test @MainActor func settingsWindowOpeningARowFlashesItEachTime() {
    let navigator = SettingsNavigator()
    navigator.open(.page(.terminal))
    #expect(navigator.highlight.generation == 0)
    #expect(navigator.highlight.row == nil)

    navigator.open(.page(.terminal), row: .terminalGhosttyConfig)
    #expect(navigator.highlight.row == .terminalGhosttyConfig)
    #expect(navigator.highlight.generation == 1)

    // The same row again flashes again; another page's row moves it.
    navigator.open(.page(.terminal), row: .terminalGhosttyConfig)
    #expect(navigator.highlight.generation == 2)
    navigator.open(.page(.notifications), row: .notificationsBackground)
    #expect(navigator.highlight.row == .notificationsBackground)
    #expect(navigator.highlight.generation == 3)
    #expect(navigator.route == .page(.notifications))

    // Back and Forward flash nothing.
    navigator.goBack()
    #expect(navigator.highlight.generation == 3)
}

@Test @MainActor func settingsWindowReconcileDropsAGoneAgentAndProjectAndFallsBack() {
    let navigator = SettingsNavigator()
    navigator.open(.agent("claude"))
    navigator.open(.project("/work/api"))
    navigator.open(.page(.terminal))
    navigator.open(.agent("codex"))

    // Codex was deleted while its page showed, and the api project removed.
    navigator.reconcile(agentIDs: ["claude"], projectRoots: ["/work/cherry"])
    #expect(navigator.route == .page(.agents))
    #expect(navigator.backHistory == [.page(.interface), .agent("claude"), .page(.terminal)])

    // A project's page falls back to Projects; repeats the drop leaves go.
    navigator.open(.project("/work/cherry"))
    navigator.open(.page(.projects))
    navigator.open(.project("/work/docs"))
    navigator.reconcile(agentIDs: ["claude"], projectRoots: ["/work/cherry"])
    #expect(navigator.route == .page(.projects))
    #expect(navigator.backHistory == [
        .page(.interface), .agent("claude"), .page(.terminal), .page(.agents), .project("/work/cherry"),
    ])

    // Forward loses gone pages too.
    navigator.goBack()
    navigator.goBack()
    #expect(navigator.forwardHistory == [.page(.projects), .project("/work/cherry")])
    navigator.reconcile(agentIDs: [], projectRoots: [])
    #expect(navigator.route == .page(.agents))
    #expect(navigator.forwardHistory == [.page(.projects)])
    #expect(navigator.backHistory == [.page(.interface), .page(.terminal)])
    #expect(navigator.canGoBack)
    #expect(navigator.canGoForward)
}

@Test @MainActor func settingsWindowReconcileLeavesPagesThatStillExistAlone() {
    let navigator = SettingsNavigator()
    navigator.open(.agent("claude"))
    navigator.open(.project("/work/cherry"))

    navigator.reconcile(agentIDs: ["claude"], projectRoots: ["/work/cherry"])
    #expect(navigator.route == .project("/work/cherry"))
    #expect(navigator.backHistory == [.page(.interface), .agent("claude")])
}

@Test @MainActor func settingsWindowRenamingAnAgentRepointsItsPageAndHistory() {
    let navigator = SettingsNavigator()
    navigator.open(.agent("claude"))
    navigator.open(.page(.themes))
    navigator.open(.agent("claude"))
    navigator.goBack()
    navigator.goBack()
    #expect(navigator.route == .agent("claude"))

    navigator.renameAgent(from: "claude", to: "claude work")
    #expect(navigator.route == .agent("claude work"))
    #expect(navigator.backHistory == [.page(.interface)])
    #expect(navigator.forwardHistory == [.agent("claude work"), .page(.themes)])

    // So a reconcile after the rename keeps them.
    navigator.reconcile(agentIDs: ["claude work"], projectRoots: [])
    #expect(navigator.route == .agent("claude work"))
    #expect(navigator.forwardHistory == [.agent("claude work"), .page(.themes)])
}

// MARK: - Opening Settings

@Test @MainActor func settingsWindowEditAgentsOpensAgentsAndMCPAtItsAgentsList() {
    let navigator = SettingsNavigator(initial: .page(.updates))
    var openedOn: [SettingsRoute] = []

    SettingsOpening.editAgents(navigator: navigator) {
        // The page is set before the window opens on it.
        openedOn.append(navigator.route)
    }

    #expect(openedOn == [.page(.agents)])
    #expect(navigator.route == .page(.agents))
    #expect(navigator.highlight.row == .agentsList)
    #expect(navigator.highlight.generation == 1)
    #expect(navigator.backHistory == [.page(.updates)])
}

@Test @MainActor func settingsWindowOpeningFromOutsideEndsASearchLeftInTheField() {
    let navigator = SettingsNavigator(searchRows: {
        [SettingsSearchRow(id: "terminal.fontSize", route: .page(.terminal), section: "Text", title: "Font size")]
    })
    navigator.search.text = "zzzz"
    #expect(navigator.search.hasNoResults)
    var opened = 0

    SettingsOpening.open(.page(.notifications), row: .notificationsBackground, navigator: navigator) { opened += 1 }

    // The sidebar shows the pages, with the one opened selected, and no
    // "No settings match" covers it.
    #expect(navigator.search.text.isEmpty)
    #expect(!navigator.search.isSearching)
    #expect(!navigator.search.hasNoResults)
    #expect(navigator.route == .page(.notifications))
    #expect(navigator.highlight.row == .notificationsBackground)
    #expect(opened == 1)
}

// MARK: - Keys

@Test func settingsWindowKeysAreCommandFAndTheBrackets() {
    #expect(SettingsKeyMonitor.action(for: "f", modifiers: [.command]) == .focusSearch)
    #expect(SettingsKeyMonitor.action(for: "[", modifiers: [.command]) == .goBack)
    #expect(SettingsKeyMonitor.action(for: "]", modifiers: [.command]) == .goForward)
    // Caps Lock and the flags AppKit adds are not modifiers held.
    #expect(SettingsKeyMonitor.action(for: "F", modifiers: [.command, .capsLock]) == .focusSearch)
    #expect(SettingsKeyMonitor.action(for: "[", modifiers: [.command, .function, .numericPad]) == .goBack)

    // Nothing else: other keys, other modifiers, no ⌘.
    #expect(SettingsKeyMonitor.action(for: "f", modifiers: []) == nil)
    #expect(SettingsKeyMonitor.action(for: "f", modifiers: [.command, .shift]) == nil)
    #expect(SettingsKeyMonitor.action(for: "f", modifiers: [.command, .option]) == nil)
    #expect(SettingsKeyMonitor.action(for: "[", modifiers: [.control]) == nil)
    #expect(SettingsKeyMonitor.action(for: ",", modifiers: [.command]) == nil)
    #expect(SettingsKeyMonitor.action(for: "w", modifiers: [.command]) == nil)
    #expect(SettingsKeyMonitor.action(for: nil, modifiers: [.command]) == nil)
}

@Test @MainActor func settingsWindowKeyMonitorTakesOnlyItsKeysInTheSettingsWindow() throws {
    let capture = SettingsKeyCapture()
    var performed: [SettingsKeyMonitor.Action] = []

    #expect(SettingsKeyMonitor.handle(try keyDown("f"), inSettingsWindow: true, capture: capture) { performed.append($0) })
    #expect(SettingsKeyMonitor.handle(try keyDown("]"), inSettingsWindow: true, capture: capture) { performed.append($0) })
    #expect(performed == [.focusSearch, .goForward])

    // Other keys go on to the window.
    #expect(!SettingsKeyMonitor.handle(try keyDown("w"), inSettingsWindow: true, capture: capture) { performed.append($0) })
    #expect(!SettingsKeyMonitor.handle(try keyDown("a", modifiers: []), inSettingsWindow: true, capture: capture) {
        performed.append($0)
    })
    // Another window's ⌘F is the menus' Find.
    #expect(!SettingsKeyMonitor.handle(try keyDown("f"), inSettingsWindow: false, capture: capture) { performed.append($0) })
    #expect(performed == [.focusSearch, .goForward])
}

@Test @MainActor func settingsWindowKeyCaptureSeesKeysFirstAndOnlyInTheSettingsWindow() throws {
    let capture = SettingsKeyCapture()
    let log = NavigationCallLog()
    var performed: [SettingsKeyMonitor.Action] = []
    capture.handler = { event in
        log.calls.append(event.charactersIgnoringModifiers ?? "")
        return true
    }

    // A page that records takes ⌘[ before Back does, and any other key.
    #expect(SettingsKeyMonitor.handle(try keyDown("["), inSettingsWindow: true, capture: capture) { performed.append($0) })
    #expect(SettingsKeyMonitor.handle(try keyDown("k", modifiers: [.shift]), inSettingsWindow: true, capture: capture) {
        performed.append($0)
    })
    #expect(log.calls == ["[", "k"])
    #expect(performed.isEmpty)

    // Never another window's.
    #expect(!SettingsKeyMonitor.handle(try keyDown("["), inSettingsWindow: false, capture: capture) { performed.append($0) })
    #expect(log.calls == ["[", "k"])

    // A capture that lets a key go leaves it to the window's keys.
    capture.handler = { _ in false }
    #expect(SettingsKeyMonitor.handle(try keyDown("["), inSettingsWindow: true, capture: capture) { performed.append($0) })
    #expect(performed == [.goBack])
}

// MARK: - Status item

@Test func settingsWindowStatusItemSaysWhatTheHostIsDoing() {
    typealias Summary = SettingsStatusItem.Summary
    func summary(
        _ status: SessionHostStatus?,
        problem: String? = nil,
        isRestarting: Bool = false,
        restartFailure: String? = nil,
        unavailableReason: String? = nil
    ) -> Summary {
        SettingsStatusItem.summary(
            status: status,
            problem: problem,
            isRestarting: isRestarting,
            restartFailure: restartFailure,
            unavailableReason: unavailableReason
        )
    }
    let running = SessionHostStatus(running: true, sessions: 3, runningSessions: 2)

    #expect(summary(running) == Summary(text: "Host running · 3 sessions", label: "3 sessions", tone: .green))
    #expect(summary(SessionHostStatus(running: true, sessions: 1)) == Summary(text: "Host running · 1 session", label: "1 session", tone: .green))
    #expect(summary(SessionHostStatus(running: true)) == Summary(text: "Host running", label: "Running", tone: .green))
    #expect(summary(SessionHostStatus(running: false, socket: "/tmp/host.sock")) == Summary(text: "Host not running", label: "Not running", tone: .gray))
    #expect(summary(nil) == Summary(text: "Checking…", label: "Checking…", tone: .gray))
    #expect(summary(running, isRestarting: true) == Summary(text: "Restarting…", label: "Restarting…", tone: .yellow))
    #expect(summary(running, restartFailure: "cherry restart failed (exit status 1).")
        == Summary(text: "Restart failed", label: "Restart failed", tone: .red))
    #expect(summary(nil, problem: "The cherry helper is missing.") == Summary(text: "Sessions unavailable", label: "Unavailable", tone: .orange))
    #expect(summary(running, unavailableReason: "Cherry runs from a disk image.")
        == Summary(text: "Sessions unavailable", label: "Unavailable", tone: .orange))
}

@Test @MainActor func settingsWindowStatusItemRunsOnlyCherryStatusAtMostEveryFiveSeconds() async {
    let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    let diagnostics = SessionHostDiagnostics(
        runner: { arguments in
            calls.withLock { $0.append(arguments) }
            return HostCommandOutput(status: 0, output: #"{"running":false}"#, errors: "")
        },
        unavailableReason: { nil },
        revealInFinder: { _ in },
        copyToPasteboard: { _ in }
    )
    var now = ContinuousClock.now
    let refresh = SettingsHostStatusRefresh(now: { now })

    await refresh.refresh(diagnostics)?.value
    // The window coming to the front right after it opened: no second run.
    #expect(refresh.refresh(diagnostics) == nil)
    now += .seconds(4)
    #expect(refresh.refresh(diagnostics) == nil)
    now += .seconds(1)
    await refresh.refresh(diagnostics)?.value

    // `cherry host status --json` only, which never starts a host.
    #expect(calls.withLock { $0 } == [["host", "status", "--json"], ["host", "status", "--json"]])
}

// MARK: - Sidebar rows

@Test func settingsWindowSidebarListsAgentsInTheirOrderWithLettersAndOff() {
    let items = SettingsSidebarItems.agents([
        AgentToolDefinition(name: "Codex", command: "codex", arguments: "--yolo"),
        AgentToolDefinition(name: "Claude", command: "claude"),
        AgentToolDefinition(name: "Gemini", command: "gemini", enabled: false),
        AgentToolDefinition(name: "reviewer", command: "my-agent"),
        AgentToolDefinition(name: "Work", command: "claude --model opus"),
    ])

    #expect(items.map(\.title) == ["Codex", "Claude", "Gemini", "reviewer", "Work"])
    #expect(items.map(\.route) == [
        .agent("codex"), .agent("claude"), .agent("gemini"), .agent("reviewer"), .agent("work"),
    ])
    // A CLI's letters; a custom agent's name's first two; an agent that runs
    // a known CLI under another name has that CLI's.
    #expect(items.map(\.tile.glyph) == [
        .letters("Cx"), .letters("Cl"), .letters("Ge"), .letters("Re"), .letters("Cl"),
    ])
    #expect(items.allSatisfy { $0.tile.background == "#55555C" })
    #expect(items.map(\.isOff) == [false, false, true, false, false])
    #expect(SettingsSidebarItems.offOpacity == 0.55)
}

@Test func settingsWindowSidebarListsThisMacsProjectsByNameInTheirColors() throws {
    let device = try #require(UUID(uuidString: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8"))
    let projects = [
        CherryProject(root: "/work/zeta"),
        CherryProject(root: "device:\(device.uuidString):/Users/me/code/api"),
        CherryProject(root: "/work/Alpha"),
        CherryProject(root: "/work/beta"),
    ]

    let items = SettingsSidebarItems.projects(projects) { root in
        root == "/work/beta" ? .green : nil
    }

    #expect(items.map(\.title) == ["Alpha", "beta", "zeta"])
    #expect(items.map(\.route) == [.project("/work/Alpha"), .project("/work/beta"), .project("/work/zeta")])
    #expect(items.map(\.tile.background) == ["#7C7C84", ProjectIdentityColor.green.hexRGB, "#7C7C84"])
    #expect(items.allSatisfy { $0.tile.glyph == .symbol("folder.fill") && !$0.isOff })
}

@Test @MainActor func settingsWindowSidebarProjectColorsComeFromTheProjectsAppearance() throws {
    let colored = try canonicalTemporaryDirectory("SettingsWindowNavigationColored")
    let plain = try canonicalTemporaryDirectory("SettingsWindowNavigationPlain")
    defer {
        try? FileManager.default.removeItem(at: colored)
        try? FileManager.default.removeItem(at: plain)
    }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowNavigation"))
    let coloredRoot = try #require(settings.addProject(path: colored.path)).root
    let plainRoot = try #require(settings.addProject(path: plain.path)).root
    try settings.setProjectAppearance(ProjectAppearanceSettings(color: .violet), for: coloredRoot, storage: .local)

    let items = SettingsSidebarItems.projects(settings.projects) { settings.projectAppearance(for: $0).color }
    let backgrounds = Dictionary(uniqueKeysWithValues: items.map { ($0.route, $0.tile.background) })

    #expect(backgrounds[.project(coloredRoot)] == "#8B5CF6")
    #expect(backgrounds[.project(plainRoot)] == "#7C7C84")
}
