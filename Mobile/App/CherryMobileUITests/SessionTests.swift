import XCTest

@MainActor
final class SessionTests: XCTestCase {
    private var app: XCUIApplication!
    private var list: XCUIElement { app.descendants(matching: .any)["conversation"].firstMatch }
    private var field: XCUIElement { app.descendants(matching: .any)["reply-field"].firstMatch }
    private var send: XCUIElement { app.buttons["send-reply"] }
    private let ending = "History end. Ready for your reply."

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app?.terminate()
        super.tearDown()
    }

    private func launch(_ extra: [String] = [], claude: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = ["-screen", "session:\(claude ? "demo-claude" : "demo-pi")", "-demoLongConversation", "YES", "-demoTurnSeconds", "4"] + extra
        app.launch()
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        if !claude { XCTAssertTrue(message(ending).waitForExistence(timeout: 5)) }
    }

    private func message(_ text: String) -> XCUIElement { app.staticTexts[text].firstMatch }

    private func wait(_ predicate: String, on element: XCUIElement, timeout: TimeInterval = 8) {
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: timeout) == .completed)
    }

    private func visible(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, file: file, line: line)
        let frame = element.frame
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, list.frame.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, field.frame.minY, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    private func reply(_ text: String) {
        field.tap()
        field.typeText(text)
        send.tap()
    }

    private func answer(_ text: String) -> XCUIElement { message("(pi in the demo) Done: \(text)") }

    func testOpeningShowsEnd() { launch(); visible(message(ending)) }

    func testSendSubmitsAndFollowsAnswer() {
        launch()
        reply("UI reply")
        XCTAssertTrue(message("UI reply").waitForExistence(timeout: 4))
        XCTAssertEqual(field.value as? String, "Reply")
        XCTAssertTrue(app.descendants(matching: .any)["working-row"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(answer("UI reply").waitForExistence(timeout: 8))
        visible(answer("UI reply"))
    }

    func testReturnMakesMultilineReply() {
        launch()
        field.tap(); field.typeText("First line\nSecond line")
        XCTAssertEqual(field.value as? String, "First line\nSecond line")
        XCTAssertFalse(message("First line").exists)
        send.tap()
        XCTAssertTrue(message("First line\nSecond line").waitForExistence(timeout: 4))
        XCTAssertTrue(answer("First line\nSecond line").waitForExistence(timeout: 8))
    }

    func testEmptyAndWhitespaceDisableSend() {
        launch(); XCTAssertFalse(send.isEnabled)
        field.tap(); field.typeText("   ")
        XCTAssertFalse(send.isEnabled)
    }

    func testKeyboardPreservesEndAndDragDismisses() {
        launch(); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        visible(message(ending))
        list.swipeDown()
        wait("exists == false", on: app.keyboards.firstMatch, timeout: 3)
    }

    func testConversationTapDismissesKeyboard() {
        launch(); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        message(ending).tap()
        wait("exists == false", on: app.keyboards.firstMatch, timeout: 3)
    }

    func testIncomingEntriesFollowEnd() {
        launch(["-demoIncremental", "YES", "-demoTurnSeconds", "6"])
        reply("Stream reply")
        let tool = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Streaming file 1.swift")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 5)); visible(tool)
        XCTAssertTrue(answer("Stream reply").waitForExistence(timeout: 8)); visible(answer("Stream reply"))
    }

    func testIncomingEntriesPreserveReadingPosition() {
        launch(["-demoIncremental", "YES", "-demoTurnSeconds", "10"])
        reply("Read while working")
        list.swipeDown(); list.swipeDown()
        guard let anchor = app.staticTexts.allElementsBoundByIndex.first(where: { $0.label.hasPrefix("History message") && $0.isHittable }) else {
            return XCTFail("Scrolling up should reveal a history message")
        }
        let before = anchor.frame
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !anchor.exists || abs(anchor.frame.minY - before.minY) > 2
        }, object: anchor)
        moved.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 12), .completed)
        XCTAssertEqual(anchor.frame.minY, before.minY, accuracy: 2)
        XCTAssertFalse(answer("Read while working").isHittable)
    }

    func testSendFromHistoryGoesToEnd() {
        launch(); list.swipeDown(); list.swipeDown()
        XCTAssertFalse(message(ending).isHittable)
        reply("Return to end")
        XCTAssertTrue(answer("Return to end").waitForExistence(timeout: 8)); visible(answer("Return to end"))
    }

    func testToolExpansionMovesRowsWithoutOverlap() {
        launch()
        let more = app.buttons["more-tool-calls"].firstMatch
        for _ in 0..<5 { if more.isHittable { break }; list.swipeDown() }
        XCTAssertTrue(more.isHittable)
        let before = app.descendants(matching: .any).matching(identifier: "tool-line").count
        more.tap()
        let rows = app.descendants(matching: .any).matching(identifier: "tool-line")
        XCTAssertGreaterThan(rows.count, before)
        guard let row = rows.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            return XCTFail("Expanded tools should have a visible row")
        }
        let oldHeight = row.frame.height
        row.tap()
        wait("frame.size.height > \(oldHeight)", on: row, timeout: 3)
        let visibleRows = rows.allElementsBoundByIndex.filter { $0.isHittable }.sorted { $0.frame.minY < $1.frame.minY }
        for (a, b) in zip(visibleRows, visibleRows.dropFirst()) { XCTAssertLessThanOrEqual(a.frame.maxY, b.frame.minY + 1) }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "History result")).firstMatch.exists)
    }

    func testApprovalStartsTurnAndAnswers() {
        launch(claude: true)
        let card = app.descendants(matching: .any)["question-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 4))
        app.buttons["Option 1: Yes"].tap()
        wait("exists == false", on: card, timeout: 4)
        XCTAssertTrue(app.descendants(matching: .any)["working-row"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(message("All 16 key encoder tests passed.").waitForExistence(timeout: 8))
    }

    func testScreenRoundTripReturnsToEnd() {
        launch(); list.swipeDown()
        app.buttons["Show Screen"].tap(); app.buttons["Show Conversation"].tap()
        XCTAssertTrue(message(ending).waitForExistence(timeout: 5)); visible(message(ending))
    }

    func testKeysCanBeTapped() {
        launch(); app.buttons["show-keys"].tap()
        for key in ["esc", "↑", "↓", "←", "→", "⏎", "⇥", "⌃C"] {
            let button = app.buttons[key]
            if !button.isHittable { app.scrollViews.containing(.button, identifier: "esc").firstMatch.swipeLeft() }
            XCTAssertTrue(button.isHittable); button.tap()
        }
    }

    func testRotationKeepsEndUncut() {
        launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        visible(message(ending))
        XCUIDevice.shared.orientation = .portrait
        visible(message(ending))
    }

    func testAssistantTextOffersCopyOrSelection() {
        launch(); message(ending).press(forDuration: 1)
        let action = app.menuItems.matching(NSPredicate(format: "label CONTAINS[c] 'copy' OR label CONTAINS[c] 'select'")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3))
    }

    func testReconnectKeepsConversationAndCanSend() {
        launch(["-demoDropAfter", "5", "-demoTurnSeconds", "1"])
        let note = message("Reconnecting to Demo Mac…")
        XCTAssertTrue(note.waitForExistence(timeout: 7))
        XCTAssertTrue(message(ending).exists)
        wait("exists == false", on: note, timeout: 4)
        reply("After reconnect")
        XCTAssertTrue(answer("After reconnect").waitForExistence(timeout: 4))
    }

    func testDraftSurvivesScreenRoundTrip() {
        launch(); field.tap(); field.typeText("Unsent draft")
        app.buttons["Show Screen"].tap(); app.buttons["Show Conversation"].tap()
        XCTAssertEqual(field.value as? String, "Unsent draft")
        XCTAssertFalse(message("Unsent draft").exists)
    }
}
