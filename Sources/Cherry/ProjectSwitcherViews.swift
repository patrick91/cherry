import AppKit
import SwiftUI

// The palette (design A) and the Macs sidebar (design B) of the project
// switcher (`ProjectSwitcherStyle`). Both read `ProjectSwitcherLiveModel`
// and open projects through `ProjectSwitcherActions`, the picker menu's own
// code path.

/// The palette, or the Macs sidebar while the title-bar picker is hidden,
/// centred over the window with the command palette's scrim and surface.
struct ProjectSwitcherOverlay: View {
    let presentation: ProjectSwitcherPresentation
    let currentProjectKey: String?
    let actions: ProjectSwitcherActions
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CommandPaletteDesign.usesGlassKey) private var usesGlass = CommandPaletteDesign.defaultUsesGlass
    @AppStorage(CommandPaletteDesign.cornerRadiusKey) private var cornerRadius = CommandPaletteDesign.defaultCornerRadius
    @AppStorage(CommandPaletteDesign.scrimOpacityKey) private var scrimOpacity = CommandPaletteDesign.defaultScrimOpacity
    @AppStorage(CommandPaletteDesign.animatesEntranceKey) private var animatesEntrance = CommandPaletteDesign.defaultAnimatesEntrance
    @State private var didAppear = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(scrimOpacity)
                .opacity(didAppear ? 1 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            Group {
                switch presentation {
                case .palette:
                    ProjectSwitcherPalette(
                        currentProjectKey: currentProjectKey,
                        actions: actions,
                        dismiss: dismiss
                    )
                case .sidebarOverlay, .sidebarPopover:
                    ProjectSwitcherMacsSidebar(
                        currentProjectKey: currentProjectKey,
                        actions: actions,
                        dismiss: dismiss
                    )
                }
            }
            .modifier(CommandPaletteSurface(
                usesGlass: usesGlass,
                cornerRadius: CGFloat(cornerRadius),
                colorScheme: colorScheme
            ))
            .scaleEffect(didAppear ? 1 : 0.97, anchor: .top)
            .opacity(didAppear ? 1 : 0)
            .padding(.horizontal, 20)
            .padding(.top, 70)
            .padding(.bottom, 30)
        }
        .onAppear {
            if animatesEntrance {
                withAnimation(.snappy(duration: 0.18)) { didAppear = true }
            } else {
                didAppear = true
            }
        }
    }
}

// MARK: - Design A: the palette

struct ProjectSwitcherPalette: View {
    let currentProjectKey: String?
    let actions: ProjectSwitcherActions
    let dismiss: () -> Void

    @StateObject private var live: ProjectSwitcherLiveModel
    @AppStorage(CommandPaletteDesign.panelWidthKey) private var panelWidth = CommandPaletteDesign.defaultPanelWidth
    @AppStorage(CommandPaletteDesign.selectionStyleKey) private var selectionStyle = CommandPaletteDesign.defaultSelectionStyle
    @AppStorage(CommandPaletteDesign.showsFooterKey) private var showsFooter = CommandPaletteDesign.defaultShowsFooter
    @State private var query = ""
    @State private var filter: ProjectSwitcherModel.Machine?
    @State private var selection = ProjectSwitcherSelection()

    init(currentProjectKey: String?, actions: ProjectSwitcherActions, dismiss: @escaping () -> Void) {
        self.currentProjectKey = currentProjectKey
        self.actions = actions
        self.dismiss = dismiss
        _live = StateObject(wrappedValue: ProjectSwitcherLiveModel(currentProjectKey: { currentProjectKey }))
    }

    var body: some View {
        let model = live.model
        let sections = model.sections(query: query, filter: filter)
        let rows = ProjectSwitcherRows(sections: sections)

        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                CommandPaletteSearchField(
                    text: $query,
                    placeholder: "Open a project on any Mac…",
                    focusRequest: selection.focusRequest,
                    onSubmit: { commit(rows: rows, model: model) },
                    accessibilityLabel: "Search projects"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(rows.count == 1 ? "1 project" : "\(rows.count) projects")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 17)
            .frame(height: 52)

            machineChips(model: model)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            ProjectSwitcherList(
                model: model,
                rows: rows,
                showsPills: true,
                selection: $selection,
                selectionStyle: CommandPaletteSelectionStyle(rawValue: selectionStyle) ?? .softTint,
                open: { open($0, model: model) }
            ) {
                emptyState(model: model)
            }
            .frame(height: 430)

            if showsFooter {
                Divider()
                footer(model: model)
            }
        }
        .frame(width: max(600, min(720, CGFloat(panelWidth) + 40)))
        .background(CommandPaletteKeyMonitor(
            handle: { handleKey($0, rows: rows, model: model) },
            onScroll: { selection.suppressHover() }
        ))
        .onAppear {
            live.start()
            selection.focusSearch()
        }
        .onDisappear { live.stop() }
        .onChange(of: query) { _, _ in selection.reset() }
        .onChange(of: filter) { _, _ in selection.reset() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project switcher")
    }

    private func machineChips(model: ProjectSwitcherModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ProjectSwitcherChip(
                    title: "All Macs",
                    meta: nil,
                    dot: nil,
                    isOn: filter == nil,
                    isDimmed: false
                ) { filter = nil }
                ForEach(model.machines) { machine in
                    ProjectSwitcherChip(
                        title: machine.name,
                        meta: machine.sessionCount.map { $0 == 1 ? "1 session" : "\($0) sessions" }
                            ?? (machine.isReachable ? nil : machine.status),
                        dot: machine.machine == .thisMac ? nil : machine.dot,
                        isOn: filter == machine.machine,
                        isDimmed: !machine.isReachable
                    ) { filter = machine.machine }
                }
            }
            .padding(.horizontal, 3)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func emptyState(model: ProjectSwitcherModel) -> some View {
        VStack(spacing: 12) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No projects yet.")
            } else {
                Text("No project matches “\(query)”.")
            }
            if ProjectSwitcherModel.looksLikePath(query) {
                Button("Open “\(query)” as a folder…") { openQueryAsFolder() }
                    .buttonStyle(ProjectSwitcherFooterButtonStyle())
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func footer(model: ProjectSwitcherModel) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                CommandPaletteFooterHint(key: "↑↓", label: "Select")
                CommandPaletteFooterHint(key: "↩", label: "Open")
                CommandPaletteFooterHint(key: "⇥", label: "Next Mac")
            }
            Spacer(minLength: 8)
            Button("Add Project…") { run { actions.addProject(on: filter ?? .thisMac) } }
            Button("Open Folder…") { run { actions.openFolder(on: filter ?? .thisMac) } }
            Button("Add Mac…") { run { actions.perform(.addMac) } }
                .disabled(!RemoteDeviceStore.shared.canModify)
        }
        .buttonStyle(ProjectSwitcherFooterButtonStyle())
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func handleKey(_ event: NSEvent, rows: ProjectSwitcherRows, model: ProjectSwitcherModel) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch event.keyCode {
        case 53: // Escape
            if query.isEmpty { dismiss() } else { query = "" }
            return true
        case 36, 76: // Return
            commit(rows: rows, model: model)
            return true
        case 125 where modifiers.isEmpty:
            selection.move(by: 1, count: rows.count)
            return true
        case 126 where modifiers.isEmpty:
            selection.move(by: -1, count: rows.count)
            return true
        case 48 where modifiers.subtracting(.shift).isEmpty: // Tab, ⇧Tab
            filter = model.nextFilter(after: filter, backwards: modifiers.contains(.shift))
            return true
        default:
            return false
        }
    }

    private func commit(rows: ProjectSwitcherRows, model: ProjectSwitcherModel) {
        guard let group = rows.group(at: selection.index) else {
            if ProjectSwitcherModel.looksLikePath(query) { openQueryAsFolder() } else { NSSound.beep() }
            return
        }
        open(group.primary, model: model)
    }

    private func open(_ location: ProjectSwitcherModel.Location, model: ProjectSwitcherModel) {
        guard let action = model.action(opening: location) else {
            NSSound.beep()
            return
        }
        run { actions.perform(action) }
    }

    private func openQueryAsFolder() {
        let query = query
        let machine = filter ?? .thisMac
        run {
            if !actions.openPath(query, on: machine) { NSSound.beep() }
        }
    }

    /// Closes the palette, then acts (an open panel or a new window runs
    /// after the palette has gone).
    private func run(_ work: @escaping @MainActor () -> Void) {
        dismiss()
        DispatchQueue.main.async { work() }
    }
}

// MARK: - Design B: the Macs sidebar

struct ProjectSwitcherMacsSidebar: View {
    let currentProjectKey: String?
    let actions: ProjectSwitcherActions
    let dismiss: () -> Void

    @StateObject private var live: ProjectSwitcherLiveModel
    @AppStorage(CommandPaletteDesign.selectionStyleKey) private var selectionStyle = CommandPaletteDesign.defaultSelectionStyle
    @State private var query = ""
    @State private var machine: ProjectSwitcherModel.Machine?
    @State private var selection = ProjectSwitcherSelection()

    init(currentProjectKey: String?, actions: ProjectSwitcherActions, dismiss: @escaping () -> Void) {
        self.currentProjectKey = currentProjectKey
        self.actions = actions
        self.dismiss = dismiss
        _live = StateObject(wrappedValue: ProjectSwitcherLiveModel(currentProjectKey: { currentProjectKey }))
    }

    var body: some View {
        let model = live.model
        let selected = machine.flatMap(model.machine) ?? model.machine(model.currentMachine) ?? model.machines[0]
        let sections = model.sections(query: query, filter: selected.machine)
        let rows = ProjectSwitcherRows(sections: sections)

        HStack(spacing: 0) {
            rail(model: model, selected: selected.machine)
                .frame(width: 220)

            Divider()

            VStack(spacing: 0) {
                header(selected)

                if let message = selected.unreachableMessage {
                    unreachableBanner(message, machine: selected)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                filterField(selected, model: model, rows: rows)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                ProjectSwitcherList(
                    model: model,
                    rows: rows,
                    showsPills: false,
                    selection: $selection,
                    selectionStyle: CommandPaletteSelectionStyle(rawValue: selectionStyle) ?? .softTint,
                    open: { open($0, model: model) }
                ) {
                    Text(query.isEmpty ? "No projects on \(selected.name) yet." : "Nothing here matches.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                }
                .frame(maxHeight: .infinity)

                Divider()

                HStack(spacing: 8) {
                    HStack(spacing: 10) {
                        CommandPaletteFooterHint(key: "↑↓", label: "Select")
                        CommandPaletteFooterHint(key: "↩", label: "Open")
                        CommandPaletteFooterHint(key: "⇥", label: "Next Mac")
                    }
                    Spacer(minLength: 8)
                    Button("Add Project…") { run { actions.addProject(on: selected.machine) } }
                        .disabled(selected.machine != .thisMac && !RemoteDeviceStore.shared.canModify)
                    Button("Edit Projects…") { run { actions.perform(.editProjects) } }
                }
                .buttonStyle(ProjectSwitcherFooterButtonStyle())
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
        }
        .frame(width: 780, height: 560)
        .background(CommandPaletteKeyMonitor(
            handle: { handleKey($0, rows: rows, model: model, selected: selected.machine) },
            onScroll: { selection.suppressHover() }
        ))
        .onAppear {
            live.start()
            selection.focusSearch()
        }
        .onDisappear { live.stop() }
        .onChange(of: query) { _, _ in selection.reset() }
        .onChange(of: machine) { _, _ in
            query = ""
            selection.reset()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project switcher")
    }

    private func rail(model: ProjectSwitcherModel, selected: ProjectSwitcherModel.Machine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MACS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.machines) { info in
                        ProjectSwitcherMacRow(info: info, isSelected: info.machine == selected) {
                            machine = info.machine
                            selection.focusSearch()
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)

            Button { run { actions.perform(.addMac) } } label: {
                Label("Add Mac…", systemImage: "plus")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!RemoteDeviceStore.shared.canModify)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
    }

    private func header(_ info: ProjectSwitcherModel.MachineInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.name)
                    .font(.system(size: 17, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(info.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Open Folder on \(info.name)…") { run { actions.openFolder(on: info.machine) } }
                .buttonStyle(ProjectSwitcherFooterButtonStyle())
                .disabled(!info.allowsOpening || (info.machine != .thisMac && !RemoteDeviceStore.shared.canModify))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func unreachableBanner(_ message: String, machine info: ProjectSwitcherModel.MachineInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let id = info.machine.deviceID {
                if info.offersTrustNewIdentity {
                    Button("Trust New Identity…") { run { actions.perform(.trustDeviceIdentity(id)) } }
                        .disabled(!RemoteDeviceStore.shared.canModify)
                } else {
                    Button("Try Again") { actions.perform(.reconnectDevice(id)) }
                }
            }
        }
        .buttonStyle(ProjectSwitcherFooterButtonStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func filterField(
        _ info: ProjectSwitcherModel.MachineInfo,
        model: ProjectSwitcherModel,
        rows: ProjectSwitcherRows
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            let count = model.projectCount(on: info.machine)
            CommandPaletteSearchField(
                text: $query,
                placeholder: "Filter \(count == 1 ? "1 project" : "\(count) projects") on \(info.name)",
                focusRequest: selection.focusRequest,
                onSubmit: { commit(rows: rows, model: model) },
                fontSize: 14,
                accessibilityLabel: "Filter projects on \(info.name)"
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func handleKey(
        _ event: NSEvent,
        rows: ProjectSwitcherRows,
        model: ProjectSwitcherModel,
        selected: ProjectSwitcherModel.Machine
    ) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch event.keyCode {
        case 53:
            if query.isEmpty { dismiss() } else { query = "" }
            return true
        case 36, 76:
            commit(rows: rows, model: model)
            return true
        case 125 where modifiers.isEmpty:
            selection.move(by: 1, count: rows.count)
            return true
        case 126 where modifiers.isEmpty:
            selection.move(by: -1, count: rows.count)
            return true
        case 48 where modifiers.subtracting(.shift).isEmpty:
            machine = model.nextMachine(after: selected, backwards: modifiers.contains(.shift))
            return true
        default:
            return false
        }
    }

    private func commit(rows: ProjectSwitcherRows, model: ProjectSwitcherModel) {
        guard let group = rows.group(at: selection.index) else {
            NSSound.beep()
            return
        }
        open(group.primary, model: model)
    }

    private func open(_ location: ProjectSwitcherModel.Location, model: ProjectSwitcherModel) {
        guard let action = model.action(opening: location) else {
            NSSound.beep()
            return
        }
        run { actions.perform(action) }
    }

    private func run(_ work: @escaping @MainActor () -> Void) {
        dismiss()
        DispatchQueue.main.async { work() }
    }
}

// MARK: - Shared pieces

/// The selected row, and the requests that move focus and scrolling.
struct ProjectSwitcherSelection: Equatable {
    var index = 0
    var focusRequest = 0
    /// Bumped by the keyboard: the list scrolls the selection into view.
    var keyboardRequest = 0
    /// Hover selects only once the pointer moves from here (a scroll or a
    /// key press leaves the pointer over another row).
    var hoverSuppressedAt: CGPoint?

    mutating func reset() {
        index = 0
        suppressHover()
    }

    mutating func focusSearch() {
        focusRequest &+= 1
        suppressHover()
    }

    mutating func suppressHover() {
        hoverSuppressedAt = NSEvent.mouseLocation
    }

    mutating func move(by delta: Int, count: Int) {
        guard count > 0 else { return }
        suppressHover()
        index = min(max(index + delta, 0), count - 1)
        keyboardRequest &+= 1
    }

    mutating func hover(_ row: Int) {
        if let suppressed = hoverSuppressedAt {
            let location = NSEvent.mouseLocation
            guard abs(location.x - suppressed.x) >= 1 || abs(location.y - suppressed.y) >= 1 else { return }
            hoverSuppressedAt = nil
        }
        if index != row { index = row }
    }
}

/// The sections with each group's row number.
struct ProjectSwitcherRows {
    struct Row: Identifiable {
        let index: Int
        let group: ProjectSwitcherModel.Group
        var id: String { group.id }
    }

    struct Section: Identifiable {
        let section: ProjectSwitcherModel.Section
        let rows: [Row]
        var id: String { section.id }
    }

    let sections: [Section]
    let count: Int

    init(sections: [ProjectSwitcherModel.Section]) {
        var index = 0
        self.sections = sections.map { section in
            let rows = section.groups.map { group in
                defer { index += 1 }
                return Row(index: index, group: group)
            }
            return Section(section: section, rows: rows)
        }
        count = index
    }

    func group(at index: Int) -> ProjectSwitcherModel.Group? {
        for section in sections {
            if let row = section.rows.first(where: { $0.index == index }) { return row.group }
        }
        return nil
    }

    func id(at index: Int) -> String? {
        group(at: index)?.id
    }
}

private struct ProjectSwitcherList<Empty: View>: View {
    let model: ProjectSwitcherModel
    let rows: ProjectSwitcherRows
    let showsPills: Bool
    @Binding var selection: ProjectSwitcherSelection
    let selectionStyle: CommandPaletteSelectionStyle
    let open: (ProjectSwitcherModel.Location) -> Void
    @ViewBuilder let empty: () -> Empty

    private static var topMarkerID: String { "project-switcher-top" }

    var body: some View {
        let now = Date()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Color.clear.frame(height: 2).id(Self.topMarkerID)
                    if rows.count == 0 {
                        empty()
                    }
                    ForEach(rows.sections) { section in
                        Text(section.section.title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.rows) { row in
                            ProjectSwitcherRow(
                                group: row.group,
                                model: model,
                                showsPills: showsPills,
                                isSelected: row.index == selection.index,
                                selectionStyle: selectionStyle,
                                now: now,
                                open: open
                            )
                            .id(row.group.id)
                            .onHover { hovering in
                                if hovering { selection.hover(row.index) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selection.keyboardRequest) { _, _ in
                // anchor nil: the least scrolling that shows the row whole
                // (headers make rows' offsets unpredictable). The first row
                // scrolls to the top so its section's header shows too.
                let target = selection.index == 0 ? Self.topMarkerID : rows.id(at: selection.index)
                if let target { proxy.scrollTo(target, anchor: nil) }
            }
            .onChange(of: rows.count) { _, _ in
                proxy.scrollTo(Self.topMarkerID, anchor: .top)
            }
        }
    }
}

private enum ProjectSwitcherTint {
    static let colors: [Color] = [
        Color(red: 0.91, green: 0.63, blue: 0.66),
        Color(red: 0.62, green: 0.77, blue: 0.91),
        Color(red: 0.71, green: 0.84, blue: 0.66),
        Color(red: 0.95, green: 0.83, blue: 0.54),
        Color(red: 0.79, green: 0.70, blue: 0.90),
        Color(red: 0.95, green: 0.71, blue: 0.55),
        Color(red: 0.62, green: 0.85, blue: 0.81),
    ]

    static func color(for name: String) -> Color {
        colors[name.count % colors.count]
    }

    static func initial(of name: String) -> String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }
}

private enum ProjectSwitcherColors {
    static let working = Color(red: 0.91, green: 0.64, blue: 0.24)
    static let idle = Color(red: 0.44, green: 0.75, blue: 0.45)

    static func dot(_ dot: RemoteDeviceConnectionState.Dot) -> Color {
        switch dot {
        case .green: idle
        case .yellow: .yellow
        case .red: .red
        case .gray: .gray
        }
    }
}

private struct ProjectSwitcherRow: View {
    let group: ProjectSwitcherModel.Group
    let model: ProjectSwitcherModel
    let showsPills: Bool
    let isSelected: Bool
    let selectionStyle: CommandPaletteSelectionStyle
    let now: Date
    let open: (ProjectSwitcherModel.Location) -> Void

    var body: some View {
        let primary = group.primary
        let isAvailable = model.canOpen(primary) && model.isReachable(primary.machine)
        Button { open(primary) } label: {
            HStack(spacing: 12) {
                Text(ProjectSwitcherTint.initial(of: group.name))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(red: 0.11, green: 0.10, blue: 0.12))
                    .frame(width: 28, height: 28)
                    .background(ProjectSwitcherTint.color(for: group.name), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(group.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isAccentFill ? Color.white : Color.primary)
                            .lineLimit(1)
                        if let status = statusText {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill((group.openLocation?.openStatus?.workingAgents ?? 0) > 0 ? ProjectSwitcherColors.working : ProjectSwitcherColors.idle)
                                    .frame(width: 7, height: 7)
                                Text(status)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryColor)
                        }
                        if group.isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(secondaryColor)
                        }
                    }
                    Text(primary.displayPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if !group.isOpen, let date = group.lastOpened {
                        Text(ProjectSwitcherModel.agoLabel(date, now: now))
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                    }
                    if showsPills, showsPillsForGroup {
                        ForEach(group.locations) { location in
                            ProjectSwitcherPill(
                                title: model.name(of: location.machine),
                                isPrimary: location.id == primary.id,
                                isDimmed: !model.isReachable(location.machine),
                                accessibilityLabel: "Open \(group.name) on \(model.name(of: location.machine))"
                            ) { open(location) }
                        }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(selectionFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isAvailable ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isAvailable ? "Opens the project" : "\(model.name(of: primary.machine)) is not reachable now")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Pills show on which Macs a project is: always for another Mac's, and
    /// for This Mac's when it is on several.
    private var showsPillsForGroup: Bool {
        group.locations.count > 1 || group.primary.machine != .thisMac
    }

    private var statusText: String? {
        guard let open = group.openLocation, let status = open.openStatus else { return nil }
        if group.locations.count > 1 || open.machine != .thisMac {
            return "\(status.text) on \(model.name(of: open.machine))"
        }
        return status.text
    }

    private var accessibilityLabel: String {
        var parts = [group.name]
        if let statusText { parts.append(statusText) }
        parts.append(group.primary.displayPath)
        if group.locations.count > 1 || group.primary.machine != .thisMac {
            parts.append("on " + group.locations.map { model.name(of: $0.machine) }.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }

    private var isAccentFill: Bool {
        isSelected && selectionStyle == .accentFill
    }

    private var secondaryColor: Color {
        isAccentFill ? Color.white.opacity(0.75) : Color.secondary
    }

    private var selectionFill: Color {
        guard isSelected else { return .clear }
        switch selectionStyle {
        case .accentFill: return .accentColor
        case .softTint: return Color.accentColor.opacity(0.2)
        case .flat: return Color.primary.opacity(0.08)
        }
    }
}

private struct ProjectSwitcherPill: View {
    let title: String
    let isPrimary: Bool
    let isDimmed: Bool
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isPrimary ? .medium : .regular))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .foregroundStyle(isPrimary || isHovering ? Color.primary : Color.secondary)
                .background(Color.primary.opacity(isPrimary ? 0.1 : 0), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(isPrimary || isHovering ? 0.3 : 0.14), lineWidth: 1)
                }
                .opacity(isDimmed ? 0.55 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ProjectSwitcherChip: View {
    let title: String
    let meta: String?
    let dot: RemoteDeviceConnectionState.Dot?
    let isOn: Bool
    let isDimmed: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot {
                    Circle()
                        .fill(ProjectSwitcherColors.dot(dot))
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .fontWeight(isOn ? .semibold : .regular)
                if let meta {
                    Text(meta).opacity(0.6)
                }
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(isOn ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.85))
            .background(
                isOn ? Color.primary.opacity(0.9) : Color.primary.opacity(isHovering ? 0.06 : 0),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.14), lineWidth: 1)
            }
            .opacity(isDimmed && !isOn ? 0.6 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(meta.map { "\(title), \($0)" } ?? title)
        .accessibilityHint("Shows the projects on \(title)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct ProjectSwitcherMacRow: View {
    let info: ProjectSwitcherModel.MachineInfo
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: info.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(ProjectSwitcherColors.dot(info.dot))
                            .frame(width: 7, height: 7)
                        Text(info.status)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 48)
            .background(
                Color.primary.opacity(isSelected ? 0.1 : (isHovering ? 0.05 : 0)),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(info.isReachable ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(info.name), \(info.status)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProjectSwitcherFooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.85 : 0.35))
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
