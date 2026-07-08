import AppKit
import SwiftUI

// A menu-bar (NSStatusItem via SwiftUI `MenuBarExtra`) summary of every live agent
// across all project windows, with a glanceable aggregate state on the icon and a
// click-to-focus list grouped by project. The per-agent state comes from
// `TerminalSession.agentActivityState`; see the activity state machine for how idle
// vs working vs permission is decided.

// MARK: - Snapshot

/// The worst-case state across all live agents, shown as a badge on the menu-bar icon.
/// Priority: a pending permission prompt (needs the user now) outranks everything.
enum MenuBarAggregateState: Equatable {
    case none        // no live agents
    case idle        // agents present, all idle
    case working
    case attention   // at least one agent is waiting on a permission prompt
    case error

    init(items: [MenuBarAgentItem]) {
        if items.isEmpty {
            self = .none
        } else if items.contains(where: { $0.activity == .permission }) {
            self = .attention
        } else if items.contains(where: { $0.activity == .error }) {
            self = .error
        } else if items.contains(where: { $0.activity == .working }) {
            self = .working
        } else {
            self = .idle
        }
    }

}

struct MenuBarAgentItem: Equatable, Identifiable {
    let id: UUID
    let projectRoot: String
    let title: String
    let agentKey: String
    let activity: AgentActivityState
}

struct MenuBarProjectGroup: Equatable, Identifiable {
    let projectRoot: String
    let projectName: String
    let items: [MenuBarAgentItem]
    var id: String { projectRoot }
}

// MARK: - Model

/// Drives the working-state breath of the menu-bar glyph: a slow fade of the top
/// layer between the full glyph color and a dim gray.
///
/// Two hard-won constraints shape this:
/// - It must NOT be a `TimelineView` in the `MenuBarExtra` label: that livelocks
///   SwiftUI's status-item update loop at launch (requestUpdate → setImage →
///   requestUpdate never drains) and the app never finishes launching.
/// - It must NOT publish through `MenuBarAgentsModel`: `CherryApp` holds that model
///   as `@StateObject`, so every publish re-evaluates the entire App body and the
///   dropdown panel — at pulse rate that costs ~11% CPU. A separate object observed
///   only by the status label keeps each tick's invalidation to the tiny label view.
///
/// One timer tick per step: quantizing the breath into a fixed alpha table keeps the
/// tick rate low and gives every frame a stable alpha, so the label can reuse a small
/// set of cached NSImages instead of baking a fresh symbol image per frame.
@MainActor
final class MenuBarPulseModel: ObservableObject {
    static let shared = MenuBarPulseModel()

    @Published private(set) var alpha: CGFloat = 1.0

    private var timer: Timer?
    private var step = 0
    // A 4s breath at 4 ticks/s: every status-item update costs real main-thread time
    // (label snapshot → setImage → length adjust, ~1% CPU per tick/s), so the rate is
    // as low as the fade stays smooth. The range tops out at 0.9 so working never
    // momentarily reads as idle at the peak of the breath.
    private static let period: TimeInterval = 4.0
    private static let steps = 16
    private static let alphas: [CGFloat] = (0..<steps).map {
        0.65 + 0.25 * sin(CGFloat($0) / CGFloat(steps) * 2 * .pi)
    }

    func setActive(_ active: Bool) {
        if active, timer == nil {
            let timer = Timer(timeInterval: Self.period / Double(Self.steps), repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                MainActor.assumeIsolated {
                    self.step = (self.step + 1) % Self.steps
                    self.alpha = Self.alphas[self.step]
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !active, let timer {
            timer.invalidate()
            self.timer = nil
            step = 0
            alpha = 1.0
        }
    }
}

@MainActor
final class MenuBarAgentsModel: ObservableObject {
    @Published private(set) var groups: [MenuBarProjectGroup] = []
    @Published private(set) var aggregate: MenuBarAggregateState = .none

    private var timer: Timer?

    init() {
        refresh()
        // A light 1s poll keeps the glanceable icon current without wiring Combine
        // across a set of workspaces/sessions/windows that churns as windows open and
        // close. It only reads cheap published properties (never probes the process
        // table) and republishes solely when the deduped snapshot actually changes.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        var groups: [MenuBarProjectGroup] = []
        for (root, workspace) in ProjectWindowRegistry.shared.workspacesByProjectRoot() {
            let agents = workspace.runningAgentSessions
            guard !agents.isEmpty else { continue }
            let items = agents.map { session in
                MenuBarAgentItem(
                    id: session.id,
                    projectRoot: root,
                    title: session.title,
                    agentKey: AgentToolDefinition.normalizedName(session.agentName ?? session.title),
                    activity: session.agentActivityState
                )
            }
            let name = URL(fileURLWithPath: root, isDirectory: true).lastPathComponent
            groups.append(MenuBarProjectGroup(
                projectRoot: root,
                projectName: name.isEmpty ? "Cherry" : name,
                items: items
            ))
        }
        groups.sort { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
        apply(groups: groups)
    }

    private func apply(groups: [MenuBarProjectGroup]) {
        let aggregate = MenuBarAggregateState(items: groups.flatMap(\.items))
        if groups != self.groups { self.groups = groups }
        if aggregate != self.aggregate { self.aggregate = aggregate }
        MenuBarPulseModel.shared.setActive(aggregate == .working)
    }

    func reveal(_ item: MenuBarAgentItem) {
        ProjectWindowRegistry.shared.revealSession(id: item.id, projectRoot: item.projectRoot)
    }
}

// MARK: - Per-state presentation

extension AgentActivityState {
    var menuBarColor: Color {
        switch self {
        case .idle: Color(nsColor: .systemGreen)
        case .working: Color(nsColor: .systemBlue)
        case .permission: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
        case .unknown: Color(nsColor: .tertiaryLabelColor)
        }
    }

    var menuBarLabel: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .permission: "needs input"
        case .error: "error"
        case .unknown: "starting…"
        }
    }
}

// MARK: - Menu-bar icon (app brandmark + state badge)

struct MenuBarStatusLabel: View {
    @ObservedObject var model: MenuBarAgentsModel
    @ObservedObject private var pulse = MenuBarPulseModel.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: Self.cachedIcon(for: model.aggregate, dark: colorScheme == .dark, pulseAlpha: pulse.alpha))
            .accessibilityLabel("Cherry agents")
    }

    // Reuse one NSImage per (state, appearance, pulse step): the pulse revisits the
    // same alpha table every cycle, and handing AppKit the same instance lets its
    // symbol rasterization cache hit instead of re-rendering a fresh image per frame.
    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor
    private static func cachedIcon(for state: MenuBarAggregateState, dark: Bool, pulseAlpha: CGFloat) -> NSImage {
        let key = "\(state)|\(dark)|\(Int((pulseAlpha * 1000).rounded()))"
        if let cached = iconCache[key] { return cached }
        let image = icon(paletteColors: paletteColors(for: state, dark: dark, pulseAlpha: pulseAlpha))
        iconCache[key] = image
        return image
    }

    // The state is carried by the glyph itself: idle / no-agents stay monochrome,
    // working breathes the top layer between the glyph color and a dim gray, and
    // needs-input / error tint the whole glyph orange / red. Every state renders
    // through the same symbol image (mono states just pass a single glyph color) so
    // the icon never changes size between states. MenuBarExtra flattens a colored
    // SwiftUI label to a template, so the image is baked non-template; the glyph
    // color follows the current appearance.
    private static func paletteColors(for state: MenuBarAggregateState, dark: Bool, pulseAlpha: CGFloat) -> [NSColor] {
        let glyph: NSColor = dark ? .white : NSColor(white: 0.12, alpha: 1)
        switch state {
        case .none, .idle: return [glyph]
        case .working: return [glyph.withAlphaComponent(pulseAlpha), glyph]
        case .attention: return [.systemOrange]
        case .error: return [.systemRed]
        }
    }

    @MainActor
    private static func icon(paletteColors: [NSColor]) -> NSImage {
        let base = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil) ?? NSImage()
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: paletteColors))
        let image = base.withSymbolConfiguration(configuration) ?? base
        image.isTemplate = false
        return image
    }
}

// MARK: - Dropdown panel

struct MenuBarAgentsPanel: View {
    @ObservedObject var model: MenuBarAgentsModel
    @State private var listHeight: CGFloat = 96

    // Grow the panel to fit its rows so a handful of agents never scrolls; only once
    // the list would exceed this height does it start scrolling.
    private static let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.groups.isEmpty {
                Text("No active agents")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    agentList
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, Self.maxListHeight))
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider()

            footer
        }
        .frame(width: 300)
    }

    private var agentList: some View {
        // The project header is always shown, even for a single project, so it's
        // always clear which window an agent belongs to.
        VStack(alignment: .leading, spacing: 1) {
            ForEach(model.groups) { group in
                Text(Self.projectTitle(group.projectName))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(group.items) { item in
                    MenuBarAgentRow(item: item) { model.reveal(item) }
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(spacing: 1) {
            SettingsLink {
                MenuBarActionLabel(title: "Settings…", shortcut: "⌘,")
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                MenuBarActionLabel(title: "Quit Cherry", shortcut: "⌘Q")
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 5)
        .padding(.bottom, 6)
    }

    // Project folder names are usually lowercase; show them sentence-cased (no
    // all-caps) so the section header reads like a native grouped menu.
    private static func projectTitle(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }
}

private struct MenuBarAgentRow: View {
    let item: MenuBarAgentItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                MenuBarAgentGlyph(agentKey: item.agentKey)
                    .frame(width: 14, height: 14)
                Text(item.title.isEmpty ? "Agent" : item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                HStack(spacing: 7) {
                    Text(item.activity.menuBarLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(item.activity.menuBarColor)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(MenuBarRowHighlight(isActive: isHovering))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 6)
    }
}

// Brand glyph for the agent (Claude, Codex, …), rendered as a template so it tints
// to the label color and reads consistently in both light and dark menus. Falls back
// to a neutral terminal glyph so the leading column stays aligned for every row.
private struct MenuBarAgentGlyph: View {
    let agentKey: String

    var body: some View {
        if let name = Self.logoResource(for: agentKey), let image = Self.logo(named: name) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(Color.primary.opacity(0.85))
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private static func logoResource(for key: String) -> String? {
        switch key {
        case "claude": "claude"
        case "codex", "openai": "openai"
        case "gemini": "gemini"
        case "amp": "amp"
        default: nil
        }
    }

    @MainActor private static var cache: [String: NSImage?] = [:]
    @MainActor private static func logo(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        // `.process` flattens the resource tree, so the SVGs live at the bundle root,
        // not under AgentLogos/ — try the subdirectory first, then the flattened path.
        let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "AgentLogos")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        cache[name] = image
        return image
    }
}

// A footer action row (Settings…, Quit) styled like the agent rows: label left,
// right-aligned tertiary ⌘-shortcut hint, neutral inset highlight on hover.
private struct MenuBarActionLabel: View {
    let title: String
    let shortcut: String?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(MenuBarRowHighlight(isActive: isHovering))
        .onHover { isHovering = $0 }
        .padding(.horizontal, 6)
    }
}

private struct MenuBarRowHighlight: View {
    let isActive: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isActive ? Color.primary.opacity(0.09) : Color.clear)
    }
}
