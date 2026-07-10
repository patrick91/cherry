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

            SummarySettingsSection(settings: settings)
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

private struct SummarySettingsSection: View {
    @ObservedObject var settings: AgentSettings
    @StateObject private var debugStore = AgentSummaryDebugStore.shared
    @StateObject private var optionKey = OptionKeyObserver()

    @State private var testTask: Task<Void, Never>?
    @State private var testStatus: SummaryTestStatus = .idle

    private var commandPreview: String {
        settings.effectiveAgentSummaryCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsCard("Auto-Summarization") {
            SummarySettingsRow {
                Text("Summary engine")
                Text("Cherry uses Codex MCP for background agent summaries and sends a compact rendered-text snapshot from recent terminal output, not the full raw transcript.")
                    .foregroundStyle(.secondary)
            } control: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Codex MCP")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsDivider()

            SummarySettingsRow {
                Text("Cadence")
                Text("Minimum time between auto-summary attempts for the same session. Cherry still waits for a brief idle pause before requesting a summary.")
                    .foregroundStyle(.secondary)
            } control: {
                Picker("Cadence", selection: $settings.agentSummaryCadence) {
                    ForEach(AgentSummaryCadence.allCases) { cadence in
                        Text(cadence.label)
                            .tag(cadence)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            SettingsDivider()

            SummarySettingsRow {
                Text("Model")
                Text(AgentSummaryTool.codex.modelFlagDescription)
                    .foregroundStyle(.secondary)
            } control: {
                Picker("Model", selection: $settings.agentSummaryModel) {
                    if !settings.agentSummaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !AgentSummaryTool.codex.modelOptions.contains(settings.agentSummaryModel) {
                        Text("\(settings.agentSummaryModel) (custom)")
                            .tag(settings.agentSummaryModel)
                    }

                    ForEach(AgentSummaryTool.codex.modelOptions, id: \.self) { model in
                        Text(model)
                            .tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 250)
            }

            SettingsDivider()

            SummarySettingsRow {
                Text("Generated titles")
                Text("Use the generated task title for agents that do not have a manual title.")
                    .foregroundStyle(.secondary)
            } control: {
                Toggle("Generated titles", isOn: $settings.useAgentSummaryAsTitle)
                    .labelsHidden()
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command preview")
                    Text("The Codex MCP command path Cherry uses for summarization.")
                        .foregroundStyle(.secondary)
                }

                Text(commandPreview)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            SettingsDivider()

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test summarizer")
                        .font(.callout)
                    Text(testStatus.message)
                        .font(.callout)
                        .foregroundStyle(testStatus.isError ? .red : .secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(testStatus.isRunning ? "Testing" : "Test") {
                    runTest()
                }
                .disabled(testStatus.isRunning)
                .settingsGlassButtonStyle()
                .frame(width: 82)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            if optionKey.isOptionDown {
                SettingsDivider()

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Debug")
                            .font(.callout)
                        Text(debugStore.lastRecord?.status ?? "No summary attempts recorded yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(debugStore.logURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Button("Copy") {
                            debugStore.copyLastRecord()
                        }
                        .disabled(debugStore.lastRecord == nil)
                        .settingsGlassButtonStyle()

                        Button("Reveal") {
                            debugStore.revealLog()
                        }
                        .settingsGlassButtonStyle()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            }
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    private func runTest() {
        testTask?.cancel()
        testStatus = .running
        testTask = Task {
            do {
                let transcript = """
                User asked Cherry to summarize an agent session.
                The agent inspected settings, changed SwiftUI, and ran tests.
                """
                let result = try await CodexMCPSummaryRunner.shared.run(
                    transcript: transcript,
                    workingDirectory: NSHomeDirectory(),
                    model: settings.agentSummaryModel
                )
                let resultText = [result.title, result.summary]
                    .compactMap { $0 }
                    .joined(separator: " — ")
                await MainActor.run {
                    testStatus = .success(resultText)
                }
            } catch {
                await MainActor.run {
                    testStatus = .failure(error.localizedDescription)
                }
            }
        }
    }
}

private struct SummarySettingsRow<Description: View, Control: View>: View {
    let description: () -> Description
    let control: () -> Control

    init(
        @ViewBuilder description: @escaping () -> Description,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.description = description
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                description()
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
                .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

private enum SummaryTestStatus: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)

    var isRunning: Bool {
        self == .running
    }

    var isError: Bool {
        if case .failure = self {
            return true
        }
        return false
    }

    var message: String {
        switch self {
        case .idle:
            "Runs the selected tool directly to verify setup. Any OS permission prompts come from that tool."
        case .running:
            "Waiting for the summarizer to return one short line."
        case .success(let summary):
            "Returned: \(summary)"
        case .failure(let message):
            "Failed: \(message)"
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
