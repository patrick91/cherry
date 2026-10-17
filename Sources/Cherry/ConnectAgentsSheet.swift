import AppKit
import CherryControl
import Combine
import Foundation
import SwiftUI

// Connect Agents to Cherry… (the Omni bar, Settings › Agents & MCP › MCP
// server) and Connect This Agent to Cherry… (the Omni bar, for the selected
// agent tab): each CLI's row from its connection model in
// `MCPRegistrations.shared` (so the sheet, an agent's page and Connect This
// Agent say the same), and every button that writes a CLI's settings opens
// `ConnectAgentsConfirmation` first, which alone runs the plan. Reading
// happens when a sheet or page appears and on Check Again, never at launch.

// MARK: - The confirmation

/// A plan (or Connect All's plans) waiting for the user's answer.
struct AgentConnectionRequest: Identifiable {
    let id = UUID()
    let plans: [AgentConnection.Plan]
}

/// "Connect Claude Code to Cherry?": the exact commands Cherry will run, in
/// mono and selectable, what each CLI writes and what it replaces; Connect
/// runs them, Cancel runs nothing.
struct ConnectAgentsConfirmation: View {
    let plans: [AgentConnection.Plan]
    let connect: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AgentConnection.confirmationTitle(plans))
                .font(.title3.weight(.semibold))
            Text(AgentConnection.confirmationLead)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(plans.flatMap(\.displayedCommands).joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            ForEach(Array(AgentConnection.confirmationNotes(plans).enumerated()), id: \.offset) { _, note in
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

extension View {
    /// Shows `request`'s confirmation as a sheet; its Connect clears it and
    /// runs `perform` (the only way a plan runs), its Cancel only clears it.
    func agentConnectionConfirmation(
        _ request: Binding<AgentConnectionRequest?>,
        perform: @escaping @MainActor ([AgentConnection.Plan]) async -> Void
    ) -> some View {
        sheet(item: request) { pending in
            ConnectAgentsConfirmation(
                plans: pending.plans,
                connect: {
                    request.wrappedValue = nil
                    Task { await perform(pending.plans) }
                },
                cancel: { request.wrappedValue = nil }
            )
        }
    }
}

// MARK: - A row's parts

/// A row's buttons: its primary action and its `⋯` menu. Check Again reads
/// again; every other button asks `confirm` about its plan, and runs
/// nothing itself.
struct AgentConnectionActions<Model: AgentConnectionModel>: View {
    @ObservedObject var model: Model
    let row: AgentConnection.Row
    let size: SettingsButtonSize
    let confirm: (AgentConnection.Plan) -> Void

    var body: some View {
        if model.isRunning {
            ProgressView().controlSize(.small)
        }
        if let action = row.primaryAction {
            Button(action.title) { press(action) }
                .settingsButton(.standard, size: size)
                .disabled(model.isRunning || (action.registers && model.plan(for: action) == nil))
                .help(action.registers
                    ? "Shows the command first, and runs it when you confirm."
                    : "Looks for \(model.harness.executableName) and its settings again.")
        }
        if !row.menuActions.isEmpty {
            SettingsMoreMenu("More for \(model.harness.productName)'s connection") {
                ForEach(row.menuActions, id: \.self) { action in
                    Button(action.title) { press(action) }
                        .disabled(model.isRunning || model.plan(for: action) == nil)
                }
            }
        }
    }

    private func press(_ action: AgentConnection.Action) {
        switch AgentConnection.effect(of: action, plan: model.plan(for: action)) {
        case .checkAgain:
            Task { await model.refresh(asksAgain: true) }
        case .confirm(let plan):
            confirm(plan)
        case .unavailable:
            NSSound.beep()
        }
    }
}

/// What a row's state means, what the last run said and, after one that
/// worked, the restart hint; `showsLaunchLine` adds what the agents Cherry
/// starts get.
struct AgentConnectionStatus<Model: AgentConnectionModel>: View {
    @ObservedObject var model: Model
    let row: AgentConnection.Row
    var showsLaunchLine = false

    var body: some View {
        let isConnected = row.style == .ok
        VStack(alignment: .leading, spacing: 4) {
            if let detail = row.detail {
                Label(detail, systemImage: isConnected ? "checkmark.circle.fill" : "info.circle")
                    .font(SettingsDesign.Fonts.help)
                    .foregroundStyle(isConnected ? AnyShapeStyle(SettingsDesign.Colors.okText) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                AgentRegistrationOutput(text: message, failed: model.lastRunFailed)
            }
            if model.lastRunSucceeded {
                Text(AgentConnection.restartHint(model.harness))
                    .font(SettingsDesign.Fonts.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsLaunchLine {
                Text(row.launchLine)
                    .font(SettingsDesign.Fonts.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One CLI's row in a sheet: its name and version, its status and
/// buttons, what its state means, the exact command, and its launch line.
struct ConnectAgentsRow<Model: AgentConnectionModel>: View {
    @ObservedObject var model: Model
    let connectsAtLaunch: Bool
    let confirm: (AgentConnection.Plan) -> Void

    var body: some View {
        let row = model.row(connectsAtLaunch: connectsAtLaunch)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(row.title)
                    .font(SettingsDesign.Fonts.rowTitle)
                Spacer()
                SettingsStatusText(row.status, style: row.style, dot: row.dot)
                AgentConnectionActions(model: model, row: row, size: .small, confirm: confirm)
            }
            AgentConnectionStatus(model: model, row: row)
            if let command = Self.command(model: model, row: row) {
                SettingsCodeBlock(text: command, copyLabel: "Copy the \(model.harness.productName) command")
            }
            Text(row.launchLine)
                .font(SettingsDesign.Fonts.help)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The command its button runs, with the CLI as found; nil while the
    /// row has no button that registers (`Row.commandAction`).
    private static func command(model: Model, row: AgentConnection.Row) -> String? {
        row.commandAction.flatMap { model.plan(for: $0) }?.displayedCommands.joined(separator: "\n")
    }
}

// MARK: - Connect Agents to Cherry…

/// Connect Agents to Cherry…: Claude Code's, Codex's and Pi's models (the
/// app's `MCPRegistrations.shared`), read again as the sheet opens, the
/// request the confirmation answers, and Connect All.
@MainActor
final class ConnectAgentsModel: ObservableObject {
    let registrations: MCPRegistrations
    private let connectsAtLaunch: @MainActor () -> Bool
    /// The plans the confirmation shows; nil while it is closed.
    @Published var request: AgentConnectionRequest?
    private var subscriptions: [AnyCancellable] = []

    init(
        registrations: MCPRegistrations = .shared,
        connectsAtLaunch: @escaping @MainActor () -> Bool = { AgentMCPLaunch.isEnabled() }
    ) {
        self.registrations = registrations
        self.connectsAtLaunch = connectsAtLaunch
        for publisher in [
            registrations.claude.objectWillChange, registrations.codex.objectWillChange, registrations.pi.objectWillChange,
        ] {
            subscriptions.append(publisher.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    var isConnectingAtLaunch: Bool { connectsAtLaunch() }

    /// Each CLI's row, in the presets' order: Claude Code, Codex, Pi.
    var rows: [AgentConnection.Row] {
        let connectsAtLaunch = connectsAtLaunch()
        return registrations.models.map { $0.row(connectsAtLaunch: connectsAtLaunch) }
    }

    /// What Connect All runs (`AgentConnection.connectAllPlans`).
    var connectAllPlans: [AgentConnection.Plan] {
        AgentConnection.connectAllPlans(rows) { registrations.model(for: $0).plan(for: $1) }
    }

    /// Reads every CLI again, at once.
    func refresh(asksAgain: Bool = false) async {
        async let claude: Void = registrations.claude.refresh(asksAgain: asksAgain)
        async let codex: Void = registrations.codex.refresh(asksAgain: asksAgain)
        async let pi: Void = registrations.pi.refresh(asksAgain: asksAgain)
        _ = await (claude, codex, pi)
    }

    /// Asks about `plan` (one row's button).
    func confirm(_ plan: AgentConnection.Plan) {
        request = AgentConnectionRequest(plans: [plan])
    }

    /// Connect All: one confirmation listing every plan's commands.
    func confirmConnectAll() {
        let plans = connectAllPlans
        guard !plans.isEmpty else { return }
        request = AgentConnectionRequest(plans: plans)
    }

    /// Runs plans the user confirmed: only the confirmation's Connect calls
    /// it.
    func perform(_ plans: [AgentConnection.Plan]) async {
        await registrations.perform(plans)
    }
}

/// Connect Agents to Cherry…: one row per CLI found, "Not found: …"
/// collapsed at the end, Connect All and Done.
struct ConnectAgentsSheet: View {
    static let title = "Connect Agents to Cherry"
    static let intro = "Agents Cherry starts get Cherry MCP when they start. Connecting adds it to an agent CLI's own settings, for sessions you start yourself. Nothing runs until you confirm."

    @StateObject var model: ConnectAgentsModel
    let close: () -> Void
    @State private var showsNotFound = false

    /// "Not found: Codex, Pi".
    static func notFoundTitle(_ rows: [AgentConnection.Row]) -> String {
        "Not found: " + rows.map(\.harness.productName).joined(separator: ", ")
    }

    var body: some View {
        let rows = model.rows
        let notFound = rows.filter { !$0.isInstalled }
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.title).font(.title2.weight(.semibold))
            Text(Self.intro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows.filter(\.isInstalled), id: \.harness) { row in
                harnessRow(row.harness)
                Divider()
            }
            if !notFound.isEmpty {
                DisclosureGroup(Self.notFoundTitle(notFound), isExpanded: $showsNotFound) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notFound, id: \.harness) { row in
                            Text(row.detail ?? row.harness.productName)
                                .font(SettingsDesign.Fonts.help)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
            HStack {
                Button("Check Again") {
                    Task { await model.refresh(asksAgain: true) }
                }
                Spacer()
                Button("Connect All") {
                    model.confirmConnectAll()
                }
                .disabled(model.connectAllPlans.isEmpty || model.registrations.models.contains { $0.isRunning })
                .help("Connects each CLI that isn't connected, or whose Cherry MCP is off, hidden or gone; shows the commands first.")
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { await model.refresh() }
        .agentConnectionConfirmation($model.request) { await model.perform($0) }
    }

    @ViewBuilder
    private func harnessRow(_ harness: MCPHarness) -> some View {
        let connectsAtLaunch = model.isConnectingAtLaunch
        switch harness {
        case .claude:
            ConnectAgentsRow(model: model.registrations.claude, connectsAtLaunch: connectsAtLaunch, confirm: model.confirm)
        case .codex:
            ConnectAgentsRow(model: model.registrations.codex, connectsAtLaunch: connectsAtLaunch, confirm: model.confirm)
        case .pi:
            ConnectAgentsRow(model: model.registrations.pi, connectsAtLaunch: connectsAtLaunch, confirm: model.confirm)
        }
    }
}

/// Shows Connect Agents to Cherry… as a sheet on the key window (the Omni
/// bar's command, Settings › Agents & MCP).
@MainActor
enum ConnectAgentsPresenter {
    static func present(registrations: MCPRegistrations = .shared) {
        RemoteDeviceSheet.present(size: NSSize(width: 620, height: 460)) { close in
            ConnectAgentsSheet(model: ConnectAgentsModel(registrations: registrations), close: close)
        }
    }
}

// MARK: - Connect This Agent to Cherry…

/// What Connect This Agent says about the selected agent tab beside its
/// CLI's row: how this launch started, what this project's settings change,
/// and for a device's tab when it gets Cherry MCP there.
enum ConnectThisAgent {
    /// Where the tab runs.
    enum Place: Equatable {
        case thisMac
        case device(id: UUID, name: String)
    }

    /// What a project's `.pi/mcp.json` has under the server's name (Pi
    /// reads it once it trusts the project; its entry replaces the user one,
    /// and one without a command overrides only its `enabled` and
    /// `exposure`).
    enum PiProjectEntry: Equatable {
        case turnedOff
        case exposure(String)
        case ownEntry(line: String)
    }

    struct Lines: Equatable {
        /// This launch, with or without Cherry MCP; nil when nothing was
        /// decided (a context-less workspace).
        var launch: String?
        /// Restart Tab: a launch now would get Cherry MCP, or a connect
        /// from this sheet worked for a launch that had none.
        var offersRestart = false
        /// This project's settings that win over the user registration.
        var project: String?
        /// A device's tab: when its agent gets Cherry MCP there.
        var device: String?
        /// Set Up Cherry MCP on <Mac>….
        var offersSetUp = false
    }

    /// The CLI an agent tab runs, when Cherry connects it (Claude Code,
    /// Codex, Pi): its brand from `agentToolKey`. Nil for other tabs.
    @MainActor
    static func harness(of session: TerminalSession) -> MCPHarness? {
        guard session.kind == .agent else { return nil }
        return AgentToolBrand(rawValue: session.agentToolKey)?.mcpHarness
    }

    /// The lines for an agent tab of `harness` at `place`: `launchOutcome`
    /// is what its launch decided (`TerminalSession.lastAgentMCPLaunchOutcome`),
    /// `outcomeNow` what a launch would decide now; `connectedHere`: a
    /// connect from this sheet worked.
    static func lines(
        harness: MCPHarness,
        place: Place,
        launchOutcome: AgentMCPLaunch.Outcome?,
        outcomeNow: AgentMCPLaunch.Outcome?,
        piProjectEntry: PiProjectEntry?,
        claudeLocalLine: String?,
        connectedHere: Bool = false,
        serverName: String
    ) -> Lines {
        let product = harness.productName
        if case .device(_, let name) = place {
            let pi = harness == .pi ? " and Pi \(PiMCPRegistration.minimumVersion) or later" : ""
            return Lines(
                device: "\(product) on \(name) gets Cherry MCP at launch when \(name)'s session host is this build or newer (Update Session Host…), with an sh-family login shell\(pi).",
                offersSetUp: true
            )
        }
        var lines = Lines()
        var appended = false
        switch launchOutcome {
        case .appended?:
            appended = true
            lines.launch = harness == .pi
                ? "This tab started Pi with Cherry MCP, for this session; a \(serverName) entry in Pi's settings takes precedence over it."
                : "This tab started \(product) with Cherry MCP, for this session: its own registration is for sessions started elsewhere."
        case .skipped(let reason)?:
            lines.launch = "This tab started \(product) without Cherry MCP: \(reason)."
            if case .appended? = outcomeNow { lines.offersRestart = true }
        case nil:
            break
        }
        if connectedHere, harness != .pi, !appended { lines.offersRestart = true }
        switch harness {
        case .pi:
            lines.project = piProjectEntry.map { piProjectNote($0, serverName: serverName) }
        case .claude where !appended:
            lines.project = claudeLocalLine.map {
                "Claude Code's settings for this project define their own \(serverName) (runs \($0)), used instead of the user one."
            }
        case .claude, .codex:
            break
        }
        return lines
    }

    static func piProjectNote(_ entry: PiProjectEntry, serverName: String) -> String {
        let trusted = " (when Pi trusts this project)."
        switch entry {
        case .turnedOff:
            return "This project's .pi/mcp.json turns \(serverName) off" + trusted
        case .exposure(let exposure):
            return "This project's .pi/mcp.json sets \(serverName)'s exposure to \(exposure)" + trusted
        case .ownEntry(let line):
            return "This project's .pi/mcp.json defines its own \(serverName), which runs \(line)" + trusted
        }
    }

    /// The entry under `serverName` (or a name Pi takes for it: `-` and `_`
    /// alike) of the first of `directories`' `.pi/mcp.json` that has one: the
    /// tab's working directory, then its project root. Reads the files
    /// only; Cherry never edits a project's.
    static func piProjectEntry(serverName: String, directories: [String]) -> PiProjectEntry? {
        let namespace = serverName.replacingOccurrences(of: "-", with: "_")
        var seen = Set<String>()
        for directory in directories where seen.insert(URL(fileURLWithPath: directory).standardizedFileURL.path).inserted {
            let file = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(".pi/mcp.json", isDirectory: false)
            guard let data = FileManager.default.contents(atPath: file.path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any],
                  let server = (servers[serverName] ?? servers.first {
                      $0.key.replacingOccurrences(of: "-", with: "_") == namespace
                  }?.value) as? [String: Any]
            else { continue }
            if server["enabled"] as? Bool == false { return .turnedOff }
            if server["command"] != nil || server["url"] != nil || server["type"] != nil {
                return .ownEntry(line: AgentConnection.shownLine(server) ?? "a \(server["type"] as? String ?? "custom") server")
            }
            if let exposure = server["exposure"] as? String { return .exposure(exposure) }
        }
        return nil
    }
}

/// Connect This Agent for one tab: its CLI's model, what this launch
/// decided, and this project's settings, read as the sheet opens.
@MainActor
final class ConnectThisAgentModel: ObservableObject {
    let harness: MCPHarness
    let registrations: MCPRegistrations
    let session: TerminalSession
    let workspace: TerminalWorkspace
    let place: ConnectThisAgent.Place
    @Published var request: AgentConnectionRequest?
    @Published private(set) var piProjectEntry: ConnectThisAgent.PiProjectEntry?
    @Published private(set) var claudeLocalLine: String?
    /// A connect from this sheet worked.
    @Published private(set) var connectedHere = false
    private var subscription: AnyCancellable?

    init(
        harness: MCPHarness,
        session: TerminalSession,
        workspace: TerminalWorkspace,
        place: ConnectThisAgent.Place,
        registrations: MCPRegistrations = .shared
    ) {
        self.harness = harness
        self.session = session
        self.workspace = workspace
        self.place = place
        self.registrations = registrations
        let publisher = switch harness {
        case .claude: registrations.claude.objectWillChange
        case .codex: registrations.codex.objectWillChange
        case .pi: registrations.pi.objectWillChange
        }
        subscription = publisher.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var serverName: String { registrations.model(for: harness).serverName }

    var lines: ConnectThisAgent.Lines {
        ConnectThisAgent.lines(
            harness: harness,
            place: place,
            launchOutcome: session.lastAgentMCPLaunchOutcome,
            outcomeNow: outcomeNow,
            piProjectEntry: piProjectEntry,
            claudeLocalLine: claudeLocalLine,
            connectedHere: connectedHere,
            serverName: serverName
        )
    }

    /// What a launch of the tab's command would decide now, with its
    /// workspace's context (nil without one).
    private var outcomeNow: AgentMCPLaunch.Outcome? {
        guard let context = workspace.backendPolicy.agentMCPLaunch, let command = session.launchCommand else { return nil }
        return context.outcome(
            commandLine: command,
            serverName: CherryAppIdentity.current.urlScheme,
            environmentKeys: AgentMCPLaunch.environmentKeys(
                projectRoot: session.projectRoot,
                controlSocketPath: CherryControlServer.appSocketPath,
                helperPath: context.helperPath
            )
        )
    }

    /// The CLI's state and this project's settings (This Mac's tabs only:
    /// nothing of This Mac's is read for a device's).
    func refresh(asksAgain: Bool = false) async {
        guard place == .thisMac else { return }
        await registrations.model(for: harness).refresh(asksAgain: asksAgain)
        let workingDirectory = session.workingDirectory.nilIfEmpty
        let projectRoot = session.projectRoot.map(ProjectLocation.launchPath(forKey:))?.nilIfEmpty
        switch harness {
        case .pi:
            // Pi reads the directory it started in.
            let serverName = serverName
            let directories = [workingDirectory, projectRoot].compactMap { $0 }
            piProjectEntry = await Task.detached {
                ConnectThisAgent.piProjectEntry(serverName: serverName, directories: directories)
            }.value
        case .claude:
            // Claude Code keeps a project's settings by the directory it
            // started in: an agent tab's project root.
            claudeLocalLine = await registrations.claude.localEntry(projectRoots: [projectRoot, workingDirectory].compactMap { $0 })
        case .codex:
            break
        }
    }

    func confirm(_ plan: AgentConnection.Plan) {
        request = AgentConnectionRequest(plans: [plan])
    }

    /// Runs a plan the user confirmed: only the confirmation's Connect
    /// calls it.
    func perform(_ plans: [AgentConnection.Plan]) async {
        await registrations.perform(plans)
        if !registrations.model(for: harness).lastRunFailed { connectedHere = true }
    }

    /// Restart Tab: the path Restart Active Tab takes.
    func restartTab() {
        workspace.restart(session)
    }
}

/// Connect This Agent to Cherry…: the tab's CLI row and its lines, or for a
/// device's tab when it gets Cherry MCP there and Set Up Cherry MCP on
/// <Mac>….
struct ConnectThisAgentSheet: View {
    static let title = "Connect This Agent to Cherry"

    @StateObject var model: ConnectThisAgentModel
    let close: () -> Void

    var body: some View {
        let lines = model.lines
        VStack(alignment: .leading, spacing: 14) {
            Text(ConnectThisAgentSheet.title)
                .font(.title2.weight(.semibold))
            if let device = lines.device {
                Text(device)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                harnessRow
                if let launch = lines.launch {
                    Text(launch)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let project = lines.project {
                    Label(project, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(SettingsDesign.Colors.warningText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if lines.offersRestart {
                    Button("Restart Tab") {
                        model.restartTab()
                        close()
                    }
                }
                if lines.offersSetUp, case .device(let id, let name) = model.place {
                    Button("Set Up Cherry MCP on \(name)…") {
                        close()
                        DispatchQueue.main.async { RemoteMCPSetupPresenter.present(deviceID: id) }
                    }
                }
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { await model.refresh() }
        .agentConnectionConfirmation($model.request) { await model.perform($0) }
    }

    @ViewBuilder
    private var harnessRow: some View {
        let connectsAtLaunch = AgentMCPLaunch.isEnabled()
        switch model.harness {
        case .claude:
            ConnectAgentsRow(model: model.registrations.claude, connectsAtLaunch: connectsAtLaunch, confirm: model.confirm)
        case .codex:
            ConnectAgentsRow(model: model.registrations.codex, connectsAtLaunch: connectsAtLaunch, confirm: model.confirm)
        case .pi:
            ConnectAgentsRow(model: model.registrations.pi, connectsAtLaunch: connectsAtLaunch, confirm: model.confirm)
        }
    }
}

/// Shows Connect This Agent to Cherry… for an agent tab as a sheet on the
/// key window (the Omni bar's command).
@MainActor
enum ConnectThisAgentPresenter {
    static func present(
        session: TerminalSession,
        repository: RepositoryWorkspace,
        registrations: MCPRegistrations = .shared,
        store: RemoteDeviceStore = .shared
    ) {
        guard let harness = ConnectThisAgent.harness(of: session) else { return }
        let place: ConnectThisAgent.Place
        if repository.isRemote, let id = ProjectLocation(key: repository.repositoryRoot).deviceID {
            place = .device(id: id, name: store.device(id: id)?.name ?? "the other Mac")
        } else {
            place = .thisMac
        }
        let workspace = repository.workspace
        RemoteDeviceSheet.present(size: NSSize(width: 600, height: 320)) { close in
            ConnectThisAgentSheet(
                model: ConnectThisAgentModel(
                    harness: harness, session: session, workspace: workspace, place: place, registrations: registrations
                ),
                close: close
            )
        }
    }
}
