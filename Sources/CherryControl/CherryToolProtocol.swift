import Foundation

// MARK: - Tool requests
//
// Control protocol 2 runs MCP tools in the app: `appInfo` says which app
// answers the socket and which requests it knows, `listTools` returns the
// tools for one client (`CherryToolCatalog`), and `callTool` runs one tool
// as its caller. CherryMCP pipes an agent's `tools/list` and `tools/call` to
// them; an app that predates `appInfo` gets typed requests, as before. The
// types below are the wire's (Swift-synthesized Codable, camelCase keys).

extension CherryControl {
    /// The control requests this build knows. 1: typed requests only (no
    /// `appInfo`). 2: `appInfo`, `listTools` and `callTool`.
    public static let controlProtocolVersion = 2
    /// The tab's Cherry command-line tool (its build's `cherry`).
    public static let cliEnvironmentKey = "CHERRY_CLI"
}

/// The app that answers the control socket (`appInfo`): its control
/// protocol, so a helper knows which requests it may send, and its build.
public struct AppInfoResult: Codable, Equatable, Sendable {
    /// The app's `CherryControl.controlProtocolVersion`.
    public let controlProtocol: Int
    /// The app's `CFBundleVersion`, else "dev" (`swift run`).
    public let build: String
    /// The app's `CFBundleShortVersionString`, when it has one.
    public let version: String?
    public let bundleIdentifier: String?
    /// The identity's URL scheme, which is also its MCP server's name.
    public let urlScheme: String

    public init(controlProtocol: Int, build: String, version: String?, bundleIdentifier: String?, urlScheme: String) {
        self.controlProtocol = controlProtocol
        self.build = build
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.urlScheme = urlScheme
    }
}

/// An MCP client as its `initialize` names itself (`clientInfo`), such as
/// `claude-code` or `codex-mcp-client`.
public struct ToolClientInfo: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// What Cherry knows of the client a tool call comes from. The longest wait
/// it accepts depends on it (`waitCapMilliseconds`), and so do the tool
/// descriptions that state that wait (`CherryToolCatalog.tools(for:)`).
public struct ToolClientProfile: Codable, Equatable, Hashable, Sendable {
    public var client: ToolClientInfo?
    /// The client's own limit per tool call, when known (Cherry's launch config, MCP_TOOL_TIMEOUT).
    public var toolTimeoutMilliseconds: Int?

    /// A client Cherry knows nothing of: every wait keeps the limits a
    /// typed request has.
    public static let unknown = ToolClientProfile()

    public init(client: ToolClientInfo? = nil, toolTimeoutMilliseconds: Int? = nil) {
        self.client = client
        self.toolTimeoutMilliseconds = toolTimeoutMilliseconds
    }

    /// The longest wait_for_events / wait_for_tasks this client allows (CherryToolCatalog.waitCap).
    public var waitCapMilliseconds: Int {
        CherryToolCatalog.waitCap(for: self)
    }

    /// A wait's timeout for this client: `requested`, else `defaultValue`,
    /// at least 0 and at most `waitCapMilliseconds`.
    public func clampedWait(_ requested: Int?, default defaultValue: Int) -> Int {
        Self.clampedWait(requested, default: defaultValue, cap: waitCapMilliseconds)
    }

    /// A wait's timeout: `requested`, else `defaultValue`, at least 0 and at
    /// most `cap`. The app's waits and the client's timeout for them
    /// (`CherryToolLayer.callTimeout`) both clamp by it, so the timeout
    /// always covers the wait.
    public static func clampedWait(_ requested: Int?, default defaultValue: Int, cap: Int) -> Int {
        min(max(requested ?? defaultValue, 0), cap)
    }
}

/// What a `callTool` says of its caller. None of it is identity: the app
/// identifies the caller by its process (or a device's token) and uses
/// these only for defaults it cannot verify.
public struct ToolCallContext: Codable, Equatable, Sendable {
    /// A claim (`CHERRY_PROCESS_ID`, `CHERRY_AGENT_ID`), never identity.
    public var callerProcessID: String?
    /// The MCP session's bound process (`bind_session_process`).
    public var boundProcessID: String?
    /// True when the caller keeps a binding (an MCP session); without one,
    /// `bind_session_process` has nothing to bind.
    public var bindsSession: Bool?
    /// The caller's `CHERRY_PROJECT_ROOT`.
    public var projectRoot: String?
    /// The caller's current directory, whose innermost open project scopes
    /// a call that names none.
    public var workingDirectory: String?
    public var profile: ToolClientProfile?
    /// Which interface made the call: "mcp", "call" (`CherryMCP --call`) or
    /// "cli" (`cherry`'s agent commands, `CherryMCP cli`).
    public var interface: String?

    public init(
        callerProcessID: String? = nil,
        boundProcessID: String? = nil,
        bindsSession: Bool? = nil,
        projectRoot: String? = nil,
        workingDirectory: String? = nil,
        profile: ToolClientProfile? = nil,
        interface: String? = nil
    ) {
        self.callerProcessID = callerProcessID
        self.boundProcessID = boundProcessID
        self.bindsSession = bindsSession
        self.projectRoot = projectRoot
        self.workingDirectory = workingDirectory
        self.profile = profile
        self.interface = interface
    }
}

/// `listTools`: the tools for a client (`ToolClientProfile.unknown` when it
/// names none).
public struct ListToolsRequest: Codable, Equatable, Sendable {
    public var profile: ToolClientProfile?

    public init(profile: ToolClientProfile? = nil) {
        self.profile = profile
    }
}

/// The answer to `listTools`: the tools as MCP lists them, their digest
/// (`CherryToolCatalog.digest`), and the server instructions of the app's
/// build.
public struct ListToolsResult: Codable, Equatable, Sendable {
    public let tools: [CherryToolDefinition]
    public let digest: String
    public let instructions: String

    public init(tools: [CherryToolDefinition], digest: String, instructions: String) {
        self.tools = tools
        self.digest = digest
        self.instructions = instructions
    }
}

/// `callTool`: one MCP tool call, with its arguments as the client sent
/// them.
public struct CallToolRequest: Codable, Equatable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]
    public let context: ToolCallContext?

    public init(name: String, arguments: [String: JSONValue] = [:], context: ToolCallContext? = nil) {
        self.name = name
        self.arguments = arguments
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
        case context
    }

    /// A call without arguments has none, as MCP's `tools/call` allows.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
        context = try container.decodeIfPresent(ToolCallContext.self, forKey: .context)
    }
}

/// The answer to `callTool`: the tool's result as CherryMCP returns it to
/// the client. A tool's error is a result too (`isError`, `text`
/// `{"error":{…}}`); a top-level error means the request itself failed.
public struct CallToolResult: Codable, Equatable, Sendable {
    /// The payload as agents read it: snake_case keys, sorted.
    public let text: String
    public let isError: Bool
    /// The same payload with camelCase keys (MCP's `structuredContent`).
    public let structured: JSONValue?
    /// The process the caller's MCP session binds to now
    /// (`bind_session_process`, `spawn_agent` with `bind_session`).
    public var bindProcessID: String?
    /// The digest of `listTools` for the caller's profile when the app
    /// answered: one that differs from the list a client was served means
    /// its list changed.
    public var toolsDigest: String?

    public init(
        text: String,
        isError: Bool,
        structured: JSONValue?,
        bindProcessID: String? = nil,
        toolsDigest: String? = nil
    ) {
        self.text = text
        self.isError = isError
        self.structured = structured
        self.bindProcessID = bindProcessID
        self.toolsDigest = toolsDigest
    }
}

/// An MCP tool definition, JSON-compatible with the MCP `Tool` (keys name, description, inputSchema, annotations).
public struct CherryToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    /// The tool's JSON Schema: an object with `properties` and `required`.
    public let inputSchema: JSONValue
    /// Left out of the JSON when nil.
    public let annotations: CherryToolAnnotations?

    public init(name: String, description: String, inputSchema: JSONValue, annotations: CherryToolAnnotations? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema
        case annotations
    }
}

/// MCP's tool annotations: hints for clients (Codex's approval modes read
/// them), never enforced. A nil hint is left out of the JSON.
public struct CherryToolAnnotations: Codable, Equatable, Sendable {
    /// The tool does not change Cherry or what it runs.
    public var readOnlyHint: Bool?
    /// When it is not read-only: it may end or overwrite something, rather
    /// than only add.
    public var destructiveHint: Bool?
    /// Calling it again with the same arguments changes nothing more.
    public var idempotentHint: Bool?
    /// It reaches outside Cherry's own state.
    public var openWorldHint: Bool?

    public init(
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

/// Which build an executable belongs to, for `appInfo`, CherryMCP's
/// `--version` and `get_status`.
public enum CherryBuildInfo {
    /// The enclosing .app's CFBundleVersion (CherryAppIdentity.configurationInfo), else the name of a
    /// device install's build directory (cherry-host/bin/<build>/, ^\d{14}\.[0-9a-f]+(-[0-9a-f]+)?$ or ^dev-),
    /// else "dev".
    public static func build(executableURL: URL?) -> String {
        guard let executableURL = executableURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            return developmentBuild
        }

        // As CherryAppIdentity.configurationInfo finds the app of a helper
        // in Contents/MacOS, but never falls back to another bundle.
        var directory = executableURL.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if directory.pathExtension.lowercased() == "app" {
                if let version = (Bundle(url: directory)?.infoDictionary?["CFBundleVersion"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !version.isEmpty {
                    return version
                }
                break
            }
            directory = directory.deletingLastPathComponent()
        }

        // A device install: ~/Library/Application Support/cherry-host/bin/<build>/CherryMCP,
        // where <build> is a build id, or one with the hash of its files
        // when that build's directory held other files. A copy still being
        // checked (`<build>.partial-<uuid>`) or one moved aside (`.broken-`)
        // is not a build.
        let buildDirectory = executableURL.deletingLastPathComponent()
        let binDirectory = buildDirectory.deletingLastPathComponent()
        let name = buildDirectory.lastPathComponent
        let isScratch = name.contains(".partial-") || name.contains(".broken-")
        let isBuildName = !isScratch && (
            name.hasPrefix("dev-")
                || name.range(of: #"^\d{14}\.[0-9a-f]+(-[0-9a-f]+)?$"#, options: .regularExpression) != nil
        )
        if isBuildName,
           binDirectory.lastPathComponent == "bin",
           binDirectory.deletingLastPathComponent().lastPathComponent == "cherry-host" {
            return name
        }
        return developmentBuild
    }

    /// The build of an executable outside a bundle or an install (`swift run`,
    /// `.build/debug/CherryMCP`).
    static let developmentBuild = "dev"
}
