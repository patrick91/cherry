import CherryControl
import Foundation
import Testing
@testable import Cherry

@MainActor
@Test func browserWorkspaceSnapshotsAndActsOnDocumentScopedElements() async throws {
    let workspace = BrowserWorkspace(projectRoot: nil)
    let tab = try #require(workspace.selectedTab)

    tab.loadHTMLString(
        """
        <!doctype html>
        <html>
          <body>
            <label>Name <input aria-label="Name" value="Old"></label>
            <button aria-label="Save" onclick="window.saved = document.querySelector('input').value">Save</button>
            <a aria-label="Open another tab" href="about:blank" target="_blank">Open</a>
          </body>
        </html>
        """,
        baseURL: nil
    )
    _ = try await workspace.waitForLoad(tabID: tab.id, timeoutMilliseconds: 5_000)

    let snapshot = try await workspace.snapshot(tabID: tab.id)
    #expect(snapshot.elements.map(\.name).contains("Name"))
    let input = try #require(snapshot.elements.first { $0.name == "Name" })
    let save = try #require(snapshot.elements.first { $0.name == "Save" })
    let newTabLink = try #require(snapshot.elements.first { $0.name == "Open another tab" })

    _ = try await workspace.type(
        text: "Cherry",
        elementRef: input.ref,
        clear: true,
        tabID: tab.id
    )
    _ = try await workspace.click(elementRef: save.ref, tabID: tab.id)

    let result = try await workspace.evaluate(
        script: "return { saved: window.saved, one: 1, truth: true };",
        tabID: tab.id
    )
    #expect(result == .object([
        "saved": .string("Cherry"),
        "one": .int(1),
        "truth": .bool(true),
    ]))
    #expect(try await workspace.evaluate(
        script: "return count + 1;",
        arguments: ["count": .int(2)],
        tabID: tab.id
    ) == .int(3))

    let screenshot = try await workspace.screenshot(tabID: tab.id)
    #expect(screenshot.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]))

    _ = try await workspace.click(elementRef: newTabLink.ref, tabID: tab.id)
    for _ in 0..<20 where workspace.tabs.count == 1 {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(workspace.tabs.count == 2)
    #expect(workspace.selectedTabID != tab.id)

    tab.loadHTMLString("<p>Replacement document</p>", baseURL: nil)
    _ = try await workspace.waitForLoad(tabID: tab.id, timeoutMilliseconds: 5_000)

    await #expect(throws: BrowserWorkspaceError.self) {
        _ = try await workspace.click(elementRef: save.ref, tabID: tab.id)
    }
}

@MainActor
@Test func browserWorkspaceUsesOneTabCollectionAcrossSelectionChanges() throws {
    let workspace = BrowserWorkspace(projectRoot: nil)
    let first = try #require(workspace.selectedTab)
    let second = workspace.addTab(select: true)

    #expect(workspace.tabs.map(\.id) == [first.id, second.id])
    #expect(workspace.selectedTabID == second.id)

    workspace.selectTab(first.id)
    #expect(workspace.selectedTab === first)

    _ = workspace.closeTab(first.id)
    #expect(workspace.tabs.map(\.id) == [second.id])
    #expect(workspace.selectedTab === second)
}

@MainActor
@Test func browserWebsiteDataIsPersistentAndIsolatedByProject() throws {
    let firstProjectWindow = BrowserWorkspace(projectRoot: "/tmp/cherry-project-a")
    let secondProjectWindow = BrowserWorkspace(projectRoot: "/tmp/cherry-project-a")
    let otherProjectWindow = BrowserWorkspace(projectRoot: "/tmp/cherry-project-b")
    let projectlessWindow = BrowserWorkspace(projectRoot: nil)

    let firstStoreID = try #require(firstProjectWindow.selectedTab)
        .webView.configuration.websiteDataStore.identifier
    let secondStoreID = try #require(secondProjectWindow.selectedTab)
        .webView.configuration.websiteDataStore.identifier
    let otherStoreID = try #require(otherProjectWindow.selectedTab)
        .webView.configuration.websiteDataStore.identifier

    #expect(firstStoreID == secondStoreID)
    #expect(firstStoreID != otherStoreID)
    #expect(projectlessWindow.selectedTab?.webView.configuration.websiteDataStore.identifier == nil)
}

@MainActor
@Test func browserControlServerKeepsAutomationHiddenUntilExplicitSelection() async throws {
    let defaultsName = "CherryTests.BrowserControl.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    let settings = AgentSettings(defaults: defaults)
    let projectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CherryBrowser-\(UUID().uuidString)", isDirectory: true)
    let socketDirectory = URL(
        fileURLWithPath: "/tmp/cherry-browser-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    let socketURL = socketDirectory.appendingPathComponent("control.sock")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    _ = settings.addProject(path: projectRoot.path)

    let workspace = TerminalWorkspace(projectRoot: projectRoot.path)
    let chromeState = ProjectWindowChromeState()
    let server = CherryControlServer(
        workspace: workspace,
        chromeState: chromeState,
        socketURL: socketURL,
        agentSettings: settings
    )
    defer {
        server.stop()
        workspace.closeAllSessions()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: projectRoot)
        try? FileManager.default.removeItem(at: socketDirectory)
    }
    server.start()

    let openResponse = try await sendBrowserControl(.openBrowser(.init()), socketURL: socketURL)
    guard case .openBrowser(let open)? = openResponse.result else {
        Issue.record("Expected openBrowser result, got \(String(describing: openResponse))")
        return
    }
    #expect(open.browser.visible == false)
    #expect(open.browser.selected == false)
    #expect(open.browser.placement == nil)
    #expect(open.browser.tabs.count == 1)

    let selectedResponse = try await sendBrowserControl(
        .selectBrowser(.init(placement: .splitRight)),
        socketURL: socketURL
    )
    guard case .selectBrowser(let selected)? = selectedResponse.result else {
        Issue.record("Expected selectBrowser result, got \(String(describing: selectedResponse))")
        return
    }
    #expect(selected.browser.visible)
    #expect(selected.browser.selected)
    #expect(selected.browser.placement == .splitRight)

    let browser = try #require(workspace.browserWorkspace)
    let tab = try #require(browser.selectedTab)
    tab.loadHTMLString("<p>Control page</p>")
    _ = try await browser.waitForLoad(tabID: tab.id, timeoutMilliseconds: 5_000)

    let disabledResponse = try await sendBrowserControl(
        .browserEvaluate(.init(script: "return 1")),
        socketURL: socketURL
    )
    #expect(disabledResponse.error?.code == "browser_javascript_disabled")

    settings.setBrowserJavaScriptEnabled(true, for: projectRoot.path)
    let enabledResponse = try await sendBrowserControl(
        .browserEvaluate(.init(script: "return { one: 1, truth: true }")),
        socketURL: socketURL
    )
    guard case .browserEvaluate(let evaluation)? = enabledResponse.result else {
        Issue.record("Expected browserEvaluate result, got \(String(describing: enabledResponse))")
        return
    }
    #expect(evaluation.value == .object(["one": .int(1), "truth": .bool(true)]))

    let closeResponse = try await sendBrowserControl(.closeBrowser, socketURL: socketURL)
    guard case .closeBrowser(let closed)? = closeResponse.result else {
        Issue.record("Expected closeBrowser result, got \(String(describing: closeResponse))")
        return
    }
    #expect(closed.browser.workspaceID == nil)
    #expect(closed.browser.tabs.isEmpty)
}

private func sendBrowserControl(
    _ request: CherryControlRequest,
    socketURL: URL
) async throws -> CherryControlResponse {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try CherryControlClient(socketURL: socketURL).send(request))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
