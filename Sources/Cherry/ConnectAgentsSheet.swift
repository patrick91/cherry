import AppKit
import CherryControl
import SwiftUI

// Connect Agents to Cherry… (the Omni bar, Settings › Agents › The cherry
// command): the `cherry` skill and Codex's rules file
// (`CherrySkillsModel.shared`, the rows an agent's page shows too), read
// again as the sheet opens and on Check Again. Install and Update open
// `CherrySkillConfirmation` first, which alone writes.

/// Connect Agents to Cherry…: the skill's rows, Check Again and Done.
struct ConnectAgentsSheet: View {
    static let title = "Connect Agents to Cherry"
    static let intro = "Agents Cherry starts are told about the cherry command when they start. Installing the cherry skill teaches it to the agents you start yourself too. Nothing is written until you confirm."

    @ObservedObject var skills: CherrySkillsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.title).font(.title2.weight(.semibold))
            Text(Self.intro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CherrySkillRows(model: skills)
            HStack {
                Button("Check Again") {
                    Task { await skills.refresh() }
                }
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { await skills.refresh() }
    }
}

/// Shows Connect Agents to Cherry… as a sheet on the key window (the Omni
/// bar's command, Settings › Agents).
@MainActor
enum ConnectAgentsPresenter {
    static func present(skills: CherrySkillsModel = .shared) {
        RemoteDeviceSheet.present(size: NSSize(width: 620, height: 420)) { close in
            ConnectAgentsSheet(skills: skills, close: close)
        }
    }
}
