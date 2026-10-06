import Foundation
import Testing
@testable import CherryMobileKit

/// `CherryMCP --call list_projects`, as the helper prints it (snake_case,
/// sorted keys, one line).
let listProjectsJSON = #"""
{"active_project_root":"/Users/me/cherry","projects":[{"active":true,"active_worktree_root":"/Users/me/cherry","features":{"notes_enabled":true,"todos_enabled":true},"name":"cherry","open":true,"root":"/Users/me/cherry","worktrees":[{"active":true,"branch":"main","detached":false,"head":"abc","hidden":false,"loaded":true,"locked":false,"main":true,"root":"/Users/me/cherry"},{"active":false,"branch":"fix","detached":false,"head":"def","hidden":false,"loaded":true,"locked":false,"main":false,"root":"/Users/me/cherry-fix"},{"active":false,"branch":"old","detached":false,"head":"0ab","hidden":false,"loaded":false,"locked":false,"main":false,"root":"/Users/me/cherry-old"}]},{"active":false,"features":{"notes_enabled":false,"todos_enabled":false},"name":"closed","open":false,"root":"/Users/me/closed","worktrees":[]},{"active":false,"features":{"notes_enabled":false,"todos_enabled":false},"name":"it's","open":true,"root":"/Users/me/it's here"}]}
"""#

/// `CherryMCP --call list_processes '{"project_root":…}'`.
let listProcessesJSON = #"""
{"active_project_root":"/Users/me/cherry","processes":[{"accepts_input":true,"agent_activity_state":"permission","agent_name":"Claude","agent_turn":3,"agent_turn_state":"active","id":"7f0c1e52-3b47-4e2b-9c1a-2d3e4f5a6b7c","kind":"agent","last_content_change_at":781500000.5,"line_count":40,"name":"Fix tests","output_version":9,"selected":true,"state":"live","working_directory":"/Users/me/cherry"},{"accepts_input":true,"agent_activity_state":"idle","agent_name":"Codex","agent_turn":1,"agent_turn_state":"completed","id":"11111111-2222-3333-4444-555555555555","kind":"agent","label":"Port the printer","line_count":10,"name":"codex","output_version":2,"result_summary":"Ported it","selected":false,"state":"live","task_id":"task-1","task_state":"reported","working_directory":"/Users/me/cherry"},{"accepts_input":true,"id":"99999999-2222-3333-4444-555555555555","kind":"terminal","line_count":1,"name":"zsh","output_version":1,"selected":false,"state":"live","working_directory":"/Users/me"}],"selected_process_id":"7f0c1e52-3b47-4e2b-9c1a-2d3e4f5a6b7c"}
"""#

@Test func activityAndTurnStateMapToWhatTheAgentNeeds() {
    #expect(AgentStates.attention(activity: "permission", turnState: "active") == .approval)
    #expect(AgentStates.attention(activity: "needs_input", turnState: "active") == .question)
    #expect(AgentStates.attention(activity: "error", turnState: nil) == .error)
    #expect(AgentStates.attention(activity: "working", turnState: "active") == .working)
    #expect(AgentStates.attention(activity: "idle", turnState: "completed") == .resultReady)
    #expect(AgentStates.attention(activity: "idle", turnState: "not_started") == .idle)
    #expect(AgentStates.attention(activity: "idle", turnState: "user_interrupted") == .idle)
    #expect(AgentStates.attention(activity: "unknown", turnState: nil) == .unknown)
    #expect(AgentStates.attention(activity: nil, turnState: nil) == .unknown)
}

@Test func openProjectsAndTheirLoadedWorktreesAreListed() {
    #expect(AgentStates.projectRoots(inListProjects: Data(listProjectsJSON.utf8))
        == ["/Users/me/cherry", "/Users/me/cherry-fix", "/Users/me/it's here"])
    #expect(AgentStates.projectRoots(inListProjects: Data(#"{"code":"cherry_unreachable"}"#.utf8)).isEmpty)
}

@Test func processListsGiveEachAgentTabItsState() {
    let states = AgentStates.parse(processLists: [Data(listProcessesJSON.utf8), Data("{}".utf8)])
    #expect(states.byTab.count == 2)
    let claude = states.state(forTab: "7F0C1E52-3B47-4E2B-9C1A-2D3E4F5A6B7C")
    #expect(claude?.attention == .approval)
    #expect(claude?.changedAt == Date(timeIntervalSinceReferenceDate: 781500000.5))
    let codex = states.state(forTab: "11111111-2222-3333-4444-555555555555")
    #expect(codex?.attention == .resultReady)
    #expect(codex?.detail == "Port the printer")
    #expect(states.state(forTab: "99999999-2222-3333-4444-555555555555") == nil)
}

@Test func aSessionTakesItsTabsStateThroughItsTabTag() throws {
    let info = try JSONDecoder().decode(HostWireSession.self, from: Data(sessionJSON.utf8))
    let mac = UUID()
    let states = AgentStates.parse(processLists: [Data(listProcessesJSON.utf8)])
    let session = SessionMapping.session(info, macID: mac, states: states)
    #expect(session.kind == .agent("claude"))
    #expect(session.title == "probe")
    #expect(session.attention == .approval)
    #expect(session.macID == mac)
    #expect(session.size == TerminalSize(columns: 120, rows: 32))
    #expect(SessionMapping.session(info, macID: mac, states: .empty).attention == .unknown)
}

@Test func titlesKindsAndDirectoriesReadLikeTheMacApp() {
    let agent = HostWireSession(id: "a", name: "⠋ Fix the tests", cwd: "/x", tags: ["cherry.kind": "agent", "cherry.agent": "Claude"])
    #expect(SessionMapping.kind(of: agent) == .agent("Claude"))
    #expect(SessionMapping.title(of: agent, kind: .agent("Claude")) == "Fix the tests")
    let unnamed = HostWireSession(id: "b", name: "✳ ", cwd: "/x", tags: ["cherry.kind": "agent", "cherry.agent": "Codex"])
    #expect(SessionMapping.title(of: unnamed, kind: .agent("Codex")) == "Codex")
    let command = HostWireSession(id: "c", name: "dev", cwd: "/x", tags: ["cherry.kind": "command", "cherry.command": "npm run dev"])
    #expect(SessionMapping.kind(of: command) == .command)
    #expect(SessionMapping.title(of: command, kind: .command) == "npm run dev")
    let shell = HostWireSession(id: "d", name: "Terminal", cwd: "/x", title: "vim notes.md", pwd: "file://mac.local/Users/me/My%20Notes")
    #expect(SessionMapping.kind(of: shell) == .terminal)
    #expect(SessionMapping.title(of: shell, kind: .terminal) == "vim notes.md")
    #expect(SessionMapping.directory(of: shell) == "/Users/me/My Notes")
    #expect(SessionMapping.reportedPath("kitty-shell-cwd://mac/Users/me/a b") == "/Users/me/a b")
    #expect(SessionMapping.directory(of: HostWireSession(id: "e", name: "", cwd: "/start")) == "/start")
    let exited = HostWireSession(id: "f", name: "x", cwd: "/", state: "exited", tags: ["cherry.kind": "agent", "cherry.tab": "7F0C1E52-3B47-4E2B-9C1A-2D3E4F5A6B7C"])
    let states = AgentStates.parse(processLists: [Data(listProcessesJSON.utf8)])
    #expect(SessionMapping.session(exited, macID: UUID(), states: states).attention == .unknown)
}

@Test func whyTheControlCommandEndedBeforeItsWelcome() {
    #expect(SSHMacConnection.startError(
        reason: "cherry: no cherry-host is running at /tmp/x/host.sock (this command never starts one)", status: 1
    ) == .noSessionHost("cherry: no cherry-host is running at /tmp/x/host.sock (this command never starts one)"))
    #expect(SSHMacConnection.startError(reason: "sh: /nope/cherry: No such file or directory", status: 127) == .cherryNotFound)
    #expect(SSHMacConnection.startError(reason: "protocol version mismatch: the host speaks version 8", status: 1)
        == .protocolMismatch("protocol version mismatch: the host speaks version 8"))
    #expect(SSHMacConnection.startError(reason: "something else", status: 1) == .failed("something else"))
}
