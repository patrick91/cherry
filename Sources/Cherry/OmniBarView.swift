import AppKit
import SwiftUI

// The Omni bar's view (design D): one floating bar with the search field
// and the scope's crumb, one list of one-line rows, and a footer with a
// hint, "↵ <primary>" and "⌘K Actions". Its keys come from the search
// field's own commands (arrows, ↵, ⇥, ⌫, Esc) and ⌘K from
// `AppShortcutMonitor` while it is open; it installs no key monitor.

struct OmniBarOverlay: View {
    let window: OmniBarWindow
    let request: OmniBarRequest
    let openProject: (CherryProject) -> Void
    let openSettings: () -> Void
    let restoreFocus: () -> Void

    @ObservedObject private var chromeState: ProjectWindowChromeState
    @StateObject private var live: OmniBarLiveModel
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(CommandPaletteDesign.usesGlassKey) private var usesGlass = CommandPaletteDesign.defaultUsesGlass
    @AppStorage(CommandPaletteDesign.cornerRadiusKey) private var cornerRadius = CommandPaletteDesign.defaultCornerRadius
    @AppStorage(CommandPaletteDesign.panelWidthKey) private var panelWidth = CommandPaletteDesign.defaultPanelWidth
    @AppStorage(CommandPaletteDesign.scrimOpacityKey) private var scrimOpacity = CommandPaletteDesign.defaultScrimOpacity
    @AppStorage(CommandPaletteDesign.animatesEntranceKey) private var animatesEntrance = CommandPaletteDesign.defaultAnimatesEntrance

    @State private var didAppear = false
    @State private var focusRequest = 0
    @State private var editingAgent: AgentToolDefinition?
    @State private var agentError: String?
    @State private var removalCandidate: GitWorktree?
    @State private var worktreeRemovalError: String?
    @State private var isRemovingWorktree = false

    init(
        window: OmniBarWindow,
        request: OmniBarRequest,
        openProject: @escaping (CherryProject) -> Void,
        openSettings: @escaping () -> Void,
        restoreFocus: @escaping () -> Void
    ) {
        self.window = window
        self.request = request
        self.openProject = openProject
        self.openSettings = openSettings
        self.restoreFocus = restoreFocus
        _chromeState = ObservedObject(wrappedValue: window.chromeState)
        // Made once, when the bar first shows (the autoclosure).
        _live = StateObject(wrappedValue: OmniBarLiveModel.make(for: window, at: request.scope))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(scrimOpacity)
                .opacity(didAppear ? 1 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            OmniBarPanel(
                controller: live.controller,
                focusRequest: focusRequest,
                errorMessage: worktreeRemovalError,
                panelWidth: CGFloat(panelWidth)
            )
            .modifier(CommandPaletteSurface(
                usesGlass: usesGlass,
                cornerRadius: CGFloat(cornerRadius),
                colorScheme: colorScheme
            ))
            .scaleEffect(didAppear ? 1 : 0.97, anchor: .top)
            .opacity(didAppear ? 1 : 0)
            .padding(.horizontal, 20)
            .padding(.top, 86)
        }
        .onAppear {
            let controller = live.controller
            controller.run = { handle($0) }
            controller.recordUse = { OmniFrecencyStore.shared.recordUse(id: $0) }
            controller.close = { dismiss() }
            ExternalEditorDiscovery.shared.refresh()
            live.start()
            focusRequest &+= 1
            if animatesEntrance {
                withAnimation(.snappy(duration: 0.18)) { didAppear = true }
            } else {
                didAppear = true
            }
        }
        .onDisappear { live.stop() }
        .onChange(of: request) { _, request in
            live.controller.open(at: request.scope)
            focusRequest &+= 1
        }
        .onChange(of: chromeState.omniBarActionsRequest) { _, _ in
            if !live.controller.toggleActions() { NSSound.beep() }
        }
        .sheet(item: $editingAgent) { agent in
            AgentToolEditor(
                agent: agent,
                canDelete: false,
                errorMessage: agentError,
                onSave: { updated in
                    do {
                        try AgentSettings.shared.upsertAgent(updated)
                        agentError = nil
                        editingAgent = nil
                        dismiss()
                    } catch {
                        agentError = error.localizedDescription
                    }
                },
                onDelete: {
                    agentError = nil
                    editingAgent = nil
                    dismiss()
                },
                onCancel: {
                    agentError = nil
                    editingAgent = nil
                    focusRequest &+= 1
                }
            )
        }
        .alert(
            "Remove Worktree?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            presenting: removalCandidate
        ) { worktree in
            Button("Cancel", role: .cancel) {
                removalCandidate = nil
                focusRequest &+= 1
            }
            Button(OmniWorktreeRemoval.confirmationButtonTitle(for: worktree, repository: window.repository), role: .destructive) {
                remove(worktree)
            }
        } message: { worktree in
            Text(OmniWorktreeRemoval.confirmationMessage(for: worktree, repository: window.repository))
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Omni bar")
    }

    private var performer: OmniBarPerformer {
        let chromeState = window.chromeState
        let live = live
        let colorScheme = colorScheme
        return OmniBarPerformer(
            window: window,
            settings: .shared,
            registry: .shared,
            backgroundSessionsModel: { .shared },
            switcher: ProjectSwitcherActions(
                settings: .shared,
                chromeState: chromeState,
                openProject: openProject,
                openSettings: openSettings
            ),
            editorDiscovery: .shared,
            projects: { live.controller.sources.projects },
            openSettings: openSettings,
            toggleAppearance: { TerminalSettings.shared.toggleLightDarkAppearance(currentColorScheme: colorScheme) }
        )
    }

    /// Runs a row: the bar closes first, then the action runs (an open
    /// panel or a new window comes after the bar has gone). Removing a
    /// worktree and adding an agent ask in the bar's own alert and sheet.
    private func handle(_ command: OmniCommand) {
        switch command {
        case .removeWorktree(let root):
            worktreeRemovalError = nil
            removalCandidate = window.repository.worktrees.first { $0.root == root }
        case .configureAgentPreset(let id):
            agentError = nil
            editingAgent = AgentConfiguration.presets.first { $0.id == id }
        default:
            let performer = performer
            dismiss()
            DispatchQueue.main.async { performer.perform(command) }
        }
    }

    private func remove(_ worktree: GitWorktree) {
        guard !isRemovingWorktree else { return }
        isRemovingWorktree = true
        worktreeRemovalError = nil
        let repository = window.repository
        let chromeState = window.chromeState
        Task {
            defer {
                isRemovingWorktree = false
                removalCandidate = nil
            }
            do {
                try await repository.remove(worktree, force: true, chromeState: chromeState)
                dismiss()
            } catch {
                worktreeRemovalError = error.localizedDescription
                focusRequest &+= 1
            }
        }
    }

    private func dismiss() {
        live.stop()
        window.chromeState.dismissOmniBar()
        restoreFocus()
    }
}

/// The confirmation removing a worktree asks for (the command palette's).
enum OmniWorktreeRemoval {
    @MainActor
    static func confirmationButtonTitle(for worktree: GitWorktree, repository: RepositoryWorkspace) -> String {
        if worktree.isPrunable { return "Prune Entry" }
        if repository.dirtyByRoot[worktree.root] == true || worktree.isLocked {
            return "Remove Anyway"
        }
        return "Remove Worktree"
    }

    @MainActor
    static func confirmationMessage(for worktree: GitWorktree, repository: RepositoryWorkspace) -> String {
        if worktree.isPrunable {
            return "The checkout at \(worktree.root) is already missing. Cherry will prune its stale Git entry."
        }
        var details: [String] = []
        let processCount = repository.workspaceIfLoaded(for: worktree.root)?
            .sessionsWithRunningProcess().count ?? 0
        if processCount > 0 {
            details.append("stop \(processCount) running process\(processCount == 1 ? "" : "es")")
        }
        if repository.dirtyByRoot[worktree.root] == true {
            details.append("permanently discard modified and untracked files")
        }
        if worktree.isLocked {
            details.append("override its Git lock")
        }
        let consequences = details.isEmpty
            ? "remove the checkout"
            : details.joined(separator: ", ") + ", and remove the checkout"
        return "Cherry will \(consequences) at \(worktree.root). Its branch will be kept."
    }
}

// MARK: - The panel

private struct OmniBarPanel: View {
    @ObservedObject var controller: OmniBarController
    let focusRequest: Int
    let errorMessage: String?
    let panelWidth: CGFloat

    @AppStorage(CommandPaletteDesign.rowHeightKey) private var rowHeight = CommandPaletteDesign.defaultRowHeight
    @AppStorage(CommandPaletteDesign.highlightsMatchesKey) private var highlightsMatches = CommandPaletteDesign.defaultHighlightsMatches
    /// Hover selects only when the pointer itself moves: a row that moves
    /// under a still pointer (keys scrolling the list, the rows changing)
    /// never takes the selection. A reference, so pointer moves do not
    /// redraw the panel.
    @State private var pointer = OmniPointerTracker()

    private static let topMarkerID = "omni-bar-top"
    private static let maximumListHeight: CGFloat = 400
    private static let headerHeight: CGFloat = 25

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(controller.stack.enumerated()), id: \.offset) { _, scope in
                    OmniBarCrumb(label: scope.label)
                }
                CommandPaletteSearchField(
                    text: Binding(get: { controller.query }, set: { controller.setQuery($0) }),
                    placeholder: controller.placeholder,
                    focusRequest: focusRequest,
                    onSubmit: {},
                    accessibilityLabel: controller.scope.map { "Search \($0.label)" } ?? "Search everything",
                    onCommand: handleCommand
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider().opacity(0.6)

            list
                .overlay(alignment: .bottomTrailing) {
                    if controller.isActionListOpen {
                        OmniBarActionList(controller: controller)
                            .padding(8)
                    }
                }

            Divider().opacity(0.6)

            footer
        }
        .frame(width: panelWidth)
        // Where the pointer rests as the bar opens selects nothing.
        .onAppear { pointer.reset(to: NSEvent.mouseLocation) }
    }

    private var list: some View {
        let sections = controller.sections
        let rowCount = sections.reduce(0) { $0 + $1.rows.count }
        let headers = sections.filter { $0.title != nil }.count
        let contentHeight = rowCount == 0
            ? 80
            : CGFloat(rowCount) * CGFloat(rowHeight) + CGFloat(headers) * Self.headerHeight + 12
        // Tall enough for the ⌘K list over it.
        let actionListHeight = controller.isActionListOpen
            ? CGFloat(controller.selectedActions.count) * OmniBarActionList.rowHeight + 26
            : 0
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 6).id(Self.topMarkerID)
                    if rowCount == 0 {
                        Text("No results")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 68)
                    }
                    ForEach(sections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                .frame(height: Self.headerHeight, alignment: .bottomLeading)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.rows) { row in
                            // The row reads the selection itself (by id), so
                            // exactly the selected row looks selected even
                            // when the lazy stack keeps a row's view.
                            OmniBarSelectableRow(
                                controller: controller,
                                row: row,
                                height: CGFloat(rowHeight),
                                highlightsMatches: highlightsMatches
                            )
                            .id(row.id)
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                guard case .active = phase, pointer.moved(to: NSEvent.mouseLocation) else { return }
                                controller.hover(id: row.id)
                            }
                            .onTapGesture {
                                controller.select(id: row.id)
                                controller.activate()
                            }
                            .accessibilityAction {
                                controller.select(id: row.id)
                                controller.activate()
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(contentHeight, actionListHeight), Self.maximumListHeight))
            .onChange(of: controller.scrollRequest) { _, _ in
                // anchor nil: the least scrolling that shows the row whole
                // (headers make offsets unpredictable). The first row
                // scrolls to the top so its section's header shows too.
                if controller.selection == 0 {
                    proxy.scrollTo(Self.topMarkerID, anchor: .top)
                } else if let id = controller.selectedItem?.id {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
            .onChange(of: controller.resetScrollRequest) { _, _ in
                proxy.scrollTo(Self.topMarkerID, anchor: .top)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(controller.hint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("↵ \(controller.primaryLabel)")
            Text("⌘K Actions")
                .opacity(controller.selectedActions.isEmpty ? 0.45 : 1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .accessibilityElement(children: .combine)
    }

    /// The search field's key commands.
    private func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            controller.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            controller.moveSelection(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            controller.moveSelection(by: -8)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            controller.moveSelection(by: 8)
        case #selector(NSResponder.insertNewline(_:)):
            controller.activate()
        case #selector(NSResponder.insertTab(_:)):
            if !controller.drillIntoSelection() { NSSound.beep() }
        case #selector(NSResponder.insertBacktab(_:)):
            break
        case #selector(NSResponder.cancelOperation(_:)):
            controller.escape()
        case #selector(NSResponder.deleteBackward(_:)):
            return controller.deleteBackwardOnEmptyField()
        default:
            return false
        }
        return true
    }

}

/// Tells a hover event of the pointer moving from one of a row moving
/// under a still pointer: only the first selects (the Raycast and
/// Spotlight model, where hovering moves the one selection). Fed the
/// pointer's screen location (`NSEvent.mouseLocation`), which a list
/// scrolling or changing leaves as it was.
final class OmniPointerTracker {
    private(set) var lastLocation: CGPoint?

    /// Where the pointer is now, selecting nothing (the bar opening).
    func reset(to location: CGPoint) {
        lastLocation = location
    }

    /// Whether the pointer moved since the last event; records `location`.
    /// The first location seen only sets where it is.
    func moved(to location: CGPoint) -> Bool {
        defer { lastLocation = location }
        guard let last = lastLocation else { return false }
        return abs(location.x - last.x) >= 0.5 || abs(location.y - last.y) >= 0.5
    }
}

/// App icons by bundle path (an editor row's), loaded once each; nil for an
/// app that is not there (the row keeps its symbol).
@MainActor
final class OmniAppIconCache {
    static let shared = OmniAppIconCache()

    private let exists: (String) -> Bool
    private let load: (String) -> NSImage
    private var icons: [String: NSImage] = [:]

    init(
        exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        load: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.exists = exists
        self.load = load
    }

    func icon(forAppAt path: String) -> NSImage? {
        if let icon = icons[path] { return icon }
        guard !path.isEmpty, exists(path) else { return nil }
        let icon = load(path)
        icons[path] = icon
        return icon
    }
}

/// What a row's icon column shows: an app's icon (full colour), else the
/// agent's logo (a template), else the SF Symbol.
enum OmniRowIcon {
    case app(NSImage)
    case logo(NSImage)
    case symbol(String)

    @MainActor
    static func resolve(
        _ item: OmniItem,
        appIcons: OmniAppIconCache = .shared,
        logo: (String) -> NSImage? = { AgentLogoLoader.image(named: $0) }
    ) -> OmniRowIcon {
        if let path = item.appPath, let icon = appIcons.icon(forAppAt: path) { return .app(icon) }
        if let name = item.logo, let image = logo(name) { return .logo(image) }
        return .symbol(item.symbol)
    }
}

/// A row that reads whether it is selected from the controller.
private struct OmniBarSelectableRow: View {
    @ObservedObject var controller: OmniBarController
    let row: OmniRow
    let height: CGFloat
    let highlightsMatches: Bool

    var body: some View {
        OmniBarRow(
            row: row,
            isSelected: controller.isSelected(row),
            height: height,
            highlightsMatches: highlightsMatches
        )
    }
}

private struct OmniBarCrumb: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.12)))
            .fixedSize()
            .accessibilityLabel("Scope: \(label)")
    }
}

enum OmniBarColors {
    static let working = Color(red: 0.91, green: 0.64, blue: 0.24)
    static let idle = Color(red: 0.44, green: 0.75, blue: 0.45)
    static let offline = Color(white: 0.45)

    static func color(_ status: OmniStatus) -> Color {
        switch status {
        case .working: working
        case .idle: idle
        case .offline: offline
        }
    }
}

private struct OmniBarRow: View {
    let row: OmniRow
    let isSelected: Bool
    let height: CGFloat
    let highlightsMatches: Bool

    var body: some View {
        HStack(spacing: 11) {
            icon
                .frame(width: 18)
                .accessibilityHidden(true)
            title
                .font(.system(size: 14))
                // A new match (or none) is a new title: no bold kept from
                // an earlier query.
                .id(row.matched)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let status = row.item.status {
                Circle()
                    .fill(OmniBarColors.color(status))
                    .frame(width: 6, height: 6)
            }
            if !row.item.detail.isEmpty {
                Text(row.item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0.5)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.item.accessibilityLabel)
        .accessibilityHint(row.item.actions.isEmpty ? row.item.primaryLabel : "\(row.item.primaryLabel). Command-K for actions.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// An editor's app icon in full colour; the agent's logo as a
    /// template, tinted like the symbols (the menu-bar agent list's
    /// `AgentLogoLoader`); else the SF Symbol.
    @ViewBuilder
    private var icon: some View {
        switch OmniRowIcon.resolve(row.item) {
        case .app(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
        case .logo(let image):
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(.secondary)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var title: Text {
        let characters = Array(row.item.title)
        guard highlightsMatches, !row.matched.isEmpty else {
            return Text(row.item.title).foregroundStyle(.primary)
        }
        let matched = Set(row.matched)
        var attributed = AttributedString()
        for (index, character) in characters.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(index) {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .primary
            } else {
                piece.foregroundColor = Color.primary.opacity(0.82)
            }
            attributed += piece
        }
        return Text(attributed)
    }
}

/// ⌘K: the selected row's actions, over the list's bottom-trailing corner.
private struct OmniBarActionList: View {
    static let rowHeight: CGFloat = 30

    @ObservedObject var controller: OmniBarController

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.selectedActions.enumerated()), id: \.element.id) { index, action in
                Text(action.title)
                    .font(.system(size: 13))
                    .foregroundStyle(action.isDestructive ? Color(red: 1, green: 0.45, blue: 0.5) : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: Self.rowHeight)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(index == controller.actionSelection ? Color.primary.opacity(0.12) : .clear)
                    }
                    .contentShape(Rectangle())
                    .onHover { if $0 { controller.hoverAction(index) } }
                    .onTapGesture { controller.runAction(at: index) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(action.title)
                    .accessibilityAddTraits(index == controller.actionSelection ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { controller.runAction(at: index) }
            }
        }
        .padding(5)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(controller.selectedItem?.title ?? "the selected row")")
    }
}
