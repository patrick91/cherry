import AppKit
import Foundation
import Testing
@testable import Cherry

// Background sessions, the launch notice and the menu bar with several
// windows of one project (#22): what each window shows, and what the launch
// waits for. Against the fake `cherry control` (FakeControlHelper) and test
// registries: nothing reaches a real cherry-host or comes on screen.

// MARK: - Helpers

@MainActor
private func makeModel(_ harness: PersistentHarness, registry: ProjectWindowRegistry) -> BackgroundSessionsModel {
    BackgroundSessionsModel(
        localSessions: harness.hosting,
        registry: registry,
        prefersPersistentLocalSessions: { true },
        closesTabsOnCleanExit: { true },
        presentAlert: { _, _, _ in Issue.record("Nothing asks in these tests") },
        postNotification: { _ in },
        notifiesProgramState: { _ in false },
        isAppActive: { true }
    )
}

/// Registers `window` with `registry` as the window `value` names, showing
/// `workspace`.
@MainActor
private func register(
    _ window: NSWindow,
    _ value: ProjectWindowValue,
    workspace: TerminalWorkspace,
    in registry: ProjectWindowRegistry
) {
    #expect(registry.register(
        window: window, projectRoot: value.projectRoot, windowID: value.windowID,
        workspace: workspace, todoStore: nil, chromeState: quietChromeState()
    ))
}

// MARK: - The launch notice

/// The launch notice waits for every window the launch reopens, each by
/// itself: another window of its project having opened is not it.
@Test @MainActor func theLaunchNoticeWaitsForEveryWindowItExpects() async throws {
    let harness = try PersistentHarness()
    let registry = ProjectWindowRegistry()
    let model = makeModel(harness, registry: registry)
    let defaults = privateDefaults("cherry-background-windows-notice")
    let notice = BackgroundSessionsNotice(
        model: model,
        registry: registry,
        isEnabled: { true },
        defaults: defaults,
        canPresent: { _ in true },
        settleDelay: .zero,
        restoreWait: .seconds(10),
        retryDelay: 0.05,
        retries: 2
    )
    let project = harness.project.path
    let other = ProjectWindowValue(projectRoot: project, windowID: UUID())
    let windows = [testWindow(), testWindow()]
    let workspaces = [harness.workspace(), harness.workspace()]
    defer {
        model.stop()
        registry.unregister(window: windows[0], projectRoot: project)
        registry.unregister(window: windows[1], projectRoot: project)
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    harness.fake.pendingHolders = 0

    // The launch asked for the project's primary window and another one.
    notice.launchWindowsOpened(expecting: [.primary(project), other])
    register(windows[0], .primary(project), workspace: workspaces[0], in: registry)
    // The primary is open; the other is not: it waits.
    try await Task.sleep(for: .milliseconds(300))
    #expect(notice.phase == .checking)
    register(windows[1], other, workspace: workspaces[1], in: registry)
    #expect(await eventually { notice.phase != .checking })
}

// MARK: - The menu bar

/// The menu bar lists a project's agents in one group, whichever of its
/// windows each runs in (each window's in turn), and a row shows its agent
/// in the window that has it.
@Test @MainActor func theMenuBarListsAProjectsAgentsInOneGroupAcrossItsWindows() async throws {
    let harness = try PersistentHarness()
    let registry = ProjectWindowRegistry()
    var focused: [NSWindow] = []
    registry.bringWindowForward = { focused.append($0) }
    let background = makeModel(harness, registry: registry)
    let project = harness.project.path
    let other = ProjectWindowValue(projectRoot: project, windowID: UUID())
    let windows = [testWindow(), testWindow()]
    let workspaces = [harness.workspace(), harness.workspace()]
    defer {
        background.stop()
        registry.unregister(window: windows[0], projectRoot: project)
        registry.unregister(window: windows[1], projectRoot: project)
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    register(windows[0], .primary(project), workspace: workspaces[0], in: registry)
    register(windows[1], other, workspace: workspaces[1], in: registry)
    let agents = [
        workspaces[1].addAgentSession(
            agent: AgentToolDefinition(name: "Codex", command: "/bin/cat"), projectRoot: project, select: false
        ),
        workspaces[0].addAgentSession(
            agent: AgentToolDefinition(name: "Claude", command: "/bin/cat"), projectRoot: project, select: false
        ),
    ]
    for agent in agents {
        #expect(await harness.waitUntilAttached(agent))
    }

    let model = MenuBarAgentsModel(registry: registry, background: background)
    #expect(model.groups.count == 1)
    let group = try #require(model.groups.first)
    #expect(group.projectName == harness.project.lastPathComponent)
    // The primary window's agents first, then the other window's.
    #expect(group.items.map(\.id) == [agents[1].id, agents[0].id])

    // Its row shows the other window's agent there, though the primary was
    // active last.
    let row = try #require(group.items.first { $0.id == agents[0].id })
    model.reveal(row)
    #expect(focused.count == 1)
    #expect(focused.last === windows[1])
    #expect(workspaces[1].selectedSessionID == agents[0].id)
}
