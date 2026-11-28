import AppKit
import SwiftUI

// The Omni bar's view (design D): one floating bar with the search field
// and the scope's crumb, one list of rows, and a footer with a hint and
// key caps for "Actions ⌘K" and "<primary> ↵". Rows show a command's
// shortcut, a chevron when ↵ opens a list, and a project's, Mac's or tab's
// detail on a second line; root results are grouped by kind (`OmniSections.grouped`).
// Its keys come from the search field's own commands (arrows, ↵, ⇥, ⌫, Esc) and ⌘K from
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
    @AppStorage(CommandPaletteDesign.animatesEntranceKey) private var animatesEntrance = CommandPaletteDesign.defaultAnimatesEntrance

    /// The playground's sizes, read again when the defaults change.
    @State private var metrics = OmniBarMetrics.current()
    @State private var didAppear = false
    @State private var focusRequest = 0
    @State private var editingAgent: AgentToolDefinition?
    @State private var agentError: String?

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
            Color.black.opacity(metrics[.scrimOpacity])
                .opacity(didAppear ? 1 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            OmniBarPanel(
                controller: live.controller,
                focusRequest: focusRequest
            )
            .modifier(CommandPaletteSurface(
                usesGlass: usesGlass,
                cornerRadius: metrics[.cornerRadius],
                colorScheme: colorScheme
            ))
            .scaleEffect(didAppear ? 1 : 0.97, anchor: .top)
            .opacity(didAppear ? 1 : 0)
            .padding(.horizontal, 20)
            .padding(.top, metrics[.topOffset])
        }
        .environment(\.omniBarMetrics, metrics)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let current = OmniBarMetrics.current()
            if current != metrics { metrics = current }
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
                        try AgentSettings.shared.addAgent(updated)
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
            switcher: ProjectSwitcherActions(settings: .shared, chromeState: chromeState, openProject: openProject),
            editorDiscovery: .shared,
            projects: { live.controller.sources.projects },
            openSettings: openSettings,
            toggleAppearance: { TerminalSettings.shared.toggleLightDarkAppearance(currentColorScheme: colorScheme) }
        )
    }

    /// Runs a row: the bar closes first, then the action runs (an open
    /// panel or a new window comes after the bar has gone). Adding an agent
    /// asks in the bar's own sheet.
    private func handle(_ command: OmniCommand) {
        switch command {
        case .configureAgentPreset(let id):
            agentError = nil
            editingAgent = AgentConfiguration.presets.first { $0.id == id }
        case .connectDevice:
            // The bar stays: the Mac's folders list once it is connected.
            performer.perform(command)
            focusRequest &+= 1
        default:
            let performer = performer
            dismiss()
            DispatchQueue.main.async { performer.perform(command) }
        }
    }

    private func dismiss() {
        live.stop()
        window.chromeState.dismissOmniBar()
        restoreFocus()
    }
}

// MARK: - The panel

private struct OmniBarPanel: View {
    @ObservedObject var controller: OmniBarController
    let focusRequest: Int

    @Environment(\.omniBarMetrics) private var metrics
    @AppStorage(CommandPaletteDesign.highlightsMatchesKey) private var highlightsMatches = CommandPaletteDesign.defaultHighlightsMatches
    /// Hover selects only when the pointer itself moves: a row that moves
    /// under a still pointer (keys scrolling the list, the rows changing)
    /// never takes the selection. A reference, so pointer moves do not
    /// redraw the panel.
    @State private var pointer = OmniPointerTracker()

    private static let topMarkerID = "omni-bar-top"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: metrics[.searchIconSize], weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ForEach(Array(controller.stack.enumerated()), id: \.offset) { _, scope in
                    OmniBarCrumb(label: scope.label)
                }
                CommandPaletteSearchField(
                    text: Binding(get: { controller.query }, set: { controller.setQuery($0) }),
                    placeholder: controller.placeholder,
                    focusRequest: focusRequest,
                    accessibilityLabel: controller.scope.map { "Search \($0.label)" } ?? "Search everything",
                    fontSize: metrics[.searchFontSize],
                    onCommand: handleCommand
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !controller.query.isEmpty {
                    Button {
                        controller.setQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: metrics[.searchIconSize] + 1))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, metrics[.searchPadding])
            .frame(height: metrics[.searchHeight])

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
        .frame(width: metrics[.panelWidth])
        // Where the pointer rests as the bar opens selects nothing.
        .onAppear { pointer.reset(to: NSEvent.mouseLocation) }
    }

    private var list: some View {
        let sections = controller.sections
        let rowCount = sections.reduce(0) { $0 + $1.rows.count }
        let headers = sections.filter { $0.title != nil }.count
        let rowsHeight = sections.reduce(CGFloat(0)) { total, section in
            section.rows.reduce(total) { $0 + Self.height(of: $1, metrics: metrics) }
        }
        let contentHeight = rowCount == 0
            ? 80
            : rowsHeight + CGFloat(headers) * metrics[.headerHeight] + 4 + metrics[.listBottomPadding]
        // Tall enough for the ⌘K list over it.
        let actionListHeight = controller.isActionListOpen
            ? CGFloat(controller.selectedActions.count) * metrics[.actionRowHeight] + 26
            : 0
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 4).id(Self.topMarkerID)
                    if rowCount == 0 {
                        HStack(spacing: 8) {
                            if controller.emptyState.isLoading {
                                ProgressView().controlSize(.small)
                            }
                            Text(controller.emptyState.text)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(sections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(.system(size: metrics[.headerFontSize], weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, metrics[.rowPadding])
                                .padding(.bottom, 3)
                                .frame(height: metrics[.headerHeight], alignment: .bottomLeading)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.rows, id: \.viewID) { row in
                            // The row reads the selection itself (by id), so
                            // exactly the selected row looks selected even
                            // when the lazy stack keeps a row's view.
                            OmniBarSelectableRow(
                                controller: controller,
                                row: row,
                                height: Self.height(of: row, metrics: metrics),
                                highlightsMatches: highlightsMatches
                            )
                            .id(row.viewID)
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
                .padding(.horizontal, metrics[.listInset])
                .padding(.bottom, metrics[.listBottomPadding])
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(contentHeight, actionListHeight), metrics[.maximumListHeight]))
            .onChange(of: controller.scrollRequest) { _, _ in
                // anchor nil: the least scrolling that shows the row whole
                // (headers make offsets unpredictable). The first row
                // scrolls to the top so its section's header shows too.
                if controller.selection == 0 {
                    proxy.scrollTo(Self.topMarkerID, anchor: .top)
                } else if let row = controller.rows.first(where: controller.isSelected) {
                    proxy.scrollTo(row.viewID, anchor: nil)
                }
            }
            .onChange(of: controller.resetScrollRequest) { _, _ in
                proxy.scrollTo(Self.topMarkerID, anchor: .top)
            }
        }
    }

    /// A row with its detail under the title is taller.
    static func height(of row: OmniRow, metrics: OmniBarMetrics) -> CGFloat {
        row.item.showsDetailBelowTitle ? metrics[.rowHeight] + metrics[.twoLineExtraHeight] : metrics[.rowHeight]
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(controller.hint)
                .frame(maxWidth: .infinity, alignment: .leading)
            OmniFooterKey(label: "Actions", key: "⌘K")
                .opacity(controller.selectedActions.isEmpty ? 0.45 : 1)
            OmniFooterKey(label: controller.primaryLabel, key: "↵")
        }
        .font(.system(size: metrics[.footerFontSize]))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // Clear of the panel's rounded corners: at least half the radius in.
        .padding(.horizontal, max(metrics[.footerPadding], metrics[.cornerRadius] * 0.6))
        .frame(height: metrics[.footerHeight])
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

extension OmniRow {
    /// The row's view in the list: a new match (or none) is a new view, so
    /// the lazy list never keeps the bold of an earlier query.
    var viewID: String { "\(id)|\(matched.map(String.init).joined(separator: ","))" }
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
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.omniBarMetrics) private var metrics
    let row: OmniRow
    let isSelected: Bool
    let height: CGFloat
    let highlightsMatches: Bool

    var body: some View {
        HStack(spacing: metrics[.iconSpacing]) {
            icon
                .frame(width: metrics[.iconColumnWidth])
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(.system(size: metrics[.titleFontSize]))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.item.showsDetailBelowTitle {
                    subtitle
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let status = row.item.status {
                Circle()
                    .fill(OmniBarColors.color(status))
                    .frame(width: 6, height: 6)
            }
            if !row.item.showsDetailBelowTitle {
                if !row.item.detail.isEmpty {
                    Text(row.item.detail)
                        .font(.system(size: metrics[.detailFontSize] + 0.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(0.5)
                }
                if !row.item.machineName.isEmpty {
                    machineLabel
                        // A path gives way before the Mac's name.
                        .layoutPriority(0.6)
                }
            }
            if !row.item.shortcut.isEmpty {
                Text(row.item.shortcut)
                    .font(.system(size: metrics[.shortcutFontSize]))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if row.item.opensList {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, metrics[.rowPadding])
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: metrics[.rowCornerRadius], style: .continuous)
                .fill(isSelected ? Color.primary.opacity(metrics[.selectionOpacity]) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: metrics[.rowCornerRadius], style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.item.accessibilityLabel)
        .accessibilityHint(row.item.actions.isEmpty ? row.item.primaryLabel : "\(row.item.primaryLabel). Command-K for actions.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The second line: the detail, then the Mac in its colour.
    private var subtitle: some View {
        HStack(spacing: 4) {
            if !row.item.detail.isEmpty {
                Text(row.item.detail)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            if !row.item.detail.isEmpty, !row.item.machineName.isEmpty {
                Text("·").foregroundStyle(.tertiary)
            }
            if !row.item.machineName.isEmpty {
                machineLabel
            }
        }
        .font(.system(size: metrics[.detailFontSize]))
        .lineLimit(1)
    }

    private var machineLabel: some View {
        Text(row.item.machineName)
            .font(.system(size: metrics[.detailFontSize], weight: row.item.machineColor == nil ? .regular : .medium))
            .foregroundStyle(machineStyle)
            .lineLimit(1)
    }

    /// A row on another Mac names it in its colour.
    private var machineStyle: AnyShapeStyle {
        guard let color = row.item.machineColor else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(color.color(for: colorScheme))
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
                .frame(width: metrics[.iconSize] + 2.5, height: metrics[.iconSize] + 2.5)
        case .logo(let image):
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: metrics[.iconSize] + 1.5, height: metrics[.iconSize] + 1.5)
                .foregroundStyle(.secondary)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: metrics[.iconSize], weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var title: Text {
        // Always one attributed text, every character's weight set: a
        // plain `Text` in place of a highlighted one could keep its bold
        // when the lazy list reuses the row.
        let matched = highlightsMatches ? Set(row.matched) : []
        var attributed = AttributedString()
        for (index, character) in row.item.title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(index) {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .primary
            } else {
                piece.inlinePresentationIntent = []
                piece.foregroundColor = matched.isEmpty ? .primary : Color.primary.opacity(0.82)
            }
            attributed += piece
        }
        return Text(attributed)
    }
}

/// A footer hint: its label, then its key in a key cap.
private struct OmniFooterKey: View {
    @Environment(\.omniBarMetrics) private var metrics
    let label: String
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            Text(key)
                .font(.system(size: metrics[.keyCapFontSize], weight: .medium))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                }
        }
    }
}

/// ⌘K: the selected row's actions, over the list's bottom-trailing corner.
private struct OmniBarActionList: View {
    @ObservedObject var controller: OmniBarController
    @Environment(\.omniBarMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.selectedActions.enumerated()), id: \.element.id) { index, action in
                Text(action.title)
                    .font(.system(size: 13))
                    .foregroundStyle(action.isDestructive ? Color(red: 1, green: 0.45, blue: 0.5) : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: metrics[.actionRowHeight])
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
        .frame(width: metrics[.actionListWidth])
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
