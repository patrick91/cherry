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

@MainActor
final class AgentSettings: ObservableObject {
    static let shared = AgentSettings()

    @Published private(set) var projects: [CherryProject] = []
    @Published private(set) var agents: [AgentToolDefinition] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projects = Self.loadProjects(from: defaults)
        agents = Self.loadAgents(from: defaults)
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
        saveProjects()
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

    private func setAgents(_ agents: [AgentToolDefinition]) throws {
        self.agents = try AgentConfiguration.validated(agents)
        saveAgents()
    }

    private func saveProjects() {
        Self.saveProjects(projects, to: defaults)
    }

    private func saveAgents() {
        Self.saveAgents(agents, to: defaults)
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
        static let legacyLocalAgentsByProject = "agents.localByProject"
    }
}
