import CryptoKit
import Foundation
import TOMLKit

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
    case shared
    case local
    case localOverride
}

struct ResolvedAgentTool: Equatable, Identifiable {
    let definition: AgentToolDefinition
    let source: AgentToolSource
    let isSharedConfigTrusted: Bool

    var id: String { definition.id }
    var name: String { definition.name }
    var commandLine: String { definition.commandLine }
    var enabled: Bool { definition.enabled }
    var isLaunchable: Bool {
        definition.enabled && !definition.commandLine.isEmpty && (source != .shared || isSharedConfigTrusted)
    }
    var hasLocalOverride: Bool { source == .localOverride }
}

struct ResolvedAgentProject: Equatable {
    let root: String?
    let agents: [ResolvedAgentTool]
    let configState: AgentProjectConfigState

    var validProjectRoot: String? { root }
    var launchableAgents: [ResolvedAgentTool] { agents.filter(\.isLaunchable) }
}

enum AgentProjectConfigState: Equatable {
    case noProject
    case noConfig
    case trusted(hash: String)
    case untrusted(hash: String)
    case error(String)

    var isSharedConfigTrusted: Bool {
        switch self {
        case .noProject, .noConfig, .trusted:
            true
        case .untrusted, .error:
            false
        }
    }

    var message: String {
        switch self {
        case .noProject:
            "Choose a project root to load project agents."
        case .noConfig:
            "No cherry.toml found in the project root."
        case .trusted:
            "cherry.toml is trusted."
        case .untrusted:
            "Review and trust cherry.toml before launching shared agents."
        case .error(let message):
            message
        }
    }
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

struct AgentProjectDocument: Codable, Equatable {
    var agents: [AgentToolDefinition]

    init(agents: [AgentToolDefinition] = []) {
        self.agents = agents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decodeIfPresent([AgentToolDefinition].self, forKey: .agents) ?? []
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
    static let fileName = "cherry.toml"

    static func decodeSharedAgents(from toml: String) throws -> [AgentToolDefinition] {
        let document = try TOMLDecoder().decode(AgentProjectDocument.self, from: toml)
        return try validated(document.agents)
    }

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

    static func merge(
        sharedAgents: [AgentToolDefinition],
        localAgents: [AgentToolDefinition],
        isSharedConfigTrusted: Bool
    ) -> [ResolvedAgentTool] {
        let localByName = localAgents.reduce(into: [String: AgentToolDefinition]()) { result, agent in
            result[agent.normalizedName] = agent
        }
        var usedLocalNames = Set<String>()

        var merged = sharedAgents.map { sharedAgent -> ResolvedAgentTool in
            if let localAgent = localByName[sharedAgent.normalizedName] {
                usedLocalNames.insert(sharedAgent.normalizedName)
                return ResolvedAgentTool(
                    definition: localAgent,
                    source: .localOverride,
                    isSharedConfigTrusted: isSharedConfigTrusted
                )
            }

            return ResolvedAgentTool(
                definition: sharedAgent,
                source: .shared,
                isSharedConfigTrusted: isSharedConfigTrusted
            )
        }

        merged.append(contentsOf: localAgents
            .filter { !usedLocalNames.contains($0.normalizedName) }
            .map {
                ResolvedAgentTool(
                    definition: $0,
                    source: .local,
                    isSharedConfigTrusted: isSharedConfigTrusted
                )
            })

        return merged
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projects = Self.loadProjects(from: defaults)
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
        guard let root = Self.validDirectory(requestedRoot ?? "") else {
            return ResolvedAgentProject(root: nil, agents: [], configState: .noProject)
        }
        return resolvedProject(root: root)
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

    func trustSharedConfig(for projectRoot: String?) {
        guard let root = Self.validDirectory(projectRoot ?? "") else { return }
        guard case .untrusted(let hash) = resolvedProject(for: root).configState else { return }
        var hashes = trustedHashes()
        hashes[root] = hash
        saveTrustedHashes(hashes)
    }

    func upsertLocalAgent(_ agent: AgentToolDefinition, for projectRoot: String?, replacing originalName: String? = nil) throws {
        guard let root = Self.validDirectory(projectRoot ?? "") else { return }
        let validatedAgent = try AgentConfiguration.validated([agent]).first!
        var localAgents = localAgents(for: root)
        if let originalName {
            localAgents.removeAll { $0.normalizedName == AgentToolDefinition.normalizedName(originalName) }
        }
        localAgents.removeAll { $0.normalizedName == validatedAgent.normalizedName }
        localAgents.append(validatedAgent)
        try setLocalAgents(localAgents, for: root)
    }

    func removeLocalAgent(named name: String, for projectRoot: String?) {
        guard let root = Self.validDirectory(projectRoot ?? "") else { return }
        var localAgents = localAgents(for: root)
        localAgents.removeAll { $0.normalizedName == AgentToolDefinition.normalizedName(name) }
        try? setLocalAgents(localAgents, for: root)
    }

    private func localAgents(for root: String) -> [AgentToolDefinition] {
        localAgentsByProject()[root] ?? []
    }

    private func setLocalAgents(_ agents: [AgentToolDefinition], for root: String) throws {
        var byProject = localAgentsByProject()
        byProject[root] = try AgentConfiguration.validated(agents)
        let data = try JSONEncoder().encode(byProject)
        defaults.set(data, forKey: Keys.localAgentsByProject)
    }

    private func localAgentsByProject() -> [String: [AgentToolDefinition]] {
        guard let data = defaults.data(forKey: Keys.localAgentsByProject),
              let decoded = try? JSONDecoder().decode([String: [AgentToolDefinition]].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private func trustedHashes() -> [String: String] {
        guard let data = defaults.data(forKey: Keys.trustedConfigHashes),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private func saveTrustedHashes(_ hashes: [String: String]) {
        guard let data = try? JSONEncoder().encode(hashes) else { return }
        defaults.set(data, forKey: Keys.trustedConfigHashes)
    }

    private func resolvedProject(root: String) -> ResolvedAgentProject {
        let configURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(AgentConfiguration.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            let agents = AgentConfiguration.merge(
                sharedAgents: [],
                localAgents: localAgents(for: root),
                isSharedConfigTrusted: true
            )
            return ResolvedAgentProject(root: root, agents: agents, configState: .noConfig)
        }

        do {
            let data = try Data(contentsOf: configURL)
            let hash = AgentConfiguration.hash(data)
            let toml = String(decoding: data, as: UTF8.self)
            let sharedAgents = try AgentConfiguration.decodeSharedAgents(from: toml)
            let trusted = trustedHashes()[root] == hash
            let configState = trusted ? AgentProjectConfigState.trusted(hash: hash) : .untrusted(hash: hash)
            let agents = AgentConfiguration.merge(
                sharedAgents: sharedAgents,
                localAgents: localAgents(for: root),
                isSharedConfigTrusted: configState.isSharedConfigTrusted
            )
            return ResolvedAgentProject(root: root, agents: agents, configState: configState)
        } catch {
            let agents = AgentConfiguration.merge(
                sharedAgents: [],
                localAgents: localAgents(for: root),
                isSharedConfigTrusted: false
            )
            return ResolvedAgentProject(root: root, agents: agents, configState: .error(error.localizedDescription))
        }
    }

    private func saveProjects() {
        Self.saveProjects(projects, to: defaults)
    }

    private static func loadProjects(from defaults: UserDefaults) -> [CherryProject] {
        guard let data = defaults.data(forKey: Keys.projects),
              let decoded = try? JSONDecoder().decode([CherryProject].self, from: data)
        else {
            return []
        }
        return decoded.filter { validDirectory($0.root) != nil }
    }

    private static func saveProjects(_ projects: [CherryProject], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: Keys.projects)
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
        static let localAgentsByProject = "agents.localByProject"
        static let trustedConfigHashes = "agents.trustedConfigHashes"
    }
}
