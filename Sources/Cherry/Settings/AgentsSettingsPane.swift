import AppKit
import SwiftUI

struct AgentSettingsPane: View {
    @ObservedObject var settings: AgentSettings

    @State private var editingAgent: AgentToolDefinition?
    @State private var editingOriginalName: String?
    @State private var agentError: String?

    var body: some View {
        SettingsPaneScroll(page: .agents) {
            SettingsCard("Agent Tools") {
                if settings.resolvedAgents.isEmpty {
                    SettingsEmptyState(
                        title: "No agents configured",
                        message: "Add one of the presets to start launching agents from Cherry.",
                        systemImage: "sparkles"
                    )
                } else {
                    ForEach(Array(settings.resolvedAgents.enumerated()), id: \.element.id) { index, agent in
                        AgentToolRow(agent: agent) {
                            editingAgent = agent.definition
                            editingOriginalName = agent.name
                        } onReset: {
                            settings.removeAgent(named: agent.name)
                        }

                        if index < settings.resolvedAgents.count - 1 {
                            SettingsDivider()
                        }
                    }
                }

                SettingsDivider()

                SettingsRow("Add agent", subtitle: "Start from a preset and customize the command if needed.") {
                    Menu {
                        ForEach(AgentConfiguration.presets) { preset in
                            Button(preset.name) {
                                editingAgent = preset
                                editingOriginalName = nil
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .settingsGlassButtonStyle()
                }
            }

        }
        .sheet(item: $editingAgent) { agent in
            AgentToolEditor(
                agent: agent,
                canDelete: editingOriginalName != nil,
                errorMessage: agentError,
                onSave: { updatedAgent in
                    do {
                        try settings.upsertAgent(
                            updatedAgent,
                            replacing: editingOriginalName
                        )
                        agentError = nil
                        editingOriginalName = nil
                        editingAgent = nil
                    } catch {
                        agentError = error.localizedDescription
                    }
                },
                onDelete: {
                    settings.removeAgent(named: agent.name)
                    agentError = nil
                    editingOriginalName = nil
                    editingAgent = nil
                },
                onCancel: {
                    agentError = nil
                    editingOriginalName = nil
                    editingAgent = nil
                }
            )
        }
    }
}

private struct AgentToolRow: View {
    let agent: ResolvedAgentTool
    let onEdit: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.enabled ? "sparkle.magnifyingglass" : "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(agent.enabled ? Color.accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 14, weight: .semibold))
                    if !agent.enabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !agent.isLaunchable {
                        Text("Blocked")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text(agent.commandLine.isEmpty ? "No command" : agent.commandLine)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(sourceLabel)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Edit", action: onEdit)
                .settingsGlassButtonStyle()
            Button("Delete", role: .destructive, action: onReset)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var sourceLabel: String {
        switch agent.source {
        case .global:
            "Global"
        }
    }
}

struct AgentToolEditor: View {
    @State private var draft: AgentToolDefinition

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
        self.canDelete = canDelete
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Edit agent tool")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $draft.name)
                TextField("Command", text: $draft.command)
                TextField("Default arguments", text: $draft.arguments)
                Toggle("Enabled", isOn: $draft.enabled)
            }
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                if canDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }

                Spacer()

                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
