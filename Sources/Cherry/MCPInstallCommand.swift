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
    static func appBundleURL(bundle: Bundle = .main) -> URL? {
        let bundleURL = bundle.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL
    }

    static func helperURL(appBundleURL: URL) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CherryMCP", isDirectory: false)
    }

    static func helperExists(appBundleURL: URL, fileManager: FileManager = .default) -> Bool {
        let path = helperURL(appBundleURL: appBundleURL).path
        return fileManager.isExecutableFile(atPath: path)
    }

    static func commands(appBundleURL: URL) -> [MCPInstallCommand] {
        let helperPath = shellQuote(helperURL(appBundleURL: appBundleURL).path)
        return [
            MCPInstallCommand(
                harness: .codex,
                command: "codex mcp add cherry -- \(helperPath)"
            ),
            MCPInstallCommand(
                harness: .claude,
                command: "claude mcp add --scope user cherry -- \(helperPath)"
            )
        ]
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
