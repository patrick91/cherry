import AppKit
import SwiftUI

/// Settings › Devices (the `macs` page): the user's other Macs, where tabs
/// run over SSH, one card each (how it stands, its name, SSH destination
/// and color, the iPhones paired with it, and what can be done with it:
/// Pair iPhone… among them), Add Mac…, the iPhones paired with this Mac
/// (Pair iPhone…, `PairPhoneSheet`; Remove…), and the SSH hosts saved for
/// persistent sessions that no Mac uses. It never connects a Mac: it shows
/// what their connections know (`RemoteDeviceSettingsModel`), and reads a
/// Mac's iPhones only over its SSH master while that is up
/// (`DevicePhonesModel`). Only the copy of Cherry that keeps the Macs
/// changes them; another copy shows them read-only. No page reset: a Mac's
/// color resets on its row.
struct MacsSettingsPage: View, SettingsPageContent {
    @StateObject private var model: RemoteDeviceSettingsModel
    @StateObject private var phones: PairedPhonesModel
    @StateObject private var devicePhones: DevicePhonesModel

    @Environment(\.settingsActions) private var actions
    @State private var isAddingMac = false
    @State private var isPairingPhone = false
    @State private var addingProject: RemoteDeviceReference?
    @State private var pairingDevice: RemoteDeviceReference?
    @State private var confirmation: SettingsConfirmation?
    /// Whether a This Mac window is open for Persistent Sessions on <Mac>…
    /// (`tracksPersistentSessionsAvailability`).
    @State private var canShowPersistentSessions = false

    /// `model`: the app's Macs unless a test gives its own; `phones`: the
    /// phones in the user's `~/.ssh/authorized_keys`, and `devicePhones`
    /// those of the other Macs, unless a test gives its own.
    init(model: RemoteDeviceSettingsModel? = nil, phones: PairedPhonesModel? = nil, devicePhones: DevicePhonesModel? = nil) {
        _model = StateObject(wrappedValue: model ?? RemoteDeviceSettingsModel())
        _phones = StateObject(wrappedValue: phones ?? PairedPhonesModel())
        _devicePhones = StateObject(wrappedValue: devicePhones ?? DevicePhonesModel())
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.macs.title) {
            yourMacsSection
            yourPhonesSection
            if !model.sshHostsNotAdded.isEmpty {
                sshHostsSection
            }
        }
        .settingsConfirmation($confirmation)
        .sheet(isPresented: $isAddingMac) {
            AddDeviceSheet(model: AddDeviceModel(store: model.store)) { device in
                // Its home folder opens, where Add Project on <Mac>… and its
                // sessions' projects are one menu away.
                if let home = device.homeDirectory {
                    actions.openProjectWindow(device.projectKey(path: home))
                }
            }
        }
        .sheet(isPresented: $isPairingPhone, onDismiss: { phones.reload() }) {
            PairPhoneSheet(model: {
                let pairing = MobilePairingModel(keys: phones.keys)
                pairing.onPaired = { [phones] in phones.reload() }
                return pairing
            }())
        }
        .sheet(item: $addingProject) { reference in
            AddDeviceProjectSheet(deviceID: reference.id, store: model.store) { key in
                actions.openProjectWindow(key)
            }
        }
        .sheet(item: $pairingDevice, onDismiss: { devicePhones.reload(model.store.devices) }) { reference in
            if let device = model.store.device(id: reference.id), let keys = devicePhones.keys(device, true) {
                PairPhoneSheet(model: {
                    let pairing = MobilePairingModel(target: RemotePhonePairing.target(for: device, keys: keys))
                    pairing.onPaired = { [devicePhones] in devicePhones.reload(device, connects: true) }
                    return pairing
                }())
            }
        }
        .onAppear {
            // Reads the bundled cherry-host's build in the background, for
            // "Update available".
            RemoteHostHelpers.preloadApp()
            model.update()
            phones.reload()
            devicePhones.reload(model.store.devices)
        }
        // A Mac that connects shows its iPhones.
        .onChange(of: connectedMacs) { _, _ in devicePhones.reload(model.store.devices) }
        .tracksPersistentSessionsAvailability($canShowPersistentSessions)
    }

    private var connectedMacs: Set<UUID> {
        Set(model.rows.filter { if case .connected = $0.status { true } else { false } }.map(\.id))
    }

    // MARK: Your Macs

    /// Its title and Add Mac… above one card per Mac (or the empty state),
    /// and the captions.
    private var yourMacsSection: some View {
        VStack(alignment: .leading, spacing: SettingsDesign.Metrics.columnSpacing) {
            SettingsSectionHeader("Your Macs") {
                if model.canModify {
                    SettingsLinkButton("+ Add Mac…") { isAddingMac = true }
                }
            }
            if !model.canModify {
                SettingsCaption(Self.readOnlyNote)
            }
            if model.rows.isEmpty {
                SettingsSection {
                    emptyState
                }
            } else {
                ForEach(model.rows) { row in
                    MacCard(
                        row: row,
                        model: model,
                        canShowPersistentSessions: canShowPersistentSessions,
                        showPersistentSessions: { host in
                            if !actions.showPersistentSessions(host) {
                                canShowPersistentSessions = false
                            }
                        },
                        openProject: { key in actions.openProjectWindow(key) },
                        addProject: { addingProject = RemoteDeviceReference(id: row.id) },
                        phones: devicePhones.phones[row.id] ?? [],
                        pairPhone: { pairingDevice = RemoteDeviceReference(id: row.id) },
                        limitPhone: { phone in limit(phone, onMac: row) },
                        removePhone: { phone in confirmation = removePhoneConfirmation(phone, fromMac: row) }
                    )
                }
                SettingsCaption(Self.listCaption)
            }
        }
        .settingsRow(.macsList)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.canModify {
            SettingsEmptyState(title: Self.emptyTitle, message: Self.emptyMessage, systemImage: "desktopcomputer") {
                Button("Add Mac…") { isAddingMac = true }
                    .settingsButton(.primary)
            }
        } else {
            SettingsEmptyState(title: Self.emptyTitle, message: Self.emptyMessage, systemImage: "desktopcomputer")
        }
    }

    // MARK: Your iPhones

    /// Its title and Pair iPhone… above the paired phones (or the empty
    /// state), each with its key's fingerprint and Remove…; one paired
    /// before Cherry limited keys says it has full SSH access, with Limit to
    /// Cherry.
    private var yourPhonesSection: some View {
        VStack(alignment: .leading, spacing: SettingsDesign.Metrics.columnSpacing) {
            SettingsSectionHeader("Your iPhones") {
                SettingsLinkButton("+ Pair iPhone…") { isPairingPhone = true }
            }
            if phones.phones.isEmpty {
                SettingsSection {
                    SettingsEmptyState(title: Self.phonesEmptyTitle, message: Self.phonesEmptyMessage, systemImage: "iphone") {
                        Button("Pair iPhone…") { isPairingPhone = true }
                            .settingsButton(.primary)
                    }
                }
            } else {
                SettingsSection {
                    ForEach(phones.phones) { phone in
                        PhoneListItem(phone: phone, mac: "this Mac") {
                            limit(phone)
                        } remove: {
                            confirmation = removePhoneConfirmation(phone)
                        }
                    }
                }
                SettingsCaption(Self.phonesCaption)
            }
        }
        .settingsRow(.macsPhones)
    }

    private func limit(_ phone: AuthorizedPhoneKeys.Phone) {
        do {
            try phones.limit(phone)
        } catch {
            confirmation = Self.couldNotLimit(phone, error)
        }
    }

    /// Limit to Cherry of a phone paired with another Mac, over SSH.
    private func limit(_ phone: AuthorizedPhoneKeys.Phone, onMac row: RemoteDeviceSettingsRow) {
        guard let device = model.store.device(id: row.id) else { return }
        Task {
            do {
                try await devicePhones.limit(phone, on: device)
            } catch {
                confirmation = Self.couldNotLimit(phone, error)
            }
        }
    }

    private static func couldNotLimit(_ phone: AuthorizedPhoneKeys.Phone, _ error: any Error) -> SettingsConfirmation {
        SettingsConfirmation(
            title: "Couldn't limit “\(phone.name)”",
            message: [error.localizedDescription, (error as? any PhoneKeyFailure)?.line].compactMap(\.self).joined(separator: "\n\n"),
            choices: [.init("OK", isDefault: true)]
        )
    }

    private func removePhoneConfirmation(_ phone: AuthorizedPhoneKeys.Phone, fromMac row: RemoteDeviceSettingsRow) -> SettingsConfirmation {
        SettingsConfirmation(
            title: "Remove “\(phone.name)” from \(row.name)?",
            message: "It can no longer reach \(row.name) over SSH: Cherry removes its key from ~/.ssh/authorized_keys there.",
            choices: [
                .init("Remove", role: .destructive) { [devicePhones, model] in
                    guard let device = model.store.device(id: row.id) else { return }
                    Task {
                        do {
                            try await devicePhones.remove(phone, from: device)
                        } catch {
                            confirmation = SettingsConfirmation(
                                title: "Couldn't remove “\(phone.name)”",
                                message: error.localizedDescription,
                                choices: [.init("OK", isDefault: true)]
                            )
                        }
                    }
                },
                .cancel(),
            ]
        )
    }

    private func removePhoneConfirmation(_ phone: AuthorizedPhoneKeys.Phone) -> SettingsConfirmation {
        SettingsConfirmation(
            title: "Remove “\(phone.name)”?",
            message: "It can no longer reach this Mac over SSH: Cherry removes its key from ~/.ssh/authorized_keys.",
            choices: [
                .init("Remove", role: .destructive) { [phones] in
                    do {
                        try phones.remove(phone)
                    } catch {
                        confirmation = SettingsConfirmation(
                            title: "Couldn't remove “\(phone.name)”",
                            message: error.localizedDescription,
                            choices: [.init("OK", isDefault: true)]
                        )
                    }
                },
                .cancel(),
            ]
        )
    }

    // MARK: SSH hosts

    private var sshHostsSection: some View {
        SettingsSection("SSH hosts", caption: Self.sshHostsCaption, id: .macsSSHHosts) {
            ForEach(model.sshHostsNotAdded) { host in
                SettingsListItem {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.destination)
                            .font(SettingsDesign.Fonts.mono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if host.isTrusted {
                            Text("Identity trusted")
                                .font(SettingsDesign.Fonts.help)
                                .foregroundStyle(.secondary)
                        }
                    }
                } trailing: {
                    Button("Forget…") {
                        confirmation = RemoteDeviceAlerts.forgetHostConfirmation(destination: host.destination) {
                            model.forget(host.host)
                        }
                    }
                    .settingsButton()
                }
            }
        }
    }

    // MARK: Models

    /// A Mac's status dot in Settings' colors.
    nonisolated static func tone(_ dot: RemoteDeviceConnectionState.Dot) -> SettingsStatusDot.Tone {
        switch dot {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .gray: .gray
        }
    }

    /// Whether a Mac's tile is in its color: while it is connected or
    /// connecting. Otherwise it is gray, as its dot is.
    nonisolated static func tileShowsColor(_ status: RemoteDeviceSettingsRow.Status) -> Bool {
        switch status {
        case .connected, .connecting: true
        case .notConnected, .offline, .needsAttention: false
        }
    }

    /// The Color row's badge, popover and ↺: Set here while a color is
    /// chosen, else Automatic, Cherry's default. Only the copy of Cherry
    /// that keeps the Macs gets Reset to default (Automatic), which `reset`
    /// does.
    static func colorSource(
        of row: RemoteDeviceSettingsRow,
        canModify: Bool,
        reset: @escaping @MainActor () -> Void
    ) -> SettingsSourceState {
        .app(
            source: row.color == nil ? .cherryDefault : .setHere,
            value: row.color?.title ?? automaticColorTitle,
            defaultValue: automaticColorTitle,
            // devices.json's: no launch argument sets it.
            launchArgument: "",
            reset: canModify ? reset : nil
        )
    }

    /// The Color row's swatches: each of a Mac's colors as `colorScheme`
    /// draws it.
    static func colorSwatches(for colorScheme: ColorScheme) -> [SettingsSwatchPicker<RemoteDeviceColor?>.Swatch] {
        RemoteDeviceColor.allCases.map { color in
            SettingsSwatchPicker<RemoteDeviceColor?>.Swatch(color, name: color.title, color: color.color(for: colorScheme))
        }
    }

    // MARK: Texts

    static let listCaption = "Projects on these Macs open in their own windows, and their tabs run there."
    static let readOnlyNote = "Another copy of Cherry manages your Macs, so changes are off here."
    static let emptyTitle = "No other Macs yet"
    static let emptyMessage = "Add a Mac you reach over SSH. Its projects open in their own windows and their tabs run there."
    static let automaticColorTitle = "Automatic"
    static let colorHelp = "Marks this Mac's windows and tabs. Automatic picks a color from the Mac's identity."
    static let phonesEmptyTitle = "No iPhones yet"
    static let phonesEmptyMessage = "Pair Cherry for iOS to see your agents and sessions on your iPhone, and to answer them."
    static let phonesCaption = "Each reaches your Cherry sessions on this Mac over SSH with its own key, which Cherry added to ~/.ssh/authorized_keys limited to them: it can see them and type into them, but can't log in, run other commands or forward ports. To pair one with another of your Macs, use Pair iPhone… on its card."
    static func phoneFullAccessHelp(mac: String) -> String {
        "Paired before Cherry limited iPhone keys: it can log in to \(mac) over SSH like your own keys. Limit to Cherry lets it reach only Cherry's sessions."
    }
    static let sshHostsCaption = "Hosts you saved for persistent sessions that aren't added as Macs. Sessions on SSH hosts always keep running when you close a tab, close a window or quit."

    // MARK: Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let devices = context.devices
        var rows = [
            SettingsSearchRow(
                id: .macsList,
                route: .page(.macs),
                section: "",
                title: "Your Macs",
                help: listCaption,
                keywords: ["ssh", "destination", "add mac"],
                value: devices.count == 1 ? "1 Mac" : "\(devices.count) Macs"
            ),
        ]
        rows += devices.map { device in
            SettingsSearchRow(
                id: .mac(device.id),
                route: .page(.macs),
                section: "Your Macs",
                title: device.name,
                keywords: ["ssh", "destination"],
                value: device.sshDestination
            )
        }
        // Its phones are read from ~/.ssh/authorized_keys only when the page
        // shows: search reads no file.
        rows.append(SettingsSearchRow(
            id: .macsPhones,
            route: .page(.macs),
            section: "",
            title: "Your iPhones",
            help: phonesCaption,
            keywords: ["iphone", "phone", "mobile", "pair", "qr", "authorized_keys"]
        ))
        let sshHosts = RemoteDeviceSettingsModel.sshHostsNotAdded(hosts: context.sshHosts, devices: devices)
        if !sshHosts.isEmpty {
            rows.append(SettingsSearchRow(
                id: .macsSSHHosts,
                route: .page(.macs),
                section: "",
                title: "SSH hosts",
                help: sshHostsCaption,
                keywords: ["ssh", "host", "identity"] + sshHosts.map(\.destination),
                value: sshHosts.count == 1 ? "1 host" : "\(sshHosts.count) hosts"
            ))
        }
        return rows
    }
}

extension SettingsRowID {
    static let macsSSHHosts: Self = "macs.sshHosts"
    static let macsPhones: Self = "macs.phones"
}

// MARK: - A Mac's card

/// A Mac's card: its header (tile, name, Update
/// available, status and what is wrong, Trust New Identity… or Reconnect,
/// and `···`), its name, SSH destination and color, and its actions. Its
/// projects are the project picker's (Add Project on <Mac>… is in `···`).
/// Changes are off while another copy of Cherry keeps the Macs.
private struct MacCard: View {
    let row: RemoteDeviceSettingsRow
    let model: RemoteDeviceSettingsModel
    let canShowPersistentSessions: Bool
    let showPersistentSessions: @MainActor (HostedSessionHost) -> Void
    /// Opens a project of the Mac by its key (its home folder).
    let openProject: @MainActor (String) -> Void
    /// Add Project on <Mac>…'s sheet.
    let addProject: @MainActor () -> Void
    /// The iPhones paired with it, as last read.
    let phones: [AuthorizedPhoneKeys.Phone]
    let pairPhone: @MainActor () -> Void
    let limitPhone: @MainActor (AuthorizedPhoneKeys.Phone) -> Void
    let removePhone: @MainActor (AuthorizedPhoneKeys.Phone) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsSection(id: .mac(row.id)) {
            hero

            SettingsItem("Name") {
                MacNameField(name: row.name, isEnabled: model.canModify) { name in
                    model.rename(row.id, to: name)
                }
            }

            SettingsItem("SSH destination") {
                SettingsCopyableValue(text: row.destination, copyLabel: "Copy SSH destination")
            }

            SettingsItem(
                "Color",
                help: MacsSettingsPage.colorHelp,
                source: MacsSettingsPage.colorSource(of: row, canModify: model.canModify) {
                    model.setColor(nil, for: row.id)
                }
            ) {
                SettingsSwatchPicker(
                    "Color",
                    selection: Binding(get: { row.color }, set: { model.setColor($0, for: row.id) }),
                    swatches: MacsSettingsPage.colorSwatches(for: colorScheme),
                    leading: .init(MacsSettingsPage.automaticColorTitle, value: nil)
                )
                .disabled(!model.canModify)
            }

            if !phones.isEmpty {
                SettingsGroupLabel("iPhones")
                    .settingsSeparatorAbove(false)
                ForEach(Array(phones.enumerated()), id: \.element.id) { index, phone in
                    PhoneListItem(phone: phone, mac: row.name) {
                        limitPhone(phone)
                    } remove: {
                        removePhone(phone)
                    }
                    // No separator between the label and the list.
                    .settingsSeparatorAbove(index > 0)
                }
            }

            actionsRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
    }

    private var hero: some View {
        SettingsHero(
            tile: SettingsTile(.symbol("desktopcomputer"), color: tileColor, size: .large),
            title: row.name
        ) {
            if row.updateAvailable {
                SettingsTag("Update available")
            }
        } subtitle: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    SettingsStatusDot(MacsSettingsPage.tone(row.dot))
                    Text(row.statusText(includingUpdate: false))
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(SettingsDesign.Fonts.mono)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        } actions: {
            if row.offersTrustNewIdentity {
                Button("Trust New Identity…") {
                    model.trustNewIdentity(row.id)
                }
                .settingsButton()
                .disabled(!model.canModify)
            } else if row.offersReconnect {
                Button("Reconnect") {
                    model.reconnect(row.id)
                }
                .settingsButton()
            }
            SettingsMoreMenu("More actions for \(row.name)") {
                Button("Persistent Sessions on \(row.name)…") {
                    if let host = row.host { showPersistentSessions(host) }
                }
                .disabled(row.host == nil || !canShowPersistentSessions)
                // Its projects open only while it answers as itself.
                Button("Open Home Folder") {
                    if let key = row.homeProjectKey { openProject(key) }
                }
                .disabled(row.homeProjectKey == nil || !row.allowsOpening)
                Button("Add Project on \(row.name)…") {
                    addProject()
                }
                .disabled(!model.canModify || !row.allowsOpening)
            }
        }
    }

    private var tileColor: Color {
        MacsSettingsPage.tileShowsColor(row.status)
            ? row.effectiveColor.color(for: colorScheme)
            : SettingsDesign.Colors.hex(SettingsDesign.TileColors.projectWithoutColor)
    }

    // MARK: Actions

    /// Update Session Host… (or Reinstall) when one applies, Pair iPhone…
    /// (while it answers as itself), and Remove…, at the trailing end.
    private var actionsRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if row.updateAvailable {
                Button(row.updateTitle) {
                    model.updateSessionHost(row.id)
                }
                .settingsButton()
                .disabled(!model.canModify)
            }
            Button("Pair iPhone…") {
                pairPhone()
            }
            .settingsButton()
            .disabled(!row.allowsOpening)
            Button("Remove…", role: .destructive) {
                model.confirmRemove(row.id)
            }
            .settingsButton(.danger)
            .disabled(!model.canModify)
        }
        .padding(.vertical, SettingsDesign.Metrics.rowVerticalPadding)
        .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
        .frame(minHeight: SettingsDesign.Metrics.rowMinHeight)
    }
}

/// A Mac's name, edited in place: Return or leaving the field
/// renames it (`RemoteDeviceSettingsModel.rename`); an empty or refused
/// name goes back to the one it has. A rename elsewhere (the Omni bar)
/// shows unless the field is being edited.
private struct MacNameField: View {
    let name: String
    let isEnabled: Bool
    let rename: @MainActor (String) -> Bool

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(name: String, isEnabled: Bool, rename: @escaping @MainActor (String) -> Bool) {
        self.name = name
        self.isEnabled = isEnabled
        self.rename = rename
        _draft = State(initialValue: name)
    }

    var body: some View {
        TextField("Name", text: $draft)
            .settingsTextField()
            .labelsHidden()
            .focused($isFocused)
            .disabled(!isEnabled)
            .onSubmit {
                commit()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: name) { _, name in
                if !isFocused { draft = name }
            }
    }

    private func commit() {
        guard draft != name else { return }
        if rename(draft) {
            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            draft = name
        }
    }
}

/// A paired iPhone's row: its name and key's fingerprint, Full SSH access
/// with Limit to Cherry for one paired before Cherry limited keys, and
/// Remove….
private struct PhoneListItem: View {
    let phone: AuthorizedPhoneKeys.Phone
    /// The Mac it is paired with ("this Mac", "patstudio").
    let mac: String
    let limit: @MainActor () -> Void
    let remove: @MainActor () -> Void

    var body: some View {
        SettingsListItem {
            SettingsListLabel(phone.name, subtitle: phone.key.fingerprint, monospacedSubtitle: true) {
                if !phone.isLimited {
                    SettingsTag("Full SSH access", style: .warning)
                        .help(MacsSettingsPage.phoneFullAccessHelp(mac: mac))
                }
            }
        } trailing: {
            if !phone.isLimited {
                Button("Limit to Cherry") { limit() }
                    .settingsButton()
            }
            Button("Remove…") { remove() }
                .settingsButton()
        }
    }
}

