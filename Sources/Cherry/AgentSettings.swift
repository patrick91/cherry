import Foundation
import CherryControl

struct AgentToolDefinition: Codable, Equatable, Identifiable {
    var name: String
    var command: String
    var arguments: String
    var enabled: Bool

    var id: String { normalizedName }

    var normalizedName: String {
        Self.normalizedName(name)
    }

    var commandLine: String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return "" }
        let trimmedArguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArguments.isEmpty else { return trimmedCommand }
        return "\(trimmedCommand) \(trimmedArguments)"
    }

    var isLaunchable: Bool {
        enabled && !commandLine.isEmpty
    }

    init(name: String, command: String, arguments: String = "", enabled: Bool = true) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum AgentToolBrand: String, Equatable {
    case amp
    case claude
    case codex
    case gemini
    case openCode = "opencode"
    case pi

    var displayName: String {
        switch self {
        case .amp: "Amp"
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .openCode: "OpenCode"
        case .pi: "Pi"
        }
    }

    var logoResourceName: String? {
        switch self {
        case .amp: "amp"
        case .claude: "claude"
        case .codex: "openai"
        case .gemini: "gemini"
        case .pi: "pi"
        case .openCode: nil
        }
    }

    var fallbackLabel: String {
        switch self {
        case .amp: "A"
        case .claude: "Cl"
        case .codex: "Cx"
        case .gemini: "Ge"
        case .openCode: "OC"
        case .pi: "Pi"
        }
    }

    /// How the CLI takes a reasoning effort or thinking level for one
    /// launch: Claude's `--effort`, Pi's `--thinking`, Codex's
    /// `model_reasoning_effort` setting; nil for a CLI without one.
    func effortArguments(_ level: String) -> [String]? {
        switch self {
        case .claude: ["--effort", level]
        case .pi: ["--thinking", level]
        case .codex: ["-c", "model_reasoning_effort=\"\(level)\""]
        case .gemini, .openCode, .amp: nil
        }
    }

    var modelFlag: String? {
        switch self {
        case .codex, .claude, .gemini, .openCode, .pi:
            "--model"
        case .amp:
            nil
        }
    }

    /// The logo of an agent key (`cherry.agent`, a brand's raw value, or an
    /// agent's name), as the menu-bar agent list, background sessions and
    /// the Omni bar show it; nil for a tool without one.
    static func logoResourceName(forAgentKey key: String) -> String? {
        AgentToolBrand(rawValue: key)?.logoResourceName
            ?? AgentToolBrand.detect(name: key)?.logoResourceName
    }

    static func detect(name: String?, commandLine: String? = nil) -> AgentToolBrand? {
        for source in [name, commandLine].compactMap({ $0 }) {
            let tokens = source
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)

            if tokens.contains("codex") || tokens.contains("openai") {
                return .codex
            }
            if tokens.contains("claude") || tokens.contains("anthropic") {
                return .claude
            }
            if tokens.contains("gemini") {
                return .gemini
            }
            if tokens.contains("opencode") {
                return .openCode
            }
            if tokens.contains("amp") {
                return .amp
            }
            if tokens.contains("pi") || tokens.contains("inflection") {
                return .pi
            }
        }
        return nil
    }
}

extension AgentToolDefinition {
    func overridingModel(_ model: String, for brand: AgentToolBrand) -> AgentToolDefinition {
        guard let modelFlag = brand.modelFlag else { return self }

        var overridden = self
        let overrideArguments = "\(modelFlag) \(Self.shellQuoted(model))"
        overridden.arguments = [arguments, overrideArguments]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return overridden
    }

    func overridingEffort(_ level: String, for brand: AgentToolBrand) -> AgentToolDefinition {
        guard let effortArguments = brand.effortArguments(level) else { return self }

        var overridden = self
        overridden.arguments = [arguments, effortArguments.map(Self.shellQuoted).joined(separator: " ")]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return overridden
    }

    private static func shellQuoted(_ value: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.=/:+")
        guard value.rangeOfCharacter(from: safeCharacters.inverted) != nil else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

extension AgentToolDefinition {
    /// The flags that let an agent CLI run tools without asking first:
    /// Claude Code's, and Codex's in its short and long form.
    static let permissionSkippingFlags: Set<String> = [
        "--dangerously-skip-permissions",
        "--yolo",
        "--dangerously-bypass-approvals-and-sandbox",
    ]

    /// Whether the agent runs without permission prompts (Settings' "Skips
    /// permission prompts" tag): a word of its command line, quoted or not,
    /// is one of `permissionSkippingFlags`.
    var skipsPermissionPrompts: Bool {
        commandLine.split(whereSeparator: \.isWhitespace).contains { word in
            Self.permissionSkippingFlags.contains(word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
        }
    }
}

/// Whether an agent CLI reports its state to Cherry (program status, OSC
/// 7501, docs/mcp.md): from which version, not at all, or not known. One
/// that does not report is followed by its output going quiet.
enum ProgramStatusSupport: Equatable, Sendable {
    case reports(minimumVersion: String)
    case doesNotReport
    case unknown
}

extension AgentToolBrand {
    /// The CLI's own name, as its agent's page says it: "Claude Code".
    var productName: String {
        switch self {
        case .amp: "Amp"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .openCode: "OpenCode"
        case .pi: "Pi"
        }
    }

    /// Whether the CLI reports its state (docs/mcp.md › program status):
    /// Claude Code from 2.1.295 and Pi from 1.1.0; Codex and Amp do not;
    /// Gemini CLI and OpenCode are not known either way.
    var programStatusSupport: ProgramStatusSupport {
        switch self {
        case .claude: .reports(minimumVersion: "2.1.295")
        case .pi: .reports(minimumVersion: "1.1.0")
        case .codex, .amp: .doesNotReport
        case .gemini, .openCode: .unknown
        }
    }

    /// The CLI whose `mcp add` connects it to Cherry's MCP helper; nil for
    /// one Cherry has no command for.
    var mcpHarness: MCPHarness? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .pi: .pi
        case .gemini, .openCode, .amp: nil
        }
    }
}

struct ProjectCommandDefinition: Codable, Equatable, Identifiable {
    var name: String
    var command: String
    var arguments: String
    var workingDirectory: String
    var environment: [String: String]
    var autoStart: Bool
    var autoRestart: Bool
    var enabled: Bool

    var id: String { normalizedName }

    var normalizedName: String {
        AgentToolDefinition.normalizedName(name)
    }

    var commandLine: String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return "" }
        let trimmedArguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArguments.isEmpty else { return trimmedCommand }
        return "\(trimmedCommand) \(trimmedArguments)"
    }

    var isLaunchable: Bool {
        enabled && !commandLine.isEmpty
    }

    init(
        name: String,
        command: String,
        arguments: String = "",
        workingDirectory: String = "",
        environment: [String: String] = [:],
        autoStart: Bool = false,
        autoRestart: Bool = false,
        enabled: Bool = true
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.autoStart = autoStart
        self.autoRestart = autoRestart
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        autoRestart = try container.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func resolvedWorkingDirectory(projectRoot: String) -> String {
        let location = ProjectLocation(key: projectRoot)
        if location.isRemote {
            // On another Mac: resolved against the project's path there, and
            // never looked for on this Mac (its host refuses a directory
            // that does not exist).
            let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return location.path }
            if trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") { return trimmed }
            return (location.path as NSString).appendingPathComponent(trimmed)
        }
        let normalized = Self.absoluteWorkingDirectoryPath(workingDirectory, projectRoot: projectRoot)
        guard !normalized.isEmpty else { return projectRoot }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return projectRoot
        }
        return normalized
    }

    func withPortableWorkingDirectory(projectRoot: String) -> ProjectCommandDefinition {
        var command = self
        command.workingDirectory = Self.portableWorkingDirectory(workingDirectory, projectRoot: projectRoot)
        return command
    }

    static func portableWorkingDirectory(_ workingDirectory: String, projectRoot: String) -> String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !projectRoot.isEmpty else { return trimmed }

        let absolutePath = absoluteWorkingDirectoryPath(trimmed, projectRoot: projectRoot)
        guard !absolutePath.isEmpty else { return trimmed }
        if let relativePath = relativePathIfContained(absolutePath, in: projectRoot) {
            return relativePath
        }
        return absolutePath
    }

    private static func absoluteWorkingDirectoryPath(_ workingDirectory: String, projectRoot: String) -> String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        }

        let rootURL = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        return rootURL
            .appendingPathComponent(expanded, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private static func relativePathIfContained(_ path: String, in projectRoot: String) -> String? {
        let rootComponents = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL
            .pathComponents
        let pathComponents = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .pathComponents

        guard rootComponents.count <= pathComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }

        let relativeComponents = pathComponents.dropFirst(rootComponents.count)
        return relativeComponents.isEmpty ? "" : relativeComponents.joined(separator: "/")
    }
}

struct ProjectCommandEnvironmentExtraction: Equatable {
    let environment: [String: String]
    let commandLine: String

    static func extractLeadingAssignments(from commandLine: String) -> ProjectCommandEnvironmentExtraction? {
        var cursor = commandLine.startIndex
        var environment: [String: String] = [:]
        var lastAssignmentEnd = commandLine.startIndex

        while cursor < commandLine.endIndex {
            while cursor < commandLine.endIndex, commandLine[cursor].isWhitespace {
                cursor = commandLine.index(after: cursor)
            }
            guard cursor < commandLine.endIndex else { break }

            let token = shellToken(from: commandLine, startingAt: &cursor)
            guard let assignment = environmentAssignment(from: token.value) else {
                break
            }

            environment[assignment.name] = assignment.value
            lastAssignmentEnd = token.endIndex
        }

        guard !environment.isEmpty else { return nil }
        let remainingCommand = commandLine[lastAssignmentEnd...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainingCommand.isEmpty else { return nil }

        return ProjectCommandEnvironmentExtraction(
            environment: environment,
            commandLine: remainingCommand
        )
    }

    private static func shellToken(
        from commandLine: String,
        startingAt cursor: inout String.Index
    ) -> (value: String, endIndex: String.Index) {
        var value = ""
        var quote: Character?

        while cursor < commandLine.endIndex {
            let character = commandLine[cursor]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    cursor = commandLine.index(after: cursor)
                    continue
                }
                if activeQuote == "\"", character == "\\" {
                    let nextIndex = commandLine.index(after: cursor)
                    if nextIndex < commandLine.endIndex {
                        value.append(commandLine[nextIndex])
                        cursor = commandLine.index(after: nextIndex)
                        continue
                    }
                }
                value.append(character)
                cursor = commandLine.index(after: cursor)
                continue
            }

            if character.isWhitespace {
                break
            }
            if character == "\"" || character == "'" {
                quote = character
                cursor = commandLine.index(after: cursor)
                continue
            }
            if character == "\\" {
                let nextIndex = commandLine.index(after: cursor)
                if nextIndex < commandLine.endIndex {
                    value.append(commandLine[nextIndex])
                    cursor = commandLine.index(after: nextIndex)
                    continue
                }
            }

            value.append(character)
            cursor = commandLine.index(after: cursor)
        }

        return (value, cursor)
    }

    private static func environmentAssignment(from token: String) -> (name: String, value: String)? {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
            return nil
        }

        let name = String(token[..<separator])
        guard isValidEnvironmentName(name) else { return nil }
        let value = String(token[token.index(after: separator)...])
        return (name, value)
    }

    static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.first,
              first == "_" || first.isLetter
        else {
            return false
        }

        return name.allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }
}

/// Where a project's command, features or appearance are saved: its
/// cherry.toml, or this Mac's settings.
enum ProjectSettingStorage {
    case projectFile
    case local
}

/// Where a project's value comes from (its row's badge in Settings,
/// `SettingSource(_:)`): this Mac's value wins over the project's
/// cherry.toml, which wins over the default.
enum ProjectValueSource: Equatable, Sendable {
    /// Neither sets it: the default.
    case none
    /// Only the project's cherry.toml sets it.
    case projectFile
    /// This Mac's value replaces the one cherry.toml sets.
    case overridesProjectFile
    /// Only this Mac sets it.
    case thisMacOnly

    init(thisMac: Bool, projectFile: Bool) {
        switch (thisMac, projectFile) {
        case (true, true): self = .overridesProjectFile
        case (true, false): self = .thisMacOnly
        case (false, true): self = .projectFile
        case (false, false): self = .none
        }
    }
}

enum ProjectIdentityColor: String, CaseIterable, Codable, Equatable, Identifiable {
    case red
    case orange
    case amber
    case green
    case teal
    case cyan
    case blue
    case indigo
    case violet
    case pink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .amber: "Amber"
        case .green: "Green"
        case .teal: "Teal"
        case .cyan: "Cyan"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .violet: "Violet"
        case .pink: "Pink"
        }
    }

    var hexRGB: String {
        switch self {
        case .red: "#E5484D"
        case .orange: "#F76B15"
        case .amber: "#F5A524"
        case .green: "#30A46C"
        case .teal: "#12A594"
        case .cyan: "#00A2C7"
        case .blue: "#3B82F6"
        case .indigo: "#6366F1"
        case .violet: "#8B5CF6"
        case .pink: "#D946EF"
        }
    }
}

struct ProjectFeatureSettings: Codable, Equatable {
    var todosEnabled: Bool

    static let disabled = ProjectFeatureSettings(todosEnabled: false)
}

struct ProjectAppearanceSettings: Codable, Equatable {
    var color: ProjectIdentityColor?

    static let none = ProjectAppearanceSettings(color: nil)
}

/// A project's local feature settings (`features.byProject`). The ones
/// saved before notes were removed may also name `notesEnabled`: decoding
/// ignores it and the next save drops it, on purpose (the setting went with
/// notes, and only this Mac's Cherry reads these). cherry.toml keeps its
/// `notes = …` line instead (`renderFeatureSection`): teammates' older
/// builds read that file.
struct ProjectFeatureOverrides: Codable, Equatable {
    var todosEnabled: Bool?

    var isEmpty: Bool {
        todosEnabled == nil
    }
}

struct ProjectAppearanceOverrides: Codable, Equatable {
    var color: ProjectIdentityColor?? = nil

    var isEmpty: Bool {
        color == nil
    }

    enum CodingKeys: String, CodingKey {
        case color
    }

    init(color: ProjectIdentityColor?? = nil) {
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.color) {
            let decodedColor = try container.decodeIfPresent(ProjectIdentityColor.self, forKey: .color)
            color = .some(decodedColor)
        } else {
            color = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard let color else { return }
        if let color {
            try container.encode(color, forKey: .color)
        } else {
            try container.encodeNil(forKey: .color)
        }
    }
}

struct ResolvedAgentProject: Equatable {
    let root: String?
    let agents: [AgentToolDefinition]

    var validProjectRoot: String? { root }
    var launchableAgents: [AgentToolDefinition] { agents.filter(\.isLaunchable) }
}

enum AgentConfigurationError: LocalizedError, Equatable {
    case missingName
    case missingCommand(name: String)
    case duplicateName(String)
    /// No agent has the name an edit names (it was removed meanwhile).
    case unknownAgent(String)

    var errorDescription: String? {
        switch self {
        case .missingName:
            "Agent names cannot be empty."
        case .missingCommand(let name):
            "Agent '\(name)' is missing a command."
        case .duplicateName(let name):
            "Duplicate agent name: \(name)."
        case .unknownAgent(let name):
            "There is no agent named '\(name)'."
        }
    }
}

enum ProjectCommandConfigurationError: LocalizedError, Equatable {
    case missingName
    case missingCommand(name: String)
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .missingName:
            "Command names cannot be empty."
        case .missingCommand(let name):
            "Command '\(name)' is missing a command."
        case .duplicateName(let name):
            "Duplicate command name: \(name)."
        }
    }
}

struct CherryProject: Codable, Equatable, Identifiable {
    let root: String

    var id: String { root }

    var name: String {
        URL(fileURLWithPath: root, isDirectory: true).lastPathComponent
    }
}

enum AgentConfiguration {
    static func validated(_ agents: [AgentToolDefinition]) throws -> [AgentToolDefinition] {
        var seenNames = Set<String>()
        return try agents.map { agent in
            var normalized = agent
            normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.command = normalized.command.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.arguments = normalized.arguments.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalized.name.isEmpty else {
                throw AgentConfigurationError.missingName
            }
            guard !normalized.command.isEmpty else {
                throw AgentConfigurationError.missingCommand(name: normalized.name)
            }
            guard seenNames.insert(normalized.normalizedName).inserted else {
                throw AgentConfigurationError.duplicateName(normalized.name)
            }
            return normalized
        }
    }

    static let presets: [AgentToolDefinition] = [
        AgentToolDefinition(name: "Claude", command: "claude", arguments: "--dangerously-skip-permissions"),
        AgentToolDefinition(name: "Codex", command: "codex", arguments: "--yolo"),
        AgentToolDefinition(name: "Pi", command: "pi"),
        AgentToolDefinition(name: "Gemini", command: "gemini"),
        AgentToolDefinition(name: "OpenCode", command: "opencode"),
        AgentToolDefinition(name: "Amp", command: "amp"),
        AgentToolDefinition(name: "Custom", command: "")
    ]
}

enum ProjectCommandConfiguration {
    static func validated(_ commands: [ProjectCommandDefinition]) throws -> [ProjectCommandDefinition] {
        var seenNames = Set<String>()
        return try commands.map { command in
            var normalized = command
            normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.command = normalized.command.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.arguments = normalized.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.workingDirectory = NSString(
                string: normalized.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            ).expandingTildeInPath
            normalized.environment = normalizedEnvironment(normalized.environment)

            guard !normalized.name.isEmpty else {
                throw ProjectCommandConfigurationError.missingName
            }
            guard !normalized.command.isEmpty else {
                throw ProjectCommandConfigurationError.missingCommand(name: normalized.name)
            }
            guard seenNames.insert(normalized.normalizedName).inserted else {
                throw ProjectCommandConfigurationError.duplicateName(normalized.name)
            }
            return normalized
        }
    }

    private static func normalizedEnvironment(_ environment: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawName, value) in environment {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ProjectCommandEnvironmentExtraction.isValidEnvironmentName(name) else { continue }
            normalized[name] = value
        }
        return normalized
    }
}

@MainActor
final class AgentSettings: ObservableObject {
    static let shared = AgentSettings()

    @Published private(set) var projects: [CherryProject] = []
    @Published private(set) var lastOpenedProjectRoot: String?
    @Published private(set) var agents: [AgentToolDefinition] = []
    @Published private(set) var commandsByProject: [String: [ProjectCommandDefinition]] = [:]
    @Published private(set) var featureOverridesByProject: [String: ProjectFeatureOverrides] = [:]
    @Published private(set) var appearanceOverridesByProject: [String: ProjectAppearanceOverrides] = [:]
    /// This Mac's folders the user removed from Projects: the Omni bar
    /// never offers them as "Not added yet" (adding one again forgets it).
    @Published private(set) var removedProjectRoots: Set<String> = []

    private let defaults: UserDefaults
    /// A project's folder as its tabs name it (links resolved, see
    /// `registerProjectFolder`), by the project it belongs to.
    private var projectRootByFolder: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loadedProjects = Self.loadProjects(from: defaults)
        for projectRoot in Self.performanceProjectRoots(environment: ProcessInfo.processInfo.environment)
            where !loadedProjects.contains(where: { $0.root == projectRoot }) {
            loadedProjects.append(CherryProject(root: projectRoot))
        }
        projects = loadedProjects
        lastOpenedProjectRoot = Self.loadLastOpenedProjectRoot(from: defaults)
        agents = Self.loadAgents(from: defaults)
        commandsByProject = Self.loadCommandsByProject(from: defaults)
        featureOverridesByProject = Self.loadOverridesByProject(
            ProjectFeatureOverrides.self,
            forKey: Keys.featureOverridesByProject,
            from: defaults,
            isEmpty: \.isEmpty
        )
        appearanceOverridesByProject = Self.loadOverridesByProject(
            ProjectAppearanceOverrides.self,
            forKey: Keys.appearanceOverridesByProject,
            from: defaults,
            isEmpty: \.isEmpty
        )
        removedProjectRoots = Set(defaults.stringArray(forKey: Keys.removedProjectRoots) ?? [])
    }

    func selectedProject(for root: String?) -> CherryProject? {
        guard let root = repositoryRoot(for: root) else { return nil }
        return projects.first(where: { $0.root == root }) ?? CherryProject(root: root)
    }

    func projectRoot(for requestedRoot: String?) -> String? {
        if let root = Self.validDirectory(requestedRoot ?? "") {
            return root
        }
        if let root = Self.validDirectory(lastOpenedProjectRoot ?? "") {
            return root
        }
        return projects.first?.root
    }

    func resolvedProject(for requestedRoot: String?) -> ResolvedAgentProject {
        let root = Self.validDirectory(requestedRoot ?? "")
        return ResolvedAgentProject(root: root, agents: agents)
    }

    func projectCommands(for requestedRoot: String?) -> [ProjectCommandDefinition] {
        guard let checkoutRoot = Self.validDirectory(requestedRoot ?? "") else { return [] }
        let settingsRoot = projectRootByFolder[checkoutRoot] ?? checkoutRoot
        var commands = CherryProjectFile.loadCommands(projectRoot: checkoutRoot)
        for localCommand in commandsByProject[settingsRoot] ?? [] {
            if let index = commands.firstIndex(where: { $0.normalizedName == localCommand.normalizedName }) {
                commands[index] = localCommand
            } else {
                commands.append(localCommand)
            }
        }
        return commands
    }

    func launchableProjectCommands(for requestedRoot: String?) -> [ProjectCommandDefinition] {
        projectCommands(for: requestedRoot).filter(\.isLaunchable)
    }

    /// Where the effective definition of a command currently lives. Local
    /// definitions shadow cherry.toml ones in `projectCommands(for:)`, so a
    /// name present in both is reported as `.local`.
    func commandStorage(named name: String, for requestedRoot: String?) -> ProjectSettingStorage {
        guard let checkoutRoot = Self.validDirectory(requestedRoot ?? "") else { return .local }
        let settingsRoot = projectRootByFolder[checkoutRoot] ?? checkoutRoot
        let normalizedName = AgentToolDefinition.normalizedName(name)
        if (commandsByProject[settingsRoot] ?? []).contains(where: { $0.normalizedName == normalizedName }) {
            return .local
        }
        if CherryProjectFile.loadCommands(projectRoot: checkoutRoot)
            .contains(where: { $0.normalizedName == normalizedName }) {
            return .projectFile
        }
        return .local
    }

    func projectFeatures(for requestedRoot: String?) -> ProjectFeatureSettings {
        guard let checkoutRoot = Self.validDirectory(requestedRoot ?? "") else {
            return .disabled
        }
        let root = projectRootByFolder[checkoutRoot] ?? checkoutRoot

        let shared = CherryProjectFile.loadFeatureSettings(projectRoot: root) ?? .disabled
        guard let local = featureOverridesByProject[root] else {
            return shared
        }

        return ProjectFeatureSettings(todosEnabled: local.todosEnabled ?? shared.todosEnabled)
    }

    func projectFeatureOverrides(for requestedRoot: String?) -> ProjectFeatureOverrides {
        guard let root = repositoryRoot(for: requestedRoot) else {
            return ProjectFeatureOverrides()
        }
        return featureOverridesByProject[root] ?? ProjectFeatureOverrides()
    }

    func projectAppearance(for requestedRoot: String?) -> ProjectAppearanceSettings {
        guard let root = repositoryRoot(for: requestedRoot) else {
            return .none
        }

        let shared = CherryProjectFile.loadAppearanceSettings(projectRoot: root) ?? .none
        guard let local = appearanceOverridesByProject[root],
              let localColor = local.color
        else {
            return shared
        }

        return ProjectAppearanceSettings(color: localColor)
    }

    func projectAppearanceOverrides(for requestedRoot: String?) -> ProjectAppearanceOverrides {
        guard let root = repositoryRoot(for: requestedRoot) else {
            return ProjectAppearanceOverrides()
        }
        return appearanceOverridesByProject[root] ?? ProjectAppearanceOverrides()
    }

    func projectFileConfiguresFeatures(for requestedRoot: String?) -> Bool {
        guard let root = repositoryRoot(for: requestedRoot) else { return false }
        return CherryProjectFile.loadFeatureSettings(projectRoot: root) != nil
    }

    func projectFileConfiguresAppearance(for requestedRoot: String?) -> Bool {
        guard let root = repositoryRoot(for: requestedRoot) else { return false }
        return CherryProjectFile.loadAppearanceSettings(projectRoot: root) != nil
    }

    func setProjectFeatures(_ features: ProjectFeatureSettings, for requestedRoot: String, storage: ProjectSettingStorage) throws {
        guard let root = repositoryRoot(for: requestedRoot) else { return }
        switch storage {
        case .local:
            var overrides = featureOverridesByProject[root] ?? ProjectFeatureOverrides()
            overrides.todosEnabled = features.todosEnabled
            try setFeatureOverrides(overrides, for: root)
        case .projectFile:
            try CherryProjectFile.writeFeatureSettings(features, projectRoot: root)
        }
    }

    func setProjectAppearance(_ appearance: ProjectAppearanceSettings, for requestedRoot: String, storage: ProjectSettingStorage) throws {
        guard let root = repositoryRoot(for: requestedRoot) else { return }
        switch storage {
        case .local:
            try setAppearanceOverrides(ProjectAppearanceOverrides(color: appearance.color), for: root)
        case .projectFile:
            try CherryProjectFile.writeAppearanceSettings(appearance, projectRoot: root)
        }
    }

    func clearLocalProjectFeatureOverrides(for requestedRoot: String) {
        guard let root = repositoryRoot(for: requestedRoot) else { return }
        featureOverridesByProject.removeValue(forKey: root)
        saveFeatureOverrides()
    }

    func clearLocalProjectAppearanceOverrides(for requestedRoot: String) {
        guard let root = repositoryRoot(for: requestedRoot) else { return }
        appearanceOverridesByProject.removeValue(forKey: root)
        saveAppearanceOverrides()
    }

    /// Where a project's Todos value comes from: this Mac's override, its
    /// cherry.toml's `[features]` (which sets it, off without a `todos`
    /// line), both or neither.
    func todosSource(for root: String) -> ProjectValueSource {
        ProjectValueSource(
            thisMac: projectFeatureOverrides(for: root).todosEnabled != nil,
            projectFile: projectFileConfiguresFeatures(for: root)
        )
    }

    /// Where a project's color comes from: this Mac's override (an explicit
    /// None is one), its cherry.toml's `[appearance]`, both or neither.
    func colorSource(for root: String) -> ProjectValueSource {
        ProjectValueSource(
            thisMac: !projectAppearanceOverrides(for: root).isEmpty,
            projectFile: projectFileConfiguresAppearance(for: root)
        )
    }

    /// Drops this Mac's Todos and Color overrides of a project, so its
    /// cherry.toml (else the default) applies again. Its commands keep
    /// theirs (`removeLocalCommand`), and cherry.toml is left alone.
    func revertProjectToProjectFile(_ root: String) {
        clearLocalProjectFeatureOverrides(for: root)
        clearLocalProjectAppearanceOverrides(for: root)
    }

    @discardableResult
    func addProject(path: String) -> CherryProject? {
        guard let root = Self.validDirectory(path) else { return nil }
        let project = CherryProject(root: root)
        if !projects.contains(where: { $0.root == root }) {
            projects.append(project)
            saveProjects()
        }
        if removedProjectRoots.remove(root) != nil { saveRemovedProjectRoots() }
        return project
    }

    func removeProject(_ project: CherryProject) {
        if !ProjectLocation.isRemoteKey(project.root), removedProjectRoots.insert(project.root).inserted {
            saveRemovedProjectRoots()
        }
        projects.removeAll { $0.root == project.root }
        commandsByProject.removeValue(forKey: project.root)
        featureOverridesByProject.removeValue(forKey: project.root)
        appearanceOverridesByProject.removeValue(forKey: project.root)
        if lastOpenedProjectRoot == project.root {
            lastOpenedProjectRoot = projects.first?.root
            saveLastOpenedProjectRoot()
        }
        saveProjects()
        saveCommands()
        saveFeatureOverrides()
        saveAppearanceOverrides()
    }

    /// Forgets that the user removed `root` from Projects (Offer Again): the
    /// Omni bar offers the folder as "Not added yet" again. It does not add
    /// it.
    func forgetRemovedProjectRoot(_ root: String) {
        guard removedProjectRoots.remove(root) != nil else { return }
        saveRemovedProjectRoots()
    }

    func markProjectOpened(_ projectRoot: String?) {
        guard let root = Self.validDirectory(projectRoot ?? "") else { return }
        // A new window opens This Mac's last project, never another Mac's
        // (docs/specs/remote-devices.md).
        guard !ProjectLocation.isRemoteKey(root) else { return }
        guard lastOpenedProjectRoot != root else { return }
        lastOpenedProjectRoot = root
        saveLastOpenedProjectRoot()
    }

    /// Gives `folder` (a project's folder as its tabs name it: its links
    /// resolved) the settings of the project at `projectRoot`.
    func registerProjectFolder(_ folder: String, projectRoot: String) {
        guard let canonicalRoot = Self.validDirectory(projectRoot) else { return }
        if let root = Self.validDirectory(folder) {
            projectRootByFolder[root] = canonicalRoot
        }
        projectRootByFolder[canonicalRoot] = canonicalRoot
    }

    /// The project whose settings `requestedRoot` uses: the project it is
    /// the folder of (`registerProjectFolder`), else itself.
    func repositoryRoot(for requestedRoot: String?) -> String? {
        guard let root = Self.validDirectory(requestedRoot ?? "") else { return nil }
        return projectRootByFolder[root] ?? root
    }

    func upsertAgent(_ agent: AgentToolDefinition, replacing originalName: String? = nil) throws {
        let validatedAgent = try AgentConfiguration.validated([agent]).first!
        var nextAgents = agents
        if let originalName {
            nextAgents.removeAll { $0.normalizedName == AgentToolDefinition.normalizedName(originalName) }
        }
        nextAgents.removeAll { $0.normalizedName == validatedAgent.normalizedName }
        nextAgents.append(validatedAgent)
        try setAgents(nextAgents)
    }

    func removeAgent(named name: String) {
        let normalizedName = AgentToolDefinition.normalizedName(name)
        let nextAgents = agents.filter { $0.normalizedName != normalizedName }
        try? setAgents(nextAgents)
    }

    /// `name`, trimmed, when no agent has it (names are compared without
    /// case), else the first of "<name> 2", "<name> 3"… that none has. A
    /// taken name that ends in a number counts on from it: "Claude 2" gives
    /// "Claude 3", not "Claude 2 2".
    func availableAgentName(for name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(agents.map(\.normalizedName))
        guard taken.contains(AgentToolDefinition.normalizedName(name)) else { return name }
        var base = name
        var number = 2
        if let space = name.lastIndex(of: " "),
           case let digits = name[name.index(after: space)...],
           digits.allSatisfy({ $0.isASCII && $0.isNumber }),
           let last = Int(digits), last > 0,
           !name[..<space].trimmingCharacters(in: .whitespaces).isEmpty {
            base = String(name[..<space])
            number = last + 1
        }
        while taken.contains(AgentToolDefinition.normalizedName("\(base) \(number)")) {
            number += 1
        }
        return "\(base) \(number)"
    }

    /// Adds `agent` after the others under a name no agent has
    /// (`availableAgentName`): unlike `upsertAgent`, it never replaces
    /// one. Returns the agent as stored.
    @discardableResult
    func addAgent(_ agent: AgentToolDefinition) throws -> AgentToolDefinition {
        var added = agent
        added.name = availableAgentName(for: agent.name)
        try setAgents(agents + [added])
        return agents[agents.count - 1]
    }

    /// Replaces the agent named `name` with `agent` where it is, so the
    /// Agents menu, the sidebar and MCP's list keep their order
    /// (`upsertAgent` moves it to the end). `agent` may rename it, but not
    /// to another agent's name (`duplicateName`).
    func updateAgent(named name: String, with agent: AgentToolDefinition) throws {
        let index = try agentIndex(named: name)
        var nextAgents = agents
        nextAgents[index] = agent
        try setAgents(nextAgents)
    }

    /// Adds a copy of the agent named `name` right after it, under a name
    /// no agent has ("Claude 2"). Returns the copy as stored.
    @discardableResult
    func duplicateAgent(named name: String) throws -> AgentToolDefinition {
        let index = try agentIndex(named: name)
        var copy = agents[index]
        copy.name = availableAgentName(for: copy.name)
        var nextAgents = agents
        nextAgents.insert(copy, at: index + 1)
        try setAgents(nextAgents)
        return agents[index + 1]
    }

    private func agentIndex(named name: String) throws -> Int {
        let normalizedName = AgentToolDefinition.normalizedName(name)
        guard let index = agents.firstIndex(where: { $0.normalizedName == normalizedName }) else {
            throw AgentConfigurationError.unknownAgent(name)
        }
        return index
    }

    func upsertCommand(
        _ command: ProjectCommandDefinition,
        for requestedRoot: String,
        replacing originalName: String? = nil,
        storage: ProjectSettingStorage = .local
    ) throws {
        guard let checkoutRoot = Self.validDirectory(requestedRoot) else { return }
        let settingsRoot = projectRootByFolder[checkoutRoot] ?? checkoutRoot
        let validatedCommand = try ProjectCommandConfiguration.validated([
            command.withPortableWorkingDirectory(projectRoot: ProjectLocation.launchPath(forKey: checkoutRoot))
        ]).first!
        switch storage {
        case .local:
            var nextCommands = commandsByProject[settingsRoot] ?? []
            if let originalName {
                nextCommands.removeAll { $0.normalizedName == AgentToolDefinition.normalizedName(originalName) }
            }
            nextCommands.removeAll { $0.normalizedName == validatedCommand.normalizedName }
            nextCommands.append(validatedCommand)
            try setCommands(nextCommands, for: settingsRoot)
        case .projectFile:
            try CherryProjectFile.upsertCommand(validatedCommand, projectRoot: checkoutRoot, replacing: originalName)
            // Drop any local definition with the same name: local commands
            // shadow cherry.toml ones, so leaving a stale copy behind would
            // make the just-saved shared definition invisible on this machine.
            var nextCommands = commandsByProject[settingsRoot] ?? []
            let normalizedOriginalName = originalName.map(AgentToolDefinition.normalizedName)
            let previousCount = nextCommands.count
            nextCommands.removeAll {
                $0.normalizedName == validatedCommand.normalizedName
                    || $0.normalizedName == normalizedOriginalName
            }
            if nextCommands.count != previousCount {
                try setCommands(nextCommands, for: settingsRoot)
            }
        }
    }

    func removeCommand(named name: String, for requestedRoot: String) {
        guard let checkoutRoot = Self.validDirectory(requestedRoot) else { return }
        let settingsRoot = projectRootByFolder[checkoutRoot] ?? checkoutRoot
        let normalizedName = AgentToolDefinition.normalizedName(name)
        let nextCommands = (commandsByProject[settingsRoot] ?? []).filter { $0.normalizedName != normalizedName }
        try? setCommands(nextCommands, for: settingsRoot)
        try? CherryProjectFile.removeCommand(named: name, projectRoot: checkoutRoot)
    }

    /// Where the command named `name` comes from: this Mac's copy replaces
    /// cherry.toml's of the same name (`projectCommands(for:)`).
    func commandSource(named name: String, for root: String) -> ProjectValueSource {
        guard let checkoutRoot = Self.validDirectory(root) else { return .none }
        let settingsRoot = projectRootByFolder[checkoutRoot] ?? checkoutRoot
        let normalizedName = AgentToolDefinition.normalizedName(name)
        return ProjectValueSource(
            thisMac: (commandsByProject[settingsRoot] ?? []).contains { $0.normalizedName == normalizedName },
            projectFile: CherryProjectFile.loadCommands(projectRoot: checkoutRoot)
                .contains { $0.normalizedName == normalizedName }
        )
    }

    /// Removes this Mac's copy of the command named `name`, so cherry.toml's
    /// applies again, if it has one. Unlike `removeCommand`, it leaves
    /// cherry.toml alone.
    func removeLocalCommand(named name: String, for root: String) {
        guard let checkoutRoot = Self.validDirectory(root) else { return }
        let settingsRoot = projectRootByFolder[checkoutRoot] ?? checkoutRoot
        let normalizedName = AgentToolDefinition.normalizedName(name)
        let localCommands = commandsByProject[settingsRoot] ?? []
        guard localCommands.contains(where: { $0.normalizedName == normalizedName }) else { return }
        try? setCommands(localCommands.filter { $0.normalizedName != normalizedName }, for: settingsRoot)
    }

    private func setAgents(_ agents: [AgentToolDefinition]) throws {
        self.agents = try AgentConfiguration.validated(agents)
        saveAgents()
    }

    private func setCommands(_ commands: [ProjectCommandDefinition], for root: String) throws {
        let validatedCommands = try ProjectCommandConfiguration.validated(commands)
        if validatedCommands.isEmpty {
            commandsByProject.removeValue(forKey: root)
        } else {
            commandsByProject[root] = validatedCommands
        }
        saveCommands()
    }

    private func setFeatureOverrides(_ overrides: ProjectFeatureOverrides, for root: String) throws {
        if overrides.isEmpty {
            featureOverridesByProject.removeValue(forKey: root)
        } else {
            featureOverridesByProject[root] = overrides
        }
        saveFeatureOverrides()
    }

    private func setAppearanceOverrides(_ overrides: ProjectAppearanceOverrides, for root: String) throws {
        if overrides.isEmpty {
            appearanceOverridesByProject.removeValue(forKey: root)
        } else {
            appearanceOverridesByProject[root] = overrides
        }
        saveAppearanceOverrides()
    }

    private func saveProjects() {
        defaults.setJSON(projects, forKey: Keys.projects)
    }

    private func saveRemovedProjectRoots() {
        defaults.set(removedProjectRoots.sorted(), forKey: Keys.removedProjectRoots)
    }

    private func saveLastOpenedProjectRoot() {
        if let lastOpenedProjectRoot {
            defaults.set(lastOpenedProjectRoot, forKey: Keys.lastOpenedProjectRoot)
        } else {
            defaults.removeObject(forKey: Keys.lastOpenedProjectRoot)
        }
        defaults.synchronize()
    }

    private func saveAgents() {
        defaults.setJSON(agents, forKey: Keys.agents)
    }

    private func saveCommands() {
        defaults.setJSON(commandsByProject, forKey: Keys.commandsByProject)
    }

    private func saveFeatureOverrides() {
        defaults.setJSON(featureOverridesByProject, forKey: Keys.featureOverridesByProject)
    }

    private func saveAppearanceOverrides() {
        defaults.setJSON(appearanceOverridesByProject, forKey: Keys.appearanceOverridesByProject)
    }

    private static func loadProjects(from defaults: UserDefaults) -> [CherryProject] {
        let projects = defaults.decodedJSON([CherryProject].self, forKey: Keys.projects) ?? []
        return projects.filter { validDirectory($0.root) != nil }
    }

    private static func loadLastOpenedProjectRoot(from defaults: UserDefaults) -> String? {
        validDirectory(defaults.string(forKey: Keys.lastOpenedProjectRoot) ?? "")
    }

    private static func loadAgents(from defaults: UserDefaults) -> [AgentToolDefinition] {
        guard let decoded = defaults.decodedJSON([AgentToolDefinition].self, forKey: Keys.agents),
              let validated = try? AgentConfiguration.validated(decoded)
        else {
            return []
        }
        return validated
    }

    private static func loadCommandsByProject(from defaults: UserDefaults) -> [String: [ProjectCommandDefinition]] {
        guard let decoded = defaults.decodedJSON([String: [ProjectCommandDefinition]].self, forKey: Keys.commandsByProject) else {
            return [:]
        }

        var commandsByProject: [String: [ProjectCommandDefinition]] = [:]
        for (root, commands) in decoded {
            guard let validRoot = validDirectory(root),
                  let validatedCommands = try? ProjectCommandConfiguration.validated(commands),
                  !validatedCommands.isEmpty
            else {
                continue
            }
            commandsByProject[validRoot] = validatedCommands
        }
        return commandsByProject
    }

    /// The feature or appearance overrides saved under `key`, by project,
    /// leaving out empty ones and projects whose folder is gone.
    private static func loadOverridesByProject<Overrides: Decodable>(
        _: Overrides.Type,
        forKey key: String,
        from defaults: UserDefaults,
        isEmpty: (Overrides) -> Bool
    ) -> [String: Overrides] {
        guard let decoded = defaults.decodedJSON([String: Overrides].self, forKey: key) else {
            return [:]
        }

        var overridesByProject: [String: Overrides] = [:]
        for (root, overrides) in decoded {
            guard let validRoot = validDirectory(root), !isEmpty(overrides) else {
                continue
            }
            overridesByProject[validRoot] = overrides
        }
        return overridesByProject
    }

    static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return NSString(string: trimmed).expandingTildeInPath
    }

    static func performanceProjectRoots(environment: [String: String]) -> [String] {
        guard environment["CHERRY_TERMINAL_PERF"] == "1",
              let rawValue = environment["CHERRY_PERF_PROJECT_ROOTS"]
        else {
            return []
        }

        var seen = Set<String>()
        return rawValue
            .split { character in
                character == ":" || character == "\n"
            }
            .compactMap { validDirectory(String($0)) }
            .filter { seen.insert($0).inserted }
    }

    // Called from SwiftUI body evaluation on every render pass, so repeated
    // filesystem stats add up. Only valid results are cached (with a short
    // lifetime): a directory that exists rarely disappears, while caching a
    // miss would delay noticing a freshly created project root.
    private static var validDirectoryCache: [String: (expires: TimeInterval, root: String)] = [:]
    private static let validDirectoryCacheLifetime: TimeInterval = 5

    /// The canonical root for `path`: an existing local directory,
    /// standardised, or a project on another Mac by its key
    /// (`ProjectLocation`), which is never looked for on this Mac's disk.
    static func validDirectory(_ path: String) -> String? {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return nil }
        let location = ProjectLocation(key: normalized)
        if location.isRemote { return location.key }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = validDirectoryCache[normalized], now < cached.expires {
            return cached.root
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            validDirectoryCache[normalized] = nil
            return nil
        }
        let root = URL(fileURLWithPath: normalized, isDirectory: true).standardizedFileURL.path
        validDirectoryCache[normalized] = (now + validDirectoryCacheLifetime, root)
        return root
    }

    private enum Keys {
        static let projects = "projects.items"
        static let removedProjectRoots = "projects.removedRoots"
        static let lastOpenedProjectRoot = "projects.lastOpenedRoot"
        static let agents = "agents.global"
        static let commandsByProject = "commands.byProject"
        static let featureOverridesByProject = "features.byProject"
        static let appearanceOverridesByProject = "appearance.byProject"
    }
}

private extension UserDefaults {
    /// The value saved under `key` as JSON, or nil when there is none or it
    /// does not decode.
    func decodedJSON<Value: Decodable>(_: Value.Type, forKey key: String) -> Value? {
        guard let encoded = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: encoded)
    }

    /// Saves `value` under `key` as JSON (nothing when it does not encode).
    func setJSON<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let encoded = try? JSONEncoder().encode(value) else { return }
        set(encoded, forKey: key)
    }
}

enum CherryProjectFile {
    private static let fileName = "cherry.toml"
    private static let beginMarker = "# BEGIN CHERRY COMMANDS"
    private static let endMarker = "# END CHERRY COMMANDS"

    static func fileURL(projectRoot: String) -> URL {
        // Said to be a file: inferring it would `lstat` the path, on every
        // body evaluation that reads the project's settings.
        URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(fileName, isDirectory: false)
    }

    @MainActor
    static func exists(projectRoot: String) -> Bool {
        guard !ProjectLocation.isRemoteKey(projectRoot) else {
            return RemoteProjectFiles.shared.text(for: projectRoot) != nil
        }
        return FileManager.default.fileExists(atPath: fileURL(projectRoot: projectRoot).path)
    }

    /// A project on another Mac (a `ProjectLocation` key) has its
    /// cherry.toml there: Cherry reads it through that Mac's
    /// `cherry-host project-info` (`RemoteProjectFiles`) and never writes it
    /// (docs/specs/remote-devices.md, phase 3). Its commands can be
    /// overridden or added on this Mac only.
    struct RemoteProjectFileError: LocalizedError {
        var errorDescription: String? {
            "cherry.toml of a project on another Mac is read-only in Cherry: edit it on that Mac, or save the command on this Mac only."
        }
    }

    /// The note the command editor shows for a device's project instead of
    /// offering to save to its cherry.toml.
    static let remoteReadOnlyNote = "This project's cherry.toml is on the other Mac and read-only here: edit it there. Commands you save here are kept on this Mac only."

    private static func requireLocal(_ projectRoot: String) throws {
        if ProjectLocation.isRemoteKey(projectRoot) { throw RemoteProjectFileError() }
    }

    // The load accessors run inside SwiftUI body evaluation on every render
    // pass; re-reading and re-parsing the file each time is main-thread disk
    // I/O. Parses are cached per project root and revalidated with a single
    // stat — modification date + size — so external edits are still noticed.
    private struct ParsedFile {
        var modificationDate: Date?
        var fileSize: UInt64?
        var commands: [ProjectCommandDefinition] = []
        var features: ProjectFeatureSettings?
        var appearance: ProjectAppearanceSettings?
    }

    @MainActor
    private static var parseCache: [String: ParsedFile] = [:]

    /// Forgets the parse of a project's cherry.toml: after a write, or when a
    /// device project's cherry.toml changed (`RemoteProjectFiles`).
    @MainActor
    static func invalidate(projectRoot: String) {
        parseCache[projectRoot] = nil
    }

    @MainActor
    private static func parsed(projectRoot: String) -> ParsedFile {
        if ProjectLocation.isRemoteKey(projectRoot) {
            let key = ProjectLocation(key: projectRoot).key
            if let cached = parseCache[key] { return cached }
            let parsed = RemoteProjectFiles.shared.text(for: key).map { parse(contents: $0) } ?? ParsedFile()
            parseCache[key] = parsed
            return parsed
        }
        let url = fileURL(projectRoot: projectRoot)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value
        if let cached = parseCache[projectRoot],
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize
        {
            return cached
        }

        var parsed = ParsedFile()
        if let contents = try? String(contentsOf: url, encoding: .utf8) {
            parsed = parse(contents: contents)
        }
        parsed.modificationDate = modificationDate
        parsed.fileSize = fileSize
        parseCache[projectRoot] = parsed
        return parsed
    }

    /// A cherry.toml's commands, features and appearance.
    private static func parse(contents: String) -> ParsedFile {
        var parsed = ParsedFile()
        let commandSource = managedSection(in: contents) ?? contents
        parsed.commands = (try? ProjectCommandConfiguration.validated(parseCommands(from: commandSource))) ?? []
        if let featureSource = tableSection(named: "features", in: contents) {
            let fields = parseKeyValues(from: featureSource)
            parsed.features = ProjectFeatureSettings(todosEnabled: boolValue(fields["todos"]) ?? false)
        }
        if let appearanceSource = tableSection(named: "appearance", in: contents) {
            let fields = parseKeyValues(from: appearanceSource)
            parsed.appearance = ProjectAppearanceSettings(
                color: fields["color"].flatMap(ProjectIdentityColor.init(rawValue:))
            )
        }
        return parsed
    }

    @MainActor
    static func loadCommands(projectRoot: String) -> [ProjectCommandDefinition] {
        parsed(projectRoot: projectRoot).commands
    }

    @MainActor
    static func loadFeatureSettings(projectRoot: String) -> ProjectFeatureSettings? {
        parsed(projectRoot: projectRoot).features
    }

    @MainActor
    static func loadAppearanceSettings(projectRoot: String) -> ProjectAppearanceSettings? {
        parsed(projectRoot: projectRoot).appearance
    }

    @MainActor
    static func writeFeatureSettings(_ features: ProjectFeatureSettings, projectRoot: String) throws {
        try writeTableSection(named: "features", projectRoot: projectRoot) { existing in
            renderFeatureSection(features, replacing: existing)
        }
    }

    @MainActor
    static func writeAppearanceSettings(_ appearance: ProjectAppearanceSettings, projectRoot: String) throws {
        try writeTableSection(named: "appearance", projectRoot: projectRoot) { _ in
            renderAppearanceSection(appearance)
        }
    }

    /// Replaces the `[table]` section of the project's cherry.toml with the
    /// section `render` makes of the current one (nil when there is none),
    /// or appends it.
    @MainActor
    private static func writeTableSection(
        named table: String,
        projectRoot: String,
        _ render: (_ existing: String?) -> String
    ) throws {
        try requireLocal(projectRoot)
        defer { invalidate(projectRoot: projectRoot) }
        let url = fileURL(projectRoot: projectRoot)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let section = render(tableSection(named: table, in: existing))
        let nextContents: String

        if let range = tableSectionRange(named: table, in: existing) {
            let replacement = range.upperBound == existing.endIndex ? section : section + "\n"
            nextContents = existing.replacingCharacters(in: range, with: replacement)
        } else if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextContents = section
        } else {
            nextContents = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + section
        }

        try nextContents.trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    static func upsertCommand(
        _ command: ProjectCommandDefinition,
        projectRoot: String,
        replacing originalName: String? = nil
    ) throws {
        var commands = loadCommands(projectRoot: projectRoot)
        if let originalName {
            commands.removeAll { $0.normalizedName == AgentToolDefinition.normalizedName(originalName) }
        }
        commands.removeAll { $0.normalizedName == command.normalizedName }
        commands.append(command)
        try writeCommands(commands, projectRoot: projectRoot)
    }

    @MainActor
    static func removeCommand(named name: String, projectRoot: String) throws {
        let normalizedName = AgentToolDefinition.normalizedName(name)
        let commands = loadCommands(projectRoot: projectRoot).filter { $0.normalizedName != normalizedName }
        try writeCommands(commands, projectRoot: projectRoot)
    }

    @MainActor
    private static func writeCommands(_ commands: [ProjectCommandDefinition], projectRoot: String) throws {
        try requireLocal(projectRoot)
        defer { invalidate(projectRoot: projectRoot) }
        let url = fileURL(projectRoot: projectRoot)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let nextSection = commands.isEmpty ? "" : renderManagedSection(commands)
        let nextContents: String

        if let range = managedSectionRange(in: existing) {
            nextContents = existing.replacingCharacters(in: range, with: nextSection).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextContents = nextSection
        } else {
            nextContents = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + nextSection
        }

        try nextContents.appending(nextContents.isEmpty ? "" : "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func renderManagedSection(_ commands: [ProjectCommandDefinition]) -> String {
        var lines: [String] = [beginMarker]
        for command in commands {
            lines.append("[[commands]]")
            lines.append("name = \(tomlString(command.name))")
            lines.append("command = \(tomlString(command.command))")
            if !command.arguments.isEmpty {
                lines.append("arguments = \(tomlString(command.arguments))")
            }
            if !command.workingDirectory.isEmpty {
                lines.append("workingDirectory = \(tomlString(command.workingDirectory))")
            }
            for name in command.environment.keys.sorted() {
                guard let value = command.environment[name] else { continue }
                lines.append("environment.\(tomlString(name)) = \(tomlString(value))")
            }
            lines.append("autoStart = \(command.autoStart ? "true" : "false")")
            lines.append("autoRestart = \(command.autoRestart ? "true" : "false")")
            lines.append("enabled = \(command.enabled ? "true" : "false")")
            lines.append("")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// The `[features]` section with `todos` set. An existing section keeps
    /// its other lines: a `notes = …` that builds from before notes were
    /// removed still read stays as it is for teammates on those builds.
    private static func renderFeatureSection(_ features: ProjectFeatureSettings, replacing existing: String?) -> String {
        let todosLine = "todos = \(features.todosEnabled ? "true" : "false")"
        guard let existing else {
            return ["[features]", todosLine].joined(separator: "\n")
        }
        var lines = existing.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        var replaced = false
        lines = lines.compactMap { line -> String? in
            guard parseKeyValues(from: line).keys.contains("todos") else { return line }
            defer { replaced = true }
            return replaced ? nil : todosLine
        }
        if !replaced {
            lines.append(todosLine)
        }
        return lines.joined(separator: "\n")
    }

    private static func renderAppearanceSection(_ appearance: ProjectAppearanceSettings) -> String {
        [
            "[appearance]",
            "color = \(tomlString(appearance.color?.rawValue ?? "none"))"
        ].joined(separator: "\n")
    }

    private static func parseCommands(from source: String) -> [ProjectCommandDefinition] {
        var commands: [ProjectCommandDefinition] = []
        var fields: [String: String] = [:]
        var environment: [String: String] = [:]

        func flushCommand() {
            guard !fields.isEmpty else { return }
            commands.append(ProjectCommandDefinition(
                name: fields["name"] ?? "",
                command: fields["command"] ?? "",
                arguments: fields["arguments"] ?? "",
                workingDirectory: fields["workingDirectory"] ?? "",
                environment: environment,
                autoStart: boolValue(fields["autoStart"]) ?? false,
                autoRestart: boolValue(fields["autoRestart"]) ?? false,
                enabled: boolValue(fields["enabled"]) ?? true
            ))
            fields.removeAll()
            environment.removeAll()
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line == "[[commands]]" {
                flushCommand()
                continue
            }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let environmentName = environmentName(fromTomlKey: key) {
                environment[environmentName] = tomlValue(value)
            } else {
                fields[key] = tomlValue(value)
            }
        }
        flushCommand()
        return commands
    }

    private static func environmentName(fromTomlKey key: String) -> String? {
        let prefix = "environment."
        guard key.hasPrefix(prefix) else { return nil }
        let rawName = String(key.dropFirst(prefix.count))
        let name = tomlValue(rawName)
        guard ProjectCommandEnvironmentExtraction.isValidEnvironmentName(name) else { return nil }
        return name
    }

    private static func managedSection(in contents: String) -> String? {
        guard let range = managedSectionRange(in: contents) else { return nil }
        return String(contents[range])
    }

    private static func managedSectionRange(in contents: String) -> Range<String.Index>? {
        guard let begin = contents.range(of: beginMarker),
              let end = contents.range(of: endMarker, range: begin.upperBound..<contents.endIndex)
        else {
            return nil
        }
        return begin.lowerBound..<end.upperBound
    }

    private static func tableSection(named tableName: String, in contents: String) -> String? {
        guard let range = tableSectionRange(named: tableName, in: contents) else {
            return nil
        }
        return String(contents[range])
    }

    private static func tableSectionRange(named tableName: String, in contents: String) -> Range<String.Index>? {
        let header = "[\(tableName)]"
        guard let headerRange = contents.range(of: header) else {
            return nil
        }

        var end = contents.endIndex
        var searchStart = headerRange.upperBound
        while let newlineRange = contents.range(of: "\n", range: searchStart..<contents.endIndex) {
            let lineStart = newlineRange.upperBound
            let nextNewline = contents.range(of: "\n", range: lineStart..<contents.endIndex)?.lowerBound ?? contents.endIndex
            let line = contents[lineStart..<nextNewline].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") || line == beginMarker {
                end = lineStart
                break
            }
            searchStart = nextNewline
            if searchStart == contents.endIndex {
                break
            }
        }

        return headerRange.lowerBound..<end
    }

    private static func parseKeyValues(from source: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("[") else { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = tomlValue(value)
        }
        return fields
    }

    private static func tomlString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\(value)\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func tomlValue(_ rawValue: String) -> String {
        if rawValue.hasPrefix("\""),
           let data = rawValue.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return rawValue
    }

    private static func boolValue(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "true":
            true
        case "false":
            false
        default:
            nil
        }
    }
}
