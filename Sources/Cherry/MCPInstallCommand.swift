import Foundation

enum MCPHarness: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var name: String {
        switch self {
        case .codex:
            "Codex"
        case .claude:
            "Claude"
        }
    }
}

struct MCPInstallCommand: Identifiable, Equatable {
    let harness: MCPHarness
    let command: String

    var id: MCPHarness { harness }
}

enum MCPInstallCommandBuilder {
    static var serverURL: String {
        CherryMCPHTTPServer.url
    }

    static var helperCommand: String {
        guard let executableURL = Bundle.main.executableURL else {
            return "CherryMCP"
        }
        let helperURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("CherryMCP", isDirectory: false)
        return shellQuoted(helperURL.path)
    }

    static func commands() -> [MCPInstallCommand] {
        return [
            MCPInstallCommand(
                harness: .codex,
                command: "codex mcp add cherry -- \(helperCommand)"
            ),
            MCPInstallCommand(
                harness: .claude,
                command: "claude mcp add --transport stdio --scope user cherry -- \(helperCommand)"
            )
        ]
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
