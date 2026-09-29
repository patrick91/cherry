import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// The Omni bar (⌘P, ⌘O): its fuzzy matcher and ranking, frecency, the
// root's Recent, scopes and their prefixes, the backspace and Esc stack,
// a Mac's drill, the worktree create row, each kind's ⌘K actions and ⌘K's
// routing. Everything runs on injected sources: no window comes on screen,
// no host is asked and no real store is touched.

private let studioID = UUID(uuidString: "00000000-0000-0000-0000-00000000D00D")!
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func privateDefaults() -> UserDefaults {
    let name = "cherry-omni-bar-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func local(
    _ name: String,
    open: ProjectSwitcherModel.OpenStatus? = nil,
    current: Bool = false,
    lastOpened: Date? = nil
) -> ProjectSwitcherModel.Location {
    let path = "/Users/me/code/\(name)"
    return .init(
        machine: .thisMac, key: path, name: name, path: path,
        displayPath: ProjectSwitcherModel.displayPath(path, home: "/Users/me"),
        openStatus: open, isCurrent: current, lastOpened: lastOpened
    )
}

private func remote(_ name: String, open: ProjectSwitcherModel.OpenStatus? = nil) -> ProjectSwitcherModel.Location {
    let path = "/Users/me/code/\(name)"
    return .init(
        machine: .device(studioID), key: ProjectLocation.remote(deviceID: studioID, path: path).key, name: name, path: path,
        displayPath: ProjectSwitcherModel.displayPath(path, home: "/Users/me"), openStatus: open
    )
}

private let tabCodex = UUID()
private let tabShell = UUID()
private let tabPix = UUID()
private let tabStudio = UUID()

/// Design D's data, real-shaped: projects on two Macs, tabs of several
/// windows, a background session, worktrees and an agent.
private func fixture(extraProjects: Int = 0) -> OmniSources {
    let thisMac = ProjectSwitcherModel.MachineInfo(
        machine: .thisMac, name: "This Mac", status: "14 sessions", dot: .green, sessionCount: 14, detail: "",
        symbol: "laptopcomputer"
    )
    let studio = ProjectSwitcherModel.MachineInfo(
        machine: .device(studioID), name: "patstudio", status: "Connected · 2 sessions", dot: .green,
        sessionCount: 2, detail: ""
    )
    var locations = [
        local("cherry", open: .init(tabs: 2, workingAgents: 1), current: true, lastOpened: now),
        local("pix", open: .init(tabs: 1, workingAgents: 0), lastOpened: now.addingTimeInterval(-60)),
        local("strawberry.rocks", lastOpened: now.addingTimeInterval(-600)),
        local("fastapi-cli", lastOpened: now.addingTimeInterval(-900)),
        local("django-lsp"),
        local("sqlmodel"),
        local("shop"),
        remote("rignore", open: .init(tabs: 1, workingAgents: 0)),
        remote("cherry"),
    ]
    for index in 0 ..< extraProjects {
        locations.append(local("project-\(index)"))
    }
    var sources = OmniSources()
    sources.projects = ProjectSwitcherModel(machines: [thisMac, studio], locations: locations)
    sources.tabs = [
        OmniTab(id: tabCodex, title: "Codex persistent-sessions multiplexer", projectName: "cherry", machine: .thisMac, isWorking: true, canDetach: true),
        OmniTab(id: tabShell, title: "Shell 1", projectName: "cherry", machine: .thisMac, isWorking: false, canDetach: false),
        OmniTab(id: tabPix, title: "Shell 3", projectName: "pix", machine: .thisMac, isWorking: false, canDetach: true),
        OmniTab(id: tabStudio, title: "Shell 1", projectName: "rignore", machine: .device(studioID), isWorking: false, canDetach: true),
    ]
    sources.backgroundSessions = [
        OmniBackgroundSession(id: "s-graphql", title: "GraphQL core 3.3 references update", machine: .thisMac, isAtWork: true),
    ]
    sources.repositoryName = "cherry"
    sources.worktrees = [
        OmniWorktree(root: "/Users/me/code/cherry", name: "main", branch: "main", isActive: false, canRename: false, canRemove: false),
        OmniWorktree(root: "/Users/me/wt/persistent", name: "codex/persistent-sessions", branch: "codex/persistent-sessions", isActive: true, canRename: true, canRemove: true),
        OmniWorktree(root: "/Users/me/wt/jank", name: "fix-titlebar-jank", branch: "fix-titlebar-jank", isActive: false, canRename: true, canRemove: true),
    ]
    sources.window = OmniWindowContext(
        hasWorkspace: true, hasSelectedTab: true, canSplit: true, canDetach: true, canReopenClosedTab: true,
        hasProject: true, supportsWorktrees: true
    )
    sources.listedLocalProjects = ["/Users/me/code/cherry", "/Users/me/code/pix"]
    sources.worktreeProjectKeys = ["/Users/me/code/cherry"]
    sources.editorsByProjectKey = ["/Users/me/code/cherry": OmniEditor(id: "zed", name: "Zed")]
    sources.editors = [OmniEditor(id: "zed", name: "Zed"), OmniEditor(id: "xcode", name: "Xcode")]
    sources.agents = [OmniAgent(id: "claude", name: "Claude Code", commandLine: "claude")]
    sources.agentPresets = [OmniAgent(id: "codex", name: "Codex", commandLine: "codex"), OmniAgent(id: "custom", name: "Custom", commandLine: "")]
    return sources
}

@MainActor
private final class OmniRecorder {
    var run: [OmniCommand] = []
    var used: [String] = []
    var closed = 0

    func controller(_ sources: OmniSources = fixture(), frecency: [String: Double] = [:]) -> OmniBarController {
        OmniBarController(
            sources: sources,
            frecency: frecency,
            run: { [weak self] in self?.run.append($0) },
            recordUse: { [weak self] in self?.used.append($0) },
            close: { [weak self] in self?.closed += 1 }
        )
    }
}

private func titles(_ controller: OmniBarController) -> [String] {
    MainActor.assumeIsolated { controller.rows.map(\.item.title) }
}

@MainActor
private func select(_ title: String, detail: String? = nil, in controller: OmniBarController) throws {
    let index = try #require(controller.rows.firstIndex {
        $0.item.title == title && (detail == nil || $0.item.detail == detail)
    })
    controller.select(index)
}

// MARK: - Matching

@Test func omniMatcherRewardsWordStartsAndRunsAndSaysWhatMatched() throws {
    // A word start beats an earlier letter inside a word.
    let rocks = try #require(OmniMatcher.match("sr", in: "strawberry.rocks"))
    #expect(rocks.indices == [0, 11])
    let cli = try #require(OmniMatcher.match("fc", in: "fastapi-cli"))
    #expect(cli.indices == [0, 8])
    // A run of consecutive letters scores more than the same letters apart.
    #expect(OmniMatcher.match("cli", in: "fastapi-cli")?.indices == [8, 9, 10])
    let run = try #require(OmniMatcher.match("abc", in: "abcxyz"))
    let apart = try #require(OmniMatcher.match("abc", in: "axbycz"))
    #expect(run.score > apart.score)
    // Prefix, then exact, count more.
    let prefix = try #require(OmniMatcher.match("pix", in: "pixel"))
    let exact = try #require(OmniMatcher.match("pix", in: "pix"))
    let inside = try #require(OmniMatcher.match("pix", in: "a-pix"))
    #expect(exact.score > prefix.score && prefix.score > inside.score)
    // Case, diacritics and the query's spaces do not matter.
    #expect(OmniMatcher.match("CAFE", in: "café-maxxing")?.indices == [0, 1, 2, 3])
    #expect(OmniMatcher.match("new tab", in: "New Tab")?.indices == [0, 1, 2, 4, 5, 6])
    #expect(OmniMatcher.match("xyz", in: "cherry") == nil)
    #expect(OmniMatcher.match("cherryy", in: "cherry") == nil)
    #expect(OmniMatcher.match("", in: "cherry") == OmniMatch(score: 0, indices: []))
    // camelCase starts a word.
    #expect(OmniMatcher.match("gh", in: "gitHub")?.indices == [0, 3])
}

@Test func omniRankingPutsTheBetterMatchFirstAndFrecencyOrdersTheRest() {
    func item(_ title: String) -> OmniItem {
        OmniItem(id: "x:\(title)", kind: .project, title: title, symbol: "folder", primaryLabel: "Open", primary: .openProject(key: title))
    }
    let items = [item("chore-hunter-ery"), item("cherry"), item("Shell 1"), item("Shell 3")]
    // A heavily used loose match never beats a prefix one…
    let cherry = OmniRanking.rank(items, query: "cherry", frecency: ["x:chore-hunter-ery": 200])
    #expect(cherry.map(\.item.title) == ["cherry", "chore-hunter-ery"])
    // …but frecency orders matches of the same quality.
    let shells = OmniRanking.rank(items, query: "shell", frecency: ["x:Shell 3": 150])
    #expect(shells.map(\.item.title) == ["Shell 3", "Shell 1"])
    #expect(OmniRanking.rank(items, query: "shell", frecency: [:]).map(\.item.title) == ["Shell 1", "Shell 3"])
    // Matched characters come along for bold.
    #expect(shells.first?.matched == [0, 1, 2, 3, 4])
    #expect(OmniRanking.rank(items, query: "s", frecency: [:], limit: 1).count == 1)
    // Keywords match too (a project's path), without highlighting.
    var withPath = item("docs")
    withPath.keywords = ["~/strawberry/docs"]
    let byPath = OmniRanking.rank([withPath], query: "strawb", frecency: [:])
    #expect(byPath.map(\.item.title) == ["docs"] && byPath[0].matched.isEmpty)
}

// MARK: - Frecency

@Test @MainActor func omniFrecencyTakesOverThePalettesUsageAndCountsProjectWindows() throws {
    let defaults = privateDefaults()
    let legacy: [String: OmniFrecencyStore.Entry] = [
        "command:toggleAppearance": .init(selectionCount: 3, lastSelectedAt: now.addingTimeInterval(-7_200)),
    ]
    defaults.set(try JSONEncoder().encode(legacy), forKey: OmniFrecencyStore.legacyStorageKey)
    let store = OmniFrecencyStore(defaults: defaults)
    #expect(store.entries["command:toggleAppearance"]?.selectionCount == 3)
    // Saved under its own key from then on.
    #expect(defaults.data(forKey: OmniFrecencyStore.storageKey) != nil)

    store.recordUse(id: "tab:abc", at: now)
    store.recordUse(id: "tab:abc", at: now.addingTimeInterval(60))
    let restored = OmniFrecencyStore(defaults: defaults)
    #expect(restored.entries["tab:abc"]?.selectionCount == 2)
    let scores = restored.scores(at: now.addingTimeInterval(120), projectRecency: ["/Users/me/code/pix": now])
    // 2 uses (44) within the hour (80).
    #expect(scores["tab:abc"] == 124)
    // 3 uses (56), 2 hours ago (60).
    #expect(scores["command:toggleAppearance"] == 116)
    // A project whose window came to the front a minute ago.
    #expect(scores["project:/Users/me/code/pix"] == 80)
}

// MARK: - The root

@Test @MainActor func omniRootRecentMixesKindsByFrecency() {
    let recorder = OmniRecorder()
    let frecency: [String: Double] = [
        "project:/Users/me/code/sqlmodel": 200,
        "project:/Users/me/code/shop": 190,
        "project:/Users/me/code/django-lsp": 180,
        "project:/Users/me/code/fastapi-cli": 170,
        "tab:\(tabPix.uuidString)": 160,
        "mac:\(studioID.uuidString)": 120,
        "command:newTab": 100,
    ]
    let controller = recorder.controller(frecency: frecency)
    #expect(controller.sections.map(\.title) == ["Recent"])
    let rows = controller.rows
    #expect(rows.count == OmniRanking.recentLimit)
    let kinds = rows.map(\.item.kind)
    #expect(kinds.filter { $0 == .project }.count == OmniRanking.recentPerKindLimit)
    #expect(kinds.contains(.tab) && kinds.contains(.mac) && kinds.contains(.command))
    // The most used first; the working agent's tab counts as live.
    #expect(rows.first?.item.title == "sqlmodel")
    #expect(rows.contains { $0.item.title == "Codex persistent-sessions multiplexer" })
    // Recent rows are plain: nothing is matched.
    #expect(rows.allSatisfy { $0.matched.isEmpty })

    // No history yet: what is live (open projects, working agents), then
    // commands.
    let fresh = OmniRecorder().controller()
    #expect(fresh.rows.count == OmniRanking.recentLimit)
    #expect(fresh.rows.first?.item.title == "pix" || fresh.rows.first?.item.title == "rignore")
    #expect(fresh.rows.contains { $0.item.kind == .command })
}

@Test @MainActor func omniRootQueryIsOneFlatRankedListOfTen() {
    let controller = OmniRecorder().controller()
    controller.setQuery("s")
    #expect(controller.sections.count == 1)
    #expect(controller.sections[0].title == nil)
    #expect(controller.rows.count == OmniSections.rootResultLimit)
    controller.setQuery("persistent")
    // Every kind competes: a title that starts with the query first.
    #expect(titles(controller) == [
        "Persistent Sessions…", "codex/persistent-sessions", "Codex persistent-sessions multiplexer",
    ])
    #expect(controller.rows.map(\.item.kind) == [.command, .worktree, .tab])
    controller.setQuery("new claude")
    #expect(controller.rows.first?.item.title == "New Claude Code agent")
    controller.setQuery("zzzz")
    #expect(controller.rows.isEmpty)
}

// MARK: - Scopes

@Test @MainActor func omniPrefixesEnterTheirScopesOnlyAsTheFirstCharacterAtTheRoot() {
    let controller = OmniRecorder().controller()
    let prefixes: [(String, OmniScope)] = [(">", .commands), ("@", .macs), ("#", .tabs), ("/", .worktrees)]
    for (prefix, scope) in prefixes {
        controller.open(at: nil)
        controller.setQuery(prefix)
        #expect(controller.stack == [scope])
        #expect(controller.query.isEmpty)
        #expect(controller.placeholder == scope.placeholder)
    }
    #expect(OmniScope.tabs.label == "Tabs & Sessions")

    // Typed with more (a paste): the rest is the query.
    controller.open(at: nil)
    controller.setQuery("# shell")
    #expect(controller.stack == [.tabs] && controller.query == "shell")
    #expect(Set(titles(controller)) == ["Shell 1", "Shell 3"])

    // Not the first character, or inside a scope: just text.
    controller.open(at: nil)
    controller.setQuery("a")
    controller.setQuery("a>")
    #expect(controller.stack.isEmpty && controller.query == "a>")
    controller.open(at: .projects)
    controller.setQuery("@")
    #expect(controller.stack == [.projects] && controller.query == "@")
    // A pasted path is a folder to open, not Worktrees.
    controller.open(at: nil)
    controller.setQuery("/Users/me/notes")
    #expect(controller.stack.isEmpty)
    #expect(controller.rows.last?.item.primary == .openPath("/Users/me/notes", on: .thisMac))
}

@Test @MainActor func omniBackspaceAndEscapeStepOutOneLevelAtATime() {
    let recorder = OmniRecorder()
    let controller = recorder.controller()
    // ⌫ in an empty field at the root is the field's.
    #expect(!controller.deleteBackwardOnEmptyField())

    controller.setQuery("@")
    controller.activate() // This Mac
    #expect(controller.stack.count == 2)
    controller.setQuery("sh")
    // ⌫ with text is the field's.
    #expect(!controller.deleteBackwardOnEmptyField())
    // Esc clears the query first…
    controller.escape()
    #expect(controller.query.isEmpty && controller.stack.count == 2)
    // …⌫ on the empty field steps out…
    #expect(controller.deleteBackwardOnEmptyField())
    #expect(controller.stack == [.macs])
    // …so does Esc, and at the root Esc closes.
    controller.escape()
    #expect(controller.stack.isEmpty)
    #expect(recorder.closed == 0)
    controller.escape()
    #expect(recorder.closed == 1)
}

@Test @MainActor func omniProjectsKeepOpenRecentAllHeadersOnlyWithoutAQuery() throws {
    let controller = OmniRecorder().controller()
    controller.open(at: .projects)
    #expect(controller.sections.map(\.title) == ["Open", "Recent", "All"])
    // The current window's project first, then the most recent.
    #expect(controller.sections[0].rows.map(\.item.title) == ["cherry", "pix", "rignore"])
    #expect(controller.sections[1].rows.map(\.item.title) == ["strawberry.rocks", "fastapi-cli"])
    // A project on another Mac says which; This Mac's says nothing.
    let rignore = controller.sections[0].rows[2].item
    #expect(rignore.detail == "patstudio" && rignore.status == .idle)
    #expect(controller.sections[0].rows[0].item.detail.isEmpty && controller.sections[0].rows[0].item.status == .working)
    #expect(controller.sections[0].rows[0].item.primaryLabel == "Switch")

    controller.setQuery("cher")
    #expect(controller.sections.map(\.title) == [nil])
    #expect(titles(controller) == ["cherry", "cherry"])
    #expect(controller.rows.map(\.item.detail) == ["", "patstudio"])
    try select("cherry", detail: "patstudio", in: controller)
    #expect(controller.primaryLabel == "Open")
}

@Test @MainActor func omniMacDrillShowsItsTabsAndSessionsThenItsProjects() throws {
    let recorder = OmniRecorder()
    let controller = recorder.controller()
    controller.open(at: .macs)
    #expect(titles(controller) == ["This Mac", "patstudio"])
    #expect(controller.rows.map(\.item.detail) == ["14 sessions", "2 sessions"])
    try select("patstudio", in: controller)
    // ⇥ drills like ↵.
    #expect(controller.drillIntoSelection())
    #expect(controller.stack == [.macs, .mac(.device(studioID), name: "patstudio")])
    #expect(titles(controller) == ["Shell 1", "rignore", "cherry"])
    #expect(controller.rows.map(\.item.kind) == [.tab, .project, .project])
    #expect(recorder.used == ["mac:\(studioID.uuidString)"])

    controller.pop()
    try select("This Mac", in: controller)
    controller.activate()
    let rows = controller.rows
    #expect(rows.prefix(4).map(\.item.kind) == [.tab, .tab, .tab, .session])
    #expect(rows[3].item.detail == "background")
    #expect(rows.dropFirst(4).allSatisfy { $0.item.kind == .project && $0.item.machine == .thisMac })
    // A query ranks within the Mac.
    controller.setQuery("pix")
    #expect(titles(controller).first == "pix")
    #expect(controller.rows.allSatisfy { $0.item.machine == .thisMac })
    #expect(recorder.run.isEmpty)
}

@Test @MainActor func omniTabsScopeListsEveryWindowsTabsAndTheBackgroundSessions() {
    let controller = OmniRecorder().controller()
    controller.open(at: .tabs)
    #expect(titles(controller) == [
        "Codex persistent-sessions multiplexer", "Shell 1", "Shell 3", "Shell 1", "GraphQL core 3.3 references update",
    ])
    #expect(controller.rows.map(\.item.detail) == ["cherry", "cherry", "pix", "rignore", "background"])
    #expect(controller.rows[0].item.status == .working)
    #expect(controller.rows[0].item.primaryLabel == "Go to Tab")
    #expect(controller.rows[4].item.primaryLabel == "Open in Tab")
}

@Test @MainActor func omniWorktreesOfferANewWorktreeForAQueryThatNamesNone() throws {
    let recorder = OmniRecorder()
    let controller = recorder.controller()
    controller.open(at: .worktrees)
    #expect(titles(controller) == ["main", "codex/persistent-sessions", "fix-titlebar-jank"])
    #expect(controller.rows.map(\.item.detail) == ["cherry", "cherry", "cherry"])
    controller.setQuery("MAIN")
    #expect(!titles(controller).contains { $0.hasPrefix("New worktree") })
    controller.setQuery("feature-x")
    #expect(titles(controller) == ["New worktree “feature-x”"])
    #expect(controller.primaryLabel == "Create")
    controller.activate()
    #expect(recorder.run == [.createWorktree(name: "feature-x")])
    // A "New worktree" row is not remembered as used.
    #expect(recorder.used.isEmpty)
    controller.setQuery("jank")
    #expect(titles(controller) == ["fix-titlebar-jank", "New worktree “jank”"])
    controller.activate()
    #expect(recorder.run.last == .activateWorktree(root: "/Users/me/wt/jank"))
    #expect(recorder.used == ["worktree:/Users/me/wt/jank"])

    // A project without worktrees has none, and no create row.
    var plain = fixture()
    plain.window.supportsWorktrees = false
    let other = OmniRecorder().controller(plain)
    other.open(at: .worktrees)
    other.setQuery("feature")
    #expect(other.rows.isEmpty)
}

@Test @MainActor func omniCommandsAreThePalettesAndTheMenusWithTheirShortcuts() throws {
    let controller = OmniRecorder().controller()
    controller.open(at: .commands)
    let rows = controller.rows.map(\.item)
    let shortcuts = Dictionary(rows.map { ($0.title, $0.detail) }, uniquingKeysWith: { first, _ in first })
    #expect(shortcuts["New Tab"] == "⌘T")
    #expect(shortcuts["Split Right"] == "⌘⇧D")
    #expect(shortcuts["Detach Tab"] == "⌘D")
    #expect(shortcuts["Close Tab"] == "⌘W")
    #expect(shortcuts["Reopen Closed Tab"] == "⌘Z")
    #expect(shortcuts["Clear Scrollback"] == "⌘K")
    #expect(shortcuts["Settings"] == "⌘,")
    for title in [
        "Add Mac…", "End Background Sessions…", "New Agent", "Add Project…", "Projects", "Worktrees",
        "New Worktree…", "Manage Worktrees…", "Add Agent…", "Toggle Light/Dark Mode", "Open in Zed",
        "Open in Other Editor…", "Persistent Sessions…", "New Claude Code agent",
    ] {
        #expect(shortcuts[title] != nil, "missing \(title)")
    }
    #expect(rows.first { $0.title == "New Tab" }?.primary == .menu(.newTab))
    #expect(rows.first { $0.title == "New Claude Code agent" }?.primary == .launchAgent(id: "claude"))
    // Commands have no ⌘K actions.
    #expect(rows.filter { $0.kind == .command }.allSatisfy { $0.actions.isEmpty })

    // New Agent lists the agents and Add Agent…, which lists the presets.
    try select("New Agent", in: controller)
    controller.activate()
    #expect(controller.stack == [.commands, .agents])
    #expect(titles(controller) == ["New Claude Code agent", "Add Agent…"])
    try select("Add Agent…", in: controller)
    controller.activate()
    #expect(controller.stack == [.commands, .agents, .agentPresets])
    #expect(titles(controller) == ["Codex", "Custom"])

    // What the window cannot do now is not offered.
    var bare = fixture()
    bare.window = OmniWindowContext(hasWorkspace: true)
    bare.backgroundSessions = []
    bare.editors = []
    bare.canModifyDevices = false
    let limited = OmniProviders.commands(bare).map(\.title)
    for title in ["Split Right", "Detach Tab", "Close Tab", "Reopen Closed Tab", "Clear Scrollback",
                  "End Background Sessions…", "Add Mac…", "Worktrees", "New Agent", "Open in Zed"] {
        #expect(!limited.contains(title), "offered \(title)")
    }
}

// MARK: - ⌘K

@Test @MainActor func omniActionListsForEachKind() throws {
    let sources = fixture()
    func actions(_ items: [OmniItem], _ title: String, detail: String? = nil) -> [String] {
        items.first { $0.title == title && (detail == nil || $0.detail == detail) }?.actions.map(\.title) ?? ["<none>"]
    }
    let projects = OmniProviders.projects(sources)
    #expect(actions(projects, "cherry", detail: "") == ["Open in Zed", "Reveal in Finder", "Copy Path", "New Worktree…", "Remove from Projects"])
    #expect(actions(projects, "sqlmodel") == ["Reveal in Finder", "Copy Path"])
    #expect(actions(projects, "cherry", detail: "patstudio") == ["Copy Path", "Remove from Projects"])

    let tabs = OmniProviders.tabs(sources)
    #expect(tabs[0].actions.map(\.title) == ["Rename…", "Detach", "Close"])
    #expect(tabs[0].actions.map(\.command) == [.renameTab(tabCodex), .detachTab(tabCodex), .closeTab(tabCodex)])
    // A native tab cannot detach.
    #expect(tabs[1].actions.map(\.title) == ["Rename…", "Close"])

    let session = try #require(OmniProviders.backgroundSessions(sources).first)
    #expect(session.actions.map(\.title) == ["Open in Tab", "End Session"])
    #expect(session.actions.map(\.isDestructive) == [false, true])

    let worktrees = OmniProviders.worktrees(sources)
    #expect(worktrees[0].actions.isEmpty) // the main checkout
    #expect(worktrees[1].actions.map(\.title) == ["Rename Branch…", "Remove…"])

    let thisMac = try #require(OmniProviders.macs(sources).first)
    #expect(thisMac.actions.map(\.title) == [
        "Open Folder…", "Add Project…", "New Terminal on This Mac", "Persistent Sessions…", "End Background Sessions…",
    ])

    #expect(OmniProviders.commands(sources).allSatisfy { $0.actions.isEmpty })
}

@Test @MainActor func omniActionListOpensForTheSelectedRowAndRunsWithTheKeys() throws {
    let recorder = OmniRecorder()
    let controller = recorder.controller()
    controller.open(at: .commands)
    // A command has none: ⌘K does nothing.
    #expect(!controller.toggleActions())
    #expect(!controller.isActionListOpen)

    controller.open(at: .tabs)
    #expect(controller.toggleActions())
    #expect(controller.isActionListOpen && controller.actionSelection == 0)
    // ↑↓ move in the list, not the rows.
    controller.moveSelection(by: 1)
    controller.moveSelection(by: 5)
    #expect(controller.actionSelection == 2 && controller.selection == 0)
    controller.moveSelection(by: -1)
    // Esc closes only the list.
    controller.escape()
    #expect(!controller.isActionListOpen && controller.stack == [.tabs] && recorder.closed == 0)
    // ↵ runs the selected action.
    controller.toggleActions()
    controller.moveSelection(by: 1)
    controller.activate()
    #expect(recorder.run == [.detachTab(tabCodex)])
    #expect(!controller.isActionListOpen)
    // ⌘K again closes it.
    controller.toggleActions()
    controller.toggleActions()
    #expect(!controller.isActionListOpen)
}

@Test @MainActor func commandKIsTheOmniBarsOnlyWhileItIsOpen() {
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "k", modifiers: .command) == nil)
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "k", modifiers: .command, omniBarIsOpen: true) == .toggleOmniBarActions)
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "K", modifiers: [.command, .shift], omniBarIsOpen: true) == nil)
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "p", modifiers: .command) == .toggleOmniBar)
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "o", modifiers: .command) == .showOmniBarProjects)
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "o", modifiers: [.command, .shift]) == nil)

    let chrome = ProjectWindowChromeState()
    #expect(!chrome.toggleOmniBarActions())
    #expect(chrome.omniBarActionsRequest == 0)
    chrome.toggleOmniBar()
    #expect(chrome.toggleOmniBarActions())
    #expect(chrome.omniBarActionsRequest == 1)
}

@Test @MainActor func commandPTogglesTheOmniBarAndCommandOOpensItOnProjects() {
    let chrome = ProjectWindowChromeState()
    chrome.toggleOmniBar()
    #expect(chrome.isOmniBarPresented && chrome.omniBar?.scope == nil)
    chrome.toggleOmniBar()
    #expect(!chrome.isOmniBarPresented)

    chrome.showOmniBarProjects()
    #expect(chrome.omniBar?.scope == .projects)
    chrome.showOmniBarProjects()
    #expect(!chrome.isOmniBarPresented)

    // ⌘O while it is open at the root moves it to Projects.
    chrome.toggleOmniBar()
    let first = chrome.omniBar?.id
    chrome.showOmniBarProjects()
    #expect(chrome.omniBar?.scope == .projects && chrome.omniBar?.id != first)
    chrome.dismissOmniBar()
    #expect(chrome.omniBar == nil)

    chrome.presentNewWorktree(branchName: "feature-x")
    #expect(chrome.isNewWorktreePresented && chrome.newWorktreeBranchName == "feature-x")
    chrome.presentNewWorktree()
    #expect(chrome.newWorktreeBranchName == nil)
}

// MARK: - Selection

@Test @MainActor func omniSelectionClampsAndFollowsItsRowAsTheSourcesChange() throws {
    let controller = OmniRecorder().controller()
    controller.open(at: .tabs)
    controller.moveSelection(by: -3)
    #expect(controller.selection == 0)
    let request = controller.scrollRequest
    controller.moveSelection(by: 2)
    #expect(controller.selection == 2 && controller.scrollRequest == request + 1)
    controller.moveSelection(by: 50)
    #expect(controller.selectedItem?.title == "GraphQL core 3.3 references update")

    // A tab opens elsewhere: the selected row stays selected.
    var sources = fixture()
    sources.tabs.insert(OmniTab(id: UUID(), title: "New", projectName: "pix", machine: .thisMac, isWorking: false, canDetach: true), at: 0)
    controller.update(sources: sources)
    #expect(controller.selectedItem?.title == "GraphQL core 3.3 references update")
    #expect(controller.selection == 5)
    // A new query starts from the top.
    controller.setQuery("shell")
    #expect(controller.selection == 0)
}

@Test @MainActor func omniRankingStaysUnderAFrameWithHundredsOfRows() {
    var sources = fixture(extraProjects: 320)
    for index in 0 ..< 80 {
        sources.tabs.append(OmniTab(id: UUID(), title: "Shell \(index)", projectName: "project-\(index)", machine: .thisMac, isWorking: false, canDetach: true))
    }
    let controller = OmniRecorder().controller(sources)
    let queries = ["p", "pr", "pro", "proj", "project-1", "project-12", "s", "sh", "shell 7", "cherry"]
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for query in queries {
            controller.open(at: nil)
            controller.setQuery(query)
        }
    }
    #expect(controller.rows.count <= OmniSections.rootResultLimit)
    // A keystroke well under a frame, even in a debug build.
    #expect(elapsed / queries.count < .milliseconds(30), "\(elapsed / queries.count) a keystroke")
}

// MARK: - Running rows

@Test @MainActor func omniRowsRunThroughTheWindowsOwnPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-omni-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = ProjectWindowChromeState()
    let repository = RepositoryWorkspace(projectRoot: root.path)
    let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("cherry-omni-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    var settingsOpened = 0
    let performer = OmniBarPerformer(
        window: OmniBarWindow(projectRoot: root.path, repository: repository, workspace: workspace, chromeState: chrome),
        settings: .shared,
        registry: registry,
        backgroundSessionsModel: { preconditionFailure("not asked in this test") },
        switcher: ProjectSwitcherActions(settings: .shared, chromeState: chrome, openProject: { _ in }, openSettings: {}),
        editorDiscovery: ExternalEditorDiscovery(appURLResolver: { _ in nil }, iconProvider: { _ in NSImage() }),
        projects: { ProjectSwitcherModel(machines: [], locations: []) },
        openSettings: { settingsOpened += 1 },
        toggleAppearance: {},
        pasteboard: pasteboard
    )
    performer.perform(.copyPath("/Users/me/code/cherry"))
    #expect(pasteboard.string(forType: .string) == "/Users/me/code/cherry")
    performer.perform(.createWorktree(name: "feature-x"))
    #expect(chrome.isNewWorktreePresented && chrome.newWorktreeBranchName == "feature-x")
    performer.perform(.menu(.manageWorktrees))
    #expect(chrome.isWorktreeManagerPresented && !chrome.isNewWorktreePresented)
    performer.perform(.menu(.addMac))
    #expect(chrome.isAddDevicePresented)
    performer.perform(.switcher(.addDeviceProject(studioID)))
    #expect(chrome.addProjectDevice?.id == studioID)
    performer.perform(.menu(.settings))
    #expect(settingsOpened == 1)
    // A tab no window has: nothing happens.
    performer.perform(.closeTab(UUID()))
    #expect(workspace.sessions.isEmpty)
}
