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
        autoStart: Bool = false,
        autoRestart: Bool = false,
        enabled: Bool = true
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
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
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        autoRestart = try container.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func resolvedWorkingDirectory(projectRoot: String) -> String {
        let normalized = NSString(string: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        guard !normalized.isEmpty else { return projectRoot }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return projectRoot
        }
        return URL(fileURLWithPath: normalized, isDirectory: true).standardizedFileURL.path
    }
}

enum ProjectCommandStorage: String, CaseIterable, Identifiable {
    case projectFile
    case local

    var id: String { rawValue }
}

enum AgentToolSource: Equatable {
    case global
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
}

@MainActor
final class AgentSettings: ObservableObject {
    static let shared = AgentSettings()

    @Published private(set) var projects: [CherryProject] = []
    @Published private(set) var agents: [AgentToolDefinition] = []
    @Published private(set) var commandsByProject: [String: [ProjectCommandDefinition]] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projects = Self.loadProjects(from: defaults)
        agents = Self.loadAgents(from: defaults)
        commandsByProject = Self.loadCommandsByProject(from: defaults)
    }

    var resolvedAgents: [ResolvedAgentTool] {
        agents.map { ResolvedAgentTool(definition: $0, source: .global) }
    }

    func selectedProject(for root: String?) -> CherryProject? {
        guard let root = Self.validDirectory(root ?? "") else { return nil }
        return projects.first(where: { $0.root == root }) ?? CherryProject(root: root)
    }

    func projectRoot(for requestedRoot: String?) -> String? {
        if let root = Self.validDirectory(requestedRoot ?? "") {
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
        saveProjects()
        saveCommands()
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
        let validatedCommand = try ProjectCommandConfiguration.validated([command]).first!
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

    private func saveProjects() {
        Self.saveProjects(projects, to: defaults)
    }

    private func saveAgents() {
        Self.saveAgents(agents, to: defaults)
    }

    private func saveCommands() {
        Self.saveCommandsByProject(commandsByProject, to: defaults)
    }

    private static func loadProjects(from defaults: UserDefaults) -> [CherryProject] {
        guard let data = defaults.data(forKey: Keys.projects),
              let decoded = try? JSONDecoder().decode([CherryProject].self, from: data)
        else {
            return []
        }
        return decoded.filter { validDirectory($0.root) != nil }
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

    static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return NSString(string: trimmed).expandingTildeInPath
    }

    static func validDirectory(_ path: String) -> String? {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return URL(fileURLWithPath: normalized, isDirectory: true).standardizedFileURL.path
    }

    private enum Keys {
        static let projects = "projects.items"
        static let agents = "agents.global"
        static let commandsByProject = "commands.byProject"
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

    static func loadCommands(projectRoot: String) -> [ProjectCommandDefinition] {
        let url = fileURL(projectRoot: projectRoot)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let source = managedSection(in: contents) ?? contents
        return (try? ProjectCommandConfiguration.validated(parseCommands(from: source))) ?? []
    }

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

    static func removeCommand(named name: String, projectRoot: String) throws {
        let normalizedName = AgentToolDefinition.normalizedName(name)
        let commands = loadCommands(projectRoot: projectRoot).filter { $0.normalizedName != normalizedName }
        try writeCommands(commands, projectRoot: projectRoot)
    }

    private static func writeCommands(_ commands: [ProjectCommandDefinition], projectRoot: String) throws {
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
            lines.append("autoStart = \(command.autoStart ? "true" : "false")")
            lines.append("autoRestart = \(command.autoRestart ? "true" : "false")")
            lines.append("enabled = \(command.enabled ? "true" : "false")")
            lines.append("")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    private static func parseCommands(from source: String) -> [ProjectCommandDefinition] {
        var commands: [ProjectCommandDefinition] = []
        var fields: [String: String] = [:]

        func flushCommand() {
            guard !fields.isEmpty else { return }
            commands.append(ProjectCommandDefinition(
                name: fields["name"] ?? "",
                command: fields["command"] ?? "",
                arguments: fields["arguments"] ?? "",
                workingDirectory: fields["workingDirectory"] ?? "",
                autoStart: boolValue(fields["autoStart"]) ?? false,
                autoRestart: boolValue(fields["autoRestart"]) ?? false,
                enabled: boolValue(fields["enabled"]) ?? true
            ))
            fields.removeAll()
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
            fields[key] = tomlValue(value)
        }
        flushCommand()
        return commands
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
