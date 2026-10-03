import AppKit
import CherryControl
import SwiftUI

struct MCPSettingsPane: View {
    @State private var copiedHarness: MCPHarness?
    @State private var socketExists = FileManager.default.fileExists(atPath: CherryControl.socketURL.path)
    @AppStorage(AgentMonitorRegistry.wakeLinesDefaultsKey) private var monitorWakeLines = true
    @StateObject private var piRegistration = PiMCPRegistrationModel()

    private var commands: [MCPInstallCommand] {
        MCPInstallCommandBuilder.commands()
    }

    var body: some View {
        SettingsPaneScroll(page: .mcp) {
            SettingsCard("Status") {
                SettingsRow("MCP helper", subtitle: "Installed next to the Cherry app. Runs over stdio.") {
                    Text(MCPInstallCommandBuilder.helperCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                SettingsDivider()

                MCPInstanceSocketRow(
                    socketPath: CherryControl.socketURL.path,
                    socketExists: socketExists
                )

                SettingsDivider()

                SettingsRow("Connection") {
                    Button("Refresh") {
                        socketExists = FileManager.default.fileExists(atPath: CherryControl.socketURL.path)
                    }
                    .settingsGlassButtonStyle()
                }
            }

            SettingsCard("Monitors") {
                SettingsRow(
                    "Wake idle agents",
                    subtitle: "When an agent subscribed to other processes (MCP subscribe) is idle, type a one-line note into its tab once their events are ready to read."
                ) {
                    Toggle("Wake idle agents", isOn: $monitorWakeLines)
                        .labelsHidden()
                }
            }

            SettingsCard("Install Commands") {
                ForEach(commands) { installCommand in
                    MCPInstallCommandRow(
                        installCommand: installCommand,
                        isCopied: copiedHarness == installCommand.harness
                    ) {
                        copy(installCommand)
                    }

                    if installCommand.harness == .pi {
                        PiMCPRegistrationRow(model: piRegistration)
                    }

                    if installCommand.id != commands.last?.id {
                        SettingsDivider()
                    }
                }
            }
        }
        .onAppear {
            socketExists = FileManager.default.fileExists(atPath: CherryControl.socketURL.path)
            piRegistration.refresh()
        }
    }

    private func copy(_ installCommand: MCPInstallCommand) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand.command, forType: .string)
        copiedHarness = installCommand.harness

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            if copiedHarness == installCommand.harness {
                copiedHarness = nil
            }
        }
    }
}

private struct MCPInstanceSocketRow: View {
    let socketPath: String
    let socketExists: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Instance socket")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                Text(socketPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Circle()
                    .fill(socketExists ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(socketExists ? "Listening" : "Waiting for Cherry")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct MCPInstallCommandRow: View {
    let installCommand: MCPInstallCommand
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(installCommand.harness.name)
                    .fontWeight(.medium)

                Text(installCommand.command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: onCopy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            }
            .settingsGlassButtonStyle()
            .help(isCopied ? "Copied" : "Copy command")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// Pi's registration under its command: whether Pi's mcp.json has it (read
/// only), and Add, which runs `pi mcp add` only when clicked.
private struct PiMCPRegistrationRow: View {
    @ObservedObject var model: PiMCPRegistrationModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.statusText, systemImage: model.status == .registered ? "checkmark.circle.fill" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(model.status == .registered ? Color.green : Color.secondary)
                if let message = model.message {
                    Text(message)
                        .font(.caption.monospaced())
                        .foregroundStyle(model.lastRunFailed ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }

            Spacer()

            if model.isRunning {
                ProgressView().controlSize(.small)
            }
            Button(model.status == .registered ? "Add Again" : "Add to Pi") {
                Task { await model.register() }
            }
            .settingsGlassButtonStyle()
            .disabled(model.isRunning || model.helperPath == nil)
            .help("Runs the command above (pi mcp add); Pi writes its own settings.")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }
}
