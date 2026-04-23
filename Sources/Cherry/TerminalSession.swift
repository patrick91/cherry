import AppKit
import Combine
import Foundation

@MainActor
final class TerminalWorkspace: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published var selectedSessionID: UUID?

    init() {
        sessions = [
            TerminalSession.sample(
                title: "Build",
                subtitle: "cargo watch · target/debug",
                tint: NSColor(calibratedRed: 0.52, green: 0.89, blue: 0.60, alpha: 1),
                seed: .build
            ),
            TerminalSession.sample(
                title: "Logs",
                subtitle: "observability · local stream",
                tint: NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.32, alpha: 1),
                seed: .logs
            ),
            TerminalSession.sample(
                title: "SSH",
                subtitle: "ops-east-1 · libghostty host",
                tint: NSColor(calibratedRed: 0.42, green: 0.73, blue: 0.98, alpha: 1),
                seed: .ssh
            )
        ]

        selectedSessionID = sessions.first?.id
    }

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
    }

    func select(_ session: TerminalSession) {
        selectedSessionID = session.id
    }

    func addSession() {
        let index = sessions.count + 1
        let tint = Self.palette[(index - 1) % Self.palette.count]
        let newSession = TerminalSession.sample(
            title: "Tab \(index)",
            subtitle: "prototype · interactive buffer",
            tint: tint,
            seed: .prototype(index)
        )

        sessions.append(newSession)
        selectedSessionID = newSession.id
    }

    func close(_ session: TerminalSession) {
        guard sessions.count > 1 else { return }

        let removedIndex = sessions.firstIndex(where: { $0.id == session.id })
        sessions.removeAll(where: { $0.id == session.id })

        guard selectedSessionID == session.id else { return }

        if let removedIndex, sessions.indices.contains(removedIndex) {
            selectedSessionID = sessions[removedIndex].id
        } else {
            selectedSessionID = sessions.last?.id
        }
    }

    func burstSelectedSession() {
        selectedSession?.appendBurst(count: 1_000)
    }

    func clearSelectedSession() {
        selectedSession?.clear()
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
    enum Seed {
        case build
        case logs
        case ssh
        case prototype(Int)
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let tint: NSColor
    let maxScrollback: Int?

    @Published private(set) var revision = 0

    private var lines: [String]

    init(
        title: String,
        subtitle: String,
        tint: NSColor,
        maxScrollback: Int? = nil,
        initialLines: [String] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.maxScrollback = maxScrollback
        self.lines = initialLines
    }

    var lineCount: Int {
        max(lines.count, 1)
    }

    var statusLine: String {
        if let maxScrollback {
            "\(min(lines.count, maxScrollback))/\(maxScrollback) lines"
        } else {
            "\(lines.count) lines · unlimited"
        }
    }

    func snapshot(range: Range<Int>) -> [String] {
        guard !lines.isEmpty else { return [""] }

        let lower = max(0, min(range.lowerBound, lines.count))
        let upper = max(lower, min(range.upperBound, lines.count))
        return Array(lines[lower..<upper])
    }

    func runMockCommand(_ command: String) {
        append([
            "",
            "$ \(command)"
        ])

        switch command {
        case "pwd":
            append(["/opt/cherry/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"])
        case "ls":
            append(["Cargo.toml  Package.swift  Sources  Tests  benches  docs"])
        case "clear":
            clear()
        case "burst":
            appendBurst(count: 1_000)
        case "top":
            appendBurst(count: 48, prefix: "core")
        case "bench":
            append([
                "benchmarking visible-row renderer...",
                "  draw pass median: 1.8 ms",
                "  scrollback policy: unlimited",
                "  visible rows only: enabled"
            ])
        default:
            append([
                "mock-shell: executed `\(command)`",
                "  this prototype keeps the UI native and reserves the terminal surface for a future libghostty bridge"
            ])
        }
    }

    func appendBurst(count: Int, prefix: String = "render") {
        let start = lines.count
        let formatter = Date.FormatStyle()
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
            .second(.twoDigits)

        let burst = (0..<count).map { offset in
            let lineNumber = start + offset + 1
            let tick = lineNumber.formatted(.number.grouping(.never))
            let latency = Double.random(in: 0.28...2.04).formatted(.number.precision(.fractionLength(2)))
            let timestamp = Date().formatted(formatter)
            return "[\(timestamp)] \(prefix)#\(tick) visibleRows=58 frame=\(latency)ms"
        }

        append(burst)
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    func append(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }

        lines.append(contentsOf: newLines)
        if let maxScrollback, lines.count > maxScrollback {
            lines.removeFirst(lines.count - maxScrollback)
        }
        revision &+= 1
    }

    static func sample(title: String, subtitle: String, tint: NSColor, seed: Seed) -> TerminalSession {
        let session = TerminalSession(title: title, subtitle: subtitle, tint: tint)
        session.seed(with: seed)
        return session
    }

    private func seed(with seed: Seed) {
        switch seed {
        case .build:
            append([
                "ghostty-prototype booting",
                "renderer = AppKitCanvas",
                "tabs = left rail",
                "",
                "$ cargo watch -x run",
                "[watch] compiling ui-shell",
                "[watch] linked native preview in 1.2s",
                "[watch] scrollback policy set to unlimited"
            ])

            appendBurst(count: 180, prefix: "build")
        case .logs:
            append([
                "stream attached: observability/local",
                "sampling paint and layout work on every scroll delta",
                "goal: sidebar tabs without paying for SwiftUI text rows"
            ])

            appendBurst(count: 260, prefix: "logs")
        case .ssh:
            append([
                "Connected to ops-east-1",
                "Last login: Thu Apr 23 15:38:02 on ttys004",
                "$ tmux attach -t ghostty",
                "nvim app/session.zig"
            ])

            appendBurst(count: 120, prefix: "ssh")
        case .prototype(let index):
            append([
                "prototype tab \(index) created",
                "use `burst`, `bench`, `ls`, `pwd`, or `clear` in the command bar"
            ])
        }
    }
}
