import Foundation

/// A Mac that lives in the app: a few agents in every state, which answer
/// what you type. For the demo, previews, screenshots and the app's tests.
public struct DemoMac: MacConnector {
    public static let endpoint = MacEndpoint(
        id: UUID(uuidString: "C4E77E00-0000-4000-8000-000000000001")!,
        name: "Demo Mac",
        host: "demo",
        user: "you",
        hostKeyFingerprint: "SHA256:demo"
    )

    /// How long a demo agent works on a turn.
    public let turnDuration: Duration
    /// When set, each connection drops this long after it opened, as a lost
    /// network would (to show reconnecting).
    public let dropsAfter: Duration?

    public init(turnDuration: Duration = .seconds(4), dropsAfter: Duration? = nil) {
        self.turnDuration = turnDuration
        self.dropsAfter = dropsAfter
    }

    public func connect(to endpoint: MacEndpoint) async throws -> any MacConnection {
        let connection = DemoMacConnection(endpoint: endpoint, turnDuration: turnDuration)
        if let dropsAfter {
            Task { [weak connection] in
                try? await Task.sleep(for: dropsAfter)
                await connection?.drop(reason: "The Demo Mac dropped the connection.")
            }
        }
        return connection
    }
}

public actor DemoMacConnection: MacConnection {
    public nonisolated let endpoint: MacEndpoint
    private let turnDuration: Duration
    private var sessions: [MobileSession]
    private var screens: [String: [String]]
    private var drafts: [String: String] = [:]
    private var subscribers: [UUID: AsyncStream<MacEvent>.Continuation] = [:]
    private var attachments: [String: [DemoAttachment]] = [:]
    /// Each attachment's size, which its paints keep to.
    private var attachmentSizes: [ObjectIdentifier: TerminalSize] = [:]
    private var isConnected = true
    /// Each agent's conversation as its session file would hold it: entries
    /// and the results of tools that finished later, in order.
    private var conversations: [String: [TranscriptEntry]] = DemoMacConnection.seededConversations
    /// The tool each agent waits to run until it is approved.
    private var toolsAwaitingApproval = ["demo-claude": "c5"]
    private var nextEntry = 0

    init(endpoint: MacEndpoint, turnDuration: Duration) {
        self.endpoint = endpoint
        self.turnDuration = turnDuration
        let mac = endpoint.id
        let now = Date()
        sessions = [
            MobileSession(
                id: "demo-claude", macID: mac, title: "Fix the key encoder tests", directory: "~/github/patrick91/cherry",
                kind: .agent("claude"), attention: .approval,
                detail: "Approve Bash: swift test --filter AdapterAwayKeyInput",
                size: TerminalSize(columns: 100, rows: 30), changedAt: now.addingTimeInterval(-40)
            ),
            MobileSession(
                id: "demo-codex", macID: mac, title: "Port the schema printer", directory: "~/github/patrick91/strawberry",
                kind: .agent("codex"), attention: .working, detail: "Editing SchemaPrinter.swift",
                size: TerminalSize(columns: 100, rows: 30), changedAt: now.addingTimeInterval(-2)
            ),
            MobileSession(
                id: "demo-pi", macID: mac, title: "Tidy my notes", directory: "~/notes",
                kind: .agent("pi"), attention: .resultReady, detail: "Tidied 12 notes",
                size: TerminalSize(columns: 100, rows: 30), changedAt: now.addingTimeInterval(-600)
            ),
            MobileSession(
                id: "demo-dev", macID: mac, title: "npm run dev", directory: "~/github/patrick91/site",
                kind: .command, size: TerminalSize(columns: 100, rows: 30), changedAt: now.addingTimeInterval(-90)
            ),
            MobileSession(
                id: "demo-zsh", macID: mac, title: "zsh", directory: "~",
                kind: .terminal, attention: .unknown, size: TerminalSize(columns: 100, rows: 30)
            ),
        ]
        screens = [
            "demo-claude": [
                "⏺ I'll run the key encoder tests before committing.",
                "",
                "╭──────────────────────────────────────────────────────╮",
                "│ Bash command                                         │",
                "│                                                      │",
                "│   swift test --filter AdapterAwayKeyInput            │",
                "│   Run the key encoder tests                          │",
                "│                                                      │",
                "│ Do you want to proceed?                              │",
                "│ ❯ 1. Yes                                             │",
                "│   2. Yes, and don't ask again for swift test         │",
                "│   3. No, and tell Claude what to do differently      │",
                "╰──────────────────────────────────────────────────────╯",
            ],
            "demo-codex": [
                "• Reading Sources/Printer/SchemaPrinter.swift",
                "• Editing Sources/Printer/SchemaPrinter.swift (+48 -12)",
                "",
                "• Working (1m 12s • esc to interrupt)",
                "",
                "› ",
            ],
            "demo-pi": [
                "Summarised this week's notes into weekly/2026-40.md:",
                "",
                "  - Cherry: persistent sessions merged to main",
                "  - Strawberry: schema printer port started",
                "  - Talk: outline for PyCon Italia",
                "",
                "> ",
            ],
            "demo-dev": [
                "  VITE v7.1.0  ready in 412 ms",
                "",
                "  ➜  Local:   http://localhost:5173/",
                "  ➜  Network: use --host to expose",
                "  ➜  press h + enter to show help",
                "",
                "11:04:51 PM [vite] hmr update /src/components/SessionList.tsx, /src/styles/session-list.css (x2)",
            ],
            "demo-zsh": [
                "~ ❯ ",
            ],
        ]
    }

    public func sessions() async throws -> [MobileSession] {
        try checkConnected()
        return sessions
    }

    public func screen(of sessionID: String) async throws -> ScreenSnapshot {
        try checkConnected()
        guard let session = sessions.first(where: { $0.id == sessionID }), let lines = screens[sessionID] else {
            throw MacConnectionError.sessionGone(sessionID)
        }
        return ScreenSnapshot(lines: lines + promptLine(sessionID), size: session.size)
    }

    public func send(_ keys: [MobileKey], to sessionID: String) async throws {
        try checkConnected()
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw MacConnectionError.sessionGone(sessionID)
        }
        for key in keys {
            switch key {
            case .text(let text):
                if awaitsChoice(at: index), let digit = Self.choiceDigit(text) {
                    choose(digit, at: index)
                } else {
                    drafts[sessionID, default: ""] += text
                }
            case .backspace:
                _ = drafts[sessionID]?.popLast()
            case .controlC, .escape:
                drafts[sessionID] = nil
            case .enter:
                submit(at: index)
            case .tab, .up, .down, .left, .right:
                break
            }
        }
        broadcast(.screenChanged(sessionID: sessionID))
    }

    public nonisolated func events() -> AsyncStream<MacEvent> {
        let (stream, continuation) = AsyncStream<MacEvent>.makeStream()
        let id = UUID()
        Task { await self.subscribe(id, continuation) }
        continuation.onTermination = { _ in
            Task { await self.unsubscribe(id) }
        }
        return stream
    }

    public func transcript(of sessionID: String, after cursor: String?, limit: Int) async throws -> AgentTranscript {
        try checkConnected()
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            throw MacConnectionError.sessionGone(sessionID)
        }
        guard case .agent(let agent) = session.kind, let log = conversations[sessionID] else {
            throw MacConnectionError.noConversation
        }
        if let cursor, cursor.hasPrefix("demo:"), let seen = Int(cursor.dropFirst("demo:".count)), seen <= log.count {
            return AgentTranscript(agent: agent, cursor: "demo:\(log.count)", reset: false, entries: Array(log[seen...]))
        }
        var conversation = Conversation(capacity: limit)
        conversation.apply(AgentTranscript(agent: agent, cursor: "", reset: true, entries: log))
        return AgentTranscript(
            agent: agent,
            sessionID: "\(sessionID)-session",
            cursor: "demo:\(log.count)",
            reset: true,
            moreBefore: conversation.moreBefore,
            entries: conversation.entries
        )
    }

    public func attach(_ sessionID: String, size: TerminalSize) async throws -> any TerminalAttachment {
        try checkConnected()
        guard let lines = screens[sessionID] else { throw MacConnectionError.sessionGone(sessionID) }
        let attachment = DemoAttachment(sessionID: sessionID, connection: self)
        attachments[sessionID, default: []].append(attachment)
        attachmentSizes[ObjectIdentifier(attachment)] = size
        repaint(attachment, lines: lines + promptLine(sessionID))
        return attachment
    }

    public func ping(timeout: Duration) async throws {
        try checkConnected()
    }

    public func disconnect() async {
        drop(reason: "Disconnected")
    }

    /// Ends the connection as a lost network would, with `reason`.
    public func drop(reason: String) {
        guard isConnected else { return }
        isConnected = false
        for continuation in subscribers.values {
            continuation.yield(.disconnected(reason: reason))
            continuation.finish()
        }
        subscribers.removeAll()
        for attachment in attachments.values.flatMap({ $0 }) {
            attachment.finish()
        }
        attachments.removeAll()
    }

    // MARK: - Demo behaviour

    /// What a terminal of `size` shows for `lines`: cleared, then the last
    /// lines that fit, each cut at its width (a real program would redraw
    /// for it; the demo's screens are drawn for 100 columns).
    static func paint(_ lines: [String], size: TerminalSize? = nil) -> Data {
        var shown = lines
        if let size, size.columns > 0, size.rows > 0 {
            shown = shown.suffix(size.rows).map { String($0.prefix(size.columns)) }
        }
        return Data(("\u{1B}[H\u{1B}[2J" + shown.joined(separator: "\r\n")).utf8)
    }

    /// Bytes typed into an attached terminal: echoed, and Enter submits.
    func typed(_ data: Data, into sessionID: String, by attachment: DemoAttachment) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        for byte in data {
            switch byte {
            case 0x0D:
                submit(at: index)
                repaint(attachment, lines: screens[sessionID, default: []] + promptLine(sessionID))
            case 0x7F:
                if drafts[sessionID]?.popLast() != nil {
                    attachment.emit(Data("\u{8} \u{8}".utf8))
                }
            case 0x31...0x39 where awaitsChoice(at: index):
                // A menu takes the digit by itself, as Claude Code's do.
                choose(String(UnicodeScalar(byte)), at: index)
                repaint(attachment, lines: screens[sessionID, default: []])
            case 0x20...0x7E:
                drafts[sessionID, default: ""].append(Character(UnicodeScalar(byte)))
                attachment.emit(Data([byte]))
            default:
                break
            }
        }
    }

    func resized(_ attachment: DemoAttachment, to size: TerminalSize) {
        attachmentSizes[ObjectIdentifier(attachment)] = size
        repaint(attachment, lines: screens[attachment.sessionID, default: []] + promptLine(attachment.sessionID))
    }

    func detached(_ attachment: DemoAttachment) {
        attachments[attachment.sessionID]?.removeAll { $0 === attachment }
        attachmentSizes[ObjectIdentifier(attachment)] = nil
    }

    private func repaint(_ attachment: DemoAttachment, lines: [String]) {
        attachment.emit(Self.paint(lines, size: attachmentSizes[ObjectIdentifier(attachment)]))
    }

    private func promptLine(_ sessionID: String) -> [String] {
        guard let draft = drafts[sessionID], !draft.isEmpty else { return [] }
        return ["› " + draft]
    }

    private func submit(at index: Int) {
        let id = sessions[index].id
        let draft = drafts.removeValue(forKey: id) ?? ""
        guard case .agent(let name) = sessions[index].kind else {
            screens[id, default: []].append(draft.isEmpty ? "" : "\(draft): command not found in the demo")
            return
        }
        switch sessions[index].attention {
        case .approval, .question:
            // Enter picks the selected option, the first.
            choose(Self.choiceDigit(draft) ?? "1", at: index)
            return
        case .resultReady, .idle, .unknown, .error:
            guard !draft.isEmpty else { return }
            record(TranscriptEntry(id: entryID(), kind: .user, text: draft), in: id)
            screens[id, default: []] += ["", "› \(draft)", "", "✻ Thinking… (esc to interrupt)"]
            startTurn(at: index, answer: "⏺ (\(name) in the demo) Done: \(draft)")
        case .working:
            guard !draft.isEmpty else { return }
            screens[id, default: []] += ["› \(draft) (queued)"]
        }
        sessions[index].changedAt = Date()
        broadcast(.sessionsChanged)
    }

    private func awaitsChoice(at index: Int) -> Bool {
        sessions[index].attention == .approval || sessions[index].attention == .question
    }

    /// `text` when it is one digit from 1 to 9.
    private static func choiceDigit(_ text: String) -> String? {
        let choice = text.trimmingCharacters(in: .whitespaces)
        guard choice.count == 1, let digit = choice.first, ("1"..."9").contains(digit) else { return nil }
        return choice
    }

    /// Answers the waiting menu with option `choice`: 3 stops, any other
    /// runs the command.
    private func choose(_ choice: String, at index: Int) {
        let id = sessions[index].id
        drafts[id] = nil
        if choice == "3" {
            if let tool = toolsAwaitingApproval.removeValue(forKey: id) {
                record(TranscriptEntry(id: tool, kind: .toolResult, result: "Not approved", status: .error), in: id)
            }
            record(TranscriptEntry(id: entryID(), kind: .assistant, text: "Stopped. What should I do instead?"), in: id)
            screens[id] = ["⏺ Stopped. What should I do instead?", ""]
            sessions[index].attention = .resultReady
            sessions[index].detail = "Stopped"
        } else {
            screens[id] = ["⏺ Bash(swift test --filter AdapterAwayKeyInput)", "", "✻ Running… (esc to interrupt)"]
            startTurn(at: index, answer: "⏺ All 16 key encoder tests passed.")
        }
        sessions[index].changedAt = Date()
        broadcast(.sessionsChanged)
    }

    private func startTurn(at index: Int, answer: String) {
        let id = sessions[index].id
        sessions[index].attention = .working
        sessions[index].detail = nil
        let duration = turnDuration
        Task {
            try? await Task.sleep(for: duration)
            self.finishTurn(id, answer: answer)
        }
    }

    private func finishTurn(_ id: String, answer: String) {
        guard isConnected, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let tool = toolsAwaitingApproval.removeValue(forKey: id) {
            record(TranscriptEntry(id: tool, kind: .toolResult, result: "Executed 16 tests, with 0 failures", status: .ok), in: id)
        }
        record(TranscriptEntry(id: entryID(), kind: .assistant, text: answer.replacingOccurrences(of: "⏺ ", with: "")), in: id)
        screens[id] = (screens[id] ?? []).filter { !$0.contains("esc to interrupt") } + [answer, ""]
        sessions[index].attention = .resultReady
        sessions[index].detail = answer.replacingOccurrences(of: "⏺ ", with: "")
        sessions[index].changedAt = Date()
        for attachment in attachments[id] ?? [] {
            repaint(attachment, lines: screens[id, default: []])
        }
        broadcast(.screenChanged(sessionID: id))
        broadcast(.sessionsChanged)
    }

    private func subscribe(_ id: UUID, _ continuation: AsyncStream<MacEvent>.Continuation) {
        guard isConnected else {
            continuation.finish()
            return
        }
        subscribers[id] = continuation
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func record(_ entry: TranscriptEntry, in sessionID: String) {
        conversations[sessionID, default: []].append(entry)
    }

    private func entryID() -> String {
        nextEntry += 1
        return "demo-\(nextEntry)"
    }

    /// What the demo's agents said before the app connected.
    private static let seededConversations: [String: [TranscriptEntry]] = [
        "demo-claude": [
            TranscriptEntry(id: "c1", kind: .user, text: "The key encoder tests fail on CI. Fix them, and commit once they pass."),
            TranscriptEntry(id: "c2", kind: .tool, name: "Read", summary: "/Users/you/github/patrick91/cherry/Sources/Cherry/HostRoutedKeyEncoder.swift", result: "412 lines", status: .ok),
            TranscriptEntry(id: "c2b", kind: .tool, name: "Grep", summary: "shiftReturn", result: "Sources/Cherry/HostRoutedKeyEncoder.swift:88\nTests/CherryTests/KeyEncoderTests.swift:41", status: .ok),
            TranscriptEntry(id: "c2c", kind: .tool, name: "Read", summary: "/Users/you/github/patrick91/cherry/Tests/CherryTests/KeyEncoderTests.swift", result: "120 lines", status: .ok),
            TranscriptEntry(id: "c2d", kind: .tool, name: "Bash", summary: "cd /Users/you/github/patrick91/cherry && swift test --filter KeyEncoder", result: "✘ shiftReturnIsCSI13u: expected \"\\e[13;2u\", got \"\\r\"\n1 of 16 tests failed", status: .error),
            TranscriptEntry(id: "c3", kind: .assistant, text: """
            The failure is in **Shift+Return**:

            1. Under the kitty flags it sends `CSI 13;2u`.
            2. On the legacy path it sends a bare `CR`, which Claude Code takes as Return.

            ```swift
            case .shiftReturn: kittyFlags == 0 ? "\\e[27;2;13~" : "\\e[13;2u"
            ```

            I'll fix the legacy path, then run the key encoder tests before committing.
            """),
            TranscriptEntry(id: "c4", kind: .tool, name: "Edit", summary: "/Users/you/github/patrick91/cherry/Sources/Cherry/HostRoutedKeyEncoder.swift", result: "Updated 1 hunk (+6 −2)", status: .ok),
            TranscriptEntry(id: "c5", kind: .tool, name: "Bash", summary: "swift test --filter AdapterAwayKeyInput", status: .running),
        ],
        "demo-codex": [
            TranscriptEntry(id: "x1", kind: .user, text: "Port the schema printer to the new AST."),
            TranscriptEntry(id: "x2", kind: .tool, name: "Shell", summary: "rg -l SchemaPrinter", result: "Sources/Printer/SchemaPrinter.swift\nTests/PrinterTests.swift", status: .ok),
            TranscriptEntry(id: "x3", kind: .tool, name: "Edit", summary: "SchemaPrinter.swift", result: "+48 −12", status: .ok),
            TranscriptEntry(id: "x4", kind: .assistant, text: "The printer walks the new AST now. Updating its tests next."),
            TranscriptEntry(id: "x5", kind: .tool, name: "Shell", summary: "swift test --filter Printer", status: .running),
        ],
        "demo-pi": [
            TranscriptEntry(id: "p1", kind: .user, text: "Tidy my notes: merge duplicates and fix broken links."),
            TranscriptEntry(id: "p2", kind: .tool, name: "bash", summary: "ls notes | wc -l", result: "214", status: .ok),
            TranscriptEntry(id: "p3", kind: .note, text: "Conversation compacted"),
            TranscriptEntry(id: "p4", kind: .assistant, text: """
            Tidied 12 notes: merged 3 duplicates and fixed 9 broken links.

            **What changed:**

            - **Merged:** `weekly/2026-40 (1).md` into `weekly/2026-40.md`, and two copies of `talks/pycon-outline.md`.
            - **Links:** 9 pointed at notes renamed in September; they now use the new names.
            - **Left alone:** `inbox.md`, which links to itself on purpose.

            **One thing to decide:** `archive/` still has 41 notes nothing links to. Say so and I'll move them to `archive/old/`.
            """),
        ],
    ]

    private func broadcast(_ event: MacEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func checkConnected() throws {
        guard isConnected else { throw MacConnectionError.unreachable("disconnected") }
    }
}

/// A demo terminal: it paints the session's screen, echoes what you type,
/// and repaints when the agent answers.
public final class DemoAttachment: TerminalAttachment, @unchecked Sendable {
    public let output: AsyncStream<Data>
    let sessionID: String
    private let continuation: AsyncStream<Data>.Continuation
    private weak var connection: DemoMacConnection?

    init(sessionID: String, connection: DemoMacConnection) {
        self.sessionID = sessionID
        self.connection = connection
        (output, continuation) = AsyncStream<Data>.makeStream()
    }

    public func write(_ data: Data) async throws {
        guard let connection else { throw MacConnectionError.unreachable("disconnected") }
        await connection.typed(data, into: sessionID, by: self)
    }

    public func resize(_ size: TerminalSize) async throws {
        guard let connection else { throw MacConnectionError.unreachable("disconnected") }
        await connection.resized(self, to: size)
    }

    public func detach() async {
        await connection?.detached(self)
        finish()
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func finish() {
        continuation.finish()
    }
}
