import CherryMobileKit
import SwiftUI
import UIKit

/// The Macs the app reaches, in the inbox's style: Pair a Mac (the code a
/// Mac's Cherry shows) first, then each Mac as a heading with how it stands
/// and where it is, then setting one up by hand (this iPhone's key) and
/// the Demo Mac.
struct MacsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: MacEndpoint?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pairButton
                    .padding(.top, 8)
                ForEach(model.macs) { mac in
                    MacSection(mac: mac, sessionCount: model.sessions.filter { $0.macID == mac.id }.count) {
                        if !mac.isDemo { editing = mac.endpoint }
                    } remove: {
                        Task { await model.remove(mac.id) }
                    }
                }
                byHand
                    .padding(.top, 36)
                if !model.launch.demoOnly {
                    demoToggle
                        .padding(.top, 28)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle("Macs")
        .sheet(item: $editing) { endpoint in
            NavigationStack {
                MacEditor(
                    endpoint: endpoint,
                    isNew: model.mac(endpoint.id) == nil,
                    remove: model.mac(endpoint.id) == nil ? nil : {
                        editing = nil
                        Task { await model.remove(endpoint.id) }
                    }
                ) { saved in
                    editing = nil
                    if let saved {
                        Task { await model.save(saved) }
                    }
                }
            }
        }
    }

    private var pairButton: some View {
        Button {
            model.pairing = AppModel.PairingRequest(offer: nil)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pair a Mac")
                        .font(.headline)
                    Text("Scan the code in Cherry on your Mac: Settings › Devices › Pair iPhone…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var byHand: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up by hand")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Turn on Remote Login on the Mac (System Settings › General › Sharing) and add this iPhone's key to ~/.ssh/authorized_keys there, then add the Mac by its address. With Tailscale, use its tailnet name.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            DeviceKeyView(key: model.deviceKey)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            Button("Add a Mac by Hand…", systemImage: "plus") {
                editing = MacEndpoint(name: "", host: "", user: "")
            }
            .padding(.top, 2)
        }
    }

    private var demoToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Demo Mac", isOn: Binding(
                get: { model.showsDemoMac },
                set: { shows in Task { await model.setShowsDemoMac(shows) } }
            ))
            .font(.body.weight(.medium))
            Text("A Mac inside the app, with agents in every state, to try Cherry without one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// A Mac: its name as a heading, how it stands, and where it is (its user
/// and address); a tap edits it.
struct MacSection: View {
    let mac: AppModel.Mac
    let sessionCount: Int
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(mac.endpoint.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !mac.isDemo {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                status
                    .font(.subheadline)
                Text(mac.isDemo ? "In this app" : "\(mac.endpoint.user)@\(mac.endpoint.host)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.top, 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !mac.isDemo {
                Button("Edit…", systemImage: "pencil", action: edit)
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
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
        case .reconnecting(let reason):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reconnecting… \(reason)").foregroundStyle(.secondary).lineLimit(3)
            }
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
    /// Removes the Mac; nil for a new one.
    let remove: (() -> Void)?
    let done: (MacEndpoint?) -> Void

    init(endpoint: MacEndpoint, isNew: Bool, remove: (() -> Void)? = nil, done: @escaping (MacEndpoint?) -> Void) {
        _endpoint = State(initialValue: endpoint)
        _port = State(initialValue: String(endpoint.port))
        _cherryPath = State(initialValue: endpoint.cherryPath ?? "")
        self.isNew = isNew
        self.remove = remove
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
            if let remove {
                Section {
                    Button("Remove Mac", role: .destructive, action: remove)
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
