import AppKit
import CherryControl
import Combine
import SwiftUI

// The windows, sheets and bars of devices (docs/specs/remote-devices.md).

// MARK: - Add Mac…

/// Add Mac…'s state: the SSH host typed, the check's checklist, what
/// installing this Cherry's session host there would do, the name, and the
/// install's progress. With a cherry-host path typed, nothing is installed:
/// that one is used, as checked.
@MainActor
final class AddDeviceModel: ObservableObject {
    @Published var destination = "" {
        didSet { if destination != oldValue { invalidate() } }
    }
    /// Where cherry-host is on the other Mac, when not on its PATH. A
    /// change asks for a new check before Add; with one given, Add uses it
    /// and installs nothing.
    @Published var remoteHostPath = "" {
        didSet { if remoteHostPath != oldValue { invalidate() } }
    }
    @Published var name = ""
    @Published private(set) var isChecking = false
    @Published private(set) var checklist: RemoteDeviceChecklist?
    @Published private(set) var probe: RemoteDeviceProbeResult?
    /// What Install & Add would do; nil with a cherry-host path typed.
    @Published private(set) var installation: RemoteHostInstallDecision?
    /// The install running now, and what it does.
    @Published private(set) var installStage: RemoteHostInstaller.Stage?
    @Published var error: String?
    /// What the install found once its build ran there (a session host the
    /// check could not see), shown once the Mac is added.
    @Published private(set) var installWarnings: [String] = []

    /// Host aliases from ~/.ssh/config (non-wildcard).
    let aliases: [String]
    private let store: RemoteDeviceStore
    private let shell: @MainActor () async -> RemoteDeviceShell
    private let helpers: @MainActor () async -> Result<RemoteHostHelpers, HostedSessionError>
    /// Runs `ssh <host>` in a local terminal tab (a host key to accept).
    let openInTerminal: @MainActor (String) -> Void
    private var checkedDestination: String?
    private var checkedHostPath: String?
    private var loadedHelpers: RemoteHostHelpers?

    init(
        store: RemoteDeviceStore = .shared,
        aliases: [String] = SSHConfigHosts.userAliases(),
        shell: @escaping @MainActor () async -> RemoteDeviceShell = { await RemoteDeviceShell.app() },
        helpers: @escaping @MainActor () async -> Result<RemoteHostHelpers, HostedSessionError> = { await RemoteHostHelpers.app() },
        openInTerminal: @escaping @MainActor (String) -> Void = AddDeviceModel.openLocalTerminal
    ) {
        self.store = store
        self.aliases = aliases
        self.shell = shell
        self.helpers = helpers
        self.openInTerminal = openInTerminal
    }

    private func invalidate() {
        checklist = nil
        installation = nil
    }

    var suggestions: [String] {
        let typed = destination.trimmingCharacters(in: .whitespaces)
        let matches = SSHConfigHosts.suggestions(for: typed, among: aliases)
        return matches.count == 1 && matches.first == typed ? [] : Array(matches.prefix(8))
    }

    var trimmedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedHostPath: String {
        remoteHostPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isInstalling: Bool { installStage != nil }

    /// Only what was checked, as it was checked, by the copy that keeps
    /// the devices.
    var canAdd: Bool {
        checklist?.canAdd == true && checkedDestination == trimmedDestination && checkedHostPath == trimmedHostPath
            && !isChecking && !isInstalling && store.canModify && !isAliasOfAddedMac
    }

    /// The primary button: Install & Add, Update & Add, or Add.
    var primaryTitle: String {
        installation?.plan?.addTitle ?? "Add"
    }

    /// The check found the daemon of a Mac already added (another alias).
    private var isAliasOfAddedMac: Bool {
        probe?.hostStatus?.host_id.map { store.device(withHostID: $0) != nil } ?? false
    }

    /// Reaches the host (BatchMode) and checks it, and decides what Install
    /// & Add would do there.
    func check() async {
        let destination = trimmedDestination
        guard !destination.isEmpty, !isInstalling else { return }
        do {
            _ = try HostedSessionHost.ssh(destination)
        } catch {
            self.error = error.localizedDescription
            return
        }
        if store.devices.contains(where: { $0.sshDestination == destination }) {
            error = "\(destination) is already one of your Macs."
            return
        }
        let hostPath = trimmedHostPath
        error = nil
        isChecking = true
        defer { isChecking = false }
        let result = await RemoteDeviceProbe.run(
            destination: destination, remoteHostPath: hostPath.nilIfEmpty, shell: await shell()
        )
        guard trimmedDestination == destination, trimmedHostPath == hostPath else { return }
        var decision: RemoteHostInstallDecision?
        if hostPath.isEmpty, result.sshFailure == nil, result.isMac {
            let helpers = await helpers()
            if case .success(let loaded) = helpers { loadedHelpers = loaded }
            decision = RemoteHostInstall.decide(
                probe: result,
                helpers: helpers,
                machine: result.computerName ?? destination
            )
        }
        guard trimmedDestination == destination, trimmedHostPath == hostPath else { return }
        probe = result
        installation = decision
        let checklist = RemoteDeviceChecklist(result: result, destination: destination, installation: decision)
        self.checklist = checklist
        checkedDestination = destination
        checkedHostPath = hostPath
        // Another alias of a Mac already added.
        if let hostID = result.hostStatus?.host_id, let existing = store.device(withHostID: hostID) {
            error = "\(destination) is the same Mac as \(existing.name) (\(existing.sshDestination))."
        } else if !store.canModify {
            error = RemoteDeviceStore.readOnlyReason
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty, let suggested = checklist.suggestedName {
            name = suggested
        }
    }

    /// Installs this Cherry's session host there when the check said so
    /// (Install & Add, Update & Add), then adds the Mac with it; nil (with
    /// `error`) when either could not be done.
    func addInstallingIfNeeded() async -> RemoteDevice? {
        guard canAdd, let probe else { return nil }
        let destination = trimmedDestination
        guard let plan = installation?.plan, let helpers = loadedHelpers else { return add() }
        error = nil
        installStage = .copying
        let installer = RemoteHostInstaller(
            shell: await shellForInstall(destination: destination), helpers: helpers,
            installationID: store.currentInstallationID
        )
        let outcome: RemoteHostInstaller.Outcome
        do {
            outcome = try await installer.install(
                plan, on: destination, machine: probe.computerName ?? destination,
                progress: { [weak self] stage in self?.installStage = stage }
            )
            installStage = nil
        } catch {
            installStage = nil
            self.error = error.localizedDescription
            return nil
        }
        guard trimmedDestination == destination else { return nil }
        installWarnings = outcome.warnings
        return add(installed: outcome)
    }

    /// The check's shell, through the destination's SSH master when one is
    /// up.
    private func shellForInstall(destination: String) async -> RemoteDeviceShell {
        var shell = await shell()
        shell.controlPath = HostSSHMasterManager.shared.controlPathIfUp(for: destination)
        return shell
    }

    /// Adds the checked Mac; nil (with `error`) when it could not be.
    /// `installed`: what Install & Add put there.
    @discardableResult
    func add(installed: RemoteHostInstaller.Outcome? = nil) -> RemoteDevice? {
        guard canAdd, let probe else { return nil }
        do {
            return try store.add(
                name: name.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? checklist?.suggestedName ?? trimmedDestination,
                sshDestination: trimmedDestination,
                remoteHostPath: installed?.remoteHostPath ?? trimmedHostPath.nilIfEmpty
                    ?? Self.remoteHostPath(found: probe.hostPath, home: probe.homeDirectory),
                machineNames: probe.machineNames,
                homeDirectory: probe.homeDirectory,
                hostID: probe.hostStatus?.host_id,
                installedBuild: installed?.build,
                installedArch: installed?.architecture,
                shell: probe.shell,
                installedResources: installed?.resourcesInstalled ?? false,
                userTemporaryDirectory: probe.userTemporaryDirectory
            )
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// The cherry-host path to keep for a device: one the check found in a
    /// known install place (not on PATH), as `~/…` under its home.
    nonisolated static func remoteHostPath(found: String?, home: String?) -> String? {
        guard let found = found?.nilIfEmpty else { return nil }
        let known = [
            "/Library/Application Support/Cherry/bin/cherry-host",
            "/Applications/Cherry.app/Contents/MacOS/cherry-host",
        ]
        let isOurInstall = found.contains("/\(RemoteHostInstall.rootRelativePath)/") && found.hasSuffix("/cherry-host")
        guard isOurInstall || known.contains(where: { found.hasSuffix($0) }) else { return nil }
        if let home = home?.nilIfEmpty, found.hasPrefix(home + "/") {
            return "~/" + found.dropFirst(home.count + 1)
        }
        return found
    }

    /// What the tab runs: the destination single-quoted, so no shell
    /// (zsh's globbing of `[` or `?`) reads anything into it.
    nonisolated static func terminalCommand(for destination: String) -> String {
        "ssh -- " + RemoteDeviceProbe.singleQuoted(destination)
    }

    /// A local terminal tab running `ssh <host>`: in the frontmost window
    /// of a project on This Mac.
    static func openLocalTerminal(_ destination: String) {
        guard let host = try? HostedSessionHost.ssh(destination), let destination = host.sshDestination else { return }
        let workspace = ProjectWindowRegistry.shared.frontmostLocalWorkspace()
        guard let workspace else {
            let alert = NSAlert()
            alert.messageText = "Open a project on This Mac first"
            alert.informativeText = "Run `ssh \(destination)` in a terminal on This Mac to check and accept its host key."
            alert.runModal()
            return
        }
        let tab = workspace.addSession(title: "ssh \(destination)", command: terminalCommand(for: destination))
        workspace.select(tab)
    }
}

struct AddDeviceSheet: View {
    @StateObject var model: AddDeviceModel
    @Environment(\.dismiss) private var dismiss
    /// Opens a project window of the added device (its home folder).
    let didAdd: (RemoteDevice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Mac").font(.title2.weight(.semibold))
                Text("Cherry reaches your other Mac over SSH, with key-based login (no passwords) and Remote Login turned on there, and installs its session host there (in ~/Library/Application Support/cherry-host). Projects you open on it run their tabs there.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("SSH host (an alias from ~/.ssh/config, or user@host)", text: $model.destination)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.check() } }
                        .disabled(model.isInstalling)
                    Button("Check") { Task { await model.check() } }
                        .disabled(model.trimmedDestination.isEmpty || model.isChecking || model.isInstalling)
                    if model.isChecking { ProgressView().controlSize(.small) }
                }
                if !model.suggestions.isEmpty, model.checklist == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.suggestions, id: \.self) { alias in
                                Button(alias) { model.destination = alias }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                TextField("cherry-host on that Mac (optional: use it instead of installing this Cherry's)", text: $model.remoteHostPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .disabled(model.isInstalling)
            }

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let checklist = model.checklist {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checklist.items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: Self.symbol(item.status))
                                .foregroundStyle(Self.color(item.status))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).fontWeight(.medium)
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if item.action == .openInTerminal {
                                    Button("Open in Terminal") { model.openInTerminal(model.trimmedDestination) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if model.checklist?.canAdd == true {
                HStack {
                    Text("Name")
                    TextField("Name", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isInstalling)
                }
            }

            HStack {
                if let stage = model.installStage {
                    ProgressView().controlSize(.small)
                    Text(stage.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isInstalling)
                Button(model.primaryTitle) {
                    Task {
                        if let device = await model.addInstallingIfNeeded() {
                            let warnings = model.installWarnings
                            dismiss()
                            didAdd(device)
                            if !warnings.isEmpty {
                                let alert = NSAlert()
                                alert.messageText = "Added \(device.name)"
                                alert.informativeText = warnings.joined(separator: "\n\n")
                                alert.runModal()
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    static func symbol(_ status: RemoteDeviceChecklist.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    static func color(_ status: RemoteDeviceChecklist.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

// MARK: - Update Session Host…

/// A device's Update Session Host…: checks the Mac as Add Mac… does, says
/// what installing this Cherry's session host there would do, and does it,
/// then points the device at it (its tabs use it from their next
/// connection; a daemon of an older protocol is replaced by the first one).
@MainActor
final class UpdateDeviceHostModel: ObservableObject {
    let deviceID: UUID
    @Published private(set) var isChecking = false
    @Published private(set) var probe: RemoteDeviceProbeResult?
    @Published private(set) var installation: RemoteHostInstallDecision?
    @Published private(set) var installStage: RemoteHostInstaller.Stage?
    @Published private(set) var outcome: RemoteHostInstaller.Outcome?
    @Published var error: String?

    private let store: RemoteDeviceStore
    private let shell: @MainActor () async -> RemoteDeviceShell
    private let helpers: @MainActor () async -> Result<RemoteHostHelpers, HostedSessionError>
    private let masters: HostSSHMasterManager
    /// Connects the device's control again once its host changed.
    private let reconnect: @MainActor (RemoteDevice) -> Void
    private var loadedHelpers: RemoteHostHelpers?

    init(
        deviceID: UUID,
        store: RemoteDeviceStore = .shared,
        shell: @escaping @MainActor () async -> RemoteDeviceShell = { await RemoteDeviceShell.app() },
        helpers: @escaping @MainActor () async -> Result<RemoteHostHelpers, HostedSessionError> = { await RemoteHostHelpers.app() },
        masters: HostSSHMasterManager = .shared,
        reconnect: @escaping @MainActor (RemoteDevice) -> Void = UpdateDeviceHostModel.reconnectControl
    ) {
        self.deviceID = deviceID
        self.store = store
        self.shell = shell
        self.helpers = helpers
        self.masters = masters
        self.reconnect = reconnect
    }

    var device: RemoteDevice? { store.device(id: deviceID) }
    var isInstalling: Bool { installStage != nil }

    var canInstall: Bool {
        installation?.plan != nil && !isChecking && !isInstalling && outcome == nil && store.canModify
    }

    var primaryTitle: String {
        installation?.plan?.updateTitle ?? "Update"
    }

    /// Checks the Mac with its own cherry-host path left out, so the check
    /// sees every install and the daemon, not only the one it uses now.
    func check() async {
        guard let device, !isInstalling else { return }
        error = nil
        outcome = nil
        isChecking = true
        defer { isChecking = false }
        var shell = await shell()
        shell.controlPath = masters.controlPathIfUp(for: device.sshDestination)
        // The build it uses now is marked as used (the check counts as a use).
        let marker = RemoteHostInstall.directoryName(ofRemoteHostPath: device.remoteHostPath)
            .flatMap { directory in store.currentInstallationID.map { (directoryName: directory, installationID: $0) } }
        let result = await RemoteDeviceProbe.run(
            destination: device.sshDestination, remoteHostPath: nil, marker: marker, shell: shell
        )
        let helpers = await helpers()
        if case .success(let loaded) = helpers { loadedHelpers = loaded }
        probe = result
        let decision = RemoteHostInstall.decide(probe: result, helpers: helpers, machine: device.name)
        installation = decision
        if case .blocked(let reason, _) = decision { error = reason }
        if !store.canModify { error = RemoteDeviceStore.readOnlyReason }
    }

    /// Installs it and points the device at it.
    func install() async {
        guard canInstall, let device, let plan = installation?.plan, let helpers = loadedHelpers else { return }
        error = nil
        installStage = .copying
        defer { installStage = nil }
        var shell = await shell()
        shell.controlPath = masters.controlPathIfUp(for: device.sshDestination)
        do {
            let outcome = try await RemoteHostInstaller(
                shell: shell, helpers: helpers, installationID: store.currentInstallationID
            ).install(
                plan, on: device.sshDestination, machine: device.name,
                progress: { [weak self] stage in self?.installStage = stage }
            )
            store.recordInstall(outcome, on: deviceID)
            // What the check found now: its shell and home (a terminal's
            // shell integration and `~` labels use them).
            if let probe {
                store.update(deviceID) { device in
                    device.shell = probe.shell ?? device.shell
                    device.homeDirectory = probe.homeDirectory ?? device.homeDirectory
                    device.userTemporaryDirectory = probe.userTemporaryDirectory ?? device.userTemporaryDirectory
                }
            }
            self.outcome = outcome
            if let updated = store.device(id: deviceID) { reconnect(updated) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// What the plan will do, for the sheet.
    var summary: [String] {
        guard let device else { return [] }
        switch installation {
        case .install(let plan)?:
            var lines: [String] = []
            let place = "~/\(RemoteHostInstall.rootRelativePath)/\(plan.directoryName)"
            lines.append(plan.copyNeeded
                ? "Copies this Cherry's cherry and cherry-host to \(place) on \(device.name) and uses them from the next connection."
                : "This Cherry's cherry and cherry-host are already at \(place) on \(device.name); the device uses them from the next connection.")
            switch plan.daemon {
            case .absent: lines.append("No session host runs there now; the first tab starts one.")
            case .sameProtocol(_, let newer):
                lines.append(newer
                    ? "Its session host is a newer build and keeps running; this one relays to it."
                    : "Its session host keeps its sessions. When it runs an older install of this Cherry's, it moves to this build (`cherry restart`), and its sessions carry on.")
            case .olderProtocol(let version):
                lines.append("Its session host speaks protocol \(version): the next connection replaces it, and its sessions carry on.")
            case .unknown(let reason):
                lines.append("Its session host did not answer (\(reason)).")
            }
            return lines + plan.warnings
        case .blocked(let reason, _)?:
            return [reason]
        case nil:
            return []
        }
    }

    /// Connects the device's control connection again when it is not
    /// connected (another protocol answered, or it gave up).
    static func reconnectControl(_ device: RemoteDevice) {
        guard let host = device.host else { return }
        let control = HostControlRegistry.shared.control(for: host)
        switch control.state {
        case .connected, .connecting:
            return
        case .waitingToReconnect:
            control.reconnectNow()
        case .idle, .failed:
            Task { _ = try? await control.connect(retryingLoginEnvironment: true) }
        }
    }
}

struct UpdateDeviceHostSheet: View {
    @StateObject var model: UpdateDeviceHostModel
    let close: () -> Void

    var body: some View {
        let name = model.device?.name ?? "Mac"
        VStack(alignment: .leading, spacing: 14) {
            Text("Update Session Host on \(name)").font(.title2.weight(.semibold))
            if model.isChecking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking \(name)…").foregroundStyle(.secondary)
                }
            } else if let outcome = model.outcome {
                Label(
                    outcome.handedOver
                        ? "Installed build \(outcome.build); its session host moved to it, and its sessions carry on."
                        : "\(name) now uses build \(outcome.build)\(outcome.copied ? "" : " (already there)").",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(outcome.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.summary.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let error = model.error, model.outcome == nil {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let stage = model.installStage {
                    ProgressView().controlSize(.small)
                    Text(stage.text).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.outcome != nil {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isInstalling)
                    Button(model.primaryTitle) { Task { await model.install() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canInstall)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.check() }
    }
}

/// Shows Update Session Host… for a device as a sheet on the key window
/// (the device menu, and the Update… of a tab's or window's bar).
@MainActor
enum RemoteDeviceUpdatePresenter {
    static func present(deviceID: UUID, store: RemoteDeviceStore = .shared) {
        guard store.device(id: deviceID) != nil else { return }
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        weak let weakPanel = panel
        let close = {
            guard let panel = weakPanel else { return }
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
        }
        panel.contentViewController = NSHostingController(
            rootView: UpdateDeviceHostSheet(model: UpdateDeviceHostModel(deviceID: deviceID, store: store), close: close)
        )
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// The device a hosting runs on.
    static func deviceID(for host: HostedSessionHost, store: RemoteDeviceStore = .shared) -> UUID? {
        store.devices.first { $0.host == host }?.id
    }
}

// MARK: - Add Project on <Mac>…

/// Add Project on <Mac>… as a sheet: the picker menu's, and the fallback
/// of the Omni bar's folder completion (which adds through the same
/// `RemoteDeviceProjectAdding`).
struct AddDeviceProjectSheet: View {
    let deviceID: UUID
    @ObservedObject var store: RemoteDeviceStore
    /// Opens the added project's window.
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var isChecking = false
    @State private var error: String?

    var body: some View {
        let device = store.device(id: deviceID)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Project on \(device?.name ?? "Mac")").font(.title2.weight(.semibold))
            Text("The folder on that Mac. Cherry checks that it exists there.")
                .foregroundStyle(.secondary)
            HStack {
                TextField(device?.homeDirectory.map { "\($0)/…" } ?? "/Users/you/project", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await add() } }
                if isChecking { ProgressView().controlSize(.small) }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || isChecking || device == nil || !store.canModify)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func add() async {
        guard store.device(id: deviceID) != nil else { return }
        isChecking = true
        defer { isChecking = false }
        error = nil
        switch await RemoteDeviceProjectAdding.add(path, to: deviceID, store: store) {
        case .success(let key):
            dismiss()
            open(key)
        case .failure(let failure):
            error = failure.message
        }
    }
}

// MARK: - Alerts

@MainActor
enum RemoteDeviceAlerts {
    static func rename(_ id: UUID, store: RemoteDeviceStore) {
        guard store.canModify, let device = store.device(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(device.name)"
        let field = NSTextField(string: device.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.rename(id, to: field.stringValue)
    }

    static func confirmRemove(_ id: UUID, store: RemoteDeviceStore) {
        guard store.canModify, let device = store.device(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(device.name)?"
        alert.informativeText = device.createdHostEntry
            ? "Its sessions keep running on that Mac, and its saved SSH host and trusted identity are forgotten. Windows of its projects stop opening until you add it again."
            : "Its sessions keep running on that Mac, and your saved SSH host \(device.sshDestination) stays. Windows of its projects stop opening until you add it again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.remove(id)
    }

    static func confirmTrustNewIdentity(of id: UUID, store: RemoteDeviceStore) {
        guard store.canModify, let device = store.device(id: id), let host = device.host else { return }
        confirmTrustNewIdentity(of: host, name: device.name)
    }

    static func confirmTrustNewIdentity(of host: HostedSessionHost, name: String) {
        let alert = NSAlert()
        alert.messageText = "Trust the new identity of \(name)?"
        alert.informativeText = "Its session host answered with another identity than the one Cherry trusts. This happens when its cherry-host state was reset, or when a different machine answers for \(host.sshDestination ?? name). Trust it only if you expected this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Trust New Identity")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let control = HostControlRegistry.shared.control(for: host)
        Task { try? await control.trustNewIdentity(retryingLoginEnvironment: true) }
    }
}

// MARK: - Bars of a device's tabs

/// How a device's host stands for the bars of its tabs and windows: whether
/// anything retries by itself, and what the user can do.
enum RemoteDeviceAvailability: Equatable {
    case online
    /// Leased and retrying with backoff (and at once on a wake or network
    /// change), or connecting now.
    case reconnecting
    /// SSH refused the login: retried only after a wake, a network change
    /// or Retry.
    case loginRefused(String)
    /// Another host identity answers: nothing retries until trusted.
    case identityChanged(String)
    /// Its cherry-host speaks another protocol: nothing retries.
    case incompatible(String)
    /// The cherry-host its path names is not there: Reinstall.
    case hostMissing(String)
    /// This app cannot reach it at all (no helper, a device no longer
    /// known), or it failed with nothing retrying: Check Again.
    case unavailable(String)

    enum Action: Equatable {
        case reconnectNow, retryLogin, trustNewIdentity, update, reinstall, checkAgain
    }

    static func of(_ state: HostControl.ConnectionState, installationProblem: String?) -> Self {
        if let installationProblem { return .unavailable(installationProblem) }
        switch state {
        case .connected:
            return .online
        case .idle, .connecting:
            return .reconnecting
        case .waitingToReconnect(let error):
            if error.isRemoteHostMissing { return .hostMissing(error.errorDescription ?? "") }
            return error.isAuthenticationFailure ? .loginRefused(error.errorDescription ?? "") : .reconnecting
        case .failed(let error):
            let reason = error.errorDescription ?? ""
            if error.isRemoteHostMissing { return .hostMissing(reason) }
            if error.isIdentityMismatch { return .identityChanged(reason) }
            if error.isVersionMismatch { return .incompatible(reason) }
            if error.isAuthenticationFailure { return .loginRefused(reason) }
            return .unavailable(reason)
        }
    }

    func text(machine: String) -> String {
        switch self {
        case .online: "\(machine) answers"
        case .reconnecting: "\(machine) is offline, reconnecting…"
        case .loginRefused: "\(machine) refused the SSH login"
        case .identityChanged: "Another identity answers for \(machine)"
        case .incompatible: "\(machine)'s session host speaks another protocol"
        case .hostMissing: "\(machine)'s session host is missing"
        case .unavailable(let reason): reason.isEmpty ? "\(machine) cannot be reached" : reason
        }
    }

    var detail: String? {
        switch self {
        case .online, .reconnecting: nil
        case .loginRefused(let reason), .identityChanged(let reason), .incompatible(let reason), .hostMissing(let reason): reason
        case .unavailable: nil
        }
    }

    var action: Action? {
        switch self {
        case .online: nil
        case .reconnecting: .reconnectNow
        case .loginRefused: .retryLogin
        case .identityChanged: .trustNewIdentity
        case .incompatible: .update
        case .hostMissing: .reinstall
        case .unavailable: .checkAgain
        }
    }

    var actionTitle: String? {
        switch action {
        case .reconnectNow: "Reconnect Now"
        case .retryLogin: "Retry"
        case .trustNewIdentity: "Trust New Identity…"
        case .update: "Update…"
        case .reinstall: "Reinstall…"
        case .checkAgain: "Check Again"
        case nil: nil
        }
    }

    @MainActor
    static func perform(_ action: Action, hosting: PersistentHostSessions) {
        let control = hosting.control
        switch action {
        case .reconnectNow, .retryLogin:
            // Retry: looks at it (Background Sessions, the picker) may run
            // again too.
            RemoteDevicePeeks.shared.retry(hosting.profile.host)
            if case .waitingToReconnect = control.state {
                control.reconnectNow()
            } else {
                Task { _ = try? await control.connect(retryingLoginEnvironment: true) }
            }
        case .trustNewIdentity:
            RemoteDeviceAlerts.confirmTrustNewIdentity(of: hosting.profile.host, name: hosting.profile.displayName)
        case .update, .reinstall:
            // Update Session Host…: it checks which side is older and
            // installs this Cherry's there, or says to update this Cherry.
            if let deviceID = RemoteDeviceUpdatePresenter.deviceID(for: hosting.profile.host) {
                RemoteDeviceUpdatePresenter.present(deviceID: deviceID)
            } else {
                let alert = NSAlert()
                alert.messageText = "Use the same Cherry on both Macs"
                alert.informativeText = "The session host on \(hosting.profile.displayName) speaks another protocol than this Cherry. "
                    + RemoteDeviceChecklist.manualInstallInstructions(destination: hosting.profile.host.sshDestination ?? "")
                alert.runModal()
            }
        case .checkAgain:
            hosting.refreshStatus()
            if hosting.installationProblem() == nil {
                Task { _ = try? await control.connect(retryingLoginEnvironment: true) }
            }
        }
    }
}

/// A device's tab while its Mac cannot be reached, or its adapter
/// reconnects: what stands in the way ("<Mac> is offline, reconnecting…",
/// a refused login, another identity, another protocol) and what to do
/// (keys typed meanwhile are not sent).
struct RemoteHostStateBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if session.remoteMachineName != nil, let hosting = session.persistentHosting,
           session.isRunning || session.persistentSession != nil {
            RemoteHostStateBarContent(session: session, hosting: hosting, control: hosting.control)
        }
    }
}

private struct RemoteHostStateBarContent: View {
    @ObservedObject var session: TerminalSession
    let hosting: PersistentHostSessions
    @ObservedObject var control: HostControl

    private var availability: RemoteDeviceAvailability {
        RemoteDeviceAvailability.of(control.state, installationProblem: nil)
    }

    private var offline: Bool {
        switch control.state {
        case .connected: false
        case .waitingToReconnect, .failed: true
        case .idle, .connecting: session.state == .disconnected
        }
    }

    var body: some View {
        let machine = hosting.profile.displayName
        if offline || session.state == .disconnected {
            HStack(spacing: 10) {
                Image(systemName: offline ? "network.slash" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offline ? availability.text(machine: machine) : "Reconnecting to its session on \(machine)…")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if offline, let rejected = session.offlineInputRejectedAt, Date().timeIntervalSince(rejected) < 30 {
                        Text("What you typed was not sent.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if offline, let action = availability.action, let title = availability.actionTitle {
                    Button(title) { RemoteDeviceAvailability.perform(action, hosting: hosting) }
                        .controlSize(.small)
                } else if !offline {
                    Button("Reconnect Now") { session.reconnectHostedSession() }
                        .controlSize(.small)
                }
            }
            .help(availability.detail ?? "")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 12, y: 5)
            .frame(maxWidth: 460)
            .projectWindowToastObstacle()
        }
    }
}

/// A device's tab that could not start there: "Couldn't start on <Mac>:
/// <reason>", with Retry (never a local shell instead).
struct RemoteLaunchFailureBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let reason = session.persistentLaunchFailureReason, !session.isRunning {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(reason)
                Button("Retry") { session.retryPersistentSession() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 12, y: 5)
            .frame(maxWidth: 520)
            .projectWindowToastObstacle()
        }
    }
}

/// A device window whose saved tabs wait for the device (a restore while
/// it could not be reached, or a device Cherry no longer knows): how many,
/// what stands in the way, and what to do.
struct RemoteWindowWaitingBar: View {
    @ObservedObject var repository: RepositoryWorkspace

    var body: some View {
        if repository.remoteTabsWaitingCount > 0, let hosting = repository.deviceHosting {
            RemoteWindowWaitingBarContent(
                count: repository.remoteTabsWaitingCount, hosting: hosting, control: hosting.control
            )
        }
    }
}

private struct RemoteWindowWaitingBarContent: View {
    let count: Int
    let hosting: PersistentHostSessions
    @ObservedObject var control: HostControl

    var body: some View {
        let availability = RemoteDeviceAvailability.of(
            control.state,
            installationProblem: hosting.profile.isKnownDevice ? nil : hosting.installationProblem()
        )
        let waiting = count == 1 ? "1 tab waits" : "\(count) tabs wait"
        HStack(spacing: 10) {
            Image(systemName: "network.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            Text("\(availability.text(machine: hosting.profile.displayName)) (\(waiting))")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .help(availability.detail ?? "")
            if let action = availability.action, let title = availability.actionTitle {
                Button(title) { RemoteDeviceAvailability.perform(action, hosting: hosting) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(maxWidth: 520)
        .projectWindowToastObstacle()
    }
}

// MARK: - The device chip

/// "􀙗 Studio": which Mac a tab or window runs on.
struct RemoteDeviceChip: View {
    let name: String
    var isSelected = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 8, weight: .semibold))
            Text(name)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(isSelected ? 0.12 : 0.07), in: Capsule())
        .help("Runs on \(name)")
        .accessibilityLabel("Runs on \(name)")
    }
}

// MARK: - Not open here

/// A device window's "Not open here" group: the project's sessions on that
/// Mac that no tab shows. This Cherry's own come back as its tabs (Reopen);
/// other owners' (the other Mac's own Cherry, another installation, the
/// CLI) are attached without owning them (Attach): closing such a tab only
/// disconnects it.
struct RemoteNotOpenSection: View {
    @ObservedObject var workspace: TerminalWorkspace
    let hosting: PersistentHostSessions
    @ObservedObject var control: HostControl

    init(workspace: TerminalWorkspace, hosting: PersistentHostSessions) {
        self.workspace = workspace
        self.hosting = hosting
        control = hosting.control
    }

    private var notOpen: RemoteDeviceDiscovery.NotOpenSessions {
        guard let key = workspace.projectRoot, let hostID = control.hostID else { return .init() }
        return RemoteDeviceDiscovery.notOpenSessions(
            in: control.sessions,
            projectPath: ProjectLocation.launchPath(forKey: key),
            owner: hosting.owner,
            isShown: { hosting.isShownByOpenTab($0, hostID: hostID) },
            isEnding: { hosting.isEnding($0.id) }
        )
    }

    var body: some View {
        let notOpen = notOpen
        if !notOpen.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not open here")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                ForEach(notOpen.own, id: \.id) { info in
                    row(info, action: "Reopen", help: "Open this session as one of this window's tabs")
                }
                ForEach(notOpen.others, id: \.id) { info in
                    row(info, action: "Attach", help: "Attach — may resize it on \(hosting.profile.displayName) while both show it. Closing the tab only disconnects it.")
                }
            }
        }
    }

    private func row(_ info: HostedSessionInfo, action: String, help: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: info.isRunning ? "terminal" : "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.displayName).font(.system(size: 12)).lineLimit(1)
                Text(Self.ownerLabel(info, ownOwner: hosting.owner))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action) { open(info) }
                .controlSize(.mini)
                .help(help)
        }
        .padding(.horizontal, 6)
    }

    static func ownerLabel(_ info: HostedSessionInfo, ownOwner: String) -> String {
        guard let owner = info.owner?.nilIfEmpty else { return "Another client's" }
        if owner == ownOwner { return "This Cherry's" }
        if owner.contains("@") { return "Another Cherry's" }
        return "\(owner) on that Mac"
    }

    private func open(_ info: HostedSessionInfo) {
        guard let attachment = hosting.attachment(for: info) else { return }
        workspace.attachHostedSession(attachment, info: info)
    }
}
