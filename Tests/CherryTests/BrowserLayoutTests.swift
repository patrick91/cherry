import Foundation
import Testing
@testable import Cherry

@MainActor
@Test func browserOpenDefaultsToSelectedProcessAndRemainsSingleton() throws {
    let workspace = TerminalWorkspace()
    defer { workspace.closeAllSessions() }

    let terminal = try #require(workspace.selectedSession)
    let browser = workspace.openBrowser()

    #expect(workspace.browserWorkspace === browser)
    #expect(workspace.browserPlacement == .split(hostSessionID: terminal.id))
    #expect(workspace.browserHostSessionID == terminal.id)
    #expect(workspace.isBrowserOpen)
    #expect(workspace.isBrowserPaneActive)
    #expect(workspace.showsBrowserBesideSelectedSession)
    #expect(workspace.browserSplitWidthWeights == [0.5, 0.5])

    let reopenedBrowser = workspace.openBrowser()

    #expect(reopenedBrowser === browser)
    #expect(workspace.browserPlacement == .split(hostSessionID: terminal.id))
}

@MainActor
@Test func browserSplitMovesBetweenTerminalAgentAndCommand() throws {
    let projectRoot = FileManager.default.temporaryDirectory.path
    let workspace = TerminalWorkspace(projectRoot: projectRoot)
    defer { workspace.closeAllSessions() }

    let terminal = try #require(workspace.terminalSessions.first)
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: "/bin/cat"),
        projectRoot: projectRoot,
        select: false
    )
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "Web", command: "/bin/cat"),
        projectRoot: projectRoot,
        select: false
    )

    #expect(workspace.splitBrowserRight(of: terminal))
    let browser = try #require(workspace.browserWorkspace)
    #expect(workspace.browserPlacement == .split(hostSessionID: terminal.id))
    #expect(workspace.browserIsAttached(to: terminal.id))

    #expect(workspace.splitBrowserRight(of: agent))
    #expect(workspace.browserWorkspace === browser)
    #expect(workspace.browserPlacement == .split(hostSessionID: agent.id))
    #expect(workspace.selectedSessionID == agent.id)
    #expect(workspace.browserIsAttached(to: agent.id))
    #expect(!workspace.browserIsAttached(to: terminal.id))

    #expect(workspace.splitBrowserRight(of: command))
    #expect(workspace.browserWorkspace === browser)
    #expect(workspace.browserPlacement == .split(hostSessionID: command.id))
    #expect(workspace.selectedSessionID == command.id)
    #expect(workspace.browserIsAttached(to: command.id))
    #expect(!workspace.browserIsAttached(to: agent.id))
}

@MainActor
@Test func browserSplitRespectsDetailWidthAndThreePaneCap() throws {
    let workspace = TerminalWorkspace()
    defer { workspace.closeAllSessions() }

    workspace.updateTerminalDetailWidth(700)
    let first = try #require(workspace.terminalSessions.first)
    let second = try #require(workspace.splitDuplicateActiveTerminal())

    #expect(!workspace.canSplitBrowserRight(of: second))
    #expect(!workspace.splitBrowserRight(of: second))
    #expect(!workspace.isBrowserOpen)

    workspace.updateTerminalDetailWidth(1_000)
    #expect(workspace.canSplitBrowserRight(of: second))
    #expect(workspace.splitBrowserRight(of: second))
    #expect(workspace.browserSplitWidthWeights == [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])

    workspace.select(second)
    #expect(!workspace.canAddSplitPane(to: second.id))
    #expect(workspace.splitDuplicateActiveTerminal() == nil)

    workspace.closeBrowser()
    let third = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(!workspace.canSplitBrowserRight(of: third))
    #expect(!workspace.splitBrowserRight(of: third))
    #expect(workspace.splitGroup(containing: first.id)?.paneSessionIDs == [first.id, second.id, third.id])
}

@MainActor
@Test func standaloneBrowserSelectionIsIndependentFromProcessSelection() throws {
    let workspace = TerminalWorkspace()
    defer { workspace.closeAllSessions() }

    let terminal = try #require(workspace.selectedSession)
    _ = workspace.openBrowser()
    workspace.separateBrowser(select: false)

    #expect(workspace.browserPlacement == .standalone)
    #expect(workspace.isBrowserStandalone)
    #expect(!workspace.isBrowserPaneActive)
    #expect(workspace.activePaneSelection == .process(terminal.id))
    #expect(workspace.browserSplitWidthWeights.isEmpty)

    workspace.selectBrowser()
    #expect(workspace.isStandaloneBrowserSelected)
    #expect(workspace.selectedSessionID == terminal.id)

    workspace.select(terminal)
    #expect(!workspace.isBrowserPaneActive)
    #expect(workspace.browserPlacement == .standalone)
}

@MainActor
@Test func browserFocusCyclesWithExistingTerminalSplit() throws {
    let workspace = TerminalWorkspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer { workspace.closeAllSessions() }

    let first = try #require(workspace.terminalSessions.first)
    let second = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(workspace.splitBrowserRight(of: second))
    #expect(workspace.activePaneSelection == .browser)

    #expect(workspace.focusNextPane())
    #expect(workspace.activePaneSelection == .process(first.id))
    #expect(workspace.selectedSessionID == first.id)

    #expect(workspace.focusNextPane())
    #expect(workspace.activePaneSelection == .process(second.id))
    #expect(workspace.selectedSessionID == second.id)

    #expect(workspace.focusNextPane())
    #expect(workspace.activePaneSelection == .browser)

    #expect(workspace.focusPreviousPane())
    #expect(workspace.activePaneSelection == .process(second.id))
    #expect(workspace.focusPreviousPane())
    #expect(workspace.activePaneSelection == .process(first.id))
    #expect(workspace.focusPreviousPane())
    #expect(workspace.activePaneSelection == .browser)
}

@MainActor
@Test func closingActiveBrowserLeavesProcessSessionsOpen() throws {
    let workspace = TerminalWorkspace()
    defer { workspace.closeAllSessions() }

    let terminal = try #require(workspace.selectedSession)
    let sessionIDs = workspace.sessions.map(\.id)
    _ = workspace.openBrowser()

    workspace.closeActivePane()

    #expect(workspace.sessions.map(\.id) == sessionIDs)
    #expect(workspace.selectedSessionID == terminal.id)
    #expect(workspace.browserWorkspace == nil)
    #expect(workspace.browserPlacement == .closed)
    #expect(workspace.activePaneSelection == .process(terminal.id))
}

@MainActor
@Test func closingBrowserHostReparentsBrowserWithinTerminalSplit() throws {
    let workspace = TerminalWorkspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer { workspace.closeAllSessions() }

    let first = try #require(workspace.terminalSessions.first)
    let second = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(workspace.splitBrowserRight(of: second))
    let browser = try #require(workspace.browserWorkspace)

    workspace.close(second)

    #expect(workspace.browserWorkspace === browser)
    #expect(workspace.browserPlacement == .split(hostSessionID: first.id))
    #expect(workspace.browserHostSessionID == first.id)
    #expect(workspace.selectedSessionID == first.id)
    #expect(workspace.isBrowserPaneActive)
    #expect(workspace.terminalSplitGroups.isEmpty)
    #expect(workspace.terminalDisplayItems == [.single(first.id)])
    #expect(workspace.browserSplitWidthWeights == [0.5, 0.5])
}

@MainActor
@Test func closingUngroupedBrowserHostSeparatesBrowser() throws {
    let projectRoot = FileManager.default.temporaryDirectory.path
    let workspace = TerminalWorkspace(projectRoot: projectRoot)
    defer { workspace.closeAllSessions() }

    let terminal = try #require(workspace.terminalSessions.first)
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: "/bin/cat"),
        projectRoot: projectRoot,
        select: false
    )
    #expect(workspace.splitBrowserRight(of: agent))
    let browser = try #require(workspace.browserWorkspace)

    workspace.close(agent)

    #expect(workspace.browserWorkspace === browser)
    #expect(workspace.browserPlacement == .standalone)
    #expect(workspace.isStandaloneBrowserSelected)
    #expect(workspace.selectedSessionID == terminal.id)
    #expect(workspace.browserSplitWidthWeights.isEmpty)
}

@MainActor
@Test func browserAttachesToWholeExistingTerminalSplit() throws {
    let workspace = TerminalWorkspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer { workspace.closeAllSessions() }

    let first = try #require(workspace.terminalSessions.first)
    let second = try #require(workspace.splitDuplicateActiveTerminal())
    let group = try #require(workspace.splitGroup(containing: first.id))

    #expect(workspace.splitBrowserRight(of: second))
    #expect(workspace.terminalDisplayItems == [.split(group.id)])
    #expect(workspace.browserIsAttached(to: first.id))
    #expect(workspace.browserIsAttached(to: second.id))
    #expect(workspace.activeProcessPaneSessions.map(\.id) == [first.id, second.id])
    #expect(workspace.hasMultipleActivePanes)

    workspace.select(first)
    #expect(workspace.showsBrowserBesideSelectedSession)
    #expect(workspace.browserHostSessionID == second.id)
    #expect(workspace.activeProcessPaneSessions.map(\.id) == [first.id, second.id])
}

@MainActor
@Test func browserSplitWeightsNormalizeRejectInvalidCountsAndBalance() throws {
    let workspace = TerminalWorkspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer { workspace.closeAllSessions() }

    _ = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(workspace.splitBrowserRight())

    workspace.setBrowserSplitWidthWeights([2, 1, 1], paneCount: 3)
    #expect(workspace.browserSplitWidthWeights == [0.5, 0.25, 0.25])

    workspace.setBrowserSplitWidthWeights([1, 1], paneCount: 3)
    #expect(workspace.browserSplitWidthWeights == [0.5, 0.25, 0.25])

    workspace.balanceActiveSplitGroup()
    #expect(workspace.browserSplitWidthWeights == [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])
}

@MainActor
@Test func browserSplitWeightsFollowTerminalTopologyChanges() throws {
    let workspace = TerminalWorkspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer { workspace.closeAllSessions() }

    let first = try #require(workspace.selectedSession)
    #expect(workspace.splitBrowserRight(of: first))
    workspace.select(first)
    let second = try #require(workspace.splitDuplicateActiveTerminal())

    #expect(workspace.browserSplitWidthWeights == [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])
    let group = try #require(workspace.splitGroup(containing: first.id))
    workspace.separateSplitGroup(id: group.id)
    #expect(workspace.browserSplitWidthWeights == [0.5, 0.5])

    workspace.select(first)
    #expect(workspace.splitActiveTerminal(with: second))
    #expect(workspace.browserSplitWidthWeights == [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])

    workspace.close(second)
    #expect(workspace.browserSplitWidthWeights == [0.5, 0.5])
}
