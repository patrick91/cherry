import AppKit
import Foundation
import Testing
@testable import Cherry

// ⌘W on a window's last tab and the agent close confirmation, for local
// tabs that run as persistent sessions (docs/specs/multiplexer-default.md,
// "Close intents"). Against the fake `cherry control` (FakeControlHelper).

/// Records `performClose` instead of closing.
@MainActor
private final class RecordingWindow: NSWindow {
    var closeRequests = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
    }

    override func performClose(_ sender: Any?) {
        closeRequests += 1
    }
}

@Test @MainActor func commandWOnAWindowsLastPersistentTabEndsItsSessionAsATabCloseThenClosesTheWindow() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Server")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let window = RecordingWindow()

    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: nil, window: window)
    // The tab closed as the user closing it (its session ends, as the
    // settings say for a tab close), and then the window: nothing is left
    // for the window's teardown to detach, save and bring back.
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
    #expect(await harness.fake.wait { harness.fake.requests("kill").contains { $0.string("id") == sessionID } })
    #expect(workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: []).sessions.isEmpty)
}

@Test @MainActor func commandWOnTheLastTabKeepsItsSessionWhenTabClosesKeepSessions() async throws {
    let harness = try PersistentHarness()
    harness.settings.value.keepLocalSessionsAfterTabClose = true
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Server")
    #expect(await harness.waitUntilAttached(tab))
    let window = RecordingWindow()

    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: nil, window: window)
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func commandWOnTheLastTabAsksBeforeItStopsABusyProgram() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let originalConfirmation = SessionCloseCoordinator.confirmStoppingLastTab
    defer {
        SessionCloseCoordinator.confirmStoppingLastTab = originalConfirmation
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "npm", arguments: "run dev"),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    #expect(command.hasRunningProcess())
    let window = RecordingWindow()
    let asked = Recorder(0)

    // Cancelled: the tab and the window stay.
    SessionCloseCoordinator.confirmStoppingLastTab = { parent, answer in
        #expect(parent === window)
        asked.value += 1
        answer(false)
    }
    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: nil, window: window)
    #expect(asked.value == 1)
    #expect(workspace.sessions.count == 1)
    #expect(window.closeRequests == 0)
    #expect(harness.fake.requests("kill").isEmpty)

    // Confirmed: the command stops with its tab, then the window closes.
    SessionCloseCoordinator.confirmStoppingLastTab = { _, answer in
        asked.value += 1
        answer(true)
    }
    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: nil, window: window)
    #expect(asked.value == 2)
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
    #expect(await harness.fake.wait { !harness.fake.requests("kill").isEmpty })
}

@Test @MainActor func commandWOnARunningAgentsLastTabClosesTheWindowOnceItsConfirmationClosedTheTab() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    let chromeState = ProjectWindowChromeState()
    let window = RecordingWindow()

    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: chromeState, window: window)
    // The agent confirmation is up; nothing closed yet.
    #expect(chromeState.pendingAgentCloseSessionID == agent.id)
    #expect(chromeState.pendingAgentCloseAllowsEmptyWorkspace)
    #expect(workspace.sessions.count == 1)
    #expect(window.closeRequests == 0)

    // Cancelled: the window stays.
    SessionCloseCoordinator.agentTabCloseDidFinish(sessionID: agent.id, closed: false, workspace: workspace)
    #expect(window.closeRequests == 0)

    // Asked again and confirmed: the tab closes, then the window.
    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: chromeState, window: window)
    workspace.close(agent, allowEmptyWorkspace: chromeState.pendingAgentCloseAllowsEmptyWorkspace)
    SessionCloseCoordinator.agentTabCloseDidFinish(sessionID: agent.id, closed: true, workspace: workspace)
    #expect(workspace.sessions.isEmpty)
    #expect(window.closeRequests == 1)
}

@Test @MainActor func commandWWithOtherTabsClosesOnlyTheSelectedTab() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let first = workspace.addSession(title: "One")
    let second = workspace.addSession(title: "Two")
    #expect(await harness.waitUntilAttached(first))
    #expect(await harness.waitUntilAttached(second))
    workspace.select(second)
    let window = RecordingWindow()

    SessionCloseCoordinator.closeSelectedTabOrWindow(workspace: workspace, repository: nil, chromeState: nil, window: window)
    #expect(workspace.sessions.map(\.id) == [first.id])
    #expect(window.closeRequests == 0)
}

// MARK: - Agent close confirmation

@Test @MainActor func theAgentCloseConfirmationSaysWhatClosingItsTabDoes() throws {
    let stops = AgentCloseAlertPresenterView.makeAlert(stopsAgent: true)
    #expect(stops.messageText == "Close agent?")
    #expect(stops.informativeText.contains("will be stopped"))
    #expect(stops.buttons.map(\.title) == ["Stop and close", "Cancel"])

    // Settings › Sessions keeps sessions after a tab close: the agent runs on.
    let keeps = AgentCloseAlertPresenterView.makeAlert(stopsAgent: false)
    #expect(keeps.messageText == "Close agent tab?")
    #expect(keeps.informativeText.contains("keeps running"))
    #expect(keeps.informativeText.contains("Persistent Sessions"))
    #expect(!keeps.informativeText.contains("stopped"))
    #expect(keeps.buttons.map(\.title) == ["Close Tab", "Cancel"])

    // Which one a persistent agent gets follows the setting.
    let keep = SessionPersistenceSettings(persistLocalSessions: true, keepLocalSessionsAfterTabClose: true, endLocalSessionsOnQuit: false)
    #expect(SessionClosePolicy.closeAction(for: .hostedLocal, intent: .userClosedTab, settings: keep) == .detach)
    #expect(SessionClosePolicy.closeAction(for: .hostedLocal, intent: .userClosedTab, settings: .defaults) == .terminate)
}

@Test @MainActor func closingAnAgentTabAttachedToASessionItDoesNotOwnSaysTheAgentKeepsRunning() throws {
    let policy = SessionBackendPolicy(settings: { .defaults })
    // A local session another app or the CLI runs, attached from File ›
    // Persistent Sessions: its close action is `.terminate` (a local
    // hosted tab with the default settings), but closing only disconnects.
    let attached = TerminalSession(
        title: "Claude", subtitle: "", tint: .systemOrange, launchShell: false, kind: .agent,
        agentName: "Claude",
        hostedAttachment: HostedSessionAttachment(
            host: .local, hostID: "host-a", sessionID: "session-cli", name: "Claude",
            remoteWorkingDirectory: "/", executablePath: "/usr/bin/true"
        )
    )
    #expect(policy.closeAction(for: attached, intent: .userClosedTab) == .terminate)
    #expect(!SessionCloseCoordinator.closeEndsProgram(of: attached, policy: policy))
    let alert = AgentCloseAlertPresenterView.makeAlert(for: attached, policy: policy)
    #expect(alert.messageText == "Close agent tab?")
    #expect(alert.informativeText.contains("keeps running"))
    #expect(alert.buttons.map(\.title) == ["Close Tab", "Cancel"])
    // An SSH host's session: the same.
    let remote = TerminalSession(
        title: "Codex", subtitle: "", tint: .systemOrange, launchShell: false, kind: .agent,
        hostedAttachment: HostedSessionAttachment(
            host: try HostedSessionHost.ssh("devbox"), hostID: "host-b", sessionID: "session-remote", name: "Codex",
            remoteWorkingDirectory: "~", executablePath: "/c"
        )
    )
    #expect(AgentCloseAlertPresenterView.makeAlert(for: remote, policy: policy).messageText == "Close agent tab?")

    // A native agent's tab stops it.
    let native = TerminalSession(title: "Claude", subtitle: "", tint: .systemOrange, launchShell: false, kind: .agent)
    #expect(SessionCloseCoordinator.closeEndsProgram(of: native, policy: policy))
    #expect(AgentCloseAlertPresenterView.makeAlert(for: native, policy: policy).messageText == "Close agent?")
}

@Test @MainActor func aPersistentAgentsCloseConfirmationFollowsTheTabCloseSetting() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    #expect(AgentCloseAlertPresenterView.makeAlert(for: agent, policy: workspace.backendPolicy).messageText == "Close agent?")
    harness.settings.value.keepLocalSessionsAfterTabClose = true
    #expect(AgentCloseAlertPresenterView.makeAlert(for: agent, policy: workspace.backendPolicy).messageText == "Close agent tab?")
}
