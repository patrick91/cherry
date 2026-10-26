import CherryMobileKit
import SwiftUI
import UIKit

/// The Macs the app reaches, this device's key, and the Demo Mac.
struct MacsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: MacEndpoint?

    var body: some View {
        List {
            Section {
                ForEach(model.macs) { mac in
                    Button {
                        if !mac.isDemo { editing = mac.endpoint }
                    } label: {
                        MacRow(mac: mac, sessionCount: model.sessions.filter { $0.macID == mac.id }.count)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if !mac.isDemo {
                            Button("Remove", role: .destructive) {
                                Task { await model.remove(mac.id) }
                            }
                        }
                    }
                }
                Button {
                    editing = MacEndpoint(name: "", host: "", user: "")
                } label: {
                    Label("Add a Mac", systemImage: "plus")
                }
            } header: {
                Text("Macs")
            } footer: {
                Text("Cherry reaches each Mac over SSH: turn on Remote Login there (System Settings › General › Sharing). With Tailscale, use the Mac's tailnet name.")
            }

            Section {
                DeviceKeyView(key: model.deviceKey)
            } header: {
                Text("This device's key")
            } footer: {
                Text("Add it to ~/.ssh/authorized_keys on each Mac.")
            }

            if !model.launch.demoOnly {
                Section {
                    Toggle("Demo Mac", isOn: Binding(
                        get: { model.showsDemoMac },
                        set: { shows in Task { await model.setShowsDemoMac(shows) } }
                    ))
                } footer: {
                    Text("A Mac inside the app, with agents in every state, to try Cherry without one.")
                }
            }
        }
        .navigationTitle("Macs")
        .sheet(item: $editing) { endpoint in
            NavigationStack {
                MacEditor(endpoint: endpoint, isNew: model.mac(endpoint.id) == nil) { saved in
                    editing = nil
                    if let saved {
                        Task { await model.save(saved) }
                    }
                }
            }
        }
    }
}

struct MacRow: View {
    let mac: AppModel.Mac
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mac.isDemo ? "sparkles.tv" : "desktopcomputer")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.endpoint.name)
                    .font(.body.weight(.semibold))
                Text(mac.isDemo ? "In this app" : "\(mac.endpoint.user)@\(mac.endpoint.host)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                statusText
                    .font(.footnote)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusText: some View {
        switch mac.status {
        case .idle:
            Text("Not connected").foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .connected:
            Label("Connected · \(sessionCount) session\(sessionCount == 1 ? "" : "s")", systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .green))
        case .awaitingTrust:
            Label("Waiting for you to trust its host key", systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .orange))
        case .failed(let reason):
            Label(reason, systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .red))
                .lineLimit(3)
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(color)
            configuration.title
                .foregroundStyle(.secondary)
        }
    }
}

struct DeviceKeyView: View {
    let key: Result<String, AppModel.KeyUnavailable>?
    @State private var copied = false

    var body: some View {
        switch key {
        case .success(let line):
            VStack(alignment: .leading, spacing: 8) {
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                Button(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = line
                    copied = true
                }
            }
        case .failure(let problem):
            Label(problem.reason, systemImage: "key.slash")
                .foregroundStyle(.secondary)
        case nil:
            ProgressView()
        }
    }
}

/// Adds or edits a Mac.
struct MacEditor: View {
    @State private var endpoint: MacEndpoint
    @State private var port: String
    @State private var cherryPath: String
    let isNew: Bool
    let done: (MacEndpoint?) -> Void

    init(endpoint: MacEndpoint, isNew: Bool, done: @escaping (MacEndpoint?) -> Void) {
        _endpoint = State(initialValue: endpoint)
        _port = State(initialValue: String(endpoint.port))
        _cherryPath = State(initialValue: endpoint.cherryPath ?? "")
        self.isNew = isNew
        self.done = done
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $endpoint.name, prompt: Text("patstudio"))
                TextField("Host", text: $endpoint.host, prompt: Text("patstudio.tailnet.ts.net"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                TextField("User", text: $endpoint.user, prompt: Text("patrick"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                TextField("Cherry helper", text: $cherryPath, prompt: Text("Found by itself"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
            } footer: {
                Text("Leave empty to use ~/Applications/Cherry.app, then /Applications/Cherry.app.")
            }
            if let fingerprint = endpoint.hostKeyFingerprint {
                Section("Host key") {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("Forget Host Key", role: .destructive) {
                        endpoint.hostKeyFingerprint = nil
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Add a Mac" : endpoint.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { done(nil) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = endpoint
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.host = saved.host.trimmingCharacters(in: .whitespaces)
                    saved.user = saved.user.trimmingCharacters(in: .whitespaces)
                    saved.port = Int(port) ?? 22
                    let path = cherryPath.trimmingCharacters(in: .whitespaces)
                    saved.cherryPath = path.isEmpty ? nil : path
                    if saved.name.isEmpty { saved.name = saved.host }
                    done(saved)
                }
                .disabled(endpoint.host.trimmingCharacters(in: .whitespaces).isEmpty
                    || endpoint.user.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
