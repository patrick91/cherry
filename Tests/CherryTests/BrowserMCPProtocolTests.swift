import CherryControl
import Foundation
import MCP
import Testing
@testable import CherryMCP

@Test func browserControlRequestsRoundTrip() throws {
    let tabID = UUID().uuidString
    let requests: [CherryControlRequest] = [
        .getBrowserStatus,
        .openBrowser(.init(url: "https://example.com")),
        .closeBrowser,
        .selectBrowser(.init(placement: .splitRight)),
        .openBrowserTab(.init(url: "http://127.0.0.1:8000")),
        .closeBrowserTab(.init(tabID: tabID)),
        .selectBrowserTab(.init(tabID: nil)),
        .browserNavigate(.init(tabID: tabID, url: "https://example.com/docs")),
        .browserBack(.init(tabID: tabID)),
        .browserForward(.init()),
        .browserReload(.init(tabID: tabID)),
        .browserWait(.init(tabID: tabID, timeoutMilliseconds: 2_000)),
        .browserSnapshot(.init(tabID: tabID)),
        .browserScreenshot(.init(tabID: tabID)),
        .browserClick(.init(tabID: tabID, elementRef: "3:button-1")),
        .browserType(.init(tabID: tabID, elementRef: "3:input-2", text: "Cherry", clear: true)),
        .browserPress(.init(tabID: tabID, key: "Enter", modifiers: ["command"])),
        .browserScroll(.init(tabID: tabID, deltaX: 0, deltaY: 640)),
        .browserEvaluate(.init(
            tabID: tabID,
            script: "return count + 1",
            arguments: [
                "count": .int(2),
                "options": .object(["enabled": .bool(true)])
            ]
        ))
    ]

    for request in requests {
        let scoped = CherryControlRequest.scoped(.init(projectRoot: "/tmp/cherry-browser", request: request))
        let data = try JSONEncoder().encode(scoped)
        let decoded = try JSONDecoder().decode(CherryControlRequest.self, from: data)
        #expect(decoded == scoped)
    }
}

@Test func browserControlResultsRoundTrip() throws {
    let tab = BrowserTabInfo(
        id: UUID().uuidString,
        title: "Example",
        url: "https://example.com",
        isLoading: false,
        estimatedProgress: 1,
        canGoBack: true,
        canGoForward: false
    )
    let status = BrowserStatusResult(
        workspaceID: UUID().uuidString,
        projectRoot: "/tmp/cherry-browser",
        visible: true,
        selected: false,
        placement: .splitRight,
        selectedTabID: tab.id,
        tabs: [tab]
    )
    let results: [CherryControlResult] = [
        .getBrowserStatus(status),
        .openBrowser(.init(browser: status, tab: tab)),
        .closeBrowser(.init(browser: status)),
        .selectBrowser(.init(browser: status, tab: tab)),
        .openBrowserTab(.init(browser: status, tab: tab)),
        .closeBrowserTab(.init(browser: status)),
        .selectBrowserTab(.init(browser: status, tab: tab)),
        .browserNavigate(.init(browser: status, tab: tab)),
        .browserBack(.init(browser: status, tab: tab)),
        .browserForward(.init(browser: status, tab: tab)),
        .browserReload(.init(browser: status, tab: tab)),
        .browserWait(.init(browser: status, tab: tab)),
        .browserSnapshot(.init(
            tabID: tab.id,
            url: tab.url,
            title: tab.title,
            documentGeneration: 3,
            elements: [.init(ref: "3:button-1", role: "button", name: "Continue")],
            text: "button \"Continue\" [ref=3:button-1]"
        )),
        .browserScreenshot(.init(
            tabID: tab.id,
            url: tab.url,
            title: tab.title,
            dataBase64: "iVBORw0KGgo="
        )),
        .browserClick(.init(browser: status, tab: tab)),
        .browserType(.init(browser: status, tab: tab)),
        .browserPress(.init(browser: status, tab: tab)),
        .browserScroll(.init(browser: status, tab: tab)),
        .browserEvaluate(.init(
            tabID: tab.id,
            url: tab.url,
            title: tab.title,
            value: .object(["ok": .bool(true), "count": .int(3)])
        ))
    ]

    for result in results {
        let response = CherryControlResponse(result: result)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CherryControlResponse.self, from: data)
        #expect(decoded == response)
    }
}

@Test func browserJSONValueUsesNaturalJSONEncoding() throws {
    let value = BrowserJSONValue.object([
        "null": .null,
        "bool": .bool(true),
        "int": .int(4),
        "double": .double(2.5),
        "string": .string("Cherry"),
        "array": .array([.int(1), .string("two")])
    ])
    let data = try JSONEncoder().encode(value)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["bool"] as? Bool == true)
    #expect(object["int"] as? Int == 4)
    #expect(object["string"] as? String == "Cherry")
    #expect(try JSONDecoder().decode(BrowserJSONValue.self, from: data) == value)
}

@Test func browserMCPToolsAdvertiseProjectAndTabScopes() throws {
    let browserToolNames: Set<String> = [
        "get_browser_status", "open_browser", "close_browser", "select_browser",
        "open_browser_tab", "close_browser_tab", "select_browser_tab", "browser_navigate",
        "browser_back", "browser_forward", "browser_reload", "browser_wait",
        "browser_snapshot", "browser_screenshot", "browser_click", "browser_type",
        "browser_press", "browser_scroll", "browser_evaluate"
    ]
    let tools = Dictionary(uniqueKeysWithValues: CherryMCPTools.all.map { ($0.name, $0) })

    #expect(browserToolNames.isSubset(of: Set(tools.keys)))
    for name in browserToolNames {
        let tool = try #require(tools[name])
        let schema = try #require(tool.inputSchema.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(properties["project_root"] != nil)
        if name.hasPrefix("browser_") || ["close_browser_tab", "select_browser_tab"].contains(name) {
            #expect(properties["tab_id"] != nil)
        }
    }

    let selectSchema = try #require(tools["select_browser"]?.inputSchema.objectValue)
    let selectProperties = try #require(selectSchema["properties"]?.objectValue)
    let placement = try #require(selectProperties["placement"]?.objectValue)
    #expect(placement["enum"]?.arrayValue == [.string("split_right"), .string("standalone")])

    let evaluateSchema = try #require(tools["browser_evaluate"]?.inputSchema.objectValue)
    let evaluateProperties = try #require(evaluateSchema["properties"]?.objectValue)
    #expect(evaluateProperties["script"] != nil)
    #expect(evaluateProperties["arguments"]?.objectValue?["type"] == .string("object"))
}

@Test func browserMCPArgumentsMapToControlRequests() throws {
    #expect(try CherryMCPTools.controlRequest(
        name: "select_browser",
        arguments: ["placement": .string("split_right")]
    ) == .selectBrowser(.init(placement: .splitRight)))

    #expect(try CherryMCPTools.controlRequest(
        name: "browser_screenshot",
        arguments: [:]
    ) == .browserScreenshot(.init(tabID: nil)))

    #expect(try CherryMCPTools.controlRequest(
        name: "browser_evaluate",
        arguments: [
            "tab_id": .string("tab-1"),
            "script": .string("return options"),
            "arguments": .object([
                "options": .array([.string("one"), .int(2), .bool(true)])
            ])
        ]
    ) == .browserEvaluate(.init(
        tabID: "tab-1",
        script: "return options",
        arguments: ["options": .array([.string("one"), .int(2), .bool(true)])]
    )))

    #expect(throws: CherryControlError(
        code: "invalid_browser_placement",
        message: "Unknown browser placement: floating"
    )) {
        try CherryMCPTools.controlRequest(
            name: "select_browser",
            arguments: ["placement": .string("floating")]
        )
    }
}

@Test func browserScreenshotMCPResultIncludesNativeImageContent() throws {
    let payload = BrowserScreenshotResult(
        tabID: UUID().uuidString,
        url: "https://example.com",
        title: "Example",
        dataBase64: "iVBORw0KGgo="
    )
    let result = try CherryMCPTools.toolResult(.browserScreenshot(payload))

    #expect(result.isError == false)
    #expect(result.structuredContent != nil)
    #expect(result.content.contains { content in
        if case .image(let data, let mimeType, _, _) = content {
            return data == payload.dataBase64 && mimeType == "image/png"
        }
        return false
    })
}
