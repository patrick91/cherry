import Foundation

/// What the Mac's Cherry says about each of its tabs, read with its MCP
/// helper (`CherryMCP --call list_projects`, then `list_processes` per open
/// project and loaded worktree), keyed by tab id. A host session names its
/// tab in its `cherry.tab` tag; MCP's process `id` is the same tab id
/// (docs/specs/ios-app.md, Agent state).
struct AgentStates: Equatable, Sendable {
    struct State: Equatable, Sendable {
        var attention: AgentAttention
        /// A Cherry task's label, else its result summary.
        var detail: String?
        var changedAt: Date?
    }

    /// By tab id, uppercased.
    var byTab: [String: State] = [:]

    static let empty = AgentStates()

    func state(forTab tab: String?) -> State? {
        guard let tab else { return nil }
        return byTab[tab.uppercased()]
    }

    /// `agent_activity_state` and `agent_turn_state` as the phone shows
    /// them: `permission` an approval, `needs_input` a question, `idle`
    /// after a completed turn a result ready.
    static func attention(activity: String?, turnState: String?) -> AgentAttention {
        switch activity {
        case "permission": .approval
        case "needs_input": .question
        case "error": .error
        case "working": .working
        case "idle": turnState == "completed" ? .resultReady : .idle
        default: .unknown
        }
    }

    /// The states in `list_processes` results (one JSON object per project),
    /// agents only; later results win for a tab listed twice.
    static func parse(processLists: [Data]) -> AgentStates {
        var states = AgentStates()
        for data in processLists {
            guard let list = try? MCPPayload.decoder.decode(MCPProcessList.self, from: data) else { continue }
            for process in list.processes where process.kind == "agent" {
                states.byTab[process.id.uppercased()] = State(
                    attention: attention(activity: process.agentActivityState, turnState: process.agentTurnState),
                    detail: process.label?.nilIfBlank ?? process.resultSummary?.nilIfBlank,
                    changedAt: process.lastContentChangeAt.map(Date.init(timeIntervalSinceReferenceDate:))
                )
            }
        }
        return states
    }

    /// The roots to list processes in: each open project and its loaded
    /// worktrees, once each.
    static func projectRoots(inListProjects data: Data) -> [String] {
        guard let list = try? MCPPayload.decoder.decode(MCPProjectList.self, from: data) else { return [] }
        var seen = Set<String>()
        var roots: [String] = []
        for project in list.projects where project.open {
            for root in [project.root] + (project.worktrees ?? []).filter(\.loaded).map(\.root) where seen.insert(root).inserted {
                roots.append(root)
            }
        }
        return roots
    }
}

/// The MCP helper's tool results: JSON with snake_case keys, dates as
/// seconds since 2001 (`JSONEncoder`'s default).
enum MCPPayload {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

struct MCPProjectList: Decodable {
    struct Project: Decodable {
        let root: String
        let open: Bool
        let worktrees: [Worktree]?
    }

    struct Worktree: Decodable {
        let root: String
        let loaded: Bool
    }

    let projects: [Project]
}

struct MCPProcessList: Decodable {
    struct Process: Decodable {
        let id: String
        let kind: String
        let agentActivityState: String?
        let agentTurnState: String?
        let label: String?
        let resultSummary: String?
        let lastContentChangeAt: Double?
    }

    let processes: [Process]
}

/// The commands that read agent state on the Mac, run in a POSIX `sh` (the
/// login shell may be fish).
enum AgentStateCommands {
    /// `CherryMCP` next to the `cherry` helper: both are in
    /// `Cherry.app/Contents/MacOS`.
    static func mcpPath(nextTo cherryPath: String) -> String {
        (cherryPath as NSString).deletingLastPathComponent + "/CherryMCP"
    }

    static func listProjects(mcpPath: String) -> String {
        ShellQuote.sh(#"[ -x "$1" ] || exit 3; exec "$1" --call list_projects"#, arguments: [mcpPath])
    }

    /// One `list_processes` per root, each result on a line of its own (the
    /// helper prints compact JSON); a failed call prints `{}`.
    static func listProcesses(mcpPath: String, roots: [String]) -> String {
        let script = #"""
        m=$1; shift
        [ -x "$m" ] || exit 3
        for arguments in "$@"; do
          "$m" --call list_processes "$arguments" 2>/dev/null || printf '{}\n'
        done
        """#
        let arguments = roots.map { root -> String in
            let object = ["project_root": root]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return ShellQuote.sh(script, arguments: [mcpPath] + arguments)
    }

    /// The non-empty lines of a command's output.
    static func lines(_ output: Data) -> [Data] {
        output.split(separator: UInt8(ascii: "\n")).map { Data($0) }.filter { !$0.isEmpty }
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
