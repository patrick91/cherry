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

    // Distinct from the pink brandmark so the badge stays legible on top of it
    // (a pink "working" dot on the pink icon would vanish).
    var badgeColor: Color? {
        switch self {
        case .none: nil
        case .idle: Color(nsColor: .systemGreen)
        case .working: Color(nsColor: .systemBlue)
        case .attention: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MenuBarBrandIcon()
            if let color = model.aggregate.badgeColor {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .offset(x: 1.5, y: -1.5)
            }
        }
        .frame(width: 20, height: 18, alignment: .center)
        .accessibilityLabel("Cherry agents")
    }
}

private struct MenuBarBrandIcon: View {
    // The Cherry layered-stack motif as a monochrome template glyph. macOS tints it
    // to the menu-bar foreground — white on dark bars, black on light — so it reads
    // like the system icons beside it instead of a colored tile.
    var body: some View {
        Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: 15, weight: .regular))
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
