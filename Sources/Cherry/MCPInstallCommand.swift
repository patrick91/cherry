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

    static func commands() -> [MCPInstallCommand] {
        return [
            MCPInstallCommand(
                harness: .codex,
                command: "codex mcp add cherry --url \(serverURL)"
            ),
            MCPInstallCommand(
                harness: .claude,
                command: "claude mcp add --transport http --scope user cherry \(serverURL)"
            )
        ]
    }
}
