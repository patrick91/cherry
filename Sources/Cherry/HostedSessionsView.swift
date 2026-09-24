import SwiftUI

@MainActor
final class HostedSessionsController: ObservableObject {
    @Published private(set) var sessions: [HostedSessionInfo] = []
    @Published private(set) var hostID: String?
    @Published private(set) var isBusy = false
    @Published var error: String?
    /// The host whose answer did not match its trusted identity.
    @Published private(set) var identityMismatchHost: HostedSessionHost?
    private(set) var loadedHost: HostedSessionHost?
    /// Set when this copy of the app must not start a local session daemon
    /// (it runs from a disk image). No command runs for "This Mac" then.
    let localHostUnavailableReason: String?
    /// As provided: resolving its login environment can run the user's shell.
    private var client: HostedSessionClient?
    /// What the last list or create resolved, for the helpers that follow and
    /// the attach adapters they lead to. Resolving again could run the
    /// user's shell on the main actor, or in the middle of a kill poll.
    private var loginEnvironment: HostedSessionLoginEnvironment.Capture?
    private let clientProvider: () throws -> HostedSessionClient
    private let hostStore: HostedSessionHostStore
    private let terminationTimeout: TimeInterval

    init(
        clientProvider: @escaping () throws -> HostedSessionClient = { try HostedSessionClient.installed() },
        hostStore: HostedSessionHostStore = .shared,
        terminationTimeout: TimeInterval = 5,
        localHostUnavailableReason: String? = HostedSessionInstallation.localHostUnavailableReason()
    ) {
        self.clientProvider = clientProvider
        self.hostStore = hostStore
        self.terminationTimeout = terminationTimeout
        self.localHostUnavailableReason = localHostUnavailableReason
    }

    func isUnavailable(_ host: HostedSessionHost) -> Bool {
        host.sshDestination == nil && localHostUnavailableReason != nil
    }

    /// `retryingLoginEnvironment` is for the Refresh button: it tries the
    /// login shell again even while the wait after a failed capture lasts.
    func refresh(_ host: HostedSessionHost, retryingLoginEnvironment: Bool = false) async {
        await load(host, acceptingNewIdentity: false, retryingLoginEnvironment: retryingLoginEnvironment)
    }

    /// Lists without the saved identity and trusts whatever answers. Only for
    /// an explicit user decision after a mismatch.
    func trustNewHostIdentity(_ host: HostedSessionHost) async {
        await load(host, acceptingNewIdentity: true)
    }

    private func load(
        _ host: HostedSessionHost,
        acceptingNewIdentity: Bool,
        retryingLoginEnvironment: Bool = false
    ) async {
        guard !isBusy else { return }
        error = nil
        identityMismatchHost = nil
        if loadedHost != host || isUnavailable(host) {
            sessions = []
            hostID = nil
            loadedHost = nil
        }
        // Even `list` would start the daemon from the disk image.
        guard !isUnavailable(host) else { return }
        isBusy = true
        defer { isBusy = false }
        let trustedHostID = acceptingNewIdentity ? nil : hostStore.trustedHostID(for: host)
        var sshRanWithoutLoginEnvironment = false
        do {
            let client = try clientProvider()
            await resolveLoginEnvironment(with: client, retryingNow: retryingLoginEnvironment)
            sshRanWithoutLoginEnvironment = host.sshDestination != nil && loginEnvironment?.fromUserShell != true
            let result = try await pinned(client).list(on: host, expectedHostID: trustedHostID)
            if let trustedHostID, result.hostID != trustedHostID {
                throw HostedSessionError.identityMismatch(
                    "Expected host identity \(trustedHostID), received \(result.hostID)."
                )
            }
            hostStore.trust(result.hostID, for: host)
            self.client = client
            hostID = result.hostID
            loadedHost = host
            sessions = result.sessions
        } catch let failure as HostedSessionError where failure.isIdentityMismatch {
            sessions = []
            hostID = nil
            loadedHost = nil
            identityMismatchHost = host
            self.error = "\(host.displayName) answered with a different host identity than the one Cherry trusts. "
                + "A host keeps its identity across restarts and reboots. It changes when the host's "
                + "cherry-host state directory is deleted or reset (~/Library/Application Support/cherry-host on macOS, "
                + "${XDG_STATE_HOME:-~/.local/state}/cherry-host on Linux), when the host runs as another user or with "
                + "another state directory or socket path, or when a different machine answers for this name. "
                + "Trust the new identity only if you expected this change.\n\(failure.localizedDescription)"
        } catch {
            hostID = nil
            loadedHost = nil
            // ssh runs without a shell: without the login shell's environment,
            // an agent socket exported only from its startup files was
            // missing. Only a failure to connect or authenticate can say so.
            let explainsFailure = sshRanWithoutLoginEnvironment
                && (error as? HostedSessionError)?.isTransportFailure == true
            self.error = error.localizedDescription
                + (explainsFailure ? " " + Self.missingLoginEnvironmentHint : "")
        }
    }

    /// Resolves the login environment off the main actor and keeps it.
    private func resolveLoginEnvironment(with client: HostedSessionClient, retryingNow: Bool) async {
        loginEnvironment = await client.resolvedLoginEnvironment(retryingNow: retryingNow)
    }

    /// `client` with the kept login environment, so its helpers never run
    /// the user's shell.
    private func pinned(_ client: HostedSessionClient) -> HostedSessionClient {
        let environment = loginEnvironment
        var pinned = client
        pinned.loginEnvironment = { _ in environment }
        return pinned
    }

    static let missingLoginEnvironmentHint = "Cherry could not read the environment your login shell "
        + "(\(ShellProcessController.defaultShellName)) sets up, so ssh ran without variables that its "
        + "startup files export, such as SSH_AUTH_SOCK. Refresh to try again."

    func create(on host: HostedSessionHost, name: String, cwd: String) async -> HostedSessionAttachment? {
        guard !isBusy, !isUnavailable(host), loadedHost == host, let client, let hostID else { return nil }
        isBusy = true
        error = nil
        defer { isBusy = false }
        // One request ID per Create action. The host creates at most one
        // session for it, so retrying after a lost response cannot duplicate it.
        let requestID = UUID()
        await resolveLoginEnvironment(with: client, retryingNow: false)
        let creating = pinned(client)
        do {
            let session: HostedSessionInfo
            do {
                session = try await creating.create(
                    on: host, expectedHostID: hostID, name: name, cwd: cwd, requestID: requestID
                )
            } catch let failure as HostedSessionError where failure.isTransportFailure {
                session = try await creating.create(
                    on: host, expectedHostID: hostID, name: name, cwd: cwd, requestID: requestID
                )
            }
            sessions.removeAll { $0.id == session.id }
            sessions.append(session)
            return attachment(for: session, host: host, hostID: hostID, client: client)
        } catch let failure as HostedSessionError where failure.isTransportFailure {
            self.error = "\(failure.localizedDescription) Refresh before trying again; the session may have been created."
        } catch {
            self.error = error.localizedDescription
        }
        return nil
    }

    func attachment(for session: HostedSessionInfo, on host: HostedSessionHost) -> HostedSessionAttachment? {
        guard !isUnavailable(host), loadedHost == host, let hostID, let client else { return nil }
        return attachment(for: session, host: host, hostID: hostID, client: client)
    }

    func terminate(_ session: HostedSessionInfo, on host: HostedSessionHost) async {
        guard !isBusy, loadedHost == host, let client = client.map(pinned), let hostID else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            try await client.terminate(session.id, on: host, expectedHostID: hostID)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            return
        }

        // Kill acknowledges a request; the session worker publishes exit
        // asynchronously. Keep the same host identity until it confirms this
        // session exited (or another client removed its exited row).
        let unconfirmed = "Termination was requested, but the host has not confirmed that the session exited yet. Refresh to check its state."
        let deadline = Date().addingTimeInterval(terminationTimeout)
        do {
            while true {
                try Task.checkCancellation()
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    self.error = unconfirmed
                    return
                }
                var pollingClient = client
                pollingClient.timeout = min(client.timeout, remaining)
                let result = try await pollingClient.list(on: host, expectedHostID: hostID)
                try Task.checkCancellation()
                guard result.hostID == hostID else {
                    throw HostedSessionError.identityMismatch("received \(result.hostID)")
                }
                guard loadedHost == host, self.hostID == hostID else { return }
                sessions = result.sessions
                guard result.sessions.first(where: { $0.id == session.id })?.isRunning == true else { return }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch is CancellationError {
            return
        } catch let failure as HostedSessionError where failure.isIdentityMismatch {
            self.hostID = nil
            loadedHost = nil
            self.error = "The host identity changed while waiting for the session to exit. Refresh to reconnect to the intended host."
        } catch {
            // A failed or timed-out poll says nothing about the kill the host
            // already accepted.
            self.error = unconfirmed
        }
    }

    func remove(_ session: HostedSessionInfo, on host: HostedSessionHost) async {
        guard !isBusy, !session.isRunning, loadedHost == host, let client = client.map(pinned), let hostID else { return }
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
            executablePath: client.executableURL.path,
            environment: loginEnvironment?.environment ?? [:]
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

    private var canAttachSelectedSession: Bool {
        !controller.isBusy && controller.loadedHost == selectedHost && selectedSession?.isRunning == true
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

            if let reason = controller.localHostUnavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
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
                    .help("Remove this saved host and its trusted identity; its sessions keep running")
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await controller.refresh(selectedHost, retryingLoginEnvironment: true) }
                }
                .labelStyle(.iconOnly)
                .help("Refresh sessions")
                .disabled(controller.isUnavailable(selectedHost))
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
                        Text(session.statusText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(session.id)
                }
            }
            .overlay {
                if controller.isUnavailable(selectedHost) {
                    ContentUnavailableView(
                        "Sessions on This Mac are unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This copy of the app runs from a disk image, so it does not start a local session host. SSH hosts still work.")
                    )
                } else if controller.sessions.isEmpty, !controller.isBusy {
                    ContentUnavailableView(
                        controller.hostID == nil ? "Connect to a session host" : "No sessions yet",
                        systemImage: "terminal",
                        description: Text(controller.hostID == nil
                            ? "The cherry-host executable must be available on the selected machine."
                            : "Create a shell below. It keeps running when you close Cherry.")
                    )
                }
            }
            .frame(minHeight: 190)
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
                        .disabled(!canAttachSelectedSession)
                }
                Button("Attach & Take Over") { attachSelectedSession(takeover: true) }
                    .disabled(!canAttachSelectedSession)
                    .help("Open this session here and disconnect every other client attached to it. The session's terminal size then follows this window.")
                Button("Attach") { attachSelectedSession(takeover: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAttachSelectedSession)
                    .help("Open this session here. Other attached terminals stay connected and can also type.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("New Session").font(.headline)
                HStack {
                    TextField("Name", text: $sessionName)
                    TextField("Working directory (default: home)", text: $workingDirectory)
                        .frame(minWidth: 280)
                        .help("An absolute path or ~/path on the selected host. Leave empty for its home directory.")
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
                HStack(alignment: .top) {
                    ScrollView {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if controller.identityMismatchHost == selectedHost {
                        Button("Trust New Host Identity") {
                            Task { await controller.trustNewHostIdentity(selectedHost) }
                        }
                        .disabled(controller.isBusy)
                        .help("Accept the identity this host now reports and remember it for future connections")
                    }
                }
                .frame(maxHeight: 76)
            }
        }
        .padding(24)
        .frame(width: 720, height: 640)
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

    private func attachSelectedSession(takeover: Bool) {
        guard let selectedSession,
              let attachment = controller.attachment(for: selectedSession, on: selectedHost)
        else { return }
        attach(attachment, takeover: takeover)
    }

    private func attach(_ attachment: HostedSessionAttachment, takeover: Bool = false) {
        workspace.attachHostedSession(attachment, takeover: takeover)
        chromeState.selectTerminal()
        dismiss()
    }
}

/// What a hosted tab's connection bar shows for the tab's current state.
struct HostedConnectionBarState: Equatable {
    enum Action: Equatable {
        case disconnect
        case reconnect
        case removeFromHost
        /// Disabled for a workspace's last tab, which stays open.
        case closeTab(enabled: Bool)
    }

    let message: String?
    let actions: [Action]

    init(isRunning: Bool, status: HostedAttachmentStatus?, removedFromHost: Bool, canClose: Bool) {
        if isRunning {
            message = nil
            actions = [.disconnect]
        } else if let status, status.sessionEnded {
            // Removing twice would only fail with the host's "no such session".
            message = removedFromHost ? "Removed from host" : status.summary
            actions = (removedFromHost ? [] : [.removeFromHost]) + [.closeTab(enabled: canClose)]
        } else if let status {
            message = status.summary
            actions = [.reconnect]
        } else {
            message = nil
            actions = []
        }
    }
}

struct HostedSessionConnectionBar: View {
    @ObservedObject var session: TerminalSession
    /// nil when the tab cannot be closed (the workspace's last tab).
    let close: (() -> Void)?
    @State private var isRemoving = false
    @State private var removalError: String?

    var body: some View {
        if let attachment = session.hostedAttachment {
            let state = HostedConnectionBarState(
                isRunning: session.isRunning,
                status: session.hostedAttachmentStatus,
                removedFromHost: session.hostedSessionRemovedFromHost,
                canClose: close != nil
            )
            HStack(spacing: 10) {
                Image(systemName: attachment.host.sshDestination == nil ? "desktopcomputer" : "network")
                Text(attachment.host.displayName).fontWeight(.medium)
                Text(attachment.remoteWorkingDirectory).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if let message = removalError ?? state.message {
                    Text(message)
                        .foregroundStyle(removalError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(message)
                }
                ForEach(Array(state.actions.enumerated()), id: \.offset) { _, action in
                    button(for: action, attachment: attachment)
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func button(for action: HostedConnectionBarState.Action, attachment: HostedSessionAttachment) -> some View {
        switch action {
        case .disconnect:
            Button("Disconnect") { session.disconnectHostedSession() }
        case .reconnect:
            Button("Reconnect") { session.reconnectHostedSession() }
                .buttonStyle(.borderedProminent)
        case .removeFromHost:
            Button("Remove from Host") { remove(attachment) }
                .disabled(isRemoving)
                .help(close == nil
                    ? "Delete this ended session and its retained history on \(attachment.host.displayName)"
                    : "Delete this ended session and its retained history on \(attachment.host.displayName), then close the tab")
        case .closeTab(let enabled):
            Button("Close Tab") { close?() }
                .buttonStyle(.borderedProminent)
                .disabled(!enabled)
                .help(enabled ? "Close this tab" : "The last tab in a workspace stays open. Open another tab to close this one.")
        }
    }

    private func remove(_ attachment: HostedSessionAttachment) {
        isRemoving = true
        removalError = nil
        Task {
            defer { isRemoving = false }
            do {
                try await attachment.client.remove(
                    attachment.sessionID, on: attachment.host, expectedHostID: attachment.hostID
                )
                session.noteHostedSessionRemovedFromHost()
                close?()
            } catch {
                removalError = error.localizedDescription
            }
        }
    }
}
