import Combine
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
    /// (it runs from a disk image). No helper runs for "This Mac" then.
    let localHostUnavailableReason: String?
    private let controls: HostControlRegistry
    private let hostStore: HostedSessionHostStore
    private let terminationTimeout: TimeInterval
    /// Keeps the loaded host's connection (and its live session list) up
    /// while the sheet shows it.
    private var lease: HostControlLease?
    private var sessionUpdates: AnyCancellable?
    /// The load under way. A load of another host (the picker changed)
    /// replaces it; the replaced one then changes nothing.
    private var loading: (host: HostedSessionHost, generation: Int)?
    private var loadGeneration = 0

    init(
        controls: HostControlRegistry = .shared,
        hostStore: HostedSessionHostStore = .shared,
        terminationTimeout: TimeInterval = 5,
        localHostUnavailableReason: String? = HostedSessionInstallation.localHostUnavailableReason()
    ) {
        self.controls = controls
        self.hostStore = hostStore
        self.terminationTimeout = terminationTimeout
        self.localHostUnavailableReason = localHostUnavailableReason
    }

    func isUnavailable(_ host: HostedSessionHost) -> Bool {
        host.sshDestination == nil && localHostUnavailableReason != nil
    }

    /// `retryingLoginEnvironment` is for the Refresh button: a new connection
    /// tries the login shell again even while the wait after a failed
    /// capture lasts.
    func refresh(_ host: HostedSessionHost, retryingLoginEnvironment: Bool = false) async {
        await load(host, acceptingNewIdentity: false, retryingLoginEnvironment: retryingLoginEnvironment)
    }

    /// Reconnects and trusts whatever identity answers. Only for an explicit
    /// user decision after a mismatch.
    func trustNewHostIdentity(_ host: HostedSessionHost) async {
        await load(host, acceptingNewIdentity: true)
    }

    private func load(
        _ host: HostedSessionHost,
        acceptingNewIdentity: Bool,
        retryingLoginEnvironment: Bool = false
    ) async {
        if isBusy {
            // Only switching hosts replaces a load under way; any other
            // operation (or a load of the same host) finishes first.
            guard let loading, loading.host != host else { return }
        }
        loadGeneration += 1
        let generation = loadGeneration
        error = nil
        identityMismatchHost = nil
        if loadedHost != host || isUnavailable(host) {
            unload()
        }
        // Even connecting would start the daemon from the disk image.
        guard !isUnavailable(host) else {
            loading = nil
            isBusy = false
            return
        }
        loading = (host, generation)
        isBusy = true
        defer {
            if loading?.generation == generation {
                loading = nil
                isBusy = false
            }
        }
        let control = controls.control(for: host)
        do {
            if acceptingNewIdentity {
                try await control.trustNewIdentity(retryingLoginEnvironment: retryingLoginEnvironment)
            }
            let result = try await control.list(retryingLoginEnvironment: retryingLoginEnvironment)
            guard loading?.generation == generation else { return }
            hostID = result.hostID
            loadedHost = host
            sessions = result.sessions
            follow(control, identity: result.hostID)
        } catch is CancellationError {
            // The sheet moved on (another host, or it closed).
            return
        } catch let failure as HostedSessionError where failure.isIdentityMismatch {
            guard loading?.generation == generation else { return }
            unload()
            identityMismatchHost = host
            self.error = "\(host.displayName) answered with a different host identity than the one Cherry trusts. "
                + "A host keeps its identity across restarts and reboots. It changes when the host's "
                + "cherry-host state directory is deleted or reset (~/Library/Application Support/cherry-host on macOS, "
                + "${XDG_STATE_HOME:-~/.local/state}/cherry-host on Linux), when the host runs as another user or with "
                + "another state directory or socket path, or when a different machine answers for this name. "
                + "Trust the new identity only if you expected this change.\n\(failure.localizedDescription)"
        } catch {
            guard loading?.generation == generation else { return }
            hostID = nil
            loadedHost = nil
            sessionUpdates = nil
            lease?.release()
            lease = nil
            // ssh runs without a shell: without the login shell's environment,
            // an agent socket exported only from its startup files was
            // missing. Only a failure to connect or authenticate can say so.
            let failure = error as? HostedSessionError
            let explainsFailure = host.sshDestination != nil
                && control.loginEnvironment?.fromUserShell != true
                && (failure?.isTransportFailure == true || failure?.isUnavailable == true)
            self.error = error.localizedDescription
                + (explainsFailure ? " " + Self.missingLoginEnvironmentHint : "")
        }
    }

    /// Mirrors the host's live session list while it is the same host.
    private func follow(_ control: HostControl, identity: String) {
        let host = control.host
        if lease == nil { lease = control.retain() }
        sessionUpdates = control.$sessions.dropFirst().sink { [weak self, weak control] sessions in
            guard let self, let control, self.loadedHost == host, self.hostID == identity,
                  control.hostID == nil || control.hostID == identity
            else { return }
            self.sessions = sessions
        }
    }

    private func unload() {
        sessions = []
        hostID = nil
        loadedHost = nil
        sessionUpdates = nil
        lease?.release()
        lease = nil
    }

    static let missingLoginEnvironmentHint = "Cherry could not read the environment your login shell "
        + "(\(ShellProcessController.defaultShellName)) sets up, so ssh ran without variables that its "
        + "startup files export, such as SSH_AUTH_SOCK. Refresh to try again."

    func create(on host: HostedSessionHost, name: String, cwd: String) async -> HostedSessionAttachment? {
        guard !isBusy, !isUnavailable(host), loadedHost == host, let hostID else { return nil }
        isBusy = true
        error = nil
        defer { isBusy = false }
        let control = controls.control(for: host)
        do {
            // Typed text: surrounding spaces and newlines are not part of
            // the path (the control takes a path as given).
            let cwd = try HostedSessionClient.hostWorkingDirectory(cwd)
            // One request ID per Create action. The host creates at most one
            // session for it, so the control's retry after a lost answer
            // cannot duplicate it.
            let session = try await control.create(name: name, cwd: cwd, requestID: UUID(), expectedHostID: hostID)
            sessions.removeAll { $0.id == session.id }
            sessions.append(session)
            return attachment(for: session, host: host, hostID: hostID, control: control)
        } catch let failure as HostedSessionError where failure.isTransportFailure {
            self.error = "\(failure.localizedDescription) Refresh before trying again; the session may have been created."
        } catch {
            self.error = error.localizedDescription
        }
        return nil
    }

    func attachment(for session: HostedSessionInfo, on host: HostedSessionHost) -> HostedSessionAttachment? {
        guard !isUnavailable(host), loadedHost == host, let hostID else { return nil }
        return attachment(for: session, host: host, hostID: hostID, control: controls.control(for: host))
    }

    func terminate(_ session: HostedSessionInfo, on host: HostedSessionHost) async {
        guard !isBusy, loadedHost == host, let hostID else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        let control = controls.control(for: host)
        do {
            try Task.checkCancellation()
            try await control.terminate(session.id, expectedHostID: hostID)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            return
        }

        // Kill acknowledges a request; the host reports the exit later. Wait
        // for this session to exit (or for another client to remove it) on
        // the same host identity.
        let ended: Bool
        do {
            ended = try await control.waitForSession(session.id, timeout: .seconds(terminationTimeout)) { current in
                if let identity = control.hostID, identity != hostID { return true }
                return current?.isRunning != true
            }
        } catch {
            return
        }
        guard loadedHost == host, self.hostID == hostID else { return }
        // Another host answered: either this Mac's (never pinned), or an SSH
        // host the control refused, whose last known list is still shown.
        let identityChanged: Bool
        if let identity = control.hostID {
            identityChanged = identity != hostID
        } else if case .failed(let failure) = control.state {
            identityChanged = failure.isIdentityMismatch
        } else {
            identityChanged = false
        }
        if identityChanged {
            self.hostID = nil
            loadedHost = nil
            sessionUpdates = nil
            self.error = "The host identity changed while waiting for the session to exit. Refresh to reconnect to the intended host."
            return
        }
        if !ended {
            self.error = "Termination was requested, but the host has not confirmed that the session exited yet. Refresh to check its state."
        }
    }

    func remove(_ session: HostedSessionInfo, on host: HostedSessionHost) async {
        guard !isBusy, !session.isRunning, loadedHost == host, let hostID else { return }
        isBusy = true
        error = nil
        do {
            try await controls.control(for: host).remove(session.id, expectedHostID: hostID)
        } catch {
            self.error = error.localizedDescription
            isBusy = false
            return
        }
        isBusy = false
        await refresh(host)
    }

    /// Attach adapters get the helper and the login environment the host's
    /// control connection runs with.
    private func attachment(
        for session: HostedSessionInfo,
        host: HostedSessionHost,
        hostID: String,
        control: HostControl
    ) -> HostedSessionAttachment? {
        guard let executableURL = control.executableURL else { return nil }
        return HostedSessionAttachment(
            host: host,
            hostID: hostID,
            sessionID: session.id,
            name: session.displayName,
            remoteWorkingDirectory: session.cwd,
            executablePath: executableURL.path,
            environment: control.loginEnvironment?.environment ?? [:]
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

    private var canActOnSelectedSession: Bool {
        !controller.isBusy && controller.loadedHost == selectedHost && selectedSession?.isRunning == true
    }

    /// Not a session this app is ending: its closed tab's ⌘Z brings it
    /// back as the tab's own (`BackgroundSessionsModel.isEnding`).
    private var canAttachSelectedSession: Bool {
        guard canActOnSelectedSession, let selectedSession else { return false }
        guard selectedHost == .local, let hostID = controller.hostID else { return true }
        return !BackgroundSessionsModel.shared.isEnding(selectedSession, hostID: hostID)
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
                        if let label = ownershipLabel(for: session) {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
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
                Text(selectedHost == .local
                    ? "Closing a tab ends this app's own sessions and disconnects from the others. Terminate stops the session."
                    : "Closing a tab disconnects it. Terminate stops the hosted process.")
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
                        .disabled(!canActOnSelectedSession)
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
        attach(attachment, takeover: takeover, info: selectedSession)
    }

    /// A session on This Mac that this app started, and that no tab or other
    /// client shows, becomes a regular tab of this window (closing it follows
    /// Settings › Sessions); others attach, and closing them only disconnects.
    private func attach(_ attachment: HostedSessionAttachment, takeover: Bool = false, info: HostedSessionInfo? = nil) {
        workspace.attachHostedSession(attachment, takeover: takeover, info: info)
        chromeState.selectTerminal()
        dismiss()
    }

    /// Marks this app's own sessions: those being ended (their tab closed;
    /// they cannot be attached), those an open tab shows, those in the
    /// background (Background Sessions in the menu bar lists them), and the
    /// others (a window's restore may still bring them back).
    private func ownershipLabel(for session: HostedSessionInfo) -> String? {
        guard selectedHost == .local, let hostID = controller.hostID else { return nil }
        return BackgroundSessionsModel.shared.ownershipLabel(for: session, hostID: hostID)
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

    /// `reconnecting`: the running adapter has been reconnecting by itself
    /// for a while (its host restarted); it keeps the tab's screen.
    init(
        isRunning: Bool,
        status: HostedAttachmentStatus?,
        removedFromHost: Bool,
        canClose: Bool,
        reconnecting: Bool = false
    ) {
        if isRunning {
            message = reconnecting ? "Reconnecting…" : nil
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
                canClose: close != nil,
                reconnecting: session.isAdapterReconnecting
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
                try await HostControlRegistry.shared.control(for: attachment.host).remove(
                    attachment.sessionID, expectedHostID: attachment.hostID
                )
                session.noteHostedSessionRemovedFromHost()
                close?()
            } catch {
                removalError = error.localizedDescription
            }
        }
    }
}
