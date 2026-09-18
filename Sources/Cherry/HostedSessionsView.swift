import SwiftUI

@MainActor
final class HostedSessionsController: ObservableObject {
    @Published private(set) var sessions: [HostedSessionInfo] = []
    @Published private(set) var hostID: String?
    @Published private(set) var isBusy = false
    @Published var error: String?
    private(set) var loadedHost: HostedSessionHost?
    private var client: HostedSessionClient?
    private let clientProvider: () throws -> HostedSessionClient
    private let terminationTimeout: TimeInterval

    init(
        clientProvider: @escaping () throws -> HostedSessionClient = { try HostedSessionClient.installed() },
        terminationTimeout: TimeInterval = 5
    ) {
        self.clientProvider = clientProvider
        self.terminationTimeout = terminationTimeout
    }

    func refresh(_ host: HostedSessionHost) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        if loadedHost != host {
            sessions = []
            hostID = nil
            loadedHost = nil
        }
        defer { isBusy = false }
        do {
            let client = try clientProvider()
            let result = try await client.list(on: host)
            self.client = client
            hostID = result.hostID
            loadedHost = host
            sessions = result.sessions
        } catch {
            hostID = nil
            loadedHost = nil
            self.error = error.localizedDescription
        }
    }

    func create(on host: HostedSessionHost, name: String, cwd: String) async -> HostedSessionAttachment? {
        guard !isBusy, loadedHost == host, let client, let hostID else { return nil }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            // Never retry a create automatically: a lost response may still have
            // created the session. Refresh lets the user reconcile it by name/ID.
            let session = try await client.create(on: host, expectedHostID: hostID, name: name, cwd: cwd)
            sessions.append(session)
            return attachment(for: session, host: host, hostID: hostID, client: client)
        } catch {
            self.error = "\(error.localizedDescription) Refresh before trying again; the session may have been created."
            return nil
        }
    }

    func attachment(for session: HostedSessionInfo, on host: HostedSessionHost) -> HostedSessionAttachment? {
        guard loadedHost == host, let hostID, let client else { return nil }
        return attachment(for: session, host: host, hostID: hostID, client: client)
    }

    func terminate(_ session: HostedSessionInfo, on host: HostedSessionHost) async {
        guard !isBusy, loadedHost == host, let client, let hostID else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            try await client.terminate(session.id, on: host, expectedHostID: hostID)
            // Kill acknowledges a request; the session worker publishes exit
            // asynchronously. Keep the same host identity until it confirms
            // this session exited (or another client removed its exited row).
            let deadline = Date().addingTimeInterval(terminationTimeout)
            while true {
                try Task.checkCancellation()
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    throw HostedSessionError.message("Termination was requested, but the host has not confirmed the session exited. Refresh to check its state.")
                }
                var pollingClient = client
                pollingClient.timeout = min(client.timeout, remaining)
                let result = try await pollingClient.list(on: host, expectedHostID: hostID)
                try Task.checkCancellation()
                guard result.hostID == hostID else {
                    self.hostID = nil
                    loadedHost = nil
                    throw HostedSessionError.message("The host identity changed while waiting for the session to exit. Refresh to reconnect to the intended host.")
                }
                guard loadedHost == host, self.hostID == hostID else { return }
                sessions = result.sessions
                guard result.sessions.first(where: { $0.id == session.id })?.isRunning == true else { return }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ session: HostedSessionInfo, on host: HostedSessionHost) async {
        guard !isBusy, !session.isRunning, loadedHost == host, let client, let hostID else { return }
        isBusy = true
        error = nil
        do {
            try await client.remove(session.id, on: host, expectedHostID: hostID)
        } catch {
            self.error = error.localizedDescription
            isBusy = false
            return
        }
        isBusy = false
        await refresh(host)
    }

    private func attachment(
        for session: HostedSessionInfo,
        host: HostedSessionHost,
        hostID: String,
        client: HostedSessionClient
    ) -> HostedSessionAttachment {
        HostedSessionAttachment(
            host: host,
            hostID: hostID,
            sessionID: session.id,
            name: session.displayName,
            remoteWorkingDirectory: session.cwd,
            executablePath: client.executableURL.path
        )
    }
}

struct HostedSessionsSheet: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject private var hosts = HostedSessionHostStore.shared
    @StateObject private var controller = HostedSessionsController()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedHost = HostedSessionHost.local
    @State private var newHost = ""
    @State private var sessionName = ""
    @State private var workingDirectory = ""
    @State private var selectedSessionID: String?
    @State private var terminationCandidate: HostedSessionInfo?

    private var selectedSession: HostedSessionInfo? {
        controller.sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Persistent Sessions").font(.title2.weight(.semibold))
                    Text("Reconnect to shells on this Mac or an SSH host.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack {
                Picker("Host", selection: $selectedHost) {
                    Text("This Mac").tag(HostedSessionHost.local)
                    ForEach(hosts.hosts) { host in Text(host.displayName).tag(host) }
                }
                if selectedHost.sshDestination != nil {
                    Button("Forget Host", systemImage: "minus.circle") {
                        hosts.remove(selectedHost)
                        selectedHost = .local
                    }
                    .labelStyle(.iconOnly)
                    .help("Remove this saved host; its sessions keep running")
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await controller.refresh(selectedHost) }
                }
                .labelStyle(.iconOnly)
                .help("Refresh sessions")
                if controller.isBusy { ProgressView().controlSize(.small) }
            }
            .disabled(controller.isBusy)

            HStack {
                TextField("SSH alias or user@hostname", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveHost)
                Button("Add Host", action: saveHost)
                    .disabled(newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(controller.isBusy)

            List(selection: $selectedSessionID) {
                ForEach(controller.sessions) { session in
                    HStack(spacing: 10) {
                        Image(systemName: session.isRunning ? "terminal" : "checkmark.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.displayName).fontWeight(.medium)
                            Text(session.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(session.isRunning ? (session.attached ? "Attached" : "Running") : "Exited")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(session.id)
                }
            }
            .overlay {
                if controller.sessions.isEmpty, !controller.isBusy {
                    ContentUnavailableView(
                        controller.hostID == nil ? "Connect to a session host" : "No sessions yet",
                        systemImage: "terminal",
                        description: Text(controller.hostID == nil
                            ? "The cherry-host executable must be available on the selected machine."
                            : "Create a shell below. It keeps running when you close Cherry.")
                    )
                }
            }
            .frame(minHeight: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Closing a tab disconnects it. Terminate stops the hosted process.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let selectedSession, !selectedSession.isRunning {
                    Button("Remove") {
                        Task { await controller.remove(selectedSession, on: selectedHost) }
                    }
                    .disabled(controller.isBusy || controller.loadedHost != selectedHost)
                    .help("Remove this exited session and its retained terminal history")
                } else {
                    Button("Terminate…", role: .destructive) { terminationCandidate = selectedSession }
                        .disabled(controller.isBusy || controller.loadedHost != selectedHost || selectedSession?.isRunning != true)
                }
                Button("Attach") {
                    if let selectedSession,
                       let attachment = controller.attachment(for: selectedSession, on: selectedHost) {
                        attach(attachment)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isBusy || controller.loadedHost != selectedHost || selectedSession?.isRunning != true)
                .help("Open this session here. Other attached terminals stay connected and can also type.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("New Session").font(.headline)
                HStack {
                    TextField("Name", text: $sessionName)
                    TextField("Working directory (default: home)", text: $workingDirectory)
                        .frame(minWidth: 280)
                        .help("An absolute path on the selected host. Leave empty for its home directory.")
                    Button("Create & Attach") {
                        Task {
                            let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let cwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let attachment = await controller.create(on: selectedHost, name: name, cwd: cwd) {
                                attach(attachment)
                            }
                        }
                    }
                    .disabled(sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isBusy || controller.loadedHost != selectedHost)
            }

            if let error = controller.error {
                ScrollView {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 76)
            }
        }
        .padding(24)
        .frame(width: 720, height: 610)
        .task(id: selectedHost.id) {
            selectedSessionID = nil
            await controller.refresh(selectedHost)
        }
        .confirmationDialog("Terminate this hosted session?", isPresented: Binding(
            get: { terminationCandidate != nil },
            set: { if !$0 { terminationCandidate = nil } }
        ), titleVisibility: .visible) {
            if let candidate = terminationCandidate {
                Button("Terminate \(candidate.displayName)", role: .destructive) {
                    Task { await controller.terminate(candidate, on: selectedHost) }
                    terminationCandidate = nil
                }
            }
        } message: {
            Text("The session and its running programs will stop on \(selectedHost.displayName).")
        }
    }

    private func saveHost() {
        do {
            selectedHost = try hosts.add(newHost)
            newHost = ""
        } catch {
            controller.error = error.localizedDescription
        }
    }

    private func attach(_ attachment: HostedSessionAttachment) {
        workspace.attachHostedSession(attachment)
        chromeState.selectTerminal()
        dismiss()
    }
}

struct HostedSessionConnectionBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let attachment = session.hostedAttachment {
            HStack(spacing: 10) {
                Image(systemName: attachment.host.sshDestination == nil ? "desktopcomputer" : "network")
                Text(attachment.host.displayName).fontWeight(.medium)
                Text(attachment.remoteWorkingDirectory).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if session.isRunning {
                    Button("Disconnect") { session.disconnectHostedSession() }
                } else {
                    Text("Disconnected").foregroundStyle(.secondary)
                    Button("Reconnect") { session.reconnectHostedSession() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.bar)
        }
    }
}
