import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

@Test func cherryControlRequestRoundTrips() async throws {
    let request = CherryControlRequest.sendInput(.init(
        terminalID: UUID().uuidString,
        text: "pwd\n",
        rawBase64: nil,
        waitMilliseconds: 100,
        lineLimit: 20
    ))

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(CherryControlRequest.self, from: data)

    #expect(decoded == request)
}

@Test func cherryControlRunAgentRequestRoundTrips() async throws {
    let request = CherryControlRequest.runAgent(.init(
        agentName: "Codex",
        text: "status\n",
        rawBase64: nil,
        waitMilliseconds: 100,
        lineLimit: 20,
        select: true
    ))

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(CherryControlRequest.self, from: data)

    #expect(decoded == request)
}

@MainActor
@Test func controlServerListsConfiguredAgents() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }

    try harness.settings.upsertAgent(AgentToolDefinition(name: "Codex", command: "codex", arguments: "--yolo"))
    try harness.settings.upsertAgent(AgentToolDefinition(name: "Claude", command: "claude", enabled: false))
    harness.server.start()

    let response = try await harness.send(.listAgents)
    guard case .listAgents(let result)? = response.result else {
        Issue.record("Expected listAgents result, got \(String(describing: response))")
        return
    }

    #expect(response.error == nil)
    #expect(result.activeProjectRoot == harness.projectRoot.path)
    #expect(result.agents.map(\.name) == ["Codex", "Claude"])
    #expect(result.agents[0].commandLine == "codex --yolo")
    #expect(result.agents[0].launchable == true)
    #expect(result.agents[0].activeSessionCount == 0)
    #expect(result.agents[1].enabled == false)
    #expect(result.agents[1].launchable == false)
}

@MainActor
@Test func controlServerRunsConfiguredAgentSession() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }

    try harness.settings.upsertAgent(AgentToolDefinition(name: "Echo", command: "/bin/cat"))
    harness.server.start()

    let response = try await harness.send(.runAgent(.init(
        agentName: " echo ",
        text: "agent-input\n",
        waitMilliseconds: 250,
        lineLimit: 20,
        select: false
    )))

    guard case .runAgent(let result)? = response.result else {
        Issue.record("Expected runAgent result, got \(String(describing: response))")
        return
    }

    #expect(response.error == nil)
    #expect(result.projectRoot == harness.projectRoot.path)
    #expect(result.kind == "agent")
    #expect(result.agentName == "Echo")
    #expect(result.title == "Echo")
    #expect(result.sentBytes == Data("agent-input\n".utf8).count)
    #expect(result.output?.lines.joined(separator: "\n").contains("agent-input") == true)
    #expect(harness.workspace.agentSessions.count == 1)
    #expect(harness.workspace.selectedSessionID != UUID(uuidString: result.terminalID))
}

@MainActor
@Test func controlServerCreatesDuplicateAgentSessions() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }

    try harness.settings.upsertAgent(AgentToolDefinition(name: "Echo", command: "/bin/cat"))
    harness.server.start()

    let firstResponse = try await harness.send(.runAgent(.init(agentName: "Echo")))
    let secondResponse = try await harness.send(.runAgent(.init(agentName: "Echo")))

    guard case .runAgent(let firstResult)? = firstResponse.result,
          case .runAgent(let secondResult)? = secondResponse.result
    else {
        Issue.record("Expected runAgent results")
        return
    }

    #expect(firstResult.title == "Echo")
    #expect(secondResult.title == "Echo 2")
    #expect(harness.workspace.agentSessions.map(\.title) == ["Echo", "Echo 2"])
}

@MainActor
@Test func controlServerRejectsUnknownAndDisabledAgents() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }

    try harness.settings.upsertAgent(AgentToolDefinition(name: "Claude", command: "claude", enabled: false))
    harness.server.start()

    let missingResponse = try await harness.send(.runAgent(.init(agentName: "Codex")))
    #expect(missingResponse.error?.code == "agent_not_found")

    let disabledResponse = try await harness.send(.runAgent(.init(agentName: "Claude")))
    #expect(disabledResponse.error?.code == "agent_not_launchable")
}

@MainActor
@Test func terminalSessionCapturesAndClearsRawOutput() async throws {
    let session = TerminalSession(
        title: "Test",
        subtitle: "No shell",
        tint: .systemGreen,
        launchShell: false
    )

    session.ingestTestingData(Data("hello\u{1B}[31m raw".utf8))

    let output = session.rawOutput(maxBytes: 1024)
    #expect(String(decoding: output.data, as: UTF8.self) == "hello\u{1B}[31m raw")
    #expect(output.truncated == false)

    let truncated = session.rawOutput(maxBytes: 4)
    #expect(String(decoding: truncated.data, as: UTF8.self) == " raw")
    #expect(truncated.truncated == true)

    session.clearScrollback()
    #expect(session.rawOutput(maxBytes: 1024).data.isEmpty)
}

@MainActor
@Test func terminalSessionMetadataFollowsOSCSequences() async throws {
    let session = TerminalSession(
        title: "Shell 1",
        subtitle: "No shell",
        tint: .systemGreen,
        launchShell: false
    )

    session.ingestTestingData(Data("\u{1B}]2;vim README.md\u{7}".utf8))
    #expect(session.title == "vim README.md")

    session.ingestTestingData(Data("\u{1B}]7;file://localhost/tmp/cherry\u{7}".utf8))
    #expect(session.workingDirectory == "/tmp/cherry")

    session.ingestTestingData(Data("\u{1B}]7;kitty-shell-cwd://localhost/tmp/cherry/kitty\u{7}".utf8))
    #expect(session.workingDirectory == "/tmp/cherry/kitty")

    session.ingestTestingData(Data("\u{1B}]7;kitty-shell-cwd://example.com/tmp/cherry/remote\u{7}".utf8))
    #expect(session.workingDirectory == "/tmp/cherry/kitty")

    session.ingestTestingData(Data("\u{1B}]7;/tmp/cherry/raw\u{7}".utf8))
    #expect(session.workingDirectory == "/tmp/cherry/kitty")
}

@MainActor
@Test func agentSessionIgnoresTitleMetadata() async throws {
    let session = TerminalSession(
        title: "Codex",
        subtitle: "No shell",
        tint: .systemGreen,
        launchShell: false,
        kind: .agent,
        agentName: "Codex"
    )

    session.ingestTestingData(Data("\u{1B}]2;~/github/patrick91/cherry\u{7}".utf8))
    session.ingestTestingData(Data("\u{1B}]7;file://localhost/tmp/cherry\u{7}".utf8))

    #expect(session.title == "Codex")
    #expect(session.workingDirectory == "/tmp/cherry")
}

@MainActor
@Test func terminalSessionTracksEnhancedKeyboardProtocol() async throws {
    let session = TerminalSession(
        title: "Shell 1",
        subtitle: "No shell",
        tint: .systemGreen,
        launchShell: false
    )

    session.ingestTestingData(Data("\u{1B}[>7u".utf8))
    #expect(session.isEnhancedKeyboardProtocolActive == true)

    session.ingestTestingData(Data("\u{1B}[<u".utf8))
    #expect(session.isEnhancedKeyboardProtocolActive == false)

    session.ingestTestingData(Data("\u{1B}[=1u".utf8))
    #expect(session.isEnhancedKeyboardProtocolActive == true)

    session.ingestTestingData(Data("\u{1B}[=0u".utf8))
    #expect(session.isEnhancedKeyboardProtocolActive == false)
}

@Test func tabInputIsOnlyRewrittenForEnhancedKeyboardProtocol() async throws {
    let tab = Data([0x09])
    let enter = Data("\r".utf8)
    let encodedTab = Data("\u{1B}[9u".utf8)

    #expect(TerminalInputNormalizer.normalize(tab, isEnhancedKeyboardProtocolActive: false) == tab)
    #expect(TerminalInputNormalizer.normalize(tab, isEnhancedKeyboardProtocolActive: true) == encodedTab)
    #expect(TerminalInputNormalizer.normalize(enter, isEnhancedKeyboardProtocolActive: true) == enter)
}

@Test func shiftEnterUsesEnhancedKeyboardProtocolWhenActive() async throws {
    let shift = NSEvent.ModifierFlags.shift
    let commandShift: NSEvent.ModifierFlags = [.command, .shift]

    #expect(TerminalInputEncoder.shiftEnterSequence(
        keyCode: 36,
        modifiers: shift,
        isEnhancedKeyboardProtocolActive: false
    ) == Data("\r".utf8))
    #expect(TerminalInputEncoder.shiftEnterSequence(
        keyCode: 76,
        modifiers: shift,
        isEnhancedKeyboardProtocolActive: true
    ) == Data("\u{1B}[13;2u".utf8))
    #expect(TerminalInputEncoder.shiftEnterSequence(
        keyCode: 36,
        modifiers: commandShift,
        isEnhancedKeyboardProtocolActive: true
    ) == nil)
}

@MainActor
@Test func workspaceCanCreateBackgroundSession() async throws {
    let workspace = TerminalWorkspace()
    let initialSelection = workspace.selectedSessionID

    let session = workspace.addSession(title: "Background", select: false)

    #expect(workspace.selectedSessionID == initialSelection)
    #expect(workspace.sessions.contains(where: { $0.id == session.id }))
}

@MainActor
@Test func workspaceCanReorderSessions() async throws {
    let workspace = TerminalWorkspace()
    defer {
        workspace.sessions.forEach { $0.stop() }
    }

    let firstSession = try #require(workspace.sessions.first)
    let secondSession = workspace.addSession(title: "Second")
    let thirdSession = workspace.addSession(title: "Third")

    workspace.moveSession(id: thirdSession.id, to: 0)

    #expect(workspace.sessions.map(\.id) == [thirdSession.id, firstSession.id, secondSession.id])

    workspace.moveSession(id: thirdSession.id, to: 99)

    #expect(workspace.sessions.map(\.id) == [firstSession.id, secondSession.id, thirdSession.id])
}

@MainActor
@Test func workspaceShortcutSelectionFollowsSidebarOrder() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let workspace = TerminalWorkspace(projectRoot: directory.path)
    defer {
        workspace.sessions.forEach { $0.stop() }
    }

    let firstTerminal = try #require(workspace.terminalSessions.first)
    let secondTerminal = workspace.addSession(title: "Second", select: false)
    let firstAgent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: "/bin/cat"),
        projectRoot: directory.path,
        select: false
    )
    let secondAgent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "/bin/cat"),
        projectRoot: directory.path,
        select: false
    )
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "Web", command: "/bin/cat"),
        projectRoot: directory.path,
        select: false
    )

    #expect(workspace.sessions.map(\.id) == [
        firstTerminal.id,
        secondTerminal.id,
        firstAgent.id,
        secondAgent.id,
        command.id
    ])
    #expect(workspace.sidebarOrderedSessions.map(\.id) == [
        firstAgent.id,
        secondAgent.id,
        firstTerminal.id,
        secondTerminal.id,
        command.id
    ])

    workspace.select(firstAgent)
    workspace.selectNextSession()
    #expect(workspace.selectedSessionID == secondAgent.id)

    workspace.selectNextSession()
    #expect(workspace.selectedSessionID == firstTerminal.id)

    workspace.selectNextSession()
    #expect(workspace.selectedSessionID == secondTerminal.id)

    workspace.selectNextSession()
    #expect(workspace.selectedSessionID == command.id)

    workspace.selectNextSession()
    #expect(workspace.selectedSessionID == firstAgent.id)

    workspace.selectPreviousSession()
    #expect(workspace.selectedSessionID == command.id)
}

@Test func agentDefinitionsValidateAndNormalize() async throws {
    let agents = try AgentConfiguration.validated([
        AgentToolDefinition(name: " Codex ", command: " codex ", arguments: " --yolo ", enabled: true),
        AgentToolDefinition(name: "Claude", command: "claude")
    ])

    #expect(agents == [
        AgentToolDefinition(name: "Codex", command: "codex", arguments: "--yolo", enabled: true),
        AgentToolDefinition(name: "Claude", command: "claude", arguments: "", enabled: true)
    ])
}

@Test func agentDefinitionsRejectDuplicateNames() async throws {
    #expect(throws: AgentConfigurationError.duplicateName("codex")) {
        try AgentConfiguration.validated([
            AgentToolDefinition(name: "Codex", command: "codex"),
            AgentToolDefinition(name: " codex ", command: "other")
        ])
    }
}

@Test func projectCommandDefinitionsValidateAndNormalize() async throws {
    let commands = try ProjectCommandConfiguration.validated([
        ProjectCommandDefinition(name: " Web ", command: " npm ", arguments: " run dev ", enabled: true),
        ProjectCommandDefinition(name: "API", command: "uvicorn", arguments: "main:app")
    ])

    #expect(commands == [
        ProjectCommandDefinition(name: "Web", command: "npm", arguments: "run dev", enabled: true),
        ProjectCommandDefinition(name: "API", command: "uvicorn", arguments: "main:app", enabled: true)
    ])
}

@Test func projectCommandDefinitionsRejectDuplicateNames() async throws {
    #expect(throws: ProjectCommandConfigurationError.duplicateName("web")) {
        try ProjectCommandConfiguration.validated([
            ProjectCommandDefinition(name: "Web", command: "npm"),
            ProjectCommandDefinition(name: " web ", command: "pnpm")
        ])
    }
}

@MainActor
@Test func agentSettingsPersistGlobalAgentsAcrossProjects() async throws {
    let defaultsName = "CherryTests.AgentSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer {
        defaults.removePersistentDomain(forName: defaultsName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let settings = AgentSettings(defaults: defaults)
    settings.addProject(path: directory.path)
    try settings.upsertAgent(AgentToolDefinition(name: "Codex", command: "codex", arguments: "--yolo"))

    let project = settings.resolvedProject(for: directory.path)
    #expect(project.agents.count == 1)
    #expect(project.agents[0].source == .global)
    #expect(project.agents[0].isLaunchable == true)

    let reloadedSettings = AgentSettings(defaults: defaults)
    #expect(reloadedSettings.agents == [
        AgentToolDefinition(name: "Codex", command: "codex", arguments: "--yolo")
    ])
    #expect(reloadedSettings.resolvedProject(for: directory.path).agents == project.agents)
}

@MainActor
@Test func agentSettingsPersistProjectCommandsPerProject() async throws {
    let defaultsName = "CherryTests.ProjectCommands.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer {
        defaults.removePersistentDomain(forName: defaultsName)
    }

    let firstDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let secondDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: firstDirectory)
        try? FileManager.default.removeItem(at: secondDirectory)
    }

    let settings = AgentSettings(defaults: defaults)
    settings.addProject(path: firstDirectory.path)
    settings.addProject(path: secondDirectory.path)
    try settings.upsertCommand(
        ProjectCommandDefinition(
            name: "Web",
            command: "npm",
            arguments: "run dev",
            workingDirectory: firstDirectory.path,
            autoStart: true,
            autoRestart: true
        ),
        for: firstDirectory.path
    )
    try settings.upsertCommand(
        ProjectCommandDefinition(name: "API", command: "uvicorn", arguments: "main:app"),
        for: secondDirectory.path
    )

    let reloadedSettings = AgentSettings(defaults: defaults)
    #expect(reloadedSettings.projectCommands(for: firstDirectory.path) == [
        ProjectCommandDefinition(
            name: "Web",
            command: "npm",
            arguments: "run dev",
            workingDirectory: firstDirectory.path,
            autoStart: true,
            autoRestart: true
        )
    ])
    #expect(reloadedSettings.projectCommands(for: secondDirectory.path) == [
        ProjectCommandDefinition(name: "API", command: "uvicorn", arguments: "main:app")
    ])
    #expect(reloadedSettings.launchableProjectCommands(for: firstDirectory.path).map(\.name) == ["Web"])
}

@MainActor
@Test func agentSettingsCanStoreProjectCommandsInCherryToml() async throws {
    let defaultsName = "CherryTests.ProjectFileCommands.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer {
        defaults.removePersistentDomain(forName: defaultsName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let configURL = directory.appendingPathComponent("cherry.toml")
    try "# Existing config\n[project]\nname = \"Demo\"\n".write(to: configURL, atomically: true, encoding: .utf8)

    let settings = AgentSettings(defaults: defaults)
    settings.addProject(path: directory.path)
    try settings.upsertCommand(
        ProjectCommandDefinition(
            name: "Web",
            command: "npm",
            arguments: "run dev",
            autoStart: true,
            autoRestart: true
        ),
        for: directory.path,
        storage: .projectFile
    )

    let contents = try String(contentsOf: configURL, encoding: .utf8)
    #expect(contents.contains("[project]"))
    #expect(contents.contains("[[commands]]"))
    #expect(contents.contains("name = \"Web\""))

    let reloadedSettings = AgentSettings(defaults: defaults)
    #expect(reloadedSettings.projectCommands(for: directory.path) == [
        ProjectCommandDefinition(
            name: "Web",
            command: "npm",
            arguments: "run dev",
            autoStart: true,
            autoRestart: true
        )
    ])

    reloadedSettings.removeCommand(named: "Web", for: directory.path)
    let removedContents = try String(contentsOf: configURL, encoding: .utf8)
    #expect(removedContents.contains("[project]"))
    #expect(!removedContents.contains("[[commands]]"))
}

@MainActor
@Test func agentSettingsCanAddProjectsWithoutGlobalSelection() async throws {
    let defaultsName = "CherryTests.Projects.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer {
        defaults.removePersistentDomain(forName: defaultsName)
    }

    let firstDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let secondDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: firstDirectory)
        try? FileManager.default.removeItem(at: secondDirectory)
    }

    let settings = AgentSettings(defaults: defaults)
    settings.addProject(path: firstDirectory.path)
    settings.addProject(path: secondDirectory.path)

    #expect(settings.projects.map(\.root) == [firstDirectory.path, secondDirectory.path])

    let reloadedSettings = AgentSettings(defaults: defaults)

    #expect(reloadedSettings.projects.map(\.root) == [firstDirectory.path, secondDirectory.path])
    #expect(reloadedSettings.projectRoot(for: nil) == firstDirectory.path)
    #expect(reloadedSettings.resolvedProject(for: firstDirectory.path).validProjectRoot == firstDirectory.path)
    #expect(reloadedSettings.resolvedProject(for: secondDirectory.path).validProjectRoot == secondDirectory.path)
}

@MainActor
@Test func workspaceCanCreateAgentSession() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let workspace = TerminalWorkspace()
    defer {
        workspace.sessions.forEach { $0.stop() }
    }

    let session = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: "codex", arguments: "--yolo"),
        projectRoot: directory.path
    )

    #expect(session.kind == .agent)
    #expect(session.agentName == "Codex")
    #expect(session.title == "Codex")
    #expect(session.subtitle == "codex --yolo")
    #expect(session.workingDirectory == directory.path)
    #expect(workspace.agentSessions.map(\.id) == [session.id])

    let secondSession = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: "codex", arguments: "--yolo"),
        projectRoot: directory.path
    )

    #expect(secondSession.kind == .agent)
    #expect(secondSession.agentName == "Codex")
    #expect(secondSession.title == "Codex 2")
    #expect(workspace.agentSessions.map(\.id) == [session.id, secondSession.id])
}

@MainActor
@Test func workspaceCanCreateCommandSession() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let workspace = TerminalWorkspace(projectRoot: directory.path)
    defer {
        workspace.sessions.forEach { $0.stop() }
    }

    let customDirectory = directory.appendingPathComponent("web", isDirectory: true)
    try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)

    let session = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "Web", command: "/bin/cat", workingDirectory: customDirectory.path),
        projectRoot: directory.path
    )
    let duplicate = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: " web ", command: "/bin/cat"),
        projectRoot: directory.path
    )

    #expect(session.id == duplicate.id)
    #expect(session.kind == .command)
    #expect(session.commandName == "Web")
    #expect(session.title == "Web")
    #expect(session.subtitle == "/bin/cat")
    #expect(session.workingDirectory == customDirectory.path)
    #expect(workspace.commandSessions.map(\.id) == [session.id])
    #expect(workspace.commandSession(named: "web")?.id == session.id)

    session.stopManagedCommand()
    if case .exited(let status) = session.state {
        #expect(status == 0)
    } else {
        Issue.record("Expected stopped command session to be exited")
    }
}

@MainActor
@Test func workspaceUpdatesExistingCommandSessionAfterRename() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let workspace = TerminalWorkspace(projectRoot: directory.path)
    defer {
        workspace.sessions.forEach { $0.stop() }
    }

    let session = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "Tree", command: "/bin/cat"),
        projectRoot: directory.path
    )
    workspace.select(session)

    let renamedCommand = ProjectCommandDefinition(
        name: "Tree App",
        command: "/bin/echo",
        arguments: "ok"
    )
    workspace.updateCommandSession(
        named: "Tree",
        with: renamedCommand,
        projectRoot: directory.path
    )

    #expect(workspace.selectedSessionID == session.id)
    #expect(workspace.commandSession(named: "Tree") == nil)
    #expect(workspace.commandSession(named: "Tree App")?.id == session.id)
    #expect(session.title == "Tree App")
    #expect(session.subtitle == "/bin/echo ok")
}

@MainActor
@Test func agentSessionExecsCommandAndKeepsFinalOutput() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let workspace = TerminalWorkspace(projectRoot: directory.path)
    defer {
        workspace.sessions.forEach { $0.stop() }
    }

    let session = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Echo", command: "/bin/echo", arguments: "agent-done"),
        projectRoot: directory.path
    )

    try await waitForExit(session)

    let output = session.snapshot(range: 0..<session.lineCount).joined(separator: "\n")
    let rawOutput = String(decoding: session.rawOutput(maxBytes: 1024).data, as: UTF8.self)
    #expect(workspace.selectedSessionID == session.id)
    #expect(session.kind == .agent)
    #expect(output.contains("agent-done"))
    #expect(!output.contains("exec /bin/echo agent-done"))
    #expect(!output.contains("[agent exited with status 0]"))
    #expect(rawOutput.contains("agent-done"))
    #expect(!rawOutput.contains("exec /bin/echo agent-done"))
    #expect(!rawOutput.contains("[agent exited with status 0]"))
    #expect(session.cursorState.isVisible == false)
}

@MainActor
private func waitForExit(_ session: TerminalSession) async throws {
    for _ in 0..<300 {
        if case .exited = session.state {
            return
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("Timed out waiting for session to exit")
}

@MainActor
private final class ControlServerHarness {
    let defaultsName: String
    let defaults: UserDefaults
    let settings: AgentSettings
    let projectRoot: URL
    let workspace: TerminalWorkspace
    let socketURL: URL
    let server: CherryControlServer

    init() throws {
        defaultsName = "CherryTests.ControlServer.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))

        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let socketDirectory = URL(
            fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        socketURL = socketDirectory.appendingPathComponent("control.sock")

        settings = AgentSettings(defaults: defaults)
        _ = settings.addProject(path: projectRoot.path)
        workspace = TerminalWorkspace(projectRoot: projectRoot.path)
        server = CherryControlServer(workspace: workspace, socketURL: socketURL, agentSettings: settings)
    }

    func send(_ request: CherryControlRequest) async throws -> CherryControlResponse {
        try await Self.send(request, socketURL: socketURL)
    }

    func stop() {
        server.stop()
        workspace.sessions.forEach { $0.stop() }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: projectRoot)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }

    nonisolated private static func send(
        _ request: CherryControlRequest,
        socketURL: URL
    ) async throws -> CherryControlResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try CherryControlClient(socketURL: socketURL).send(request)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
@Test func newSessionInheritsSelectedSessionWorkingDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let workspace = TerminalWorkspace()
    let selectedSession = workspace.addSession(workingDirectory: directory.path)

    let inheritedSession = workspace.addSession()

    #expect(selectedSession.workingDirectory == directory.path)
    #expect(inheritedSession.workingDirectory == directory.path)
    #expect(inheritedSession.launchWorkingDirectory == directory.path)
}

@MainActor
@Test func explicitWorkingDirectoryOverridesSelectedSessionDirectory() async throws {
    let selectedDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let requestedDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: requestedDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: selectedDirectory)
        try? FileManager.default.removeItem(at: requestedDirectory)
    }

    let workspace = TerminalWorkspace()
    _ = workspace.addSession(workingDirectory: selectedDirectory.path)

    let explicitSession = workspace.addSession(workingDirectory: requestedDirectory.path)

    #expect(explicitSession.workingDirectory == requestedDirectory.path)
    #expect(explicitSession.launchWorkingDirectory == requestedDirectory.path)
}

@Test func zshShellIntegrationBootstrapInstallsTitleHooks() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let bootstrap = try #require(try ShellIntegrationBootstrap.prepare(
        shellPath: "/bin/zsh",
        homeDirectory: temporaryDirectory
    ))

    let integrationURL = URL(fileURLWithPath: bootstrap.zdotdir)
        .appendingPathComponent("cherry-integration.zsh")
    let integration = try String(contentsOf: integrationURL, encoding: .utf8)

    #expect(integration.contains("add-zsh-hook preexec _cherry_preexec"))
    #expect(integration.contains("add-zsh-hook chpwd _cherry_set_working_directory"))
    #expect(integration.contains("add-zsh-hook precmd _cherry_precmd"))
    #expect(integration.contains("\\e]2;"))
    #expect(integration.contains("\\e]7;"))
    #expect(integration.contains("kitty-shell-cwd://"))
    #expect(integration.contains("_cherry_set_working_directory"))

    let syntaxCheck = Process()
    syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/zsh")
    syntaxCheck.arguments = ["-n", integrationURL.path]
    try syntaxCheck.run()
    syntaxCheck.waitUntilExit()
    #expect(syntaxCheck.terminationStatus == 0)

    let zshrcURL = URL(fileURLWithPath: bootstrap.zdotdir).appendingPathComponent(".zshrc")
    let zshrc = try String(contentsOf: zshrcURL, encoding: .utf8)

    #expect(zshrc.contains("source \"${CHERRY_BOOTSTRAP_ZDOTDIR}/cherry-integration.zsh\""))
    #expect(zshrc.contains("CHERRY_ORIGINAL_ZDOTDIR"))
}

@Test func zshStartupCommandRunsAfterUserZshrcAliasesLoad() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let userZdotdir = temporaryDirectory.appendingPathComponent("user-zdotdir", isDirectory: true)
    try FileManager.default.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
    try "alias cherryalias='echo cherry-alias-expanded'\n"
        .write(to: userZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    let bootstrap = try #require(try ShellIntegrationBootstrap.prepare(
        shellPath: "/bin/zsh",
        homeDirectory: temporaryDirectory
    ))

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-l", "-i"]
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.environment = [
        "CHERRY_BOOTSTRAP_ZDOTDIR": bootstrap.zdotdir,
        "CHERRY_ORIGINAL_ZDOTDIR": userZdotdir.path,
        "CHERRY_STARTUP_COMMAND": "cherryalias",
        "HOME": temporaryDirectory.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "ZDOTDIR": bootstrap.zdotdir
    ]

    try process.run()
    process.waitUntilExit()

    let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0)
    #expect(output.contains("cherry-alias-expanded"), Comment(rawValue: errorOutput))
}

@Test func scrollbackIsBounded() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: 3)
    buffer.appendPlainLines(["one", "two", "three", "four"])

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["two", "three", "four"])
}

@Test func pagedScrollbackStoresLinesAcrossPageBoundaries() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines((0..<300).map { "line-\($0)" })

    #expect(buffer.lineCount == 300)
    #expect(buffer.snapshot(range: 254..<258) == ["line-254", "line-255", "line-256", "line-257"])
}

@Test func pagedScrollbackTrimsAcrossPageBoundaries() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: 260)
    buffer.appendPlainLines((0..<300).map { "line-\($0)" })

    #expect(buffer.lineCount == 260)
    #expect(buffer.snapshot(range: 0..<3) == ["line-40", "line-41", "line-42"])
}

@Test func ansiForegroundColorIsPreserved() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("\u{1B}[32mhello\u{1B}[0m world".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["hello world"])
    let styled = buffer.styledSnapshot(range: 0..<buffer.lineCount)
    #expect(styled.count == 1)
    #expect(styled[0].runs.count == 2)
    #expect(styled[0].runs[0] == TerminalTextRun(text: "hello", style: TerminalTextStyle(foreground: .ansi16(2))))
    #expect(styled[0].runs[1] == TerminalTextRun(text: " world", style: TerminalTextStyle()))
}

@Test func ansiBackgroundColorIsPreserved() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("\u{1B}[48;5;236mhello\u{1B}[49m world".utf8))

    let styled = buffer.styledSnapshot(range: 0..<buffer.lineCount)

    #expect(styled[0].runs[0] == TerminalTextRun(
        text: "hello",
        style: TerminalTextStyle(background: .palette256(236))
    ))
    #expect(styled[0].runs[1] == TerminalTextRun(text: " world", style: TerminalTextStyle()))
}

@Test func colonSeparatedBackgroundColorIsPreserved() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("\u{1B}[48:5:236;38:5:250mhello\u{1B}[0m".utf8))

    let styled = buffer.styledSnapshot(range: 0..<buffer.lineCount)

    #expect(styled[0].runs == [
        TerminalTextRun(
            text: "hello",
            style: TerminalTextStyle(foreground: .palette256(250), background: .palette256(236))
        )
    ])
}

@Test func colonSeparatedTruecolorBackgroundIgnoresColorSpace() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("\u{1B}[48:2::49:48:55mempty\u{1B}[0m ".utf8))
    buffer.ingest(Data("\u{1B}[48:2:0:49:48:55mzero\u{1B}[0m".utf8))

    let styled = buffer.styledSnapshot(range: 0..<buffer.lineCount)

    #expect(styled[0].runs == [
        TerminalTextRun(
            text: "empty",
            style: TerminalTextStyle(background: .rgb(49, 48, 55))
        ),
        TerminalTextRun(text: " ", style: TerminalTextStyle()),
        TerminalTextRun(
            text: "zero",
            style: TerminalTextStyle(background: .rgb(49, 48, 55))
        )
    ])
}

@Test func eraseLineUsesCurrentBackgroundStyle() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    let viewportSize = TerminalViewportSize(columns: 8, rows: 3)

    buffer.ingest(Data("\u{1B}[48;5;236m\u{1B}[KX".utf8), viewportSize: viewportSize)

    #expect(buffer.lineLength(at: 0) == 8)
    #expect(buffer.styledSnapshot(range: 0..<1)[0].runs == [
        TerminalTextRun(
            text: "X       ",
            style: TerminalTextStyle(background: .palette256(236))
        )
    ])
}

@Test func carriageReturnRewritesTheCurrentLine() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("loading".utf8))
    buffer.ingest(Data("\r\u{1B}[2Kready".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["ready"])
}

@Test func splitUTF8ScalarSurvivesReadBoundary() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data([0xC3]))
    buffer.ingest(Data([0xA9]))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["é"])
}

@Test func nerdFontPrivateUseGlyphsSurviveBuffering() async throws {
    let branchGlyph = String(UnicodeScalar(0xE0A0)!)
    let fileGlyph = String(UnicodeScalar(0xF15B)!)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\(branchGlyph) main \(fileGlyph) README.md".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["\(branchGlyph) main \(fileGlyph) README.md"])
}

@Test func vt100CharsetDesignationDoesNotLeakSelectorBytes() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}(Bplain".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["plain"])
}

@Test func decSpecialGraphicsMapsLineDrawingCharacters() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}(0lqk\r\nx x\r\nmqj\u{1B}(B".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == [
        "┌─┐",
        "│ │",
        "└─┘"
    ])
}

@Test func shiftOutSelectsG1CharsetUntilShiftIn() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B})0\u{0E}q\u{0F}q".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["─q"])
}

@Test func wideEmojiGlyphsOccupyTwoTerminalCells() async throws {
    let upArrow = "\u{2B06}\u{FE0F}"
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("a\(upArrow)b".utf8), viewportSize: TerminalViewportSize(columns: 10, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["a\(upArrow)b"])
    #expect(buffer.lineLength(at: 0) == 4)
    #expect(buffer.cursorState.column == 4)
}

@Test func styledWideGlyphBackgroundTracksCellWidth() async throws {
    let upArrow = "\u{2B06}\u{FE0F}"
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[48;5;236m\(upArrow)\u{1B}[0m".utf8))

    #expect(buffer.styledSnapshot(range: 0..<1)[0].runs == [
        TerminalTextRun(
            text: upArrow,
            style: TerminalTextStyle(background: .palette256(236)),
            cellWidth: 2
        )
    ])
}

@Test func wideGlyphSoftWrapsBeforeRightEdge() async throws {
    let upArrow = "\u{2B06}\u{FE0F}"
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("ab\(upArrow)c".utf8), viewportSize: TerminalViewportSize(columns: 3, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["ab", "\(upArrow)c"])
}

@Test func disabledWraparoundOverwritesRightmostCell() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("abc\u{1B}[?7lXY".utf8), viewportSize: TerminalViewportSize(columns: 3, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["abY"])
    #expect(buffer.cursorState.column == 2)
}

@Test func privateKeyboardModifierSequenceDoesNotChangeTextStyle() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[>4;2mplain".utf8))

    #expect(buffer.styledSnapshot(range: 0..<1)[0].runs == [
        TerminalTextRun(text: "plain", style: TerminalTextStyle())
    ])
}

@Test func repeatPrecedingCharacterRepeatsLastGlyph() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("a\u{1B}[4b".utf8), viewportSize: TerminalViewportSize(columns: 10, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["aaaaa"])
}

@Test func insertCharactersShiftsTextRightWithinRow() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("abcdef\u{1B}[4D\u{1B}[2@".utf8), viewportSize: TerminalViewportSize(columns: 8, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["ab  cdef"])
}

@Test func insertAndDeleteLinesShiftWithinScrollRegion() async throws {
    let viewportSize = TerminalViewportSize(columns: 8, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[?1049ha\r\nb\r\nc\u{1B}[2;1H\u{1B}[L".utf8), viewportSize: viewportSize)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["a", "", "b", "c"])

    buffer.ingest(Data("\u{1B}[2;1H\u{1B}[M".utf8), viewportSize: viewportSize)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["a", "b", "c", ""])
}

@Test func nerdFontFamiliesPreferMonoFonts() async throws {
    let families = [
        "Example Nerd Font",
        "JetBrainsMono Nerd Font Mono",
        "Apple Symbols",
        "CaskaydiaCove Nerd Font Mono"
    ]

    #expect(TerminalFontPalette.preferredNerdFontFamilies(from: families) == [
        "JetBrainsMono Nerd Font Mono",
        "CaskaydiaCove Nerd Font Mono",
        "Example Nerd Font"
    ])
}

@Test func outputSoftWrapsAtViewportWidth() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("abcdef".utf8), viewportSize: TerminalViewportSize(columns: 3, rows: 10))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["abc", "def"])
}

@Test func selectedTextOmitsNewlineAcrossSoftWrap() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("abcdef".utf8), viewportSize: TerminalViewportSize(columns: 3, rows: 10))
    let selection = TerminalSelectionRange(
        anchor: buffer.gridPoint(row: 0, column: 0),
        extent: buffer.gridPoint(row: 1, column: 3)
    )

    #expect(buffer.selectedText(in: selection) == "abcdef")
}

@Test func cursorPositionReportRespondsToDeviceStatusRequest() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    let viewportSize = TerminalViewportSize(columns: 10, rows: 5)
    buffer.ingest(Data("abc\r\nxy".utf8), viewportSize: viewportSize)

    let responses = buffer.ingest(Data("\u{1B}[6n".utf8), viewportSize: viewportSize)

    #expect(responses == [Data("\u{1B}[2;3R".utf8)])
}

@Test func terminalPaletteQueriesRespondWithDefaultColors() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    let responses = buffer.ingest(Data("\u{1B}]10;?\u{07}\u{1B}]11;?\u{1B}\\".utf8))

    #expect(responses == [
        Data("\u{1B}]10;rgb:dbdb/e3e3/ebeb\u{07}".utf8),
        Data("\u{1B}]11;rgb:1212/1111/1717\u{07}".utf8)
    ])
}

@Test func deviceAttributesAndKeyboardProtocolQueriesRespond() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    let startupProbe =
        "\u{1B}[?2004h" +
        "\u{1B}[>7u" +
        "\u{1B}[?1004h" +
        "\u{1B}[?u" +
        "\u{1B}[c" +
        "\u{1B}[>c"
    let responses = buffer.ingest(Data(startupProbe.utf8))

    #expect(responses == [
        Data("\u{1B}[?0u".utf8),
        Data("\u{1B}[?1;2c".utf8),
        Data("\u{1B}[>0;0;0c".utf8)
    ])
}

@Test func cursorStateTracksWritesAndMovement() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("abc\u{1B}[D".utf8), viewportSize: TerminalViewportSize(columns: 10, rows: 5))

    #expect(buffer.cursorState == TerminalCursorState(row: 0, column: 2, shape: .block, isVisible: true))
}

@Test func cursorShapeAndVisibilityFollowControlSequences() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[5 q\u{1B}[?25l".utf8))
    #expect(buffer.cursorState == TerminalCursorState(row: 0, column: 0, shape: .bar, isVisible: false))

    buffer.ingest(Data("\u{1B}[4 q\u{1B}[?25h".utf8))
    #expect(buffer.cursorState == TerminalCursorState(row: 0, column: 0, shape: .underline, isVisible: true))

    buffer.ingest(Data("\u{1B}[2 q".utf8))
    #expect(buffer.cursorState.shape == .block)
}

@Test func terminalTracksMouseAndAlternateScrollModes() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?1007l\u{1B}[?1004h".utf8))

    #expect(buffer.usesAlternateScreen)
    #expect(buffer.mouseState == TerminalMouseState(
        trackingMode: .normal,
        usesSGREncoding: true,
        alternateScrollMode: false,
        sendsFocusEvents: true
    ))
}

@Test func terminalTracksApplicationCursorKeyMode() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[?1h".utf8))
    #expect(buffer.usesApplicationCursorKeys)

    buffer.ingest(Data("\u{1B}[?1l".utf8))
    #expect(!buffer.usesApplicationCursorKeys)
}

@Test func alternateScreenScrollWheelProducesCursorKeys() async throws {
    var remainder: CGFloat = 0

    let sequence = TerminalInputEncoder.alternateScreenScrollSequence(
        deltaY: 20,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        remainder: &remainder
    )

    #expect(sequence == Data("\u{1B}[A\u{1B}[A\u{1B}[A".utf8))
}

@Test func preciseScrollAccumulatesByPartialTerminalCells() async throws {
    var remainder: CGFloat = 0

    let firstSequence = TerminalInputEncoder.alternateScreenScrollSequence(
        deltaY: 10,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        remainder: &remainder
    )
    let secondSequence = TerminalInputEncoder.alternateScreenScrollSequence(
        deltaY: 10,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        remainder: &remainder
    )

    #expect(firstSequence == Data("\u{1B}[A".utf8))
    #expect(secondSequence == Data("\u{1B}[A\u{1B}[A".utf8))
}

@Test func sgrMouseWheelProducesTerminalMouseEvents() async throws {
    var remainder: CGFloat = 0

    let sequence = TerminalInputEncoder.mouseWheelSequence(
        deltaY: -20,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        column: 5,
        row: 3,
        mouseState: TerminalMouseState(trackingMode: .normal, usesSGREncoding: true),
        remainder: &remainder
    )

    #expect(sequence == Data("\u{1B}[<65;5;3M\u{1B}[<65;5;3M\u{1B}[<65;5;3M".utf8))
}

@Test func decPrivateModeStatusReportsCurrentAndUnsupportedModes() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    let responses = buffer.ingest(Data((
        "\u{1B}[?1h" +
        "\u{1B}[?25l" +
        "\u{1B}[?69h" +
        "\u{1B}[?1004h" +
        "\u{1B}[?2004h" +
        "\u{1B}[?1$p" +
        "\u{1B}[?25$p" +
        "\u{1B}[?69$p" +
        "\u{1B}[?1004$p" +
        "\u{1B}[?2004$p" +
        "\u{1B}[?2026$p"
    ).utf8))

    #expect(responses == [
        Data("\u{1B}[?1;1$y".utf8),
        Data("\u{1B}[?25;2$y".utf8),
        Data("\u{1B}[?69;1$y".utf8),
        Data("\u{1B}[?1004;1$y".utf8),
        Data("\u{1B}[?2004;1$y".utf8),
        Data("\u{1B}[?2026;4$y".utf8)
    ])
}

@Test func horizontalMarginCommandDoesNotOverwriteSavedCursor() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[sabc\u{1B}[2;5H\u{1B}[?69h\u{1B}[3;8s\u{1B}[uX".utf8))

    #expect(buffer.snapshot(range: 0..<1) == ["Xbc"])
}

@Test func terminalMousePositionUsesVisibleViewportCoordinates() async throws {
    let position = TerminalInputEncoder.mousePosition(
        documentLocation: NSPoint(x: 22 + 4.5 * 8, y: 900 + 24 + 2.5 * 20),
        visibleOrigin: NSPoint(x: 0, y: 900),
        viewportSize: TerminalViewportSize(columns: 80, rows: 24),
        sideInset: 22,
        topInset: 24,
        cellWidth: 8,
        lineHeight: 20
    )

    #expect(position.column == 5)
    #expect(position.row == 3)
}

@Test func viewportScrollOffsetClampsAtDocumentEdges() async throws {
    let contentHeight: CGFloat = 1_000
    let viewportHeight: CGFloat = 400

    #expect(TerminalInputEncoder.clampedViewportOffset(
        currentOffset: 4,
        deltaY: 20,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        documentHeight: contentHeight,
        viewportHeight: viewportHeight
    ) == 0)
    #expect(TerminalInputEncoder.clampedViewportOffset(
        currentOffset: 590,
        deltaY: -20,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        documentHeight: contentHeight,
        viewportHeight: viewportHeight
    ) == 600)
}

@Test func terminalEnterSendsCarriageReturn() async throws {
    let enter = TerminalInputEncoder.commandSequence(for: #selector(NSResponder.insertNewline(_:)))

    #expect(enter == Data("\r".utf8))
}

@Test func terminalArrowKeysFollowApplicationCursorMode() async throws {
    let normalUp = TerminalInputEncoder.commandSequence(for: #selector(NSResponder.moveUp(_:)))
    let applicationUp = TerminalInputEncoder.commandSequence(
        for: #selector(NSResponder.moveUp(_:)),
        usesApplicationCursorKeys: true
    )

    #expect(normalUp == Data("\u{1B}[A".utf8))
    #expect(applicationUp == Data("\u{1B}OA".utf8))
    #expect(TerminalInputEncoder.cursorKeySequence(.down, usesApplicationCursorKeys: true) == "\u{1B}OB")
    #expect(TerminalInputEncoder.cursorKeySequence(.right, usesApplicationCursorKeys: true) == "\u{1B}OC")
    #expect(TerminalInputEncoder.cursorKeySequence(.left, usesApplicationCursorKeys: true) == "\u{1B}OD")
}

@Test func terminalInsertedTextIgnoresAppKitFunctionKeyCharacters() async throws {
    #expect(TerminalInputEncoder.insertedTextData(String(UnicodeScalar(NSUpArrowFunctionKey)!)) == nil)
    #expect(TerminalInputEncoder.insertedTextData("a") == Data("a".utf8))
}

@Test func appKitArrowFastPathUsesApplicationCursorMode() async throws {
    let normal = TerminalInputEncoder.appKitUnmodifiedArrowSequence(
        keyCode: 0x7D,
        modifiers: [],
        usesApplicationCursorKeys: false
    )
    let application = TerminalInputEncoder.appKitUnmodifiedArrowSequence(
        keyCode: 0x7D,
        modifiers: [],
        usesApplicationCursorKeys: true
    )
    let modified = TerminalInputEncoder.appKitUnmodifiedArrowSequence(
        keyCode: 0x7D,
        modifiers: .shift,
        usesApplicationCursorKeys: true
    )
    let appKitArrowFlags = TerminalInputEncoder.appKitUnmodifiedArrowSequence(
        keyCode: 0x7D,
        modifiers: [.numericPad, .function],
        usesApplicationCursorKeys: true
    )

    #expect(normal == Data("\u{1B}[B".utf8))
    #expect(application == Data("\u{1B}OB".utf8))
    #expect(modified == nil)
    #expect(appKitArrowFlags == Data("\u{1B}OB".utf8))
}

@Test func appKitOptionArrowsPreserveOptionModifier() async throws {
    #expect(TerminalInputEncoder.appKitOptionArrowSequence(
        keyCode: 0x7E,
        modifiers: .option
    ) == Data("\u{1B}[1;3A".utf8))
    #expect(TerminalInputEncoder.appKitOptionArrowSequence(
        keyCode: 0x7D,
        modifiers: .option
    ) == Data("\u{1B}[1;3B".utf8))
    #expect(TerminalInputEncoder.appKitOptionArrowSequence(
        keyCode: 0x7C,
        modifiers: .option
    ) == Data("\u{1B}[1;3C".utf8))
    #expect(TerminalInputEncoder.appKitOptionArrowSequence(
        keyCode: 0x7B,
        modifiers: .option
    ) == Data("\u{1B}[1;3D".utf8))
    #expect(TerminalInputEncoder.appKitOptionArrowSequence(
        keyCode: 0x7B,
        modifiers: [.option, .shift]
    ) == nil)
    #expect(TerminalInputEncoder.appKitUnmodifiedArrowSequence(
        keyCode: 0x7B,
        modifiers: .option,
        usesApplicationCursorKeys: true
    ) == nil)
}

@Test func appKitOptionLeftRightUseShellWordMotionOutsideTUI() async throws {
    #expect(TerminalInputEncoder.appKitOptionArrowSequence(
        keyCode: 0x7C,
        modifiers: .option,
        sendsModifiedArrowKeys: false
    ) == Data("\u{1B}f".utf8))
    #expect(TerminalInputEncoder.appKitOptionArrowSequence(
        keyCode: 0x7B,
        modifiers: .option,
        sendsModifiedArrowKeys: false
    ) == Data("\u{1B}b".utf8))
    #expect(TerminalInputEncoder.appKitOptionArrowSequence(
        keyCode: 0x7E,
        modifiers: .option,
        sendsModifiedArrowKeys: false
    ) == Data("\u{1B}[1;3A".utf8))
}

@Test func pastedTextNormalizesLineEndings() async throws {
    let data = TerminalInputEncoder.pastedTextData("one\r\ntwo\rthree")

    #expect(String(decoding: data, as: UTF8.self) == "one\ntwo\nthree")
}

@Test func selectedTextSpansRows() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("alpha\r\nbravo\r\ncharlie".utf8))
    let selection = TerminalSelectionRange(
        anchor: TerminalGridPoint(row: 0, column: 2),
        extent: TerminalGridPoint(row: 2, column: 4)
    )

    #expect(buffer.selectedText(in: selection) == "pha\nbravo\nchar")
}

@Test func selectedTextHandlesReverseSelection() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("alpha\r\nbravo".utf8))
    let selection = TerminalSelectionRange(
        anchor: TerminalGridPoint(row: 1, column: 3),
        extent: TerminalGridPoint(row: 0, column: 1)
    )

    #expect(buffer.selectedText(in: selection) == "lpha\nbra")
}

@Test func selectedTextAnchorsSurviveScrollbackTrim() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: 260)
    buffer.appendPlainLines((0..<260).map { "line-\($0)" })
    let selection = TerminalSelectionRange(
        anchor: buffer.gridPoint(row: 250, column: 0),
        extent: buffer.gridPoint(row: 251, column: 8)
    )

    buffer.appendPlainLines((260..<300).map { "line-\($0)" })

    #expect(buffer.selectedText(in: selection) == "line-250\nline-251")
}

@Test func alternateScreenDoesNotPolluteScrollback() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["main-1", "main-2"])

    buffer.ingest(Data("\u{1B}[?1049hfull".utf8), viewportSize: viewportSize)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["full", "", "", ""])

    buffer.ingest(Data("\u{1B}[?1049l".utf8), viewportSize: viewportSize)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["main-1", "main-2"])
}

@Test func alternateScreenScrollsWithinViewport() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 3)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[?1049ha\r\nb\r\nc\r\nd".utf8), viewportSize: viewportSize)

    #expect(buffer.lineCount == 3)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["b", "c", "d"])
}

@Test func screenRelativeCursorAddressingPreservesScrollback() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 3)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["old-0", "old-1", "screen-0", "screen-1", "screen-2"])

    buffer.ingest(Data("\u{1B}[1;1HX".utf8), viewportSize: viewportSize)

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == [
        "old-0",
        "old-1",
        "Xcreen-0",
        "screen-1",
        "screen-2"
    ])
}

@Test func scrollRegionScrollsOnlyRegion() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["top", "one", "two", "bottom"])

    buffer.ingest(Data("\u{1B}[2;3r\u{1B}[3;1H\r\n".utf8), viewportSize: viewportSize)

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["top", "two", "", "bottom"])
}

@Test func topAnchoredPrimaryScrollRegionPreservesScrollback() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["one", "two", "three", "status"])

    buffer.ingest(Data("\u{1B}[1;3r\u{1B}[3;1H\r\n".utf8), viewportSize: viewportSize)

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["one", "two", "three", "", "status"])
    #expect(buffer.cursorState.row == 3)
}

@Test func reverseIndexScrollsOnlyRegion() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["top", "one", "two", "bottom"])

    buffer.ingest(Data("\u{1B}[2;3r\u{1B}[2;1H\u{1B}M".utf8), viewportSize: viewportSize)

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["top", "", "one", "bottom"])
}

@Test func cursorUpAndEraseDisplayAllowPromptRepaint() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("top line\r\n> a".utf8))
    buffer.ingest(Data("\r\r\u{1B}[A\u{1B}[Jtop line\r\n> abc".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["top line", "> abc"])
}

@Test func capturedZshPromptRedrawKeepsFullCommand() async throws {
    let prompt = Data(hexEncoded:
        "7e2020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020200d200d1b5d373b6b697474792d7368656c6c2d6377643a2f2f706174626f6f6b2f55736572732f7061747269636b2f6769746875622f7061747269636b39312f636865727279071b5d373b6b697474792d7368656c6c2d6377643a2f2f706174626f6f6b2f55736572732f7061747269636b2f6769746875622f7061747269636b39312f636865727279071b5d323be280a62f6769746875622f7061747269636b39312f636865727279070d1b5b306d1b5b32376d1b5b32346d1b5b4a1b5d3133333b413b636c3d6c696e65071b5b313b33366d7e2f6769746875622f7061747269636b39312f6368657272791b5b306d201b5b313b33356d206d61696e1b5b306d201b5b313b33336d5b21363f335d1b5b306d200d0a1b5b313b33326de29daf1b5b306d201b5d3133333b42071b5b4b1b5b3520711b5b3f3230303468"
    )
    let redraw = Data(hexEncoded:
        "611b5b411b5b306d1b5b32376d1b5b32346d1b5b4a1b5d3133333b413b636c3d6c696e65071b5b313b33366d7e2f6769746875622f7061747269636b39312f6368657272791b5b306d201b5b313b33356d206d61696e1b5b306d201b5b313b33336d5b21363f335d1b5b306d200d0a1b5b313b33326de29daf1b5b306d201b5d3133333b42076162630808081b5b316d1b5b33316d611b5b316d1b5b33316d621b5b316d1b5b33316d631b5b306d1b5b33396d"
    )

    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(prompt)
    buffer.ingest(redraw)

    let snapshot = buffer.snapshot(range: 0..<buffer.lineCount)
    #expect(snapshot.last?.contains("abc") == true)
}

private extension Data {
    init(hexEncoded string: String) {
        self.init()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            let byte = UInt8(string[index..<next], radix: 16)!
            append(byte)
            index = next
        }
    }
}
