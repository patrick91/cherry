import SwiftUI

/// The sheet that adds an agent (Settings › Agents & MCP's + Add Agent and
/// Custom…, the Omni bar's Add Agent…) or edits one: its name, command,
/// default arguments and whether it is on. Delete… (only while editing)
/// asks first. Saving is the caller's (`onSave`), which shows why it failed
/// in `errorMessage`.
struct AgentToolEditor: View {
    static let nameLabel = "Name"
    static let commandLabel = "Command"
    static let commandPlaceholder = "claude"
    static let argumentsLabel = "Default arguments"
    static let argumentsPlaceholder = "--model opus"
    static let enabledLabel = "Enabled"
    static let enabledHelp = "Off hides it from the Agents menu, the sidebar's + menu and the Omni bar."

    @State private var draft: AgentToolDefinition
    @State private var confirmation: SettingsConfirmation?
    /// The name the agent is stored under, which Delete… names.
    private let storedName: String

    let canDelete: Bool
    let errorMessage: String?
    let onSave: (AgentToolDefinition) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    init(
        agent: AgentToolDefinition,
        canDelete: Bool,
        errorMessage: String?,
        onSave: @escaping (AgentToolDefinition) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: agent)
        storedName = agent.name
        self.canDelete = canDelete
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    /// "Add Agent" while adding (no Delete…), else "Edit Agent".
    static func title(canDelete: Bool) -> String {
        canDelete ? "Edit Agent" : "Add Agent"
    }

    /// What Delete… asks first: the agent's definition goes, and the tabs
    /// it started keep running.
    static func deleteConfirmation(agentName: String, delete: @escaping @MainActor () -> Void) -> SettingsConfirmation {
        SettingsConfirmation(
            title: "Delete the agent “\(agentName)”?",
            message: "Its command and default arguments are deleted. Tabs it started keep running.",
            choices: [
                SettingsConfirmation.Choice("Delete", role: .destructive, perform: delete),
                .cancel(),
            ]
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Self.title(canDelete: canDelete))
                .font(.title2.weight(.semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(Self.nameLabel)
                        .gridColumnAlignment(.trailing)
                    TextField(Self.nameLabel, text: $draft.name)
                        .labelsHidden()
                }
                GridRow {
                    Text(Self.commandLabel)
                    TextField(Self.commandLabel, text: $draft.command, prompt: Text(Self.commandPlaceholder))
                        .labelsHidden()
                        .font(.body.monospaced())
                }
                GridRow {
                    Text(Self.argumentsLabel)
                    TextField(Self.argumentsLabel, text: $draft.arguments, prompt: Text(Self.argumentsPlaceholder))
                        .labelsHidden()
                        .font(.body.monospaced())
                }
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(Self.enabledLabel, isOn: $draft.enabled)
                            .toggleStyle(.checkbox)
                        Text(Self.enabledHelp)
                            .font(SettingsDesign.Fonts.help)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if canDelete {
                    Button("Delete…", role: .destructive) {
                        confirmation = Self.deleteConfirmation(agentName: storedName, delete: onDelete)
                    }
                }

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .settingsConfirmation($confirmation)
    }
}
