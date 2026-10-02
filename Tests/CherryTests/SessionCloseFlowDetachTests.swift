import AppKit
import Foundation
import Testing
@testable import Cherry

// ⌘D (Detach Tab) and the close question's edges: which tab a detach takes,
// when it does nothing, and a question whose program changed before it was
// answered (docs/specs/multiplexer-default.md, "Close intents"). Against the
// fake `cherry control` (FakeControlHelper); no window comes on screen, and
// no toast reaches VoiceOver or a timer.

/// Records `performClose` instead of closing.
@MainActor
private final class ClosingWindow: NSWindow {
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

/// A window's chrome whose toasts never dismiss themselves or announce.
@MainActor
private func quietChromeState() -> ProjectWindowChromeState {
    ProjectWindowChromeState(toasts: ProjectWindowToasts(
        schedule: { _, _ in },
        announce: { _ in },
        voiceOverEnabled: { false }
    ))
}

@MainActor
private func sidebarName(of session: TerminalSession) -> String {
    SidebarSessionLabel.label(for: session, pathDisplayMode: TerminalSettings.shared.sidebarTerminalPathDisplayMode).title
}

@Test @MainActor func commandDDetachesOnlyTheFocusedPaneOfASplit() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    workspace.updateTerminalDetailWidth(1_200)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let left = workspace.addSession(title: "Left")
    #expect(await harness.waitUntilAttached(anchor))
    #expect(await harness.waitUntilAttached(left))
    let right = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(await harness.waitUntilAttached(right))
    let third = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(await harness.waitUntilAttached(third))
    let group = try #require(workspace.splitGroup(containing: left.id))
    #expect(group.paneSessionIDs == [left.id, right.id, third.id])
    workspace.select(right)
    let rightSession = try #require(right.persistentSession?.sessionID)
    let rightName = sidebarName(of: right)
    let chromeState = quietChromeState()
    let window = ClosingWindow()

    SessionCloseCoordinator.detachSelectedTabOrWindow(
        workspace: workspace, repository: nil, chromeState: chromeState, window: window,
        registry: ProjectWindowRegistry()
    )
    // Only that pane went; the split keeps the others, the pane before it
    // focused, and the window stays.
    #expect(workspace.session(withID: right.id) == nil)
    #expect(workspace.splitGroup(containing: left.id)?.paneSessionIDs == [left.id, third.id])
    #expect(workspace.selectedSessionID == left.id)
    #expect(window.closeRequests == 0)
    #expect(chromeState.toasts.current?.title == "\(rightName) is running in the background")
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.sessions.contains { $0.id == rightSession && $0.isRunning })
}

@Test @MainActor func commandDDoesNothingForANativeTabOrWhileTheWindowShowsANote() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let chromeState = quietChromeState()
    let window = ClosingWindow()
    func commandD() {
        SessionCloseCoordinator.detachSelectedTabOrWindow(
            workspace: workspace, repository: nil, chromeState: chromeState, window: window,
            registry: ProjectWindowRegistry()
        )
    }

    // A native tab, the window's last: it stays, and so does the window.
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addSession(title: "Native")
    harness.settings.value.persistLocalSessions = true
    #expect(!SessionCloseCoordinator.canDetach(native))
    commandD()
    #expect(workspace.sessions.map(\.id) == [native.id])
    #expect(window.closeRequests == 0)
    #expect(chromeState.toasts.current == nil)

    // A persistent tab hidden behind a note: ⌘D does not reach it.
    let tab = workspace.addSession(title: "Persistent")
    #expect(await harness.waitUntilAttached(tab))
    #expect(SessionCloseCoordinator.canDetach(tab))
    chromeState.selectNote(id: UUID())
    commandD()
    #expect(workspace.session(withID: tab.id) != nil)
    // Shown again: it detaches.
    chromeState.selectTerminal()
    commandD()
    #expect(workspace.session(withID: tab.id) == nil)
    #expect(workspace.sessions.map(\.id) == [native.id])
    #expect(window.closeRequests == 0)
}

@Test @MainActor func closingABusyNativeProgramAsksWithoutDetachInsteadAndCloseStopsIt() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))
    harness.settings.value.persistLocalSessions = false
    let native = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "cat", command: "/bin/cat"),
        projectRoot: harness.project.path
    )
    harness.settings.value.persistLocalSessions = true
    #expect(native.hasRunningProcess())
    let chromeState = quietChromeState()

    SessionCloseCoordinator.close(native, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry())
    let request = try #require(chromeState.pendingTabClose)
    let question = try #require(SessionCloseCoordinator.question(for: request))
    #expect(question.messageText == "Close “cat”?")
    #expect(question.informativeText.hasPrefix("/bin/cat is running. Closing the tab stops it."))
    #expect(!question.canDetach)
    #expect(question.buttonTitles == ["Close", "Cancel"])
    #expect(workspace.session(withID: native.id) != nil)

    SessionCloseCoordinator.answerTabClose(question.answer(for: .alertFirstButtonReturn), to: request, chromeState: chromeState)
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    #expect(!native.isRunning)
    #expect(chromeState.toasts.current == nil)
}

@Test @MainActor func aCloseQuestionWhoseProgramEndedMeanwhileHasNothingToAskAndItsDetachCloses() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "build", command: "make"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(anchor))
    #expect(await harness.waitUntilAttached(command))
    let commandSession = try #require(command.persistentSession?.sessionID)
    let chromeState = quietChromeState()

    SessionCloseCoordinator.close(command, in: workspace, chromeState: chromeState, registry: ProjectWindowRegistry())
    let request = try #require(chromeState.pendingTabClose)
    #expect(SessionCloseCoordinator.question(for: request)?.canDetach == true)

    // The command ends before the question is answered: nothing is left to
    // ask, and a Detach Instead answered anyway closes the tab. Its ended
    // session goes with it once the close can no longer be undone.
    harness.exit(commandSession, code: 0)
    #expect(await harness.fake.wait { !command.isProgramRunning })
    #expect(SessionCloseCoordinator.question(for: request) == nil)
    #expect(!SessionCloseCoordinator.canDetach(command))
    SessionCloseCoordinator.answerTabClose(.detach, to: request, chromeState: chromeState)
    #expect(chromeState.pendingTabClose == nil)
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    #expect(chromeState.toasts.current?.title == "Closed \(sidebarName(of: command))")
    #expect(harness.hosting.isEnding(commandSession))
    chromeState.closedTabs.endAll()
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(commandSession) })
    #expect(!harness.requestIDs("kill").contains(commandSession))
}
