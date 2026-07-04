import AppKit
import CherryControl
import SwiftUI

struct MCPSettingsPane: View {
    @State private var copiedHarness: MCPHarness?
    @State private var socketExists = FileManager.default.fileExists(atPath: CherryControl.socketURL.path)

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

            SettingsCard("Install Commands") {
                ForEach(commands) { installCommand in
                    MCPInstallCommandRow(
                        installCommand: installCommand,
                        isCopied: copiedHarness == installCommand.harness
                    ) {
                        copy(installCommand)
                    }

                    if installCommand.id != commands.last?.id {
                        SettingsDivider()
                    }
                }
            }
        }
        .onAppear {
            socketExists = FileManager.default.fileExists(atPath: CherryControl.socketURL.path)
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
