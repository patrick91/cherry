import AppKit
import CherryControl
import Foundation
import SwiftUI

// The `cherry` skill in Connect Agents to Cherry… and each agent's page
// (docs/specs/agent-cli.md, Teaching agents): its files' state, read off the
// main thread when a sheet or page shows and on Check Again (never at
// launch), and Install/Update, which only builds a plan: the files and their
// contents go to `CherrySkillConfirmation`, and only its Install writes them
// (`CherrySkillsModel.perform`). Cherry writes no agent configuration
// otherwise.

/// What an Install writes, as the confirmation shows it.
struct CherrySkillPlan: Identifiable, Equatable {
    let id = UUID()
    var targets: [CherrySkillTarget]
    var files: [CherrySkillFile]
    /// "Replaces Cherry's older skill in ~/.claude/skills/cherry."
    var replaces: [String]
}

enum CherrySkillConnection {
    /// The agent a page's brand is (Gemini reads no skill Cherry writes).
    static func agent(for brand: AgentToolBrand?) -> CherrySkillAgent? {
        switch brand {
        case .claude: .claude
        case .codex: .codex
        case .pi: .pi
        case .openCode: .opencode
        case .amp: .amp
        case .gemini, nil: nil
        }
    }

    /// A row's status: what it is, its style and dot.
    static func status(of item: CherrySkillItem) -> (String, SettingsStatusText.Style, SettingsStatusDot.Tone) {
        switch item.status {
        case .current: ("Installed", .ok, .green)
        case .outdated: ("Older version", .warning, .yellow)
        case .missing: ("Not installed", .neutral, .gray)
        case .foreign: ("Not Cherry's", .warning, .orange)
        case .unreadable: ("Can't read", .warning, .red)
        case .unsupported: ("Not found", .neutral, .gray)
        }
    }

    /// What the row says under its title.
    static func detail(of item: CherrySkillItem) -> String {
        let readers = (item.agents.isEmpty ? item.target.agents : item.agents).map(\.displayName)
        let place = item.path.isEmpty ? "" : " in \(abbreviated(item.path))"
        let what: String = switch item.target {
        case .claudeSkill, .agentsSkill:
            "Teaches \(readers.joined(separator: ", ")) the cherry command\(place)."
        case .codexRules:
            "Lets Codex run cherry's agent commands outside its sandbox, and refuses cherry host\(place)."
        }
        switch item.status {
        case .foreign:
            return what + " A file there isn't Cherry's (\(item.detail ?? "")), so Cherry leaves it alone; `cherry skill setup --force` replaces it."
        case .unreadable, .unsupported:
            return what + (item.detail.map { " \($0.prefix(1).uppercased() + $0.dropFirst())." } ?? "")
        default:
            return what
        }
    }

    /// The button: Install (missing) or Update (outdated); nil otherwise.
    static func action(for item: CherrySkillItem) -> String? {
        switch item.status {
        case .missing: "Install"
        case .outdated: "Update"
        default: nil
        }
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static let confirmationLead = "Cherry writes these files and changes nothing else. `cherry skill remove` removes them."
}

/// The skill's state for the app's life (`shared`), shared by the sheet and
/// the agents' pages. A model made without an installer (the default,
/// tests) reads and writes nothing.
@MainActor
final class CherrySkillsModel: ObservableObject {
    /// The account's, for the app's life.
    static let shared = CherrySkillsModel.live()

    @Published private(set) var items: [CherrySkillItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var message: String?
    @Published private(set) var lastRunFailed = false
    /// The plan the confirmation shows; nil while it is closed.
    @Published var request: CherrySkillPlan?

    private let makeInstaller: (@Sendable () -> CherrySkillInstaller)?

    init(makeInstaller: (@Sendable () -> CherrySkillInstaller)? = nil) {
        self.makeInstaller = makeInstaller
    }

    /// The account's skill, for the app.
    static func live() -> CherrySkillsModel {
        CherrySkillsModel { CherrySkillInstaller(environment: .current()) }
    }

    /// The items an agent reads, unsupported ones last.
    func items(for agent: CherrySkillAgent? = nil) -> [CherrySkillItem] {
        let matching = agent.map { agent in items.filter { $0.target.agents.contains(agent) } } ?? items
        return matching.filter { $0.status != .unsupported } + matching.filter { $0.status == .unsupported }
    }

    /// Reads every target again, off the main thread.
    func refresh() async {
        guard let makeInstaller else { return }
        items = await Task.detached { makeInstaller().items() }.value
    }

    /// What installing `targets` writes: only missing and outdated ones;
    /// nil when none is.
    func plan(for targets: [CherrySkillTarget]) -> CherrySkillPlan? {
        guard let makeInstaller else { return nil }
        let chosen = items.filter { targets.contains($0.target) && ($0.status == .missing || $0.status == .outdated) }
        guard !chosen.isEmpty else { return nil }
        let installer = makeInstaller()
        return CherrySkillPlan(
            targets: chosen.map(\.target),
            files: installer.files(for: chosen.map(\.target)),
            replaces: chosen.filter { $0.status == .outdated }.map {
                "Replaces Cherry's older \($0.target.title.lowercased()) in \(CherrySkillConnection.abbreviated($0.path))."
            }
        )
    }

    /// Asks about `targets` (a row's button).
    func confirm(_ targets: [CherrySkillTarget]) {
        if let plan = plan(for: targets) {
            request = plan
        } else {
            NSSound.beep()
        }
    }

    /// Writes a plan the user confirmed: only the confirmation's Install
    /// calls it. Never forces over a file that isn't Cherry's.
    func perform(_ plan: CherrySkillPlan) async {
        guard let makeInstaller else { return }
        isRunning = true
        let targets = plan.targets
        let changes = await Task.detached {
            makeInstaller().setup(agents: nil, targets: targets, force: false, dryRun: false)
        }.value
        isRunning = false
        let failures = changes.filter(\.failed)
        lastRunFailed = !failures.isEmpty
        message = failures.isEmpty
            ? nil
            : failures.map { "\(CherrySkillConnection.abbreviated($0.item.path)): \($0.detail ?? "failed")" }.joined(separator: "\n")
        await refresh()
    }
}

/// One target's row: its title, state and button, and what it does.
struct CherrySkillRow: View {
    @ObservedObject var model: CherrySkillsModel
    let item: CherrySkillItem

    var body: some View {
        let (status, style, dot) = CherrySkillConnection.status(of: item)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(item.target.title)
                    .font(SettingsDesign.Fonts.rowTitle)
                Spacer()
                SettingsStatusText(status, style: style, dot: dot)
                if let action = CherrySkillConnection.action(for: item) {
                    Button(action) { model.confirm([item.target]) }
                        .settingsButton(.standard, size: .small)
                        .disabled(model.isRunning)
                        .help("Shows the files first, and writes them when you confirm.")
                }
            }
            Text(CherrySkillConnection.detail(of: item))
                .font(SettingsDesign.Fonts.help)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The rows of `agent` (every target when nil) and the last run's failure.
struct CherrySkillRows: View {
    @ObservedObject var model: CherrySkillsModel
    var agent: CherrySkillAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.items(for: agent), id: \.target) { item in
                CherrySkillRow(model: model, item: item)
            }
            if let message = model.message {
                AgentRegistrationOutput(text: message, failed: model.lastRunFailed)
            }
        }
        .cherrySkillConfirmation(model)
    }
}

/// "Install the Cherry skill?": every file's path and contents, and what it
/// replaces; Install writes them, Cancel writes nothing.
struct CherrySkillConfirmation: View {
    let plan: CherrySkillPlan
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.targets == [.codexRules] ? "Install the Codex rules?" : "Install the Cherry skill?")
                .font(.title3.weight(.semibold))
            Text(CherrySkillConnection.confirmationLead)
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.files, id: \.path) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.path)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            Text(file.contents)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            ForEach(plan.replaces, id: \.self) { note in
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Install", action: install)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

extension View {
    /// Shows `model`'s plan as a sheet; its Install clears it and runs
    /// `perform` (the only way the skill is written), Cancel only clears it.
    func cherrySkillConfirmation(_ model: CherrySkillsModel) -> some View {
        sheet(item: Binding(get: { model.request }, set: { model.request = $0 })) { plan in
            CherrySkillConfirmation(
                plan: plan,
                install: {
                    model.request = nil
                    Task { await model.perform(plan) }
                },
                cancel: { model.request = nil }
            )
        }
    }
}
