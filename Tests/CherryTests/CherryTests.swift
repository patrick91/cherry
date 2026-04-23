import Testing
@testable import Cherry

@MainActor
@Test func scrollbackIsBounded() async throws {
    let session = TerminalSession(
        title: "Bench",
        subtitle: "tests",
        tint: .systemBlue,
        maxScrollback: 10
    )

    session.append((0..<24).map { "line-\($0)" })

    #expect(session.snapshot(range: 0..<session.lineCount).count == 10)
    #expect(session.snapshot(range: 0..<1).first == "line-14")
}

@MainActor
@Test func scrollbackIsUnlimitedByDefault() async throws {
    let session = TerminalSession(
        title: "Bench",
        subtitle: "tests",
        tint: .systemBlue
    )

    session.append((0..<24).map { "line-\($0)" })

    #expect(session.snapshot(range: 0..<session.lineCount).count == 24)
    #expect(session.statusLine == "24 lines · unlimited")
}

@MainActor
@Test func clearResetsBufferToSingleEmptyVisualLine() async throws {
    let session = TerminalSession(
        title: "Bench",
        subtitle: "tests",
        tint: .systemBlue
    )

    session.append(["hello"])
    session.clear()

    #expect(session.lineCount == 1)
    #expect(session.snapshot(range: 0..<1) == [""])
}
