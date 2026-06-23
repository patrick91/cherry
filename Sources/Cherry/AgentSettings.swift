import Foundation

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

enum ProjectCommandStorage: String, CaseIterable, Identifiable {
    case projectFile
    case local

    var id: String { rawValue }
}

enum ProjectFeatureStorage: String, CaseIterable, Identifiable {
    case projectFile
    case local

    var id: String { rawValue }
}

enum ProjectAppearanceStorage: String, CaseIterable, Identifiable {
    case projectFile
    case local

    var id: String { rawValue }
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
    var notesEnabled: Bool
    var todosEnabled: Bool

    static let disabled = ProjectFeatureSettings(notesEnabled: false, todosEnabled: false)
}

struct ProjectAppearanceSettings: Codable, Equatable {
    var color: ProjectIdentityColor?

    static let none = ProjectAppearanceSettings(color: nil)
}

struct ProjectFeatureOverrides: Codable, Equatable {
    var notesEnabled: Bool?
    var todosEnabled: Bool?

    var isEmpty: Bool {
        notesEnabled == nil && todosEnabled == nil
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

enum AgentToolSource: Equatable {
    case global
}

enum AgentSummaryTool: String, CaseIterable, Identifiable {
    case codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .codex:
            "Codex MCP"
        }
    }

    var defaultModel: String {
        switch self {
        case .codex:
            "gpt-5.3-codex-spark"
        }
    }

    var modelOptions: [String] {
        switch self {
        case .codex:
            [
                "gpt-5.3-codex-spark",
                "gpt-5.4-mini",
                "gpt-5.3-codex",
                "gpt-5.4",
                "gpt-5.5",
                "gpt-5.2"
            ]
        }
    }

    var modelFlagDescription: String {
        switch self {
        case .codex:
            "Passed to the Codex MCP tool via -m"
        }
    }

    func command(model: String) -> String {
        let modelValue = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelValue.isEmpty ? defaultModel : modelValue

        switch self {
        case .codex:
            let modelArgument = trimmedModel.isEmpty ? "" : " -m \(Self.shellQuoted(trimmedModel))"
            return "codex mcp-server -> codex tool\(modelArgument) -c model_reasoning_effort=low"
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.=/:")
        guard value.rangeOfCharacter(from: safeCharacters.inverted) != nil else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum AgentSummaryCadence: Int, CaseIterable, Identifiable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fifteenSeconds:
            "15 sec"
        case .thirtySeconds:
            "30 sec"
        case .oneMinute:
            "1 min"
        }
    }

    var interval: TimeInterval {
        TimeInterval(rawValue)
    }
}

struct ResolvedAgentTool: Equatable, Identifiable {
    let definition: AgentToolDefinition
    let source: AgentToolSource

    var id: String { definition.id }
    var name: String { definition.name }
    var commandLine: String { definition.commandLine }
    var enabled: Bool { definition.enabled }
    var isLaunchable: Bool {
        definition.enabled && !definition.commandLine.isEmpty
    }
}

struct ResolvedAgentProject: Equatable {
    let root: String?
    let agents: [ResolvedAgentTool]

    var validProjectRoot: String? { root }
    var launchableAgents: [ResolvedAgentTool] { agents.filter(\.isLaunchable) }
}

enum AgentConfigurationError: LocalizedError, Equatable {
    case missingName
    case missingCommand(name: String)
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .missingName:
            "Agent names cannot be empty."
        case .missingCommand(let name):
            "Agent '\(name)' is missing a command."
        case .duplicateName(let name):
            "Duplicate agent name: \(name)."
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
    @Published var agentSummaryTool: AgentSummaryTool {
        didSet {
            let currentModel = agentSummaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentModel.isEmpty || currentModel == oldValue.defaultModel {
                agentSummaryModel = agentSummaryTool.defaultModel
            }
            saveSummarySettings()
        }
    }
    @Published var agentSummaryCadence: AgentSummaryCadence {
        didSet {
            saveSummarySettings()
        }
    }
    @Published var agentSummaryModel: String {
        didSet {
            saveSummarySettings()
        }
    }
    @Published var agentSummaryCommand: String {
        didSet {
            saveSummarySettings()
        }
    }
    @Published var useAgentSummaryAsTitle: Bool {
        didSet {
            saveSummarySettings()
        }
    }

    private let defaults: UserDefaults

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
        featureOverridesByProject = Self.loadFeatureOverridesByProject(from: defaults)
        appearanceOverridesByProject = Self.loadAppearanceOverridesByProject(from: defaults)
        let storedSummaryCommand = defaults.string(forKey: Keys.agentSummaryCommand) ?? ""
        let storedSummaryTool = Self.loadAgentSummaryTool(from: defaults, command: storedSummaryCommand)
        agentSummaryCommand = storedSummaryCommand
        agentSummaryTool = storedSummaryTool
        agentSummaryCadence = Self.loadAgentSummaryCadence(from: defaults)
        agentSummaryModel = Self.loadAgentSummaryModel(from: defaults, tool: storedSummaryTool)
        useAgentSummaryAsTitle = defaults.bool(forKey: Keys.useAgentSummaryAsTitle)
    }

    var resolvedAgents: [ResolvedAgentTool] {
        agents.map { ResolvedAgentTool(definition: $0, source: .global) }
    }

    var effectiveAgentSummaryCommand: String {
        AgentSummaryTool.codex.command(model: agentSummaryModel)
    }

    func selectedProject(for root: String?) -> CherryProject? {
        guard let root = Self.validDirectory(root ?? "") else { return nil }
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

    func projectRootForWindow(
        requestedRoot: String?,
        onboardedRoot: String?
    ) -> String? {
        if let root = Self.validDirectory(onboardedRoot ?? "") {
            return root
        }
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
        return ResolvedAgentProject(root: root, agents: resolvedAgents)
    }

    func projectCommands(for requestedRoot: String?) -> [ProjectCommandDefinition] {
        guard let root = Self.validDirectory(requestedRoot ?? "") else { return [] }
        var commands = CherryProjectFile.loadCommands(projectRoot: root)
        for localCommand in commandsByProject[root] ?? [] {
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

    func projectFeatures(for requestedRoot: String?) -> ProjectFeatureSettings {
        guard let root = Self.validDirectory(requestedRoot ?? "") else {
            return .disabled
        }

        let shared = CherryProjectFile.loadFeatureSettings(projectRoot: root) ?? .disabled
        guard let local = featureOverridesByProject[root] else {
            return shared
        }

        return ProjectFeatureSettings(
            notesEnabled: local.notesEnabled ?? shared.notesEnabled,
            todosEnabled: local.todosEnabled ?? shared.todosEnabled
        )
    }

    func projectFeatureOverrides(for requestedRoot: String?) -> ProjectFeatureOverrides {
        guard let root = Self.validDirectory(requestedRoot ?? "") else {
            return ProjectFeatureOverrides()
        }
        return featureOverridesByProject[root] ?? ProjectFeatureOverrides()
    }

    func projectAppearance(for requestedRoot: String?) -> ProjectAppearanceSettings {
        guard let root = Self.validDirectory(requestedRoot ?? "") else {
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
        guard let root = Self.validDirectory(requestedRoot ?? "") else {
            return ProjectAppearanceOverrides()
        }
        return appearanceOverridesByProject[root] ?? ProjectAppearanceOverrides()
    }

    func setProjectFeatures(_ features: ProjectFeatureSettings, for requestedRoot: String, storage: ProjectFeatureStorage) throws {
        guard let root = Self.validDirectory(requestedRoot) else { return }
        switch storage {
        case .local:
            var overrides = featureOverridesByProject[root] ?? ProjectFeatureOverrides()
            overrides.notesEnabled = features.notesEnabled
            overrides.todosEnabled = features.todosEnabled
            try setFeatureOverrides(overrides, for: root)
        case .projectFile:
            try CherryProjectFile.writeFeatureSettings(features, projectRoot: root)
        }
    }

    func setProjectAppearance(_ appearance: ProjectAppearanceSettings, for requestedRoot: String, storage: ProjectAppearanceStorage) throws {
        guard let root = Self.validDirectory(requestedRoot) else { return }
        switch storage {
        case .local:
            try setAppearanceOverrides(ProjectAppearanceOverrides(color: appearance.color), for: root)
        case .projectFile:
            try CherryProjectFile.writeAppearanceSettings(appearance, projectRoot: root)
        }
    }

    func clearLocalProjectFeatureOverrides(for requestedRoot: String) {
        guard let root = Self.validDirectory(requestedRoot) else { return }
        featureOverridesByProject.removeValue(forKey: root)
        saveFeatureOverrides()
    }

    func clearLocalProjectAppearanceOverrides(for requestedRoot: String) {
        guard let root = Self.validDirectory(requestedRoot) else { return }
        appearanceOverridesByProject.removeValue(forKey: root)
        saveAppearanceOverrides()
    }

    @discardableResult
    func addProject(path: String) -> CherryProject? {
        guard let root = Self.validDirectory(path) else { return nil }
        let project = CherryProject(root: root)
        if !projects.contains(where: { $0.root == root }) {
            projects.append(project)
            saveProjects()
        }
        return project
    }

    func removeProject(_ project: CherryProject) {
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

    func markProjectOpened(_ projectRoot: String?) {
        guard let root = Self.validDirectory(projectRoot ?? "") else { return }
        guard lastOpenedProjectRoot != root else { return }
        lastOpenedProjectRoot = root
        saveLastOpenedProjectRoot()
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

    func upsertCommand(
        _ command: ProjectCommandDefinition,
        for requestedRoot: String,
        replacing originalName: String? = nil,
        storage: ProjectCommandStorage = .local
    ) throws {
        guard let root = Self.validDirectory(requestedRoot) else { return }
        let validatedCommand = try ProjectCommandConfiguration.validated([
            command.withPortableWorkingDirectory(projectRoot: root)
        ]).first!
        switch storage {
        case .local:
            var nextCommands = commandsByProject[root] ?? []
            if let originalName {
                nextCommands.removeAll { $0.normalizedName == AgentToolDefinition.normalizedName(originalName) }
            }
            nextCommands.removeAll { $0.normalizedName == validatedCommand.normalizedName }
            nextCommands.append(validatedCommand)
            try setCommands(nextCommands, for: root)
        case .projectFile:
            try CherryProjectFile.upsertCommand(validatedCommand, projectRoot: root, replacing: originalName)
        }
    }

    func removeCommand(named name: String, for requestedRoot: String) {
        guard let root = Self.validDirectory(requestedRoot) else { return }
        let normalizedName = AgentToolDefinition.normalizedName(name)
        let nextCommands = (commandsByProject[root] ?? []).filter { $0.normalizedName != normalizedName }
        try? setCommands(nextCommands, for: root)
        try? CherryProjectFile.removeCommand(named: name, projectRoot: root)
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
        Self.saveProjects(projects, to: defaults)
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
        Self.saveAgents(agents, to: defaults)
    }

    private func saveCommands() {
        Self.saveCommandsByProject(commandsByProject, to: defaults)
    }

    private func saveFeatureOverrides() {
        Self.saveFeatureOverridesByProject(featureOverridesByProject, to: defaults)
    }

    private func saveAppearanceOverrides() {
        Self.saveAppearanceOverridesByProject(appearanceOverridesByProject, to: defaults)
    }

    private func saveSummarySettings() {
        defaults.set(agentSummaryTool.rawValue, forKey: Keys.agentSummaryTool)
        defaults.set(agentSummaryCadence.rawValue, forKey: Keys.agentSummaryCadence)
        defaults.set(agentSummaryModel, forKey: Keys.agentSummaryModel)
        defaults.set(agentSummaryCommand, forKey: Keys.agentSummaryCommand)
        defaults.set(useAgentSummaryAsTitle, forKey: Keys.useAgentSummaryAsTitle)
    }

    private static func loadProjects(from defaults: UserDefaults) -> [CherryProject] {
        guard let data = defaults.data(forKey: Keys.projects),
              let decoded = try? JSONDecoder().decode([CherryProject].self, from: data)
        else {
            return []
        }
        return decoded.filter { validDirectory($0.root) != nil }
    }

    private static func loadLastOpenedProjectRoot(from defaults: UserDefaults) -> String? {
        validDirectory(defaults.string(forKey: Keys.lastOpenedProjectRoot) ?? "")
    }

    private static func loadAgents(from defaults: UserDefaults) -> [AgentToolDefinition] {
        if let data = defaults.data(forKey: Keys.agents),
           let decoded = try? JSONDecoder().decode([AgentToolDefinition].self, from: data),
           let validated = try? AgentConfiguration.validated(decoded) {
            return validated
        }

        return migratedProjectAgents(from: defaults)
    }

    private static func loadCommandsByProject(from defaults: UserDefaults) -> [String: [ProjectCommandDefinition]] {
        guard let data = defaults.data(forKey: Keys.commandsByProject),
              let decoded = try? JSONDecoder().decode([String: [ProjectCommandDefinition]].self, from: data)
        else {
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

    private static func loadFeatureOverridesByProject(from defaults: UserDefaults) -> [String: ProjectFeatureOverrides] {
        guard let data = defaults.data(forKey: Keys.featureOverridesByProject),
              let decoded = try? JSONDecoder().decode([String: ProjectFeatureOverrides].self, from: data)
        else {
            return [:]
        }

        var overridesByProject: [String: ProjectFeatureOverrides] = [:]
        for (root, overrides) in decoded {
            guard let validRoot = validDirectory(root), !overrides.isEmpty else {
                continue
            }
            overridesByProject[validRoot] = overrides
        }
        return overridesByProject
    }

    private static func loadAppearanceOverridesByProject(from defaults: UserDefaults) -> [String: ProjectAppearanceOverrides] {
        guard let data = defaults.data(forKey: Keys.appearanceOverridesByProject),
              let decoded = try? JSONDecoder().decode([String: ProjectAppearanceOverrides].self, from: data)
        else {
            return [:]
        }

        var overridesByProject: [String: ProjectAppearanceOverrides] = [:]
        for (root, overrides) in decoded {
            guard let validRoot = validDirectory(root), !overrides.isEmpty else {
                continue
            }
            overridesByProject[validRoot] = overrides
        }
        return overridesByProject
    }

    private static func migratedProjectAgents(from defaults: UserDefaults) -> [AgentToolDefinition] {
        guard let data = defaults.data(forKey: Keys.legacyLocalAgentsByProject),
              let decoded = try? JSONDecoder().decode([String: [AgentToolDefinition]].self, from: data)
        else {
            return []
        }

        for root in decoded.keys.sorted() {
            guard let agents = decoded[root],
                  !agents.isEmpty,
                  let validated = try? AgentConfiguration.validated(agents)
            else {
                continue
            }
            return validated
        }

        return []
    }

    private static func loadAgentSummaryTool(from _: UserDefaults, command _: String) -> AgentSummaryTool {
        .codex
    }

    private static func loadAgentSummaryModel(from defaults: UserDefaults, tool: AgentSummaryTool) -> String {
        let storedModel = defaults.string(forKey: Keys.agentSummaryModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if storedModel.isEmpty || storedModel == "gpt-5-codex" || storedModel == "haiku" {
            return AgentSummaryTool.codex.defaultModel
        }
        return storedModel
    }

    private static func loadAgentSummaryCadence(from defaults: UserDefaults) -> AgentSummaryCadence {
        let rawValue = defaults.integer(forKey: Keys.agentSummaryCadence)
        return AgentSummaryCadence(rawValue: rawValue) ?? .thirtySeconds
    }

    private static func saveProjects(_ projects: [CherryProject], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: Keys.projects)
    }

    private static func saveAgents(_ agents: [AgentToolDefinition], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        defaults.set(data, forKey: Keys.agents)
    }

    private static func saveCommandsByProject(
        _ commandsByProject: [String: [ProjectCommandDefinition]],
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(commandsByProject) else { return }
        defaults.set(data, forKey: Keys.commandsByProject)
    }

    private static func saveFeatureOverridesByProject(
        _ overridesByProject: [String: ProjectFeatureOverrides],
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(overridesByProject) else { return }
        defaults.set(data, forKey: Keys.featureOverridesByProject)
    }

    private static func saveAppearanceOverridesByProject(
        _ overridesByProject: [String: ProjectAppearanceOverrides],
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(overridesByProject) else { return }
        defaults.set(data, forKey: Keys.appearanceOverridesByProject)
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

    static func validDirectory(_ path: String) -> String? {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return nil }
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
        static let lastOpenedProjectRoot = "projects.lastOpenedRoot"
        static let agents = "agents.global"
        static let commandsByProject = "commands.byProject"
        static let featureOverridesByProject = "features.byProject"
        static let appearanceOverridesByProject = "appearance.byProject"
        static let agentSummaryTool = "agents.summaryTool"
        static let agentSummaryCadence = "agents.summaryCadence"
        static let agentSummaryModel = "agents.summaryModel"
        static let agentSummaryCommand = "agents.summaryCommand"
        static let useAgentSummaryAsTitle = "agents.summaryAsTitle"
        static let legacyLocalAgentsByProject = "agents.localByProject"
    }
}

enum CherryProjectFile {
    private static let fileName = "cherry.toml"
    private static let beginMarker = "# BEGIN CHERRY COMMANDS"
    private static let endMarker = "# END CHERRY COMMANDS"

    static func fileURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(fileName)
    }

    static func exists(projectRoot: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(projectRoot: projectRoot).path)
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

    @MainActor
    private static func invalidate(projectRoot: String) {
        parseCache[projectRoot] = nil
    }

    @MainActor
    private static func parsed(projectRoot: String) -> ParsedFile {
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

        var parsed = ParsedFile(modificationDate: modificationDate, fileSize: fileSize)
        if let contents = try? String(contentsOf: url, encoding: .utf8) {
            let commandSource = managedSection(in: contents) ?? contents
            parsed.commands = (try? ProjectCommandConfiguration.validated(parseCommands(from: commandSource))) ?? []
            if let featureSource = tableSection(named: "features", in: contents) {
                let fields = parseKeyValues(from: featureSource)
                parsed.features = ProjectFeatureSettings(
                    notesEnabled: boolValue(fields["notes"]) ?? false,
                    todosEnabled: boolValue(fields["todos"]) ?? false
                )
            }
            if let appearanceSource = tableSection(named: "appearance", in: contents) {
                let fields = parseKeyValues(from: appearanceSource)
                parsed.appearance = ProjectAppearanceSettings(
                    color: fields["color"].flatMap(ProjectIdentityColor.init(rawValue:))
                )
            }
        }
        parseCache[projectRoot] = parsed
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
        defer { invalidate(projectRoot: projectRoot) }
        let url = fileURL(projectRoot: projectRoot)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let nextSection = renderFeatureSection(features)
        let nextContents: String

        if let range = tableSectionRange(named: "features", in: existing) {
            let replacement = range.upperBound == existing.endIndex ? nextSection : nextSection + "\n"
            nextContents = existing.replacingCharacters(in: range, with: replacement)
        } else if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextContents = nextSection
        } else {
            nextContents = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + nextSection
        }

        try nextContents.trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    static func writeAppearanceSettings(_ appearance: ProjectAppearanceSettings, projectRoot: String) throws {
        defer { invalidate(projectRoot: projectRoot) }
        let url = fileURL(projectRoot: projectRoot)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let nextSection = renderAppearanceSection(appearance)
        let nextContents: String

        if let range = tableSectionRange(named: "appearance", in: existing) {
            let replacement = range.upperBound == existing.endIndex ? nextSection : nextSection + "\n"
            nextContents = existing.replacingCharacters(in: range, with: replacement)
        } else if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextContents = nextSection
        } else {
            nextContents = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + nextSection
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

    private static func renderFeatureSection(_ features: ProjectFeatureSettings) -> String {
        [
            "[features]",
            "notes = \(features.notesEnabled ? "true" : "false")",
            "todos = \(features.todosEnabled ? "true" : "false")"
        ].joined(separator: "\n")
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
