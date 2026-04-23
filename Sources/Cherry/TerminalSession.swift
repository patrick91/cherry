import AppKit
import Foundation

private let inputDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_INPUT"] == "1"

@MainActor
final class TerminalWorkspace: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published var selectedSessionID: UUID?

    init() {
        let firstSession = Self.makeSession(index: 1)
        sessions = [firstSession]
        selectedSessionID = firstSession.id
    }

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
    }

    func select(_ session: TerminalSession) {
        selectedSessionID = session.id
    }

    func addSession() {
        let session = Self.makeSession(index: sessions.count + 1)
        sessions.append(session)
        selectedSessionID = session.id
    }

    func close(_ session: TerminalSession) {
        guard sessions.count > 1 else { return }

        let removedIndex = sessions.firstIndex(where: { $0.id == session.id })
        sessions.removeAll(where: { $0.id == session.id })
        session.stop()

        guard selectedSessionID == session.id else { return }

        if let removedIndex, sessions.indices.contains(removedIndex) {
            selectedSessionID = sessions[removedIndex].id
        } else {
            selectedSessionID = sessions.last?.id
        }
    }

    func interruptSelectedSession() {
        selectedSession?.sendInterrupt()
    }

    func restartSelectedSession() {
        selectedSession?.restart()
    }

    func clearSelectedSessionScrollback() {
        selectedSession?.clearScrollback()
    }

    private static func makeSession(index: Int) -> TerminalSession {
        TerminalSession(
            title: "Shell \(index)",
            subtitle: "\(ShellProcessController.defaultShellName) login shell",
            tint: palette[(index - 1) % palette.count]
        )
    }

    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.52, green: 0.89, blue: 0.60, alpha: 1),
        NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.73, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.47, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.63, blue: 0.97, alpha: 1)
    ]
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum SessionState: Equatable {
        case launching
        case live
        case exited(Int32)
        case failed(String)

        var label: String {
            switch self {
            case .launching:
                "launching"
            case .live:
                "live"
            case .exited(let status):
                "exit \(status)"
            case .failed:
                "failed"
            }
        }
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let tint: NSColor
    let maxScrollback: Int?

    @Published private(set) var revision = 0

    private(set) var state: SessionState = .launching
    private var buffer: TerminalTextBuffer
    private var shellProcess: ShellProcessController?
    private var viewportSize = TerminalViewportSize(columns: 120, rows: 32)

    init(
        title: String,
        subtitle: String,
        tint: NSColor,
        maxScrollback: Int? = nil,
        launchShell: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.maxScrollback = maxScrollback
        self.buffer = TerminalTextBuffer(maxScrollback: maxScrollback)

        if launchShell {
            startShell()
        } else {
            state = .exited(0)
        }
    }

    var lineCount: Int {
        buffer.lineCount
    }

    var statusLine: String {
        "\(state.label) · \(lineSummary)"
    }

    var acceptsInput: Bool {
        if case .live = state {
            return true
        }

        return false
    }

    func snapshot(range: Range<Int>) -> [String] {
        buffer.snapshot(range: range)
    }

    func styledSnapshot(range: Range<Int>) -> [TerminalRenderedLine] {
        buffer.styledSnapshot(range: range)
    }

    func sendCommandLine(_ command: String) {
        send(text: command + "\n")
    }

    func send(text: String) {
        guard acceptsInput else { return }
        if inputDebugEnabled {
            fputs("[send text] \(text.debugDescription)\n", stderr)
        }
        shellProcess?.write(text)
    }

    func send(data: Data) {
        guard acceptsInput else { return }
        if inputDebugEnabled {
            let rendered = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            fputs("[send data] \(rendered) shellProcess=\(shellProcess != nil)\n", stderr)
        }
        shellProcess?.write(data)
    }

    func sendInterrupt() {
        send(data: Data([0x03]))
    }

    func clearScrollback() {
        buffer.clear()
        bumpRevision()
    }

    func restart() {
        stop()
        clearScrollback()
        startShell()
    }

    func stop() {
        shellProcess?.terminate()
        shellProcess = nil
    }

    func resize(columns: Int, rows: Int) {
        let nextSize = TerminalViewportSize(columns: columns, rows: rows)
        guard nextSize.columns > 0, nextSize.rows > 0, nextSize != viewportSize else { return }

        viewportSize = nextSize
        shellProcess?.resize(columns: nextSize.columns, rows: nextSize.rows)
    }

    func ingestTestingData(_ data: Data) {
        buffer.ingest(data)
        bumpRevision()
    }

    private func startShell() {
        state = .launching
        bumpRevision()

        do {
            shellProcess = try ShellProcessController(
                configuration: .init(
                    shellPath: ShellProcessController.defaultShellPath,
                    workingDirectory: NSHomeDirectory(),
                    term: "xterm-256color",
                    initialSize: viewportSize
                ),
                onData: { [weak self] data in
                    DispatchQueue.main.async {
                        self?.receiveOutput(data)
                    }
                },
                onExit: { [weak self] status in
                    DispatchQueue.main.async {
                        self?.handleProcessExit(status: status)
                    }
                }
            )

            state = .live
            bumpRevision()
        } catch {
            state = .failed(error.localizedDescription)
            buffer.appendPlainLines([
                "launch failed: \(error.localizedDescription)"
            ])
            bumpRevision()
        }
    }

    private func receiveOutput(_ data: Data) {
        buffer.ingest(data)
        if inputDebugEnabled {
            let tailStart = max(0, buffer.lineCount - 4)
            let tail = buffer.snapshot(range: tailStart..<buffer.lineCount)
            fputs("[buffer tail] \(tail.map(\.debugDescription).joined(separator: " | "))\n", stderr)
        }
        if case .launching = state {
            state = .live
        }
        bumpRevision()
    }

    private func handleProcessExit(status: Int32) {
        shellProcess = nil
        state = .exited(status)
        buffer.appendPlainLines([
            "",
            "[shell exited with status \(status)]"
        ])
        bumpRevision()
    }

    private var lineSummary: String {
        let visibleLineCount = max(buffer.storedLineCount, 1)
        if let maxScrollback {
            return "\(min(visibleLineCount, maxScrollback))/\(maxScrollback) lines"
        } else {
            return "\(visibleLineCount) lines · unlimited"
        }
    }

    private func bumpRevision() {
        revision &+= 1
    }
}
